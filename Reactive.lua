-- Reactive: how long you still have to press Overpower, Revenge, Mongoose Bite, Counterattack or Riposte
-- - the abilities that only open for a few seconds after a dodge, a parry or a block.
--
-- WHAT THE CLIENT TELLS US. The combat log is forbidden to addons on this client, but UNIT_COMBAT is not:
-- "this unit was just hit / dodged / parried / blocked / missed", for you, your target, focus, pet and
-- group members. MEASURED in the Forever beta (rogue, 306 events, 2026-09-19): the payload stays readable
-- in combat, and DODGE / PARRY / MISS arrive by name. It names the VICTIM, never the attacker - which is
-- exactly right for four of the five (you dodged, you parried, you blocked: the event says "player") and
-- the one wrinkle for the fifth.
--
-- THE WRINKLE. Overpower opens when the target dodges YOUR attack, and "target DODGE" cannot say whose.
-- Alone in the world that is you. In a group it could be anyone's - so there the dodge has to line up
-- with a swing of yours: this addon owns the swing timers, and PLAYER_SWING fires the instant a swing
-- lands and the next begins. A target dodge within a quarter of a second of one of your swings, or of a
-- melee ability of yours going off, is yours. Nothing else in the game is placed to make that call.
--
-- The window itself is a constant we know (five seconds, all five of them, in this era), so the bar
-- counts real numbers down with nothing secret anywhere - and it ends early the moment you USE the
-- ability, because your own casts are never secret.
local _, ns = ...

local Reactive = {}
ns.Reactive = Reactive

Reactive.MAX_SLOTS = 3 -- a warrior or a hunter has two; nobody has four

local CLASS_DEFAULTS = {
    WARRIOR = { "Overpower", "Revenge" },
    HUNTER = { "Mongoose Bite", "Counterattack" },
    ROGUE = { "Riposte" },
}

-- What opens each window: whose UNIT_COMBAT, and which outcomes. `mine = true` means the outcome has to
-- have been a swing of yours (the attribution question above).
local TRIGGERS = {
    ["overpower"]     = { victim = "target", actions = { DODGE = true }, mine = true, seconds = 5 },
    ["revenge"]       = { victim = "player", actions = { BLOCK = true, DODGE = true, PARRY = true }, seconds = 5 },
    ["mongoose bite"] = { victim = "player", actions = { DODGE = true }, seconds = 5 },
    ["counterattack"] = { victim = "player", actions = { PARRY = true }, seconds = 5 },
    ["riposte"]       = { victim = "player", actions = { PARRY = true }, seconds = 5 },
}

-- how close a target dodge has to be to a swing or melee ability of yours to count as yours, in a group
local YOURS_WITHIN = 0.4
local MAX_SAMPLES = 12

local open = {}          -- [spell] = window state
local serial = 0
local lastMeleeCastAt = -1
Reactive.samples = {}
Reactive.stats = { opened = 0, closedByUse = 0, expired = 0, notYours = 0, secretEvents = 0 }

local function now()
    return GetTime and GetTime() or 0
end

------------------------------------------------------------------------
-- What is tracked: spell NAMES, positionally bound to bar slots (see Dots.lua for why)
------------------------------------------------------------------------
function Reactive:GetTracked()
    local saved = ns.cdb and ns.cdb.reactive
    if type(saved) == "table" then
        return saved
    end
    return CLASS_DEFAULTS[ns.playerClass or ""] or {}
end

function Reactive:HasTracked()
    return #self:GetTracked() > 0
end

function Reactive:SpellForSlot(slot)
    return self:GetTracked()[slot]
end

function Reactive:SlotLabel(key)
    local slot = tonumber(string.match(key or "", "^REACT(%d+)$"))
    return slot and self:SpellForSlot(slot) or nil
end

local function isTracked(spell)
    for _, tracked in ipairs(Reactive:GetTracked()) do
        if string.lower(tracked) == spell then
            return true
        end
    end
    return false
end

