-- Buffs: how long a buff of yours still runs - first of all a rogue's Slice and Dice.
--
-- MEASURED on this client (reports of 2026-09-20): out of combat an aura is plainly readable. In a fight
-- an addon cannot touch the player's auras AT ALL: a lookup by spell returns nothing, UNIT_AURA's payload
-- is secret, and even the list of aura instance ids raises "Auras cannot be accessed when secret while
-- tainted". So a buff cast in a fight cannot be found - it used to show up only when the fight was over
-- ("just the last 10 seconds").
--
-- What is open in a fight: your OWN casts are never secret (UNIT_SPELLCAST_SENT / _SUCCEEDED name the
-- spell), and a finisher's duration follows from the combo points spent. Those are secret too - but
-- UnitPowerPercent(unit, powerType, unmodified, curve) lets the CLIENT put the secret value through a
-- curve of ours and hands back the (secret) result. With the curve "points / 5 -> minus the seconds that
-- many points buy" the result is exactly what a status bar needs as its lower bound:
--     bar:SetMinMaxValues(<secret: -duration>, 0)     bar:SetValue(-(seconds since the cast))
-- starts full and is empty when the buff ends - without a single secret value being read. The value is
-- taken when the cast is SENT (the points are still there); should that event be missing, the newest
-- snapshot from just before the cast is used. Nothing can count the seconds down as text from a bound we
-- cannot read, so the estimate is a bar only; when the fight ends the real aura takes over, with numbers.
-- A real, readable aura also teaches us the talent factor (Improved Slice and Dice stretches the table).
local _, ns = ...

local Buffs = {}
ns.Buffs = Buffs

local CLASS_DEFAULTS = {
    ROGUE = { "Slice and Dice" },
}
-- seconds per combo point spent (rank 1 and 2 alike); stretched by the talent factor once that is known
local FINISHER_SECONDS = {
    ["slice and dice"] = { 9, 12, 15, 18, 21 },
}
local TALENT_FACTORS = { 1, 1.15, 1.30, 1.45 }
local POWER_COMBO_POINTS = (Enum and Enum.PowerType and Enum.PowerType.ComboPoints) or 4
local RESOLVE_WINDOW = 1.0   -- seconds after a cast in which a readable aura is still waited for
local SENT_WINDOW = 1.5      -- a SENT older than this does not belong to the SUCCEEDED at hand
local BEFORE_THE_CAST = 0.35 -- without SENT: the newest snapshot at least this old predates the points being spent
local MAX_SAMPLES = 12

Buffs.samples = {} -- for /fct diag
Buffs.estimates = { sent = 0, snapshots = 0, lastKind = "never asked", curve = "not built", factors = {} }
local active       -- the buff on the bar
local pending      -- a tracked spell was just cast; its (readable) aura has not turned up yet
local serial = 0

local function pack(ok, ...)
    if not ok then
        return false, (...) -- the error message
    end
    return ok, select("#", ...), ...
end

------------------------------------------------------------------------
-- What is tracked: spell NAMES (ranks have different ids), first match wins
------------------------------------------------------------------------
function Buffs:GetTracked()
    local saved = ns.cdb and ns.cdb.buffs
    if type(saved) == "table" then
        return saved
    end
    return CLASS_DEFAULTS[ns.playerClass or ""] or {}
end

function Buffs:HasTracked()
    return #self:GetTracked() > 0
end

local function isTracked(name)
    for _, tracked in ipairs(Buffs:GetTracked()) do
        if string.lower(tracked) == string.lower(name) then
            return true
        end
    end
    return false
end

------------------------------------------------------------------------
-- Looking at auras - every answer may be secret, none is looked at before ns.IsSecret cleared it
------------------------------------------------------------------------
local function readAura(aura)
    if ns.IsSecret(aura) or type(aura) ~= "table" then
        return nil
    end
    local duration, expires, icon, spellID = aura.duration, aura.expirationTime, aura.icon, aura.spellId
    if ns.AnySecret(duration, expires, icon, spellID) or type(duration) ~= "number" or type(expires) ~= "number" or duration <= 0 then
        return nil
    end
    return { startTime = expires - duration, endTime = expires, total = duration, texture = icon, spellID = spellID }
