-- Casts: what the player and the target are casting right now.
--
-- On this client cast information is "SecretWhenUnitSpellCastRestricted" (API
-- docs): UnitCastingInfo / UnitChannelInfo may answer with values an addon may
-- hold and hand to a widget, but not read. So nothing here ever looks at a
-- name or an icon, and times are only used as numbers after issecretvalue()
-- said they are plain:
--
--   times readable -> own arithmetic, like the swing bars (spark, seconds left)
--   times secret   -> the bar is driven by the client: a cast duration object
--                     (UnitCastingDuration -> StatusBar:SetTimerDuration), or
--                     the secret start / end handed to StatusBar:SetMinMaxValues.
--                     UI/Bars.lua tries them in that order and reports which
--                     one the client accepted (/fct diag shows it).
--
-- One event frame per unit: even the unit in an event's payload may be secret,
-- the frame that received it is not.
local _, ns = ...

local Casts = {}
ns.Casts = Casts

local UNITS = { "player", "target" }
local SECRET_CAP = 120 -- a cast we cannot time is dropped after this long, whatever happens
local OVERRUN = 0.3    -- a timed cast is dropped this long after its end if no event said so
local MAX_SAMPLES = 16

Casts.UNITS = UNITS
Casts.current = {} -- [unit] = cast
Casts.samples = {} -- for /fct diag: what the client really handed us
local serial = 0

local BAR_OF = { player = "CAST", target = "TCAST" }

-- A cast bar that is set to "never" means: do not track that unit's casts at all.
local function enabled(unit)
    return ns.BarSettings:GetMode(BAR_OF[unit]) ~= "never"
end

local function pack(ok, ...)
    return ok, select("#", ...), ...
end

-- the duration object (possibly secret), and whether there is one
local function durationObject(fn, unit)
    if type(fn) ~= "function" then
        return nil, false
    end
    local ok, count, duration = pack(pcall(fn, unit))
    if ok and count > 0 and (ns.IsSecret(duration) or duration ~= nil) then
        return duration, true
    end
    return nil, false
end

-- kind, count, name, texture, startMS, endMS, spellID  (nil: not casting)
local function ask(unit)
    local ok, count, name, _, texture, startMS, endMS, _, _, _, spellID = pack(pcall(UnitCastingInfo, unit))
    if ok and count > 0 and (ns.IsSecret(name) or name ~= nil) then
        return "cast", count, name, texture, startMS, endMS, spellID
    end
    if UnitChannelInfo then
        ok, count, name, _, texture, startMS, endMS, _, _, spellID = pack(pcall(UnitChannelInfo, unit))
        if ok and count > 0 and (ns.IsSecret(name) or name ~= nil) then
            return "channel", count, name, texture, startMS, endMS, spellID
        end
    end
    return nil
end

------------------------------------------------------------------------
-- Casts that come from an ITEM - a sharpening stone, a bandage, the hearthstone - arrive with the
-- spell's icon, which for many of them is only a generic placeholder. Your own casts are never
-- secret, so the spell id can be matched against the "use" spells of what you carry and wear, and
-- the item's own icon shown instead.
------------------------------------------------------------------------
local itemIcons -- [spellID] = icon; nil: look again (the bags changed)

local function addItem(itemID)
    if type(itemID) ~= "number" or ns.IsSecret(itemID) then
        return
    end
    local ok, _, spellID = pcall(C_Item.GetItemSpell, itemID)
    if ok and type(spellID) == "number" and not ns.IsSecret(spellID) and not itemIcons[spellID] then
        local okIcon, icon = pcall(C_Item.GetItemIconByID, itemID)
        if okIcon and icon ~= nil and not ns.IsSecret(icon) then
            itemIcons[spellID] = icon
        end
    end
end

