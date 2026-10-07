-- Dots: how much longer your damage-over-time spells have to run on what you are fighting - Flame Shock,
-- Serpent Sting, Shadow Word: Pain and the like.
--
-- WHY THIS IS EASIER THAN THE BUFF BAR. A buff of yours cannot be found in a fight at all on this client
-- (see the note at the top of Buffs.lua: the aura lookup returns nothing and the instance ids raise), so
-- Slice and Dice has to be estimated from combo points through a curve the client evaluates for us, and
-- the result is a bar with no numbers on it. A DoT needs none of that machinery, because its duration is
-- a CONSTANT WE ALREADY KNOW. Your own casts are never secret - UNIT_SPELLCAST_SUCCEEDED names the spell
-- - so a cast plus a known duration is a real countdown with real numbers, whatever the client will or
-- will not say about the aura itself.
--
-- The aura is still read when it can be, because it is the truth and this is only arithmetic: a readable
-- aura corrects the clock, and it also TEACHES the duration for that spell, which is how ranks, talents
-- and anything else that stretches a DoT get accounted for without a table of every case.
--
-- WHOSE DOTS, ON WHAT. Only yours, and only ones you asked for. State is kept per enemy GUID, so a mob
-- you DoTted a minute ago still has its timers when you target it again, while the bars themselves only
-- ever show your current target.
local _, ns = ...

local Dots = {}
ns.Dots = Dots

Dots.MAX_SLOTS = 4 -- how many DoTs can have a bar of their own

local CLASS_DEFAULTS = {
    SHAMAN = { "Flame Shock" },
    HUNTER = { "Serpent Sting" },
    PRIEST = { "Shadow Word: Pain" },
    WARLOCK = { "Corruption", "Immolate", "Bane of Agony" }, -- Forever's name for Curse of Agony
    DRUID = { "Moonfire", "Rip" },
    ROGUE = { "Rupture" },
    WARRIOR = { "Rend" },
}

-- Spells whose length the combo points spent on them decide. These never take a duration from the table
-- above and never keep a learned one, because the next cast may have been bought with fewer points.
--
-- NOTE ON THE NUMBERS: seconds per combo point, one to five. A readable aura overrides them the moment
-- there is one, so these only decide the length of a bar drawn in a fight - worth checking in game.
local COMBO_SECONDS = {
    ["rupture"] = { 8, 10, 12, 14, 16 },
    ["rip"] = { 12, 12, 12, 12, 12 },
}

-- Seconds a DoT runs, by spell name in lower case: the length of its top ranks (two spells run for less
-- at low ranks, see RANK_SECONDS). Only spells whose duration is FIXED belong here: anything that varies
-- with combo points or talents is left out on purpose and waits to be taught by a readable aura, because
-- a confident wrong number on a timer is worse than no bar.
local DURATIONS = {
    ["flame shock"] = 12,
    ["serpent sting"] = 15,
    ["shadow word: pain"] = 18,
    ["corruption"] = 18,      -- ranks 3 and up; ranks 1 and 2 run for less, see RANK_SECONDS
    ["immolate"] = 15,
    ["bane of agony"] = 24,   -- Forever renamed Curse of Agony (and Curse of Doom: Bane of Doom)
    ["curse of agony"] = 24,
    ["moonfire"] = 12,
    ["rend"] = 21,            -- ranks 5 and up; ranks 1 to 4 run for less, see RANK_SECONDS
}

-- The low ranks that run for less than the name says, by spell id, since the name is the same: Classic's
-- lengths, which Forever keeps (Corruption measured in game at 12 and 15 seconds, 2026-10-06).
local RANK_SECONDS = {
    [172] = 12, [6222] = 15,                          -- Corruption ranks 1 and 2 (18 from rank 3)
    [772] = 9, [6546] = 12, [6547] = 15, [6548] = 18, -- Rend ranks 1 to 4 (21 from rank 5)
}

local KEEP_ENEMIES = 12   -- mobs worth remembering at once; a pull, not a raid night
local GONE_AFTER = 60     -- an enemy nothing has happened to for this long is forgotten

