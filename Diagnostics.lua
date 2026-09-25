-- Diagnostics: '/fct diag' snapshots what this client really does into
-- SavedVariables (AKForeverCombatTimersDB.diag); a /reload writes it to disk.
--
-- This is the experiment half of the addon. The enemy timer rests on assumptions
-- nobody has documented - does UNIT_COMBAT stay readable in combat and inside
-- instances? is the target's attack speed ever readable? is the combat log open
-- anywhere? - and this is where the answers get recorded.
local _, ns = ...

local Diagnostics = {}
ns.Diagnostics = Diagnostics

local API_PATHS = {
    "C_SwingTimer.EnableRangeCheck", "C_SwingTimer.IsTargetWithinSwingRange",
    "UnitAttackSpeed", "UnitCanAttack", "UnitIsFriend", "UnitIsUnit", "UnitAffectingCombat",
    "UnitCastingInfo", "UnitChannelInfo", "UnitCastingDuration", "UnitChannelDuration", "C_Spell.GetSpellInfo",
    "C_CombatLog.IsCombatLogRestricted", "CombatLogGetCurrentEventInfo", "C_CombatLog.GetCurrentEventInfo",
    "C_CVar.GetCVar", "C_CVar.SetCVar", "GetCVar", "SetCVar",
    "C_Secrets.ShouldAurasBeSecret", "issecretvalue",
    "C_Timer.After", "C_Timer.NewTicker", "C_AddOns.GetAddOnMetadata", "UnitFullName", "GetRealmName",
}

local function resolve(path)
    local value = _G
    for part in string.gmatch(path, "[^%.]+") do
        if type(value) ~= "table" then
            return nil
        end
        value = value[part]
    end
    return value
end

-- Deep copy that is safe to hand to the SavedVariables writer.
local function sanitize(value, depth)
    depth = depth or 0
    if ns.IsSecret(value) then
        return "<secret>"
    end
    local kind = type(value)
    if kind == "table" then
        if depth >= 6 then
            return "<too deep>"
        end
        local copy = {}
        for k, v in pairs(value) do
            local key = k
            if ns.IsSecret(k) then
                key = "<secret key>"
            elseif type(k) ~= "string" and type(k) ~= "number" then
                key = tostring(k)
            end
            copy[key] = sanitize(v, depth + 1)
        end
        return copy
    elseif kind == "string" or kind == "number" or kind == "boolean" then
        return value
    elseif kind == "nil" then
        return nil
    end
    return "<" .. kind .. ">"
end

local function packResults(ok, ...)
    if not ok then
        return { error = tostring((...)) }
    end
    local results = { n = select("#", ...) }
    for i = 1, results.n do
        results[i] = sanitize((select(i, ...)))
    end
    return results
end

local function try(fn, ...)
    if type(fn) ~= "function" then
        return "n/a"
    end
    return packResults(pcall(fn, ...))
end