------------------------------------------------------------------------
-- Was that dodge yours? (Overpower only.)
------------------------------------------------------------------------
local function inAGroup()
    if type(IsInGroup) == "function" then
        local ok, grouped = pcall(IsInGroup)
        if ok and not ns.IsSecret(grouped) then
            return grouped == true
        end
    end
    if type(GetNumGroupMembers) == "function" then
        local ok, count = pcall(GetNumGroupMembers)
        if ok and not ns.IsSecret(count) and type(count) == "number" then
            return count > 1
        end
    end
    return false -- no way to ask: treat it as solo, which is the forgiving reading
end

local function swungJustNow(at)
    local swings = ns.Swings
    if not swings or not swings.state then
        return false
    end
    -- a swing that LANDED at `at` is the one whose successor started at `at`; ranged cannot be dodged
    for _, key in ipairs({ "MH", "OH" }) do
        local state = swings.state[key]
        if state and type(state.startedAt) == "number" and math.abs(at - state.startedAt) <= YOURS_WITHIN then
            return true
        end
    end
    return false
end

local function wasMine(at)
    if not inAGroup() then
        return true, "solo"
    end
    if swungJustNow(at) then
        return true, "your swing"
    end
    if lastMeleeCastAt >= 0 and at - lastMeleeCastAt <= YOURS_WITHIN then
        return true, "your ability"
    end
    return false, "somebody else's"
end

