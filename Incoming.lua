-- Incoming: when will the next enemy melee swing land?
--
-- There is no C_SwingTimer for other units, and the combat log is closed to
-- addons. What the client does still announce is UNIT_COMBAT: "this unit was just
-- hit / dodged / parried / blocked / missed", for you, your target, focus, pet and
-- group members. It names the VICTIM, never the attacker - so this is a timer of
-- hits landing on one watched unit:
--
--   hostile target    -> whoever it is attacking (you, or a group member)
--   friendly target   -> that friendly (a healer watching the tank)
--   nothing targeted  -> you
--
-- Measured in the Forever beta (rogue, open world, 306 events): UNIT_COMBAT stays
-- readable in combat; the target's attack speed is readable OUT of combat and
-- secret IN combat. So the speed is noted while we can see it and kept for the
-- fight.
--
-- The model keeps one TRACK per attacker. A hit that lands where a track expects
-- its next swing belongs to that attacker; a hit that comes early is somebody
-- else; a hit that comes late means the attacker was held up (stunned, chasing,
-- out of reach) and only re-phases the track - the long gap is never learned as
-- a swing interval. Every prediction is scored against what actually happened;
-- see /fct diag and tests/replay.lua.
local _, ns = ...

local Incoming = {}
ns.Incoming = Incoming

local MAX_TRACKS = 4
local MAX_DELTAS = 5
local MIN_INTERVAL, MAX_INTERVAL = 0.7, 6.0
local DUPLICATE_WINDOW = 0.05  -- the same hit reported twice
local DEFAULT_INTERVAL = 2.0   -- typical mob, used until we know better
local IDLE_FACTOR = 2.5        -- this many intervals without a hit -> the attacker stopped
local PRIOR_TRUST = 0.12       -- observed rhythm must differ this much before it overrules the known speed
local OUTCOME_WINDOW = 6
local RAW_SAMPLE_MAX = 120

local PHYSICAL = 1
local AVOIDED = { MISS = true, DODGE = true, PARRY = true, DEFLECT = true }
local LANDED = { WOUND = true, BLOCK = true, ABSORB = true }

Incoming.watched = "player"
Incoming.tracks = {}
Incoming.hits = {}       -- recent hit times, newest last (diagnostics + tests)
Incoming.outcomes = {}   -- last few hits: true = predicted, false = not
Incoming.interval = nil  -- of the track that was hit last
Incoming.confidence = 0
Incoming.prior = nil     -- the target's attack speed, noted while the client lets us read it
Incoming.rawSamples = {}
Incoming.stats = {
    hits = 0, scored = 0, matched = 0, rephased = 0, newAttackers = 0,
    absErrorSum = 0, errors = {}, secretEvents = 0, events = 0,
}

------------------------------------------------------------------------
-- Which unit are we watching?
------------------------------------------------------------------------
-- true / false, or nil when the client will not answer
local function ask(fn, ...)
    local ok, value = pcall(fn, ...)
    if not ok or ns.IsSecret(value) then
        return nil
    end
    return value and true or false
end

-- UNIT_COMBAT only names plain tokens, so "targettarget" has to be mapped to one.
local function groupTokenFor(unit)
    if ask(UnitIsUnit, unit, "player") then
        return "player"
    end
    if UnitExists("pet") and ask(UnitIsUnit, unit, "pet") then
        return "pet"
    end
    local prefix, count = "party", 4
    if IsInRaid and IsInRaid() then
        prefix, count = "raid", 40
    end
    for i = 1, count do
        local token = prefix .. i
        if UnitExists(token) and ask(UnitIsUnit, unit, token) then
            return token
        end
    end
    return nil
end

function Incoming:ResolveWatched()
    local override = ns:GetOption("watchUnit")
    if override and UnitExists(override) then
        return override
    end
    if UnitExists("target") then
        if ask(UnitCanAttack, "player", "target") then
            if UnitExists("targettarget") then
                return groupTokenFor("targettarget") or "player"
            end
            return "player"
        elseif ask(UnitIsFriend, "player", "target") and not ask(UnitIsUnit, "target", "player") then
            return "target"
        end
    end
    return "player"
end

function Incoming:Reset(reason)
    self.tracks, self.hits, self.outcomes = {}, {}, {}
    self.interval, self.confidence = nil, 0
    ns:Log("incoming_reset", reason)
    ns:Fire("INCOMING_CHANGED")
end

function Incoming:UpdateWatched(reason)
    local watched = self:ResolveWatched()
    if watched ~= self.watched then
        self.watched = watched
        self:Reset("watching " .. watched .. " (" .. reason .. ")")
    end
    self:ReadPrior(reason)
end