-- NOTE: there is deliberately no combat log probe here. Registering
-- COMBAT_LOG_EVENT_UNFILTERED from addon code is a forbidden action in the
-- Forever client (found the hard way, 2026-09-18: it raised the "blocked from an
-- action only available to the Blizzard UI" dialog). The combat log is closed.

------------------------------------------------------------------------
-- The buff experiment: could a bar show how long a buff of yours still runs (first candidate: a
-- rogue's Slice and Dice)? Blizzard's definition: aura data is secret "when combat ... restrictions
-- are in effect. Individual spells may be flagged as never or always secret" - while your own casts
-- are never secret. So: when a watched spell is cast, look at the UNIT_AURA that follows and write
-- down what an addon gets to see, and whether the aura's duration object can drive a bar and a
-- countdown. Read-only: no Blizzard frame is touched, and none of the calls below is flagged
-- "HasRestrictions" in the API docs (that flag is what made the combat log a forbidden action).
------------------------------------------------------------------------
local WATCHED_BUFFS = { ["Slice and Dice"] = true, ["Sprint"] = true, ["Evasion"] = true, ["Lightning Shield"] = true }
local AURA_FIELDS = { "auraInstanceID", "spellId", "name", "icon", "duration", "expirationTime", "applications",
    "sourceUnit", "isFromPlayerOrPlayerPet" }
local MAX_AURA_SAMPLES = 8
local auraSamples = {}
local pendingBuff
local probeBar

local function pack(ok, ...)
    return ok, select("#", ...), ...
end

local function secrecyOf(spellID)
    local secrets = C_Secrets or {}
    return {
        spellLevel = try(secrets.GetSpellAuraSecrecy, spellID),
        spellSecretNow = try(secrets.ShouldSpellAuraBeSecret, spellID),
        aurasSecretNow = try(secrets.ShouldAurasBeSecret),
        anyRestrictions = try(secrets.HasSecretRestrictions),
    }
end

local function describeAura(aura)
    if ns.IsSecret(aura) then
        return "<secret>"
    elseif type(aura) ~= "table" then
        return tostring(aura)
    end
    local seen = {}
    for _, field in ipairs(AURA_FIELDS) do
        seen[field] = sanitize(aura[field])
    end
    return seen
end

-- Can the aura with this instance id drive a bar and a countdown?
local function probeInstance(instanceID)
    local result = { instanceID = sanitize(instanceID) }
    if ns.IsSecret(instanceID) or type(instanceID) ~= "number" then
        return result
    end
    local auras = C_UnitAuras or {}
    result.instanceSecretNow = try(C_Secrets and C_Secrets.ShouldUnitAuraInstanceBeSecret, "player", instanceID)
    if type(auras.GetAuraDataByAuraInstanceID) == "function" then
        local ok, _, data = pack(pcall(auras.GetAuraDataByAuraInstanceID, "player", instanceID))
        result.data = ok and describeAura(data) or "error"
    end
    if type(auras.GetAuraDuration) ~= "function" then
        result.duration = "no GetAuraDuration"
        return result
    end
    local ok, count, duration = pack(pcall(auras.GetAuraDuration, "player", instanceID))
    if not ok or count == 0 then
        result.duration = ok and "returned nothing" or "error"
        return result
    end
    result.duration = ns.IsSecret(duration) and "secret object" or "object"
    probeBar = probeBar or CreateFrame("StatusBar") -- never shown
    probeBar:Hide()
    if probeBar.SetTimerDuration then
        result.setTimerDuration = pcall(probeBar.SetTimerDuration, probeBar, duration) and "accepted" or "refused"
    end
    return result
end

local function recordBuff(buff, updateInfo, note)
    if #auraSamples >= MAX_AURA_SAMPLES then
        return
    end
    local sample = { spell = buff.name, spellID = buff.spellID, combat = InCombatLockdown() and true or false,
        secrecy = secrecyOf(buff.spellID), note = note }
    local lookup = C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID
    if type(lookup) == "function" then -- documented: returns NOTHING while that aura is secret
        local ok, count, aura = pack(pcall(lookup, buff.spellID))
        sample.lookup = ok and { returned = count, aura = count > 0 and describeAura(aura) or nil } or "error"
        if ok and count > 0 and not ns.IsSecret(aura) and type(aura) == "table" then
            sample.lookupInstance = probeInstance(aura.auraInstanceID)
        end
    end
    -- (kept flat: the report's sanitizer stops at six levels of nesting)
    if ns.IsSecret(updateInfo) then
        sample.event = "<secret>"
    elseif type(updateInfo) == "table" then
        sample.event = "table"
        sample.isFullUpdate = sanitize(updateInfo.isFullUpdate)
        for key, short in pairs({ addedAuras = "added", updatedAuraInstanceIDs = "updated", removedAuraInstanceIDs = "removed" }) do
            local list = updateInfo[key]
            if ns.IsSecret(list) then
                sample[short .. "Count"] = "<secret>"
            elseif type(list) == "table" then
                sample[short .. "Count"] = #list
                for i = 1, math.min(#list, 3) do
                    local entry = list[i]
                    if short == "added" then
                        local id
                        if not ns.IsSecret(entry) and type(entry) == "table" then
                            id = entry.auraInstanceID
                        end
                        sample["added" .. i] = { aura = describeAura(entry), instance = probeInstance(id) }
                    elseif short == "updated" then
                        sample["updated" .. i] = probeInstance(entry)
                    end
                end
            end
        end
    end
    auraSamples[#auraSamples + 1] = sample
end

ns:OnPlayerUnit("UNIT_SPELLCAST_SUCCEEDED", function(_, _, _, spellID)
    if #auraSamples >= MAX_AURA_SAMPLES or ns.IsSecret(spellID) or type(spellID) ~= "number" then
        return
    end
    local getName = C_Spell and C_Spell.GetSpellName
    if type(getName) ~= "function" then
        return
    end
    local ok, name = pcall(getName, spellID)
    if ok and not ns.IsSecret(name) and type(name) == "string" and WATCHED_BUFFS[name] then
        local buff = { spellID = spellID, name = name, at = GetTime() }
        pendingBuff = buff
        C_Timer.After(0.5, function()
            if pendingBuff == buff then -- no UNIT_AURA came for it: still worth a look
                pendingBuff = nil
                ns.SafeCall(recordBuff, buff, nil, "no UNIT_AURA within 0.5s of the cast")
            end
        end)
    end
end)

ns:OnPlayerUnit("UNIT_AURA", function(_, _, updateInfo)
    local buff = pendingBuff
    if buff then
        pendingBuff = nil
        recordBuff(buff, updateInfo, "first UNIT_AURA after the cast")
    end
end)

local function mean(values)
    if #values == 0 then
        return nil
    end
    local sum = 0
    for _, value in ipairs(values) do
        sum = sum + math.abs(value)
    end
    return math.floor(sum / #values * 1000) / 1000
end

------------------------------------------------------------------------
-- The aura probe ('/fct auras'). A stacking buff without a duration - Plainsrunning, say - does not fit
-- the buff bar's model at all, and which fields it carries (applications? points? a duration of 0?) is
-- not written down anywhere. So: ask the client, keep every answer as it came, and look at it afterwards.
-- Read-only, and nothing is looked at before ns.IsSecret cleared it.
------------------------------------------------------------------------
local AURA_FIELDS = { "name", "applications", "charges", "duration", "expirationTime", "spellId", "icon",
    "timeMod", "points", "sourceUnit", "isHelpful", "isHarmful", "auraInstanceID" }

Diagnostics.auraProbe = { takenAt = "never asked" }

function Diagnostics:ProbeAuras()
    local probe = {
        takenAt = date("%Y-%m-%d %H:%M:%S"),
        inCombat = InCombatLockdown() and true or false,
        auras = {},
    }
    local get = C_UnitAuras and C_UnitAuras.GetAuraDataByIndex
    if type(get) ~= "function" then
        probe.note = "this client has no C_UnitAuras.GetAuraDataByIndex"
        Diagnostics.auraProbe = probe
        return probe
    end
    for index = 1, 40 do
        local ok, aura = pcall(get, "player", index, "HELPFUL")
        if not ok then
            probe.note = "index " .. index .. " raised: " .. tostring(aura)
            break
        end
        if aura == nil then
            break
        end
        if ns.IsSecret(aura) then
            probe.auras[#probe.auras + 1] = { index = index, aura = "<secret>" }
        else
            local entry = { index = index }
            for _, field in ipairs(AURA_FIELDS) do
                local value = aura[field]
                if value ~= nil then
                    entry[field] = ns.IsSecret(value) and "<secret>" or sanitize(value)
                end
            end
            probe.auras[#probe.auras + 1] = entry
        end
    end
    Diagnostics.auraProbe = probe
    return probe
end

ns:RegisterCommand("auras", "list the buffs on you right now with every field this client gives them (for '/fct diag')", function()
    local probe = Diagnostics:ProbeAuras()
    if probe.note then
        ns:Print("auras: " .. probe.note)
    end
    if #probe.auras == 0 then
        ns:Print("no readable buffs on you right now" .. (probe.inCombat and " (in a fight an addon may not touch them)" or "") .. ".")
        return
    end
    ns:Print(#probe.auras .. " buff(s) on you" .. (probe.inCombat and " (in combat)" or "") .. ":")
    for _, entry in ipairs(probe.auras) do
        if entry.aura then
            print(string.format("   %2d  |cff888888%s|r", entry.index, entry.aura))
        else
            print(string.format("   %2d  |cffffd100%s|r  stacks %s  duration %s  expires %s  id %s",
                entry.index, tostring(entry.name), tostring(entry.applications or entry.charges or "-"),
                tostring(entry.duration or "-"), tostring(entry.expirationTime or "-"), tostring(entry.spellId or "-")))
        end
    end
    ns:Print("kept for the report - |cffffd100/fct diag|r then |cffffd100/reload|r writes it to disk.")
end)

function Diagnostics:Collect()
    local version, build, buildDate, tocVersion = GetBuildInfo()
    local incoming = ns.Incoming
    local report = {
        addonVersion = ns.version,
        capturedAt = date("%Y-%m-%d %H:%M:%S"),
        build = { version = version, build = build, date = buildDate, toc = tocVersion },
        class = ns.playerClass,
        character = ns.characterKey,
        inCombat = InCombatLockdown() and true or false,
        savedVariableLoads = ns.db.loads,
        savedStateSource = ns.savedStateSource,
        -- what every addon has cost so far, when the profiler is on ("/fct cpu"): a chat line goes by,
        -- a report can be read afterwards
        addons = Diagnostics.AddonUsage and select(1, Diagnostics.AddonUsage()) or nil,
        unknownEvents = sanitize(ns.unknownEvents),
        errors = sanitize(ns.errors),
        auraProbe = sanitize(Diagnostics.auraProbe),
        plains = sanitize(ns.Plains and ns.Plains:Describe() or "no module"),
    }

    report.api = {}
    for _, path in ipairs(API_PATHS) do
        report.api[path] = type(resolve(path))
    end
    report.enums = { PlayerSwingType = sanitize(Enum and Enum.PlayerSwingType) }
    report.cvars = { showSwingTimer = try((C_CVar and C_CVar.GetCVar) or GetCVar, "showSwingTimer") }

    report.player = {
        attackSpeed = try(UnitAttackSpeed, "player"),
        swings = sanitize(ns.Swings.state),
        swingsLocked = ns.Swings.locked,
    }

    report.enemy = {
        watched = incoming.watched,
        interval = incoming.interval,
        confidence = incoming.confidence,
        prior = incoming.prior,
        targetAttackSpeedNow = UnitExists("target") and try(UnitAttackSpeed, "target") or "no target",
        unitCombatEvents = incoming.stats.events,
        unitCombatSecretEvents = incoming.stats.secretEvents,
        hitsTimed = incoming.stats.hits,
        hitsPredicted = incoming.stats.matched,      -- landed where a track expected its next swing
        hitsLate = incoming.stats.rephased,          -- attacker was held up: track re-phased
        newAttackers = incoming.stats.newAttackers,  -- a hit nobody was due for
        tracks = sanitize(incoming.tracks),
        predictionsScored = incoming.stats.scored,
        meanAbsErrorSeconds = mean(incoming.stats.errors),
        errors = sanitize(incoming.stats.errors),
        rawSamples = sanitize(incoming.rawSamples),
    }

    report.blockedActions = sanitize(ns.blockedActions) -- should stay empty
    report.combatLogRestricted = try(C_CombatLog and C_CombatLog.IsCombatLogRestricted)

    -- Cast bars: what did the client hand us for each cast (secret or readable?), and which way of
    -- displaying it did it accept? ("numbers" | "SetTimerDuration" | "SetMinMaxValues" | "refused")
    local castFrames = {}
    for _, name in ipairs({ "PlayerCastingBarFrame", "TargetFrameSpellBar" }) do
        local bar = _G[name]
        if type(bar) == "table" and bar.GetParent then
            -- whatever a getter on Blizzard's frame returns may be secret: never looked at, only sanitized
            local ok, parent = pcall(bar.GetParent, bar)
            local parentName = "?"
            if ok and not ns.IsSecret(parent) and type(parent) == "table" and parent.GetName then
                parentName = try(parent.GetName, parent)
            end
            castFrames[name] = { parent = parentName, scale = try(bar.GetScale, bar), shown = try(bar.IsShown, bar),
                hasSecretValues = try(bar.HasSecretValues, bar) }
        else
            castFrames[name] = "absent"
        end
    end
    report.casts = {
        options = { player = ns.BarSettings:GetMode("CAST"), target = ns.BarSettings:GetMode("TCAST"),
            hideBlizzard = ns:GetOption("hideBlizzardCastBars") },
        proven = sanitize(ns.db.castProven),
        blizzardHidden = sanitize(ns.hiddenCastBars), -- [unit] = "park" | "shrink"
        blizzardFrames = castFrames,
        samples = sanitize(ns.Casts.samples),
        castingNow = try(UnitCastingInfo, "player"),
    }

    -- The buff experiment (see above): cast Slice and Dice (or Sprint / Evasion / Lightning Shield) in and
    -- out of combat, then /fct diag.
    report.buffs = { samples = sanitize(auraSamples), aurasSecretNow = try(C_Secrets and C_Secrets.ShouldAurasBeSecret),
        -- the buff BAR: how each tracked buff was found ("by spell id" | "the one new instance id" | ... |
        -- "NOT FOUND") and which display path the client took
        tracked = sanitize(ns.Buffs:GetTracked()), bar = sanitize(ns.Buffs.samples),
        probes = sanitize(ns.Buffs.probes), estimates = sanitize(ns.Buffs.estimates) }
    -- The DoT bars: which spells own a slot, how long each was found to run (and whether a real aura
    -- taught us that or the table did), and the last few that were put on a bar.
    if ns.Dots then
        local dots = ns.Dots:Report()
        -- `observed` against `expected` is the whole answer on the Rupture / Rip numbers: the
        -- durations a real aura actually handed over, beside the ones that were assumed.
        report.dots = { tracked = sanitize(dots.tracked), learned = sanitize(dots.learned),
            observedLengths = sanitize(dots.observed), assumedLengths = sanitize(dots.expected),
            enemiesRemembered = dots.enemies, timersRunning = dots.timers,
            recent = sanitize(ns.Dots.samples) }
    end
    -- The reactive windows: what has a bar, what is open right now, and the counts - in particular how
    -- many target dodges were judged somebody else's, which is the attribution question in numbers.
    if ns.Reactive then
        report.reactive = sanitize(ns.Reactive:Report())
        report.reactive.recent = sanitize(ns.Reactive.samples)
    end
    report.bars = { settings = sanitize(ns.cdb.bars), order = sanitize(ns.BarSettings:GetOrder()),
        position = sanitize(ns.cdb.position), locked = ns:GetOption("locked") and true or false }

    report.log = sanitize(ns.sessionLog)
    return report
end

function Diagnostics:Save()
    ns.db.diag = self:Collect()
    return ns.db.diag
end

ns:RegisterCommand("diag", "snapshot swing/enemy-timer data into SavedVariables (then /reload and share the file)", function()
    local report = Diagnostics:Save()
    local enemy = report.enemy
    ns:Print("diagnostics captured. own swings seen: MH", ns.Swings.state.MH.count, "OH", ns.Swings.state.OH.count, "RG", ns.Swings.state.RG.count)
    ns:Print("enemy timer: UNIT_COMBAT events", enemy.unitCombatEvents, "(secret:", enemy.unitCombatSecretEvents .. ")",
        "| hits timed", enemy.hitsTimed, "| predictions scored", enemy.predictionsScored,
        "| mean error", enemy.meanAbsErrorSeconds and (enemy.meanAbsErrorSeconds .. "s") or "n/a")
    ns:Print("blocked actions:", #ns.blockedActions, "| now type |cffffd100/reload|r to write the report to disk")
end)

------------------------------------------------------------------------
-- '/fct cpu': which addon is eating the frame?
--
-- The client can time every addon's Lua for you, but only when scriptProfile is on, and only from the
-- next reload - it has to be in place before the code runs. So the command turns it on and says to
-- reload; after that it reads the numbers back. Memory is always available and needs no reload.
--
-- CPU here is time spent in Lua since the profile began, in milliseconds. What matters is the SHAPE of
-- the list - one addon far above the rest - not the absolute figures.
------------------------------------------------------------------------
local function profiling()
    local get = _G.GetCVar or (C_CVar and C_CVar.GetCVar)
    if type(get) ~= "function" then
        return nil -- this client has no CVar interface for it
    end
    local ok, value = pcall(get, "scriptProfile")
    if not ok or ns.IsSecret(value) then
        return nil
    end
    return value == "1" or value == 1
end

local function addonList()
    local count = (C_AddOns and C_AddOns.GetNumAddOns and C_AddOns.GetNumAddOns()) or (_G.GetNumAddOns and GetNumAddOns())
    if type(count) ~= "number" then
        return nil
    end
    local getInfo = (C_AddOns and C_AddOns.GetAddOnInfo) or _G.GetAddOnInfo
    local cpuOf = _G.GetAddOnCPUUsage
    local memoryOf = _G.GetAddOnMemoryUsage
    if _G.UpdateAddOnCPUUsage then
        pcall(_G.UpdateAddOnCPUUsage)
    end
    if _G.UpdateAddOnMemoryUsage then
        pcall(_G.UpdateAddOnMemoryUsage)
    end
    local list, totalCPU, totalMemory = {}, 0, 0
    for index = 1, count do
        local okName, name = pcall(getInfo, index)
        local cpu = cpuOf and select(2, pcall(cpuOf, index)) or nil
        local memory = memoryOf and select(2, pcall(memoryOf, index)) or nil
        if okName and type(name) == "string" and not ns.IsSecret(name) then
            cpu = (type(cpu) == "number" and not ns.IsSecret(cpu)) and cpu or 0
            memory = (type(memory) == "number" and not ns.IsSecret(memory)) and memory or 0
            list[#list + 1] = { name = name, cpu = cpu, memory = memory }
            totalCPU, totalMemory = totalCPU + cpu, totalMemory + memory
        end
    end
    return list, totalCPU, totalMemory
end

Diagnostics.AddonUsage = addonList

ns:RegisterCommand("cpu", "which addon is eating the frame: turns on the client's profiler (needs one /reload), then lists the worst offenders", function()
    local on = profiling()
    local list, totalCPU, totalMemory = addonList()
    if not list then
        ns:Print("this client will not list addons, so there is nothing to measure.")
        return
    end

    table.sort(list, function(a, b)
        if a.cpu ~= b.cpu then
            return a.cpu > b.cpu
        end
        return a.memory > b.memory
    end)

    if on == false then
        local set = _G.SetCVar or (C_CVar and C_CVar.SetCVar)
        if type(set) == "function" and pcall(set, "scriptProfile", "1") then
            ns:Print("the client's profiler was off. It is on now - |cffffd100/reload|r, play for a minute, then |cffffd100/fct cpu|r again.")
        else
            ns:Print("the client's profiler is off and would not turn on; only memory is shown below.")
        end
    elseif on == nil then
        ns:Print("this client will not say whether the profiler is on; only memory may be meaningful below.")
    end

    ns:Print(string.format("addons loaded: %d | Lua time so far: %.0f ms | memory: %.1f MB", #list, totalCPU, totalMemory / 1024))
    for index = 1, math.min(8, #list) do
        local entry = list[index]
        local share = totalCPU > 0 and (entry.cpu / totalCPU * 100) or 0
        ns:Print(string.format("  %-28s %8.0f ms (%4.1f%%)  %6.1f MB", entry.name, entry.cpu, share, entry.memory / 1024))
    end
    if totalCPU <= 0 then
        ns:Print("no Lua time recorded yet - that is what the reload above is for.")
    else
        ns:Print("one addon far above the rest is your answer; an even spread means the lag is not addon Lua.")
    end
end)

-- Keep a report even if nobody asked for one: logout and /reload both write it.
ns:On("PLAYER_LOGOUT", function()
    Diagnostics:Save()
end)