end

local function lookupBySpell(spellID)
    local lookup = C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID
    if type(lookup) ~= "function" then
        return nil
    end
    local ok, count, aura = pack(pcall(lookup, spellID))
    return ok and count > 0 and readAura(aura) or nil
end

-- the aura - and whether the client gave a clear answer at all (false: we cannot tell if it is there)
local function lookupByName(name)
    local lookup = C_UnitAuras and C_UnitAuras.GetAuraDataBySpellName
    if type(lookup) ~= "function" then
        return nil, false
    end
    local ok, count, aura = pack(pcall(lookup, "player", name, "HELPFUL"))
    if not ok or ns.IsSecret(aura) then
        return nil, false
    end
    return count > 0 and readAura(aura) or nil, true
end

------------------------------------------------------------------------
-- The talent factor, learned from a real aura: its total duration is one of seconds[points] x factor
------------------------------------------------------------------------
local function factorFor(name)
    local saved = ns.cdb and ns.cdb.buffFactors
    return type(saved) == "table" and saved[string.lower(name)] or 1
end

local function learnFactor(name, total)
    local seconds = FINISHER_SECONDS[string.lower(name)]
    if not seconds then
        return nil
    end
    for _, factor in ipairs(TALENT_FACTORS) do
        for points, base in ipairs(seconds) do
            if math.abs(base * factor - total) < 0.06 then
                ns.cdb.buffFactors = ns.cdb.buffFactors or {}
                if ns.cdb.buffFactors[string.lower(name)] ~= factor then
                    ns.cdb.buffFactors[string.lower(name)] = factor
                    Buffs.curves = nil -- built for the old factor
                    ns:Log("buff_factor", { spell = name, factor = factor })
                end
                Buffs.estimates.factors[name] = factor
                return points, factor
            end
        end
    end
    Buffs.estimates.factors[name] = "a duration of " .. total .. " s fits no combo point count: the table is not this client's"
    return nil
end