local applied = {}        -- [key] = { [spell] = entry }, the key a target's GUID or a stand-in for it (see retarget)
local appliedCount = 0
local targetKey           -- what the current target's DoTs are filed under; nil without a target
local standIns = 0        -- stand-in keys handed out so far
local learned = {}        -- [spell id] = seconds, taught by a readable aura - per id, since the ranks of Corruption and
                          -- Rend run for different times; [name] = seconds only when the aura carried no id
local learnedNames = {}   -- [spell id] = the name in lower case, for the report
-- [spell] = { [seconds] = times seen }. Only for the combo-point spells, whose per-point table is the
-- one thing in here that was believed rather than measured. The durations a real aura hands over ARE
-- that table, gathered a cast at a time.
local observed = {}
local serial = 0

Dots.samples = {}         -- for /fct diag
Dots.stats = { droppedDead = 0, droppedGone = 0, standIns = 0, skipped = 0 }
local MAX_SAMPLES = 12

local function now()
    return GetTime and GetTime() or 0
end

------------------------------------------------------------------------
-- What is tracked: spell NAMES, because ranks have different ids
------------------------------------------------------------------------
-- Forever's names for spells a list may still hold under the Classic ones
local RENAMED = { ["curse of agony"] = "Bane of Agony", ["curse of doom"] = "Bane of Doom" }

function Dots:GetTracked()
    local saved = ns.cdb and ns.cdb.dots
    if type(saved) == "table" then
        for index, name in ipairs(saved) do
            local renamed = type(name) == "string" and RENAMED[string.lower(name)]
            if renamed then
                saved[index] = renamed
            end
        end
        return saved
    end
    return CLASS_DEFAULTS[ns.playerClass or ""] or {}
end

function Dots:HasTracked()
    return #self:GetTracked() > 0
end

-- which tracked spell a bar slot belongs to. Fixed by POSITION in the tracked list rather than by what
-- happens to be running, so a bar never swaps out from under you mid-fight.
function Dots:SpellForSlot(slot)
    return self:GetTracked()[slot]
end

function Dots:SlotLabel(key)
    local slot = tonumber(string.match(key or "", "^DOT(%d+)$"))
    return slot and self:SpellForSlot(slot) or nil
end

------------------------------------------------------------------------
-- The enemy under consideration
------------------------------------------------------------------------
local function guidOf(unit)
    local ok, guid = pcall(UnitGUID, unit)
    if not ok or ns.IsSecret(guid) or type(guid) ~= "string" or guid == "" then
        return nil -- nothing to file it under, so nothing is filed: better than guessing whose it was
    end
    return guid
end

local function forget(guid)
    if applied[guid] then
        applied[guid] = nil
        appliedCount = appliedCount - 1
    end
end

local function prune(at)
    local cutoff = at - GONE_AFTER
    for guid, spells in pairs(applied) do
        local latest = 0
        for _, entry in pairs(spells) do
            if entry.endTime > latest then
                latest = entry.endTime
            end
        end
        if latest < cutoff then
            forget(guid)
        end
    end
end

local function bucket(guid)
    local spells = applied[guid]
    if spells then
        return spells
    end
    if appliedCount >= KEEP_ENEMIES then
        prune(now())
    end
    if appliedCount >= KEEP_ENEMIES then
        return nil -- a pull this size is not what these bars are for
    end
    spells = {}
    applied[guid], appliedCount = spells, appliedCount + 1
    return spells
end

------------------------------------------------------------------------
-- How long it runs: what an aura taught us, else what we know, else nothing
------------------------------------------------------------------------
local function durationFor(spell, spellID)
    if COMBO_SECONDS[spell] then
        return nil -- bought with points nobody can read: no fixed answer exists to give
    end
    if spellID then
        return learned[spellID] or RANK_SECONDS[spellID] or learned[spell] or DURATIONS[spell]
    end
    return learned[spell] or DURATIONS[spell]
end