local function itemIconFor(spellID)
    if ns.IsSecret(spellID) or type(spellID) ~= "number" then
        return nil
    end
    if not (C_Item and C_Item.GetItemSpell and C_Item.GetItemIconByID) then
        return nil
    end
    if not itemIcons then
        itemIcons = {}
        if C_Container and C_Container.GetContainerNumSlots and C_Container.GetContainerItemID then
            for bag = 0, (NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4) do
                local okSlots, slots = pcall(C_Container.GetContainerNumSlots, bag)
                for slot = 1, (okSlots and type(slots) == "number" and slots) or 0 do
                    local okItem, itemID = pcall(C_Container.GetContainerItemID, bag, slot)
                    if okItem then
                        addItem(itemID)
                    end
                end
            end
        end
        if GetInventoryItemID then
            for slot = 1, 19 do -- trinkets and other worn items with a "use"
                local okItem, itemID = pcall(GetInventoryItemID, "player", slot)
                if okItem then
                    addItem(itemID)
                end
            end
        end
    end
    return itemIcons[spellID]
end

ns:On("BAG_UPDATE_DELAYED", function()
    itemIcons = nil
end)
ns:On("PLAYER_EQUIPMENT_CHANGED", function()
    itemIcons = nil
end)

-- The LAST few, not the first few. A report is read after somebody has played and noticed something
-- missing, so the samples worth keeping are the recent ones; the old behaviour filled up at login and
-- never recorded anything again.
--
-- And the spell's NAME, when the client will say it. Your own casts are never secret, so for the one
-- question these samples exist to answer - "did my Multi-Shot fire a cast event at all?" - the name is
-- the whole answer. Somebody else's may be secret, and then it is left out rather than looked at.
local function sample(unit, event, cast, count, payloadUnit, payloadSpell)
    local name = (not ns.IsSecret(cast.name) and type(cast.name) == "string") and cast.name or nil
    local spellID = (not ns.IsSecret(cast.spellID) and type(cast.spellID) == "number") and cast.spellID or nil
    local entry = {
        unit = unit, event = event, kind = cast.kind, returns = count,
        name = name, spellID = spellID,
        -- `length` is how long the cast IS. (`seconds` on this table is already taken, and means
        -- something else entirely: HOW the time left reaches the bar. ReportPath fills that in.)
        length = cast.timesReadable and cast.endTime and cast.startTime
            and math.floor((cast.endTime - cast.startTime) * 10) / 10 or nil,
        t = math.floor(GetTime() * 10) / 10,
        combat = InCombatLockdown() and true or false,
        secretName = ns.IsSecret(cast.name), secretTexture = ns.IsSecret(cast.texture),
        secretTimes = not cast.timesReadable, itemIcon = cast.fromItem or nil,
        secretPayloadUnit = ns.IsSecret(payloadUnit), secretPayloadSpell = ns.IsSecret(payloadSpell),
        durationObject = cast.hasDuration or false,
        path = "not shown yet",
    }
    cast.sample = entry
    Casts.samples[#Casts.samples + 1] = entry
    while #Casts.samples > MAX_SAMPLES do
        table.remove(Casts.samples, 1)
    end
end

-- Look at the unit again and replace what we know about it.
local function refresh(unit, event, payloadUnit, payloadSpell)
    if not enabled(unit) then
        Casts.current[unit] = nil
        return nil
    end
    local kind, count, name, texture, startMS, endMS, spellID = ask(unit)
    if not kind then
        Casts.current[unit] = nil
        return nil
    end
    local fromItem = false
    if unit == "player" then
        local icon = itemIconFor(spellID)
        if icon then
            texture, fromItem = icon, true
        end
    end
    serial = serial + 1
    local cast = { unit = unit, kind = kind, name = name, texture = texture, spellID = spellID,
        serial = serial, began = GetTime(),
        owner = Casts, drains = kind == "channel", -- (UI/Bars.lua shows casts and buffs with the same code)
        fromItem = fromItem }
    if not ns.AnySecret(startMS, endMS) and type(startMS) == "number" and type(endMS) == "number" and endMS > startMS then
        cast.timesReadable = true
        cast.startTime, cast.endTime = startMS / 1000, endMS / 1000
    else
        cast.timesReadable = false
        cast.secretStart, cast.secretEnd = startMS, endMS
        -- the object itself may count as secret: keep a plain flag next to it, never test the object
        cast.duration, cast.hasDuration = durationObject(kind == "channel" and UnitChannelDuration or UnitCastingDuration, unit)
    end
    local previous = Casts.current[unit]
    if previous and previous.sample and previous.kind == kind then
        cast.sample = previous.sample -- a pushback or a re-target of the same cast: one sample is enough
    elseif event then
        sample(unit, event, cast, count, payloadUnit, payloadSpell)
    end
    Casts.current[unit] = cast
    return cast
end

-- The cast of `unit` to show now, or nil.
function Casts:Get(unit, now)
    local cast = self.current[unit]
    if not cast then
        return nil
    end
    now = now or GetTime()
    if cast.timesReadable then
        if now > cast.endTime + OVERRUN then
            self.current[unit] = nil
            return nil
        end
    elseif now - cast.began > SECRET_CAP then
        self.current[unit] = nil
        return nil
    end
    return cast
end

-- fraction (what the bar shows: a channel drains), seconds remaining. Timed casts only.
function Casts:GetProgress(cast, now)
    local total = cast.endTime - cast.startTime
    local remaining = math.min(total, math.max(0, cast.endTime - now))
    local fraction = cast.kind == "channel" and remaining / total or 1 - remaining / total
    return fraction, remaining
end

-- UI/Bars.lua tells us how (and whether) the client let the cast be displayed.
-- `seconds`: how the time left gets onto the bar ("numbers" | "binding" | "format" | "none").
function Casts:ReportPath(cast, path, seconds)
    if cast.sample then
        cast.sample.path = path
        cast.sample.seconds = seconds
    end
    if path ~= "refused" then
        ns.db.castProven = ns.db.castProven or {}
        if not ns.db.castProven[cast.unit] then
            ns.db.castProven[cast.unit] = true
            ns:Log("cast_proven", { unit = cast.unit, path = path })
            ns:Fire("CAST_PROVEN", cast.unit)
        end
    end
end

function Casts:IsProven(unit)
    return ns.db and ns.db.castProven and ns.db.castProven[unit] and true or false
end

------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------
-- An ability with no cast time fires no START at all - only SUCCEEDED. Without those in the log,
-- "nothing here" means both "this ability is instant" and "this addon is broken", and the two cannot be
-- told apart. They are recorded for the log ONLY: no bar is armed, nothing is tracked, and a cast that
-- really is in flight is left to the code below.
local function logInstant(_, unit, _, spellID)
    if unit ~= "player" or ns.IsSecret(spellID) or type(spellID) ~= "number" then
        return
    end
    if Casts.current.player then
        return -- a real cast is running: its own sample covers it
    end
    local name = C_Spell and C_Spell.GetSpellName and select(2, pcall(C_Spell.GetSpellName, spellID))
    if ns.IsSecret(name) or type(name) ~= "string" then
        name = nil
    end
    Casts.samples[#Casts.samples + 1] = {
        unit = "player", event = "UNIT_SPELLCAST_SUCCEEDED", kind = "instant",
        name = name, spellID = spellID,
        t = math.floor(GetTime() * 10) / 10,
        combat = InCombatLockdown() and true or false,
        path = "instant - no cast to show",
    }
    while #Casts.samples > MAX_SAMPLES do
        table.remove(Casts.samples, 1)
    end
end

ns:OnPlayerUnit("UNIT_SPELLCAST_SUCCEEDED", logInstant)

local STARTS = { "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_CHANNEL_START", "UNIT_SPELLCAST_DELAYED", "UNIT_SPELLCAST_CHANNEL_UPDATE" }
local ENDS = { "UNIT_SPELLCAST_STOP", "UNIT_SPELLCAST_CHANNEL_STOP", "UNIT_SPELLCAST_INTERRUPTED" }
local FAILED = "UNIT_SPELLCAST_FAILED"

local isStart = {}
for _, event in ipairs(STARTS) do
    isStart[event] = true
end

local function onEvent(unit, event, payloadUnit, _, payloadSpell)
    if isStart[event] then
        refresh(unit, event, payloadUnit, payloadSpell)
    elseif event == FAILED then
        -- Also fires for a spell you tried to cast WHILE casting; the running cast goes on. Only
        -- believe it when the client agrees that nothing is being cast any more.
        if not ask(unit) then
            Casts.current[unit] = nil
        end
    else
        Casts.current[unit] = nil
    end
end

for _, unit in ipairs(UNITS) do
    local frame = CreateFrame("Frame")
    frame:SetScript("OnEvent", function(_, event, ...)
        ns.SafeCall(onEvent, unit, event, ...)
    end)
    for _, list in ipairs({ STARTS, ENDS, { FAILED } }) do
        for _, event in ipairs(list) do
            if not pcall(frame.RegisterUnitEvent, frame, event, unit) then
                ns.unknownEvents[event] = true
            end
        end
    end
end

-- A new target may be in the middle of a cast.
ns:On("PLAYER_TARGET_CHANGED", function()
    refresh("target", "PLAYER_TARGET_CHANGED")
end)

ns:On("PLAYER_ENTERING_WORLD", function()
    for _, unit in ipairs(UNITS) do
        refresh(unit)
    end
end)

ns:Listen("BARS_CHANGED", function()
    for _, unit in ipairs(UNITS) do
        if (Casts.current[unit] ~= nil) ~= enabled(unit) then
            refresh(unit) -- a cast bar was switched on or off
        end
    end
end)

ns:RegisterCommand("casts", "cast bars: 'on' / 'off' (both), 'player on|off', 'target on|off', 'blizzard show|hide'", function(rest)
    local what, mode = string.match(string.lower(rest or ""), "^(%S*)%s*(%S*)$")
    local Settings = ns.BarSettings
    local function switch(key, on)
        if on and Settings:GetMode(key) == "never" then
            Settings:Set(key, "mode", "used")
        elseif not on then
            Settings:Set(key, "mode", "never")
        end
    end
    if what == "on" or what == "off" then
        switch("CAST", what == "on")
        switch("TCAST", what == "on")
    elseif (what == "player" or what == "target") and (mode == "on" or mode == "off") then
        switch(BAR_OF[what], mode == "on")
    elseif what == "blizzard" and (mode == "show" or mode == "hide") then
        ns:SetOption("hideBlizzardCastBars", mode == "hide")
        if InCombatLockdown() then
            ns:Print("in combat - applied when the fight ends.")
        end
    else
        ns:Print("usage: /fct casts on | off | player on|off | target on|off | blizzard show|hide")
    end
    ns:Print("cast bars - yours:", Settings.MODE_LABELS[Settings:GetMode("CAST")], "| target:", Settings.MODE_LABELS[Settings:GetMode("TCAST")],
        "| Blizzard's:", ns:GetOption("hideBlizzardCastBars") and "hidden once ours has shown a cast" or "left alone")
end)

ns:RegisterCommand("castlog", "the last few casts this addon saw: which spell, how long, and whether it made it onto the bar", function()
    local samples = ns.Casts.samples
    if #samples == 0 then
        ns:Print("no casts seen yet. Cast something and ask again.")
        return
    end
    for index = math.max(1, #samples - 9), #samples do
        local s = samples[index]
        ns:Print(string.format("  %-7s %-26s %-18s %s%s", tostring(s.unit), tostring(s.event),
            s.name or (s.secretName and "<secret>") or "?",
            s.length and (s.length .. "s") or (s.kind == "instant" and "instant")
                or (s.secretTimes and "times secret") or "no length",
            s.path and s.path ~= "not shown yet" and ("  -> " .. s.path) or "  -> never shown"))
    end
    ns:Print("'instant' means the client fired no cast for it, so there is nothing a cast bar could show.")
end)