------------------------------------------------------------------------
-- From "a tracked spell was cast" to "this is on the bar"
------------------------------------------------------------------------
local function sample(buff, how, extra)
    if #Buffs.samples >= MAX_SAMPLES then
        table.remove(Buffs.samples, 1)
    end
    buff.sample = { spell = buff.name, combat = InCombatLockdown() and true or false, found = how, path = "not shown yet" }
    for key, value in pairs(extra or {}) do
        buff.sample[key] = value
    end
    Buffs.samples[#Buffs.samples + 1] = buff.sample
end

local function show(cast, aura, how)
    serial = serial + 1
    local points = learnFactor(cast.name, aura.total)
    active = { kind = "buff", owner = Buffs, drains = true, serial = serial, began = GetTime(), name = cast.name,
        fallbackLabel = cast.name, texture = cast.texture or aura.texture, spellID = cast.spellID or aura.spellID,
        timesReadable = true, startTime = aura.startTime, endTime = aura.endTime }
    sample(active, how, { total = aura.total, comboPoints = points })
    pending = nil
end

------------------------------------------------------------------------
-- In a fight: the combo point route (see the top of this file)
------------------------------------------------------------------------
local history = {} -- the last snapshots: { name, value, kind, at }
local sent         -- the snapshot taken when a tracked finisher was SENT

local function curveFor(name)
    local key = string.lower(name)
    Buffs.curves = Buffs.curves or {}
    if Buffs.curves[key] ~= nil then
        return Buffs.curves[key] or nil
    end
    Buffs.curves[key] = false
    local seconds = FINISHER_SECONDS[key]
    local create = C_CurveUtil and C_CurveUtil.CreateCurve
    if not seconds or type(create) ~= "function" or type(UnitPowerPercent) ~= "function" then
        Buffs.estimates.curve = "this client has no C_CurveUtil.CreateCurve / UnitPowerPercent"
        return nil
    end
    local factor = factorFor(name)
    local ok, err = pcall(function()
        local curve = create()
        if curve.SetType and Enum and Enum.LuaCurveType then
            curve:SetType(Enum.LuaCurveType.Linear) -- (exact at the points; a step curve could snap the wrong way)
        end
        curve:AddPoint(0, 0)
        for points, base in ipairs(seconds) do
            curve:AddPoint(points / #seconds, -(base * factor))
        end
        Buffs.curves[key] = curve
    end)
    Buffs.estimates.curve = ok and ("built, factor " .. factor) or ("failed: " .. tostring(err))
    return Buffs.curves[key] or nil
end

-- { value = <-seconds; secret or plain>, kind = "secret" | "number" } - or nil
local function snapshot(name)
    local curve = curveFor(name)
    if not curve then
        return nil
    end
    local ok, count, value = pack(pcall(UnitPowerPercent, "player", POWER_COMBO_POINTS, false, curve))
    local kind
    if not ok then
        kind = "error: " .. tostring(count)
    elseif count == 0 then
        kind = "returned nothing"
    elseif ns.IsSecret(value) then
        kind = "secret"
    elseif type(value) == "number" then
        kind = "number"
    else
        kind = "a " .. type(value)
    end
    Buffs.estimates.lastKind = kind
    if kind ~= "secret" and kind ~= "number" then
        return nil
    end
    Buffs.estimates.snapshots = Buffs.estimates.snapshots + 1
    return { name = name, value = value, kind = kind, at = GetTime() }
end

local function rememberSnapshots()
    for _, name in ipairs(Buffs:GetTracked()) do
        if FINISHER_SECONDS[string.lower(name)] then
            local taken = snapshot(name)
            if taken then
                history[#history + 1] = taken
                if #history > 24 then
                    table.remove(history, 1)
                end
            end
        end
    end
end

local function snapshotFor(cast, now)
    if sent and sent.spellID == cast.spellID and now - sent.at <= SENT_WINDOW then
        return sent, "when the cast was sent"
    end
    local newest
    for index = #history, 1, -1 do
        local taken = history[index]
        if string.lower(taken.name) == string.lower(cast.name) then
            newest = newest or taken
            if taken.at <= now - BEFORE_THE_CAST then
                return taken, "a snapshot from before the cast"
            end
        end
    end
    return newest, "the newest snapshot (may already be after the points were spent)"
end

-- true when the cast went onto the bar as an estimate
local function showEstimate(cast)
    local seconds = FINISHER_SECONDS[string.lower(cast.name)]
    if not seconds then
        return false
    end
    local now = GetTime()
    local taken, source = snapshotFor(cast, now)
    if not taken then
        return false
    end
    if taken.kind == "number" then
        -- this client lets us read it after all: plain arithmetic, with a countdown
        if taken.value > -0.5 then
            return false -- no combo points in it: nothing sensible to show
        end
        show(cast, { startTime = now, endTime = now - taken.value, total = -taken.value }, "combo points (readable), " .. source)
        return true
    end
    serial = serial + 1
    local began = now
    active = { kind = "buff", owner = Buffs, drains = true, serial = serial, began = began, name = cast.name,
        fallbackLabel = cast.name, texture = cast.texture, spellID = cast.spellID,
        estimated = true, timesReadable = false, hasDuration = false,
        secretStart = taken.value, secretEnd = 0, -- the bar's bounds: minus the (secret) seconds ... 0
        clock = function(at) return -(at - began) end, -- ... and where between them we are
        giveUpAt = began + seconds[#seconds] * factorFor(cast.name) + 0.3 }
    sample(active, "combo points (secret), " .. source, { snapshotAge = now - taken.at })
    return true
end

-- The buff to show now, or nil.
function Buffs:Get(now)
    if not active then
        return nil
    end
    now = now or GetTime()
    if (active.timesReadable and now > active.endTime) or (active.estimated and now > active.giveUpAt) then
        active = nil
    end
    return active
end

-- fraction (a buff drains), seconds remaining. Timed buffs only.
function Buffs:GetProgress(buff, now)
    local total = buff.endTime - buff.startTime
    local remaining = math.min(total, math.max(0, buff.endTime - now))
    return remaining / total, remaining
end

function Buffs:ReportPath(buff, path, seconds)
    if buff.sample then
        buff.sample.path, buff.sample.seconds = path, seconds
    end
end

------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------
local function trackedCast(spellID)
    if ns.IsSecret(spellID) or type(spellID) ~= "number" or not Buffs:HasTracked() then
        return nil
    end
    local getName = C_Spell and C_Spell.GetSpellName
    if type(getName) ~= "function" then
        return nil
    end
    local ok, name = pcall(getName, spellID)
    if not ok or ns.IsSecret(name) or type(name) ~= "string" or not isTracked(name) then
        return nil
    end
    local texture
    if C_Spell.GetSpellTexture then
        local okTexture, found = pcall(C_Spell.GetSpellTexture, spellID)
        if okTexture and not ns.IsSecret(found) then
            texture = found
        end
    end
    return { spellID = spellID, name = name, texture = texture, at = GetTime() }
end

-- (unit, target, castGUID, spellID) - the moment the key was pressed: the combo points are still there
ns:OnPlayerUnit("UNIT_SPELLCAST_SENT", function(_, _, _, _, spellID)
    local cast = trackedCast(spellID)
    if cast and FINISHER_SECONDS[string.lower(cast.name)] then
        Buffs.estimates.sent = Buffs.estimates.sent + 1
        sent = snapshot(cast.name)
        if sent then
            sent.spellID = spellID
        end
    end
end)

ns:OnPlayerUnit("UNIT_SPELLCAST_SUCCEEDED", function(_, _, _, spellID)
    local cast = trackedCast(spellID)
    if not cast then
        return
    end
    local aura = lookupBySpell(spellID)
    if aura then
        show(cast, aura, "by spell id")
    elseif not showEstimate(cast) then
        pending = cast -- (out of combat the aura may simply not be there yet: the next UNIT_AURA brings it)
    else
        pending = nil
    end
    sent = nil
end)

ns:OnPlayerUnit("UNIT_AURA", function()
    if pending then
        if GetTime() - pending.at > RESOLVE_WINDOW then
            if #Buffs.samples < MAX_SAMPLES then
                Buffs.samples[#Buffs.samples + 1] = { spell = pending.name, combat = InCombatLockdown() and true or false,
                    found = "NOT FOUND", path = "none", estimate = Buffs.estimates.lastKind }
            end
            pending = nil
        else
            local aura = lookupBySpell(pending.spellID)
            if aura then
                show(pending, aura, "by spell id")
            end
        end
    end
    -- a readable buff that is gone (cancelled, dispelled): off the bar. In a fight nothing can be asked.
    if active and active.timesReadable and not InCombatLockdown() then
        local aura, couldTell = lookupByName(active.name)
        if couldTell and not aura then
            active = nil
        end
    end
end)

-- Logging in, or leaving a fight: auras are readable then. A running buff goes onto the bar with its real
-- numbers (replacing an estimate); an estimate whose buff is gone is dropped.
local function lookForRunningBuffs()
    if not Buffs:HasTracked() or (active and active.timesReadable) then
        return
    end
    for _, name in ipairs(Buffs:GetTracked()) do
        local aura = lookupByName(name)
        if aura then
            show({ name = name }, aura, active and "the real aura, after the fight" or "already running")
            return
        end
    end
    if active and active.estimated and not InCombatLockdown() then
        active = nil -- readable now, and not there: it has run out
    end
end

ns:On("PLAYER_ENTERING_WORLD", lookForRunningBuffs)
ns:Listen("COMBAT_END", lookForRunningBuffs)

ns:Listen("LOGIN", function()
    if ns.playerClass == "ROGUE" or ns.playerClass == "DRUID" then
        ns:OnPlayerUnit("UNIT_POWER_FREQUENT", rememberSnapshots)
        ns:On("PLAYER_TARGET_CHANGED", rememberSnapshots) -- combo points live on the target
    end
end)

------------------------------------------------------------------------
-- /fct buff
------------------------------------------------------------------------
ns:RegisterCommand("buff", "which buffs of yours get the buff bar: '/fct buff' lists, 'add <spell name>', 'remove <spell name>', 'reset'", function(rest)
    local what, name = string.match(rest or "", "^%s*(%S*)%s*(.-)%s*$")
    what = string.lower(what or "")
    if (what == "add" or what == "remove") and name ~= "" then
        local list = {}
        for _, tracked in ipairs(Buffs:GetTracked()) do
            if string.lower(tracked) ~= string.lower(name) then
                list[#list + 1] = tracked
            end
        end
        if what == "add" then
            list[#list + 1] = name
        end
        ns.cdb.buffs = list
        ns:Fire("BARS_CHANGED") -- the buff row appears with the first tracked buff, and goes with the last
    elseif what == "reset" then
        ns.cdb.buffs = nil
        ns:Fire("BARS_CHANGED")
    elseif what ~= "" then
        ns:Print("usage: /fct buff | add <spell name> | remove <spell name> | reset")
        return
    end
    local tracked = Buffs:GetTracked()
    ns:Print("buff bar tracks:", #tracked > 0 and table.concat(tracked, ", ") or "nothing (so it takes no row) - /fct buff add <spell name>")
end)

------------------------------------------------------------------------
-- The in-combat question, asked once per session (for /fct diag -> buffs.probes): should a later build
-- let addons at the auras in a fight again, the report will say so.
------------------------------------------------------------------------
Buffs.probes = {}

local function probe(moment)
    local entry = { moment = moment, combat = InCombatLockdown() and true or false }
    local list = C_UnitAuras and C_UnitAuras.GetUnitAuraInstanceIDs
    if type(list) ~= "function" then
        entry.listing = "no GetUnitAuraInstanceIDs"
    else
        local ok, count, ids = pack(pcall(list, "player", "HELPFUL"))
        if not ok then
            entry.listing = "error: " .. tostring(count)
        elseif count == 0 or ns.IsSecret(ids) or type(ids) ~= "table" then
            entry.listing = count == 0 and "returned nothing" or "secret / not a table"
        else
            entry.listing = #ids .. " ids"
        end
    end
    Buffs.probes[#Buffs.probes + 1] = entry
end

local probedInCombat = false
ns:Listen("COMBAT_START", function()
    if probedInCombat then
        return
    end
    C_Timer.After(3, function()
        if ns.inCombat and not probedInCombat then
            probedInCombat = true
            ns.SafeCall(probe, "3s into a fight")
        end
    end)
end)

------------------------------------------------------------------------
-- The same trick, offered to anything else whose length a finisher's combo points decide: the client
-- puts the (secret) points through a curve of ours and hands back a (secret) negative duration, which is
-- exactly what a status bar wants as its lower bound. The DoT bars use it for Rupture and Rip, whose
-- length no table can predict, because the points that bought it were never readable.
------------------------------------------------------------------------
function Buffs:ComboBound(name, secondsTable)
    local key = "combo:" .. string.lower(name or "")
    Buffs.curves = Buffs.curves or {}
    if Buffs.curves[key] == nil then
        Buffs.curves[key] = false
        local create = C_CurveUtil and C_CurveUtil.CreateCurve
        if type(secondsTable) == "table" and #secondsTable > 0
            and type(create) == "function" and type(UnitPowerPercent) == "function" then
            pcall(function()
                local curve = create()
                if curve.SetType and Enum and Enum.LuaCurveType then
                    curve:SetType(Enum.LuaCurveType.Linear)
                end
                curve:AddPoint(0, 0)
                for points, base in ipairs(secondsTable) do
                    curve:AddPoint(points / #secondsTable, -base)
                end
                Buffs.curves[key] = curve
            end)
        end
    end
    local curve = Buffs.curves[key] or nil
    if not curve then
        return nil
    end
    local ok, count, value = pack(pcall(UnitPowerPercent, "player", POWER_COMBO_POINTS, false, curve))
    if not ok or count == 0 then
        return nil
    end
    if ns.IsSecret(value) or type(value) == "number" then
        return value -- secret or plain, it is never looked at here
    end
    return nil
end