------------------------------------------------------------------------
-- Windows
------------------------------------------------------------------------
local function note(sample)
    Reactive.samples[#Reactive.samples + 1] = sample
    while #Reactive.samples > MAX_SAMPLES do
        table.remove(Reactive.samples, 1)
    end
end

local function textureFor(name)
    local getID = C_Spell and (C_Spell.GetSpellIDForSpellIdentifier or nil)
    local getTexture = C_Spell and C_Spell.GetSpellTexture
    if type(getTexture) ~= "function" then
        return nil
    end
    local ok, texture = pcall(getTexture, name)
    if ok and not ns.IsSecret(texture) and texture ~= nil then
        return texture
    end
    if type(getID) == "function" then
        local okID, id = pcall(getID, name)
        if okID and not ns.IsSecret(id) and id then
            local okT, byID = pcall(getTexture, id)
            if okT and not ns.IsSecret(byID) then
                return byID
            end
        end
    end
    return nil
end

local function openWindow(spell, name, at, seconds, why)
    serial = serial + 1
    open[spell] = {
        name = name, spell = spell, texture = textureFor(name),
        startTime = at, endTime = at + seconds, total = seconds,
        serial = serial, owner = Reactive, why = why,
        timesReadable = true, -- a constant of ours, counted with our own clock
        drains = true,
    }
    Reactive.stats.opened = Reactive.stats.opened + 1
    note({ spell = name, seconds = seconds, why = why, at = math.floor(at * 100) / 100 })
end

local function trackedName(spell)
    for _, tracked in ipairs(Reactive:GetTracked()) do
        if string.lower(tracked) == spell then
            return tracked
        end
    end
    return spell
end

-- UNIT_COMBAT: the whole of the trigger. Every field may be secret; the guard comes first.
local function onUnitCombat(_, unit, action)
    if ns.AnySecret(unit, action) then
        Reactive.stats.secretEvents = Reactive.stats.secretEvents + 1
        return
    end
    if type(unit) ~= "string" or type(action) ~= "string" or not Reactive:HasTracked() then
        return
    end
    local at = now()
    for spell, trigger in pairs(TRIGGERS) do
        if trigger.victim == unit and trigger.actions[action] and isTracked(spell) then
            local mine, why = true, unit == "player" and "you " .. string.lower(action) .. "d" or "target dodged"
            if trigger.mine then
                mine, why = wasMine(at)
            end
            if mine then
                openWindow(spell, trackedName(spell), at, trigger.seconds, why)
            else
                Reactive.stats.notYours = Reactive.stats.notYours + 1
            end
        end
    end
end

-- Your own casts: a melee ability marks the moment (for attribution), and using the reactive ability
-- itself closes its window.
local function onCast(_, _, _, spellID)
    if ns.IsSecret(spellID) or type(spellID) ~= "number" then
        return
    end
    lastMeleeCastAt = now()
    local getName = C_Spell and C_Spell.GetSpellName
    if type(getName) ~= "function" then
        return
    end
    local ok, name = pcall(getName, spellID)
    if not ok or ns.IsSecret(name) or type(name) ~= "string" then
        return
    end
    local spell = string.lower(name)
    if open[spell] then
        open[spell] = nil
        Reactive.stats.closedByUse = Reactive.stats.closedByUse + 1
    end
end

ns:On("UNIT_COMBAT", onUnitCombat)
ns:OnPlayerUnit("UNIT_SPELLCAST_SUCCEEDED", onCast)
ns:On("PLAYER_TARGET_CHANGED", function()
    -- an Overpower window belongs to the mob that dodged; a new target has not
    if open["overpower"] then
        open["overpower"] = nil
    end
end)

------------------------------------------------------------------------
-- What the bars ask for
------------------------------------------------------------------------
function Reactive:Get(slot, at)
    local spellName = self:SpellForSlot(slot)
    if not spellName then
        return nil
    end
    at = at or now()
    local spell = string.lower(spellName)
    local window = open[spell]
    if not window then
        return nil
    end
    if at > window.endTime then
        open[spell] = nil
        Reactive.stats.expired = Reactive.stats.expired + 1
        return nil
    end
    return window
end

function Reactive:GetProgress(window, at)
    local total = window.endTime - window.startTime
    local remaining = math.min(total, math.max(0, window.endTime - at))
    if total <= 0 then
        return 0, 0
    end
    return remaining / total, remaining
end

function Reactive:ReportPath(window, path, seconds)
    window.path, window.reported = path, seconds
end

function Reactive:Report()
    local running = {}
    for spell, window in pairs(open) do
        running[#running + 1] = window.name or spell
    end
    return { tracked = self:GetTracked(), running = running, stats = self.stats,
        yoursWithin = YOURS_WITHIN }
end

------------------------------------------------------------------------
-- Commands
------------------------------------------------------------------------
ns:RegisterCommand("react", "which reactive abilities get a bar (Overpower, Revenge, Mongoose Bite, Counterattack, Riposte): '/fct react' lists, 'add <name>', 'remove <name>', 'reset'", function(rest)
    local what, name = string.match(rest or "", "^%s*(%S*)%s*(.-)%s*$")
    what = string.lower(what or "")
    if (what == "add" or what == "remove") and name ~= "" then
        if what == "add" and not TRIGGERS[string.lower(name)] then
            ns:Print("'" .. name .. "' is not one this addon knows how to open a window for. It knows: "
                .. "Overpower, Revenge, Mongoose Bite, Counterattack, Riposte.")
            return
        end
        local list = {}
        for _, tracked in ipairs(Reactive:GetTracked()) do
            if string.lower(tracked) ~= string.lower(name) then
                list[#list + 1] = tracked
            end
        end
        if what == "add" then
            if #list >= Reactive.MAX_SLOTS then
                ns:Print("that is already " .. Reactive.MAX_SLOTS .. ", which is as many bars as there are - remove one first.")
                return
            end
            list[#list + 1] = name
        end
        ns.cdb.reactive = list
        ns:Fire("BARS_CHANGED")
    elseif what == "reset" then
        ns.cdb.reactive = nil
        ns:Fire("BARS_CHANGED")
    elseif what ~= "" then
        ns:Print("usage: /fct react | add <name> | remove <name> | reset")
        return
    end

    local tracked = Reactive:GetTracked()
    ns:Print("reactive bars track:", #tracked > 0 and table.concat(tracked, ", ")
        or "nothing (so they take no rows) - /fct react add <name>")
    local s = Reactive.stats
    ns:Print(string.format("windows opened %d, closed by using the ability %d, ran out %d, "
        .. "target dodges judged somebody else's %d, secret events %d.",
        s.opened, s.closedByUse, s.expired, s.notYours, s.secretEvents))
end)