-- The hostile target's attack speed. Readable out of combat, secret in combat
-- (measured) - so a secret answer must NOT wipe what we noted before the pull.
function Incoming:ReadPrior(reason, targetChanged)
    if targetChanged then
        self.prior = nil
    end
    if not UnitExists("target") or ask(UnitCanAttack, "player", "target") == false then
        self.prior = nil
        return
    end
    local ok, speed = pcall(UnitAttackSpeed, "target")
    local readable = ok and not ns.IsSecret(speed) and type(speed) == "number" and speed > 0
    if readable then
        self.prior = speed
    end
    local verdict = readable and speed or (ok and "secret" or "error")
    if self.lastPriorVerdict ~= verdict then
        self.lastPriorVerdict = verdict
        ns:Log("target_attack_speed", { value = verdict, kept = self.prior, why = reason })
    end
end

------------------------------------------------------------------------
-- The model
------------------------------------------------------------------------
local function median(values)
    local sorted = {}
    for i, value in ipairs(values) do
        sorted[i] = value
    end
    table.sort(sorted)
    local n = #sorted
    if n == 0 then
        return nil
    end
    if n % 2 == 1 then
        return sorted[(n + 1) / 2]
    end
    return (sorted[n / 2] + sorted[n / 2 + 1]) / 2
end

local function tolerance(interval)
    return math.max(0.3, interval * 0.2)
end

function Incoming:ExpireTracks(now)
    for index = #self.tracks, 1, -1 do
        local track = self.tracks[index]
        if now - track.last > track.interval * IDLE_FACTOR then
            table.remove(self.tracks, index)
        end
    end
end