local function note(sample)
    Dots.samples[#Dots.samples + 1] = sample
    while #Dots.samples > MAX_SAMPLES do
        table.remove(Dots.samples, 1)
    end
end

-- a tracked spell was cast and no bar came of it: why, in the log, for the first dozen times
local skippedLogged = 0
local function skip(why, spellID)
    Dots.stats.skipped = (Dots.stats.skipped or 0) + 1
    if skippedLogged < 12 then
        skippedLogged = skippedLogged + 1
        ns:Log("dot_skipped", { why = why, spell = spellID })
    end
end

-- A DoT of ours landed, and we know when it must end
local function start(guid, spell, name, texture, at, seconds, source)
    local spells = bucket(guid)
    if not spells then
        return nil
    end
    serial = serial + 1
    spells[spell] = {
        name = name, texture = texture, spell = spell,
        startTime = at, endTime = at + seconds, total = seconds,
        serial = serial, source = source, owner = Dots,
        timesReadable = true, -- the whole point: these are our numbers, not the client's secrets
    }
    note({ spell = name, seconds = seconds, source = source, guid = guid ~= nil })
    return spells[spell]
end

-- A finisher DoT in a fight: the length is secret, so the bar is given secret bounds and fed a plain
-- clock. Right length, no numbers - the same bargain the buff bar strikes for Slice and Dice.
local function startSecret(guid, spell, name, texture, at, bound, longest)
    local spells = bucket(guid)
    if not spells then
        return nil
    end
    serial = serial + 1
    spells[spell] = {
        name = name, texture = texture, spell = spell,
        startTime = at, giveUpAt = at + longest + 1,
        serial = serial, source = "combo points", owner = Dots,
        timesReadable = false, -- nobody may read this length, only show it
        estimated = true,
        drains = true,
        secretStart = bound, secretEnd = 0,
        clock = function(when) return -(when - at) end,
    }
    note({ spell = name, seconds = "secret", source = "combo points", guid = guid ~= nil })
    return spells[spell]
end

------------------------------------------------------------------------
-- Reading the real aura. Every answer may be secret; none is looked at before ns.IsSecret cleared it.
------------------------------------------------------------------------
local function readAura(aura)
    if ns.IsSecret(aura) or type(aura) ~= "table" then
        return nil
    end
    local duration, expires = aura.duration, aura.expirationTime
    local icon, name, spellID = aura.icon, aura.name, aura.spellId
    if ns.AnySecret(duration, expires, icon, name)
        or type(duration) ~= "number" or type(expires) ~= "number" or duration <= 0
        or type(name) ~= "string" then
        return nil
    end
    if ns.IsSecret(spellID) or type(spellID) ~= "number" then
        spellID = nil
    end
    return { name = name, total = duration, endTime = expires, texture = icon, spellID = spellID }
end

-- One answer from the client, or nil when the call failed, the function is missing, or the answer is a
-- secret. (This addon has no shared Readable helper; the tooltip addon does, and this was first written
-- as if they shared one.)
local function readable(fn, ...)
    if type(fn) ~= "function" then
        return nil
    end
    local ok, value = pcall(fn, ...)
    if not ok or ns.IsSecret(value) then
        return nil
    end
    return value
end

-- WHAT THE TARGET'S DOTS ARE FILED UNDER. Its GUID when the client gives it - and in a fight the client
-- does not: measured 2026-10-06 on build 70235, UnitGUID("target") is a secret there, and every DoT cast
-- in a fight went nowhere (a "do not guess" that left the bars empty exactly where they are wanted). So
-- the key is taken when the target is TAKEN and kept until the target changes: the GUID if it is readable
-- then, else a stand-in that means "this target, whoever it is". A pull's Corruption (GUID in hand) and the
-- fight's Immolate (GUID secret) land in one bucket because the key did not move. What a stand-in cannot
-- do is recognise a mob you tab back to in a fight: that gets a fresh stand-in, and its bars return with
-- the next cast on it.
-- WHO THE TARGET IS WHEN THE GUID IS A SECRET. The API docs of this client mark UnitGUID "secret when the
-- unit's identity is restricted" - a fight - but not UnitLevel, UnitClassification, UnitExists, nor the
-- nameplate frame of a unit (C_NamePlate.GetNamePlateForUnit). A mob keeps its nameplate frame while the
-- plate is up, so the frame's name ("NamePlate3", with the level and, when readable, the name beside it)
-- is a key that survives tabbing away and back in a fight. Without a plate the name and level must do
-- (two mobs of one name share their bars), and without a readable name a stand-in: "this target".
local function weakKeyOf(unit)
    local getPlate = type(C_NamePlate) == "table" and C_NamePlate.GetNamePlateForUnit or nil
    if type(getPlate) == "function" then
        local ok, frame = pcall(getPlate, unit)
        if ok and type(frame) == "table" and not ns.IsSecret(frame) then
            local frameName = readable(frame.GetName, frame)
            if type(frameName) == "string" then
                return "plate:" .. frameName .. "|" .. tostring(readable(UnitLevel, unit)) .. "|" .. tostring(readable(UnitName, unit))
            end
        end
    end
    local name = readable(UnitName, unit)
    if type(name) == "string" and name ~= "" then
        return "name:" .. name .. "|" .. tostring(readable(UnitLevel, unit))
    end
    return nil
end

-- what a weak key stood for once the GUID could be read: [weak key] = GUID, so a mob whose DoT was filed
-- under its GUID at the pull is found again under its plate in the fight
local aliases = {}
local retargetsLogged = 0

local function keyKind(key)
    if not key then
        return "none"
    elseif string.find(key, "^target#") then
        return "stand-in"
    elseif string.find(key, "^plate:") then
        return "plate"
    elseif string.find(key, "^name:") then
        return "name"
    end
    return "guid"
end

local function retarget()
    local guid, weak = guidOf("target"), weakKeyOf("target")
    if guid then
        targetKey = guid
        if weak then
            aliases[weak] = guid
        end
    elseif readable(UnitExists, "target") == false then
        targetKey = nil -- no target at all
    elseif weak then
        targetKey = aliases[weak] or weak
    else
        standIns = standIns + 1
        targetKey = "target#" .. standIns
        Dots.stats.standIns = (Dots.stats.standIns or 0) + 1
    end
    if retargetsLogged < 12 and targetKey then
        retargetsLogged = retargetsLogged + 1
        ns:Log("dot_target", { key = keyKind(targetKey), aliased = (weak ~= nil and aliases[weak] ~= nil) or nil })
    end
end

-- Before the key is used: should the client now give a GUID that is not the key, the key follows it. A
-- weak key or a stand-in whose target can be read again (the fight is over) grows into the GUID, bars and
-- all; a GUID that simply differs is a target change the event has not told us of yet.
local function syncTarget()
    local guid = guidOf("target")
    if not guid or guid == targetKey then
        return
    end
    if targetKey and keyKind(targetKey) ~= "guid" then
        if applied[targetKey] and not applied[guid] then
            applied[guid], applied[targetKey] = applied[targetKey], nil
        end
        if keyKind(targetKey) ~= "stand-in" then
            aliases[targetKey] = guid
        end
    end
    targetKey = guid
end

-- a plate that goes (the mob died or left) takes the bars filed under it, and what the plate stood for
local function plateGone(token)
    local getPlate = type(C_NamePlate) == "table" and C_NamePlate.GetNamePlateForUnit or nil
    if type(getPlate) ~= "function" or ns.IsSecret(token) or type(token) ~= "string" then
        return
    end
    local ok, frame = pcall(getPlate, token)
    local frameName = ok and type(frame) == "table" and not ns.IsSecret(frame) and readable(frame.GetName, frame) or nil
    if type(frameName) ~= "string" then
        return
    end
    local prefix = "plate:" .. frameName .. "|"
    for key in pairs(applied) do
        if string.sub(key, 1, #prefix) == prefix then
            forget(key)
        end
    end
    for key in pairs(aliases) do
        if string.sub(key, 1, #prefix) == prefix then
            aliases[key] = nil
        end
    end
end

-- A corpse stays targeted; its DoTs are over. UnitIsDeadOrGhost carries no secret flag in the API docs,
-- and the read is guarded anyway: an unreadable answer is "not known to be dead".
local function isDead(unit)
    return readable(UnitIsDeadOrGhost, unit) == true
end

local function dropIfDead(unit)
    if not isDead(unit) then
        return false
    end
    syncTarget()
    if targetKey and applied[targetKey] then
        forget(targetKey)
        Dots.stats.droppedDead = (Dots.stats.droppedDead or 0) + 1
    end
    return true
end

-- Can an EMPTY aura walk be believed? Out of a fight, yes. In one, only if the client itself says auras
-- are not secret right now; otherwise a hidden aura would look exactly like a vanished one.
local function aurasReadableNow()
    if not InCombatLockdown() then
        return true
    end
    local secrets = C_Secrets
    if type(secrets) ~= "table" or type(secrets.ShouldAurasBeSecret) ~= "function" then
        return false
    end
    return readable(secrets.ShouldAurasBeSecret) == false
end

-- Walk the target's harmful auras, keeping only ours. Any of this may be refused in a fight - that is
-- expected, not an error, and the cast-driven clock carries on regardless.
local function readFromTarget(unit)
    local auras = C_UnitAuras
    if type(auras) ~= "table" or type(auras.GetAuraDataByIndex) ~= "function" then
        return
    end
    syncTarget()
    local guid = targetKey
    if not guid then
        return
    end
    local seen, refused = {}, false
    for index = 1, 40 do
        local ok, aura = pcall(auras.GetAuraDataByIndex, unit, index, "HARMFUL|PLAYER")
        if not ok then
            refused = true
            break
        end
        if aura == nil then
            break
        end
        local read = readAura(aura)
        if read then
            local spell = string.lower(read.name)
            if Dots:IsTracked(spell) then
                seen[spell] = true
                -- the truth, and usually a lesson too - but not for a finisher, whose next cast may be
                -- bought with fewer points and run for less
                if not COMBO_SECONDS[spell] then
                    learned[read.spellID or spell] = read.total
                    if read.spellID then
                        learnedNames[read.spellID] = spell
                    end
                else
                    -- ... though it is still worth writing down, because the set of durations this spell
                    -- is ever seen to have is exactly the table we guessed at
                    local seen = observed[spell] or {}
                    local key = string.format("%.4g", read.total)
                    seen[key] = (seen[key] or 0) + 1
                    observed[spell] = seen
                end
                local spells = bucket(guid)
                local existing = spells and spells[spell]
                if spells and (not existing or math.abs(existing.endTime - read.endTime) > 0.5) then
                    start(guid, spell, read.name, read.texture,
                        read.endTime - read.total, read.total, "aura")
                end
            end
        end
    end

    -- A tracked DoT of ours that the walk did not find is over: dispelled, ended early, or on a corpse.
    -- Only when the walk was allowed AND the client says auras are readable right now - an empty walk
    -- under secrecy proves nothing, and a live DoT must never leave the bar because the client hid it.
    if not refused and aurasReadableNow() then
        local spells = applied[guid]
        if spells then
            for spell in pairs(spells) do
                if not seen[spell] then
                    spells[spell] = nil
                    Dots.stats.droppedGone = (Dots.stats.droppedGone or 0) + 1
                end
            end
        end
    end
end

function Dots:IsTracked(spell)
    for _, tracked in ipairs(self:GetTracked()) do
        if string.lower(tracked) == spell then
            return true
        end
    end
    return false
end

------------------------------------------------------------------------
-- What the bars ask for
------------------------------------------------------------------------
function Dots:Get(slot, at)
    local spellName = self:SpellForSlot(slot)
    if not spellName then
        return nil
    end
    at = at or now()
    syncTarget()
    local guid = targetKey
    if not guid then
        return nil
    end
    local spells = applied[guid]
    local entry = spells and spells[string.lower(spellName)]
    if not entry then
        return nil
    end
    local done = entry.estimated and at > entry.giveUpAt or (entry.endTime and at > entry.endTime)
    if done then
        spells[string.lower(spellName)] = nil
        return nil
    end
    return entry
end

-- fraction (a DoT drains) and seconds left
function Dots:GetProgress(entry, at)
    local total = entry.endTime - entry.startTime
    local remaining = math.min(total, math.max(0, entry.endTime - at))
    if total <= 0 then
        return 0, 0
    end
    return remaining / total, remaining
end

function Dots:ReportPath(entry, path, seconds)
    entry.path, entry.reported = path, seconds
end

------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------
local function nameOf(spellID)
    local getName = C_Spell and C_Spell.GetSpellName
    if type(getName) ~= "function" then
        return nil
    end
    local ok, name = pcall(getName, spellID)
    if not ok or ns.IsSecret(name) or type(name) ~= "string" or name == "" then
        return nil
    end
    return name
end

local function textureOf(spellID)
    local getTexture = C_Spell and C_Spell.GetSpellTexture
    if type(getTexture) ~= "function" then
        return nil
    end
    local ok, texture = pcall(getTexture, spellID)
    if not ok or ns.IsSecret(texture) then
        return nil
    end
    return texture
end

-- You cast one of them. Your own casts are never secret, so this is the one thing that always works -
-- in a fight as much as out of one, which is exactly where a DoT timer earns its place.
-- A cast with a cast time lands on the target it was BEGUN on, whatever is targeted when it lands - so
-- the key is taken at UNIT_SPELLCAST_START and used at the SUCCEEDED of the same cast (the cast GUID ties
-- the two). An instant has no START and goes to the current target. Switching targets before a Corruption
-- finished casting used to file it under the new target (seen 2026-10-06).
local castsBegun = {} -- [castGUID] = the key of the target the cast was begun on

local function onCastStart(_, _, castGUID, spellID)
    if ns.IsSecret(castGUID) or type(castGUID) ~= "string" or ns.IsSecret(spellID) or type(spellID) ~= "number" then
        return
    end
    if not Dots:HasTracked() then
        return
    end
    local name = nameOf(spellID)
    if not name or not Dots:IsTracked(string.lower(name)) then
        return
    end
    syncTarget()
    if not targetKey then
        retarget()
    end
    castsBegun[castGUID] = targetKey or false
end

local function onCastEnd(_, _, castGUID)
    if not ns.IsSecret(castGUID) and castGUID ~= nil then
        castsBegun[castGUID] = nil
    end
end

local function onCast(_, _, castGUID, spellID)
    if ns.IsSecret(spellID) or type(spellID) ~= "number" then
        return
    end
    if not Dots:HasTracked() then
        return
    end
    local name = nameOf(spellID)
    if not name then
        skip("the client gave no name for the spell", spellID)
        return
    end
    local spell = string.lower(name)
    if not Dots:IsTracked(spell) then
        return
    end
    local begun = (not ns.IsSecret(castGUID) and type(castGUID) == "string") and castsBegun[castGUID] or nil
    if castGUID ~= nil and not ns.IsSecret(castGUID) then
        castsBegun[castGUID] = nil
    end
    local guid
    if begun then
        guid = begun -- the target the cast was begun on, whatever is targeted now
    else
        syncTarget()
        if not targetKey then
            retarget() -- a target taken before the addon was listening
        end
        guid = targetKey
    end
    if not guid then
        skip("no target", spellID)
        return
    end

    local points = COMBO_SECONDS[spell]
    if points then
        -- the length was bought with points we may not read; the client will still put them through a
        -- curve for us and hand back the answer, secret and all
        local bound = ns.Buffs and ns.Buffs:ComboBound(name, points)
        if bound ~= nil then
            startSecret(guid, spell, name, textureOf(spellID), now(), bound, points[#points])
        end
        return
    end

    local seconds = durationFor(spell, spellID)
    if not seconds then
        skip("no duration known", spellID)
        return -- nothing has taught us how long this one runs; a guessed bar would be worse than none
    end
    start(guid, spell, name, textureOf(spellID), now(), seconds, "cast")
end

ns:OnPlayerUnit("UNIT_SPELLCAST_SUCCEEDED", onCast) -- the client filters it to you
ns:OnPlayerUnit("UNIT_SPELLCAST_START", onCastStart)
ns:OnPlayerUnit("UNIT_SPELLCAST_STOP", onCastEnd) -- (after a SUCCEEDED too: by then the key was taken and the entry is gone)
ns:OnPlayerUnit("UNIT_SPELLCAST_FAILED", onCastEnd)
ns:OnPlayerUnit("UNIT_SPELLCAST_INTERRUPTED", onCastEnd)
ns:On("PLAYER_TARGET_CHANGED", function()
    retarget()
    if not dropIfDead("target") then
        readFromTarget("target")
    end
end)
ns:On("PLAYER_ENTERING_WORLD", function()
    retarget()
end)
ns:On("NAME_PLATE_UNIT_REMOVED", function(_, token)
    plateGone(token)
end)
-- UNIT_HEALTH fires when the target dies (the value is secret; the event is not), UNIT_FLAGS too
ns:On("UNIT_HEALTH", function(_, unit) if unit == "target" then dropIfDead("target") end end)
ns:On("UNIT_FLAGS", function(_, unit) if unit == "target" then dropIfDead("target") end end)
ns:On("UNIT_AURA", function(_, unit)
    if unit == "target" then
        readFromTarget("target")
    end
end)
ns:On("PLAYER_REGEN_ENABLED", function()
    -- out of a fight the client is far more forthcoming, so this is the best chance to be taught
    readFromTarget("target")
end)

------------------------------------------------------------------------
-- Diagnostics
------------------------------------------------------------------------
function Dots:Report()
    local enemies, timers = 0, 0
    for _, spells in pairs(applied) do
        enemies = enemies + 1
        for _ in pairs(spells) do
            timers = timers + 1
        end
    end
    return { enemies = enemies, timers = timers, learned = learned, learnedNames = learnedNames, observed = observed,
        targetKey = keyKind(targetKey),
        standIns = self.stats.standIns or 0, skipped = self.stats.skipped or 0,
        dropped = { dead = self.stats.droppedDead, gone = self.stats.droppedGone },
        expected = COMBO_SECONDS, tracked = self:GetTracked() }
end

------------------------------------------------------------------------
-- Commands
------------------------------------------------------------------------
ns:RegisterCommand("dot", "which of your damage-over-time spells get a bar: '/fct dot' lists, 'add <spell name>', 'remove <spell name>', 'reset'", function(rest)
    local what, name = string.match(rest or "", "^%s*(%S*)%s*(.-)%s*$")
    what = string.lower(what or "")
    if (what == "add" or what == "remove") and name ~= "" then
        local list = {}
        for _, tracked in ipairs(Dots:GetTracked()) do
            if string.lower(tracked) ~= string.lower(name) then
                list[#list + 1] = tracked
            end
        end
        if what == "add" then
            if #list >= Dots.MAX_SLOTS then
                ns:Print("that is already " .. Dots.MAX_SLOTS .. " DoTs, which is as many bars as there are - "
                    .. "remove one first.")
                return
            end
            list[#list + 1] = name
        end
        ns.cdb.dots = list
        ns:Fire("BARS_CHANGED") -- a row appears with the first tracked DoT, and goes with the last
    elseif what == "reset" then
        ns.cdb.dots = nil
        ns:Fire("BARS_CHANGED")
    elseif what ~= "" then
        ns:Print("usage: /fct dot | add <spell name> | remove <spell name> | reset")
        return
    end

    local tracked = Dots:GetTracked()
    ns:Print("DoT bars track:", #tracked > 0 and table.concat(tracked, ", ")
        or "nothing (so they take no rows) - /fct dot add <spell name>")
    for index, spellName in ipairs(tracked) do
        local spell = string.lower(spellName)
        local seconds = learned[spell] or DURATIONS[spell]
        local ranks = {}
        for id, length in pairs(learned) do
            if learnedNames[id] == spell then
                ranks[#ranks + 1] = string.format("%.4g s (spell %d)", length, id)
            end
        end
        table.sort(ranks)
        local how
        if COMBO_SECONDS[spell] then
            local list = COMBO_SECONDS[spell]
            local lengths = {}
            for length in pairs(observed[spell] or {}) do
                lengths[#lengths + 1] = length
            end
            table.sort(lengths, function(a, b) return tonumber(a) < tonumber(b) end)
            how = string.format("%g-%g seconds, bought with combo points; seen so far: %s",
                list[1], list[#list],
                #lengths > 0 and table.concat(lengths, ", ") or "nothing yet - cast it out of combat")
        elseif seconds then
            how = string.format("%.4g seconds", seconds)
                .. (learned[spell] and " (seen on a real aura)" or " (from the table, the top ranks)")
            if #ranks > 0 then
                how = how .. "; seen on real auras: " .. table.concat(ranks, ", ")
            end
        else
            how = "|cffffd100no duration known yet|r - cast it once out of combat and the aura will teach us"
        end
        ns:Print(string.format("  bar %d: %s - %s", index, spellName, how))
    end
end)