function Incoming:NewTrack(now)
    local interval = self.prior
    if not interval then
        for _, other in ipairs(self.tracks) do
            if other.hits >= 2 then
                interval = other.interval -- probably the same kind of mob
                break
            end
        end
    end
    local track = { last = now, interval = interval or DEFAULT_INTERVAL, deltas = {}, hits = 1 }
    if #self.tracks >= MAX_TRACKS then
        local stalest = 1
        for index, other in ipairs(self.tracks) do
            if other.last < self.tracks[stalest].last then
                stalest = index
            end
        end
        table.remove(self.tracks, stalest)
    end
    self.tracks[#self.tracks + 1] = track
    return track
end

local function learnInterval(self, track, delta)
    if delta < MIN_INTERVAL or delta > MAX_INTERVAL then
        return
    end
    track.deltas[#track.deltas + 1] = delta
    if #track.deltas > MAX_DELTAS then
        table.remove(track.deltas, 1)
    end
    local observed = median(track.deltas)
    if self.prior and not (#track.deltas >= 3 and math.abs(observed - self.prior) / self.prior > PRIOR_TRUST) then
        track.interval = self.prior -- the game told us; trust it until the rhythm clearly disagrees (slow, haste)
    else
        track.interval = observed
    end
end

local function recordOutcome(self, predicted)
    local outcomes = self.outcomes
    outcomes[#outcomes + 1] = predicted
    if #outcomes > OUTCOME_WINDOW then
        table.remove(outcomes, 1)
    end
end

local function score(self, err)
    local stats = self.stats
    stats.scored = stats.scored + 1
    stats.absErrorSum = stats.absErrorSum + math.abs(err)
    stats.errors[#stats.errors + 1] = math.floor(err * 1000) / 1000
    if #stats.errors > 80 then
        table.remove(stats.errors, 1)
    end
end

local function trackConfidence(self, track)
    if track.hits >= 3 then
        return 0.95
    elseif track.hits == 2 or self.prior then
        return 0.8
    end
    return 0.3
end

function Incoming:OnHit(now, action)
    self:ExpireTracks(now)
    local best, bestDiff
    for _, track in ipairs(self.tracks) do
        if now - track.last < DUPLICATE_WINDOW then
            return
        end
        local diff = now - (track.last + track.interval)
        if not bestDiff or math.abs(diff) < math.abs(bestDiff) then
            best, bestDiff = track, diff
        end
    end

    local stats = self.stats
    stats.hits = stats.hits + 1
    self.hits[#self.hits + 1] = now
    if #self.hits > 10 then
        table.remove(self.hits, 1)
    end

    local track, verdict
    if best and math.abs(bestDiff) <= tolerance(best.interval) then
        -- the swing that track was waiting for
        track, verdict = best, "predicted"
        stats.matched = stats.matched + 1
        score(self, bestDiff)
        recordOutcome(self, true)
        learnInterval(self, track, now - track.last)
        track.last, track.hits = now, track.hits + 1
    elseif best and bestDiff > 0 then
        -- late: that attacker was held up. Re-phase; do not learn the gap.
        track, verdict = best, "late"
        stats.rephased = stats.rephased + 1
        score(self, bestDiff)
        recordOutcome(self, false)
        track.last = now
    else
        -- earlier than anyone was due (or the first hit of all): another attacker
        track, verdict = self:NewTrack(now), "new attacker"
        stats.newAttackers = stats.newAttackers + 1
        if best then
            recordOutcome(self, false) -- a hit the bar did not announce
        end
    end

    self.interval = track.interval
    local predicted, total = 0, #self.outcomes
    for _, outcome in ipairs(self.outcomes) do
        if outcome then
            predicted = predicted + 1
        end
    end
    local reliability = total > 0 and (0.3 + 0.7 * predicted / total) or 1
    self.confidence = trackConfidence(self, track) * reliability

    ns:Log("incoming_hit", {
        on = self.watched,
        action = action,
        verdict = verdict,
        off = best and math.floor(bestDiff * 100) / 100 or nil,
        interval = math.floor(track.interval * 100) / 100,
        attackers = #self.tracks,
    })
    ns:Fire("INCOMING_CHANGED")
end

-- active, fraction (0 -> 1 towards the next hit), remaining, confidence, attackers
function Incoming:GetProgress(now)
    local soonest, soonestRemaining
    local attackers = 0
    for _, track in ipairs(self.tracks) do
        if now - track.last <= track.interval * IDLE_FACTOR then
            attackers = attackers + 1
            local remaining = track.last + track.interval - now
            if not soonestRemaining or remaining < soonestRemaining then
                soonest, soonestRemaining = track, remaining
            end
        end
    end
    if not soonest then
        return false, 0, 0, 0, 0
    end
    if soonestRemaining <= 0 then
        return true, 1, 0, self.confidence, attackers -- due any moment
    end
    return true, 1 - soonestRemaining / soonest.interval, soonestRemaining, self.confidence, attackers
end

------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------
local function isMeleeSwing(action, school)
    if AVOIDED[action] then
        return true
    end
    return LANDED[action] and school == PHYSICAL or false
end

ns:On("UNIT_COMBAT", function(_, unit, action, flagText, amount, school)
    local stats = Incoming.stats
    stats.events = stats.events + 1
    if ns.AnySecret(unit, action, school) then
        stats.secretEvents = stats.secretEvents + 1
        if not Incoming.loggedSecret then
            Incoming.loggedSecret = true
            ns:Log("unit_combat_secret", { unit = ns.Describe(unit), action = ns.Describe(action), school = ns.Describe(school) })
        end
        return
    end

    -- Raw samples for the experiment: what does this client actually send?
    local samples = Incoming.rawSamples
    if #samples < RAW_SAMPLE_MAX then
        samples[#samples + 1] = {
            t = math.floor(GetTime() * 1000) / 1000,
            unit = unit,
            action = action,
            flag = ns.IsSecret(flagText) and "<secret>" or flagText,
            amount = ns.IsSecret(amount) and "<secret>" or amount,
            school = school,
            combat = InCombatLockdown() and 1 or nil,
        }
    end

    if unit == Incoming.watched and isMeleeSwing(action, school) then
        Incoming:OnHit(GetTime(), action)
    end
end)

ns:On("PLAYER_TARGET_CHANGED", function()
    Incoming:ReadPrior("target changed", true)
    Incoming:UpdateWatched("target changed")
end)

ns:On("UNIT_TARGET", function(_, unit)
    if unit == "target" then
        Incoming:UpdateWatched("target's target changed")
    end
end)

ns:On("GROUP_ROSTER_UPDATE", function()
    Incoming:UpdateWatched("roster")
end)

ns:On("UNIT_ATTACK_SPEED", function(_, unit)
    if unit == "target" then
        ns:Log("target_attack_speed_event", "UNIT_ATTACK_SPEED fired for target")
        Incoming:ReadPrior("UNIT_ATTACK_SPEED")
    end
end)

ns:Listen("COMBAT_START", function()
    Incoming:UpdateWatched("combat start")
end)

ns:Listen("COMBAT_END", function()
    C_Timer.After(3, function()
        if not ns.inCombat then
            ns.SafeCall(Incoming.Reset, Incoming, "out of combat")
        end
    end)
end)

ns:Listen("OPTION_CHANGED", function(_, key)
    if key == "watchUnit" then
        Incoming:UpdateWatched("option")
    end
end)

ns:Listen("LOGIN", function()
    Incoming:UpdateWatched("login")
    C_Timer.NewTicker(1, function()
        ns.SafeCall(Incoming.UpdateWatched, Incoming, "tick")
    end)
end)

ns:RegisterCommand("watch", "whose incoming hits to time: 'auto' (default), or a unit such as focus / party2", function(rest)
    local unit = string.lower(rest or "")
    if unit == "" or unit == "auto" then
        ns:SetOption("watchUnit", nil)
        ns:Print("enemy timer: auto - currently watching", Incoming.watched)
    else
        ns:SetOption("watchUnit", unit)
        ns:Print("enemy timer: watching", unit, UnitExists(unit) and "" or "(no such unit right now - using auto until it exists)")
    end
end)
