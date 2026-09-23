-- Plainsrunning: the readout for a buff that has no duration at all.
--
-- On Forever the tauren racial is a RAMP, not a timer: +1% movement speed for every 5 seconds you keep
-- moving, up to +30%, and standing still (or taking a hit) takes it away again. So there is nothing to
-- count down - what you want to see is how much you have, whether it is going up or draining, and how
-- far the next tick is. The user's own words for when it drains: "it's always about to decay when you are
-- not moving".
--
-- THE BAR IS THE TICK: it fills toward the next +1% while you move, and empties toward the next -1% while
-- you stand still. The percentage you have is the text beside it.
--
-- TWO CLOCKS, AND THEY RUN DIFFERENTLY. This was measured, not assumed (2026-09-22, and the report that
-- settled it is the reason Plains.resumes exists):
--
--   GAINING runs on the CLOCK, not on how much of it you spent moving. Four gains that spanned a stop
--   came in at 4.96, 4.97, 4.99 and 5.05 seconds of wall time, while the MOVING time inside them was
--   4.15, 3.33, 1.03 and 1.08 seconds. One of them landed when the player had already been standing
--   still for a second. So it is a five second cycle that keeps running: a pause does not reset it and
--   does not pause it either. Counting banked moving time - the obvious reading of "+1% per 5 seconds
--   of moving" - had the bar out by as much as a second and a half after a bout of stop-start running,
--   which is exactly what "it still comes short at predicting the tick" was.
--
--   DRAINING runs on time spent STANDING - but a tick already IN FLIGHT lands anyway. Measured: a
--   percent went 0.96 seconds after the one before it while the player was moving again and the bar was
--   showing a gain bar three quarters full. So setting off does not cancel the drain that is already
--   coming; it only stops the next one being started. The bar keeps warning through that window, which
--   is the one place it used to say nothing at all.
--
-- So the gaining bar counts from the last percent gained, on the clock; the draining bar counts standing
-- time. Neither resets the other. Plains.resumes keeps recording both numbers, so if this is ever wrong
-- again the report will say so.
--
-- JUMPING IS NOT STANDING STILL. A jump straight up has no ground speed at all - GetUnitSpeed reads zero
-- for the whole second you are in the air - and yet the game goes on counting it as moving: the buff keeps
-- building. So being off the ground counts as moving here too, whatever the speed says.
--
-- STRAFING IS NOT STOPPING. GetUnitSpeed drops to zero for a frame or two whenever you change direction -
-- released one key before the next went down - and the game plainly does not count that as standing still
-- (measured 2026-09-22: the gaining tick came in at 4.99 / 5.01 seconds while really running about). So a
-- zero is only believed once it has lasted MOVE_GRACE; when it has, the clock is set back to the moment
-- the speed actually dropped, not to the moment we made up our minds. While we are still making up our
-- minds the bar HOLDS where it is - it must never look as though the gaining tick carried on through the
-- first idle moments.
--
-- HOW LONG A TICK IS is not assumed. The guides say +1% per 5 seconds of moving and say nothing at all
-- about how fast it drains, so both are MEASURED here: every time the client hands us a new stack count we
-- note how long it had been since the last one, in that direction, and the bar uses the median of the last
-- few. Until a tick has been seen, the published 5 seconds stands in - '/fct plains' says which it is.
--
-- THE FIRST DRAIN IS ITS OWN TICK, and it is NOT a fixed one. Standing still does not cost you a percent
-- straight away, and the wait is not the same every time: measured on this client at 1.45, 1.68 and 2.07
-- seconds. That looks like a wait of about a second and then a cycle running on its own, so where your
-- stop falls inside that cycle decides the rest - and nothing we can read tells us the phase.
--
-- So the bar does not promise a moment it cannot know. It counts the first percent down to the SOONEST
-- it has ever seen one go, and then HOLDS there, empty and red: "any moment now". Being early and waiting
-- is honest; draining past the loss and starting over is not.
--
-- THE SAME GOES FOR THE STEADY DRAIN, which is where this went wrong to begin with. The middle of the
-- measured drains is exactly the number that is too slow half the time - and half the time you lose the
-- percent while the bar still shows some left ("i'm losing my stack before it hits 0"). So every draining
-- countdown runs at the soonest we have ever seen, and holds at empty. Gaining keeps the median: nobody
-- minds a percent arriving early.
--
-- Every stack change is written down (Plains.changes, in '/fct diag') with WHERE THE BAR WAS when it
-- landed. That one number settles an argument the bar cannot settle by itself: a tick landing while the
-- bar reads 0.7 means our clock is running slow, and a bar that sat full for a second before the tick
-- means it is running fast. Beside it goes how much of that clock came from STRAFE DIPS - the fractions
-- of a second when the speed read zero and we decided you had not really stopped. If the game does not
-- count those as moving, they are exactly the error, and they add up fastest when you are moving about
-- like a crazy. Until a report says which, nothing is assumed.
--
-- WHAT THIS CLIENT LETS US SEE (measured, see Buffs.lua): out of combat an aura is plainly readable, in a
-- fight an addon cannot touch the player's auras AT ALL. Movement, on the other hand, is open everywhere:
-- GetUnitSpeed("player"). So:
--   * the bar's COLOUR and its "gaining / draining" word come from movement - right in combat too;
--   * the NUMBER comes from the aura out of combat, where it is exact;
--   * IN A FIGHT the client shows an addon no auras at all, so the count is carried on by us: the same
--     measured ticks, driven by the same movement, +1 while you move and -1 while you stand. It is shown
--     with a "~" - an estimate, but a live one instead of a frozen number. Taking a hit also costs you
--     some of the buff and nobody has written down how much, so once you have been hit the estimate is
--     marked "?" instead. When the fight ends the real number is read back and kept beside the estimate
--     (Plains.combats, in '/fct diag'): that is how the cost of a hit gets settled.
-- Nothing here runs on a timer of its own: GetProgress is asked once per frame by the block that is
-- already drawing, and the aura is only re-read when the game says an aura changed.
local _, ns = ...

local Plains = {}
ns.Plains = Plains

local DEFAULT_NAME = "Plainsrunning"
local MAX_PERCENT = 30      -- the cap on Forever: +30% movement speed
local RACE = "Tauren"
local GAINING = { 0.45, 0.80, 0.45 }
local DRAINING = { 0.85, 0.30, 0.25 }
local PUBLISHED_TICK = 5    -- "+1% every 5 seconds spent moving" - until this client shows us otherwise
local TICK_SAMPLES = 5      -- how many tick lengths are kept per direction; the median is used
local TICK_LIMITS = { 0.5, 60 } -- a gap outside this is a pause, a reload or a fight - not a tick
local MOVE_GRACE = 0.35     -- a zero speed shorter than this is a strafe, not a stop
local FLIGHT_CAP = 2        -- seconds: the longest the bar goes on warning about a drain after you move

Plains.state = {
    percent = nil,          -- the last number we could read
    readAt = nil,           -- when that was
    seen = false,           -- the buff has turned up at least once this session
    moving = false,
    changedAt = nil,        -- when the count last changed: where the running tick started
    flippedAt = nil,        -- when you last started or really stopped moving: a tick starts afresh there
    zeroSince = nil,        -- the speed has read zero since then (a strafe, or a stop - time tells)
    airborne = false,       -- off the ground: moving, whatever the speed says
    dipsIgnored = 0,        -- strafes and turns that did NOT count as standing still
    dipsSince = 0,          -- ... of those, how many since the last stack change
    dipTimeSince = 0,       -- ... and how many seconds of clock they handed to the gaining tick
    jumps = 0,              -- jumps that kept the buff building while the speed read zero
    lostSinceStop = false,  -- a percent has already gone since you stopped
    lastGainAt = nil,       -- when the last percent arrived: the gaining cycle counts from there
    upBanked = 0,           -- moving seconds since then - no longer what the bar runs on, but still
                            -- recorded, because it is what proved the cycle runs on the clock instead
    downBanked = 0,         -- standing seconds toward the next -1%
    drainInFlight = false,  -- ... and it is still coming even though you have set off again
    flightUntil = nil,      -- ... until here, after which it plainly is not coming
    pending = 0,            -- seconds since the speed hit zero, still being judged: neither clock's yet
    lastFrame = nil,        -- the frame the clocks were last wound on
    fraction = 0,           -- what the bar shows; held while a zero speed is still being judged
    estimate = nil,         -- what we believe the count is while the client will not say (a fight)
    hits = 0,               -- times you were hit this fight: after one, the estimate is only a guess
    startedAt = nil,        -- the count when the fight began
    lookups = 0, reads = 0, unreadable = 0,
    lastAnswer = "not asked yet",
}
-- the lengths we have measured, newest last. `firstDown` is its own thing: the gap between standing
-- still and the FIRST percent lost, which may well be longer than the drain's own pace.
Plains.ticks = { up = {}, down = {}, firstDown = {} }
Plains.changes = {}         -- every stack change, for the report: { at, from, to, moving, sinceStop }
Plains.resumes = {}         -- gains that spanned a stop: { at, banked, wall, tick } - does the game keep its place?
Plains.combats = {}         -- what our estimate was worth: { started, hits, estimated, real, out }
local CHANGES_MAX, COMBATS_MAX, RESUMES_MAX = 30, 10, 20

local function round(seconds)
    return math.floor(seconds * 100) / 100
end

local function pack(ok, ...)
    if not ok then
        return false, (...)
    end
    return ok, select("#", ...), ...
end

-- One getter's results, or nil when the call failed, the function is not there, or any answer is secret.
local function ask(fn, ...)
    if type(fn) ~= "function" then
        return nil
    end
    local ok, a, b, c = pcall(fn, ...)
    if not ok or ns.AnySecret(a, b, c) then
        return nil
    end
    return a, b, c
end

function Plains:GetName()
    local saved = ns.cdb and ns.cdb.plainsName
    return (type(saved) == "string" and saved ~= "" and saved) or DEFAULT_NAME
end

-- Does this character have the racial at all? Tauren - or anybody whose client has shown us the buff.
function Plains:Applies()
    if Plains.state.seen then
        return true
    end
    local _, token = ask(UnitRace, "player")
    return token == RACE
end

-- Are you moving? Asked once a frame by the bar. Setting off counts at once; stopping has to last.
-- Off the ground counts as moving, even at a standstill: that is what the game does.
-- Wind the two clocks up to this moment. The bar does it every frame; Refresh does it again whenever the
-- count changes, because UNIT_AURA arrives between frames - and if the bar is not on screen, it is the only
-- thing that arrives at all. Reading a bank that has not been wound is reading a stale number.
local function wind(now)
    local state = Plains.state
    local dt = state.lastFrame and (now - state.lastFrame) or 0
    if dt < 0 then
        dt = 0
    end
    state.lastFrame = now
    -- While a zero speed is still being judged this moment belongs to neither clock: it is held aside
    -- until we know whether that was a strafe or a stop.
    if state.zeroSince and state.moving then
        state.pending = state.pending + dt
    elseif state.moving then
        state.upBanked = state.upBanked + dt
        if state.drainInFlight then
            state.downBanked = state.downBanked + dt -- the one still coming is still coming
        end
    else
        state.downBanked = state.downBanked + dt
    end
end

local function updateMovement(now)
    local state = Plains.state
    wind(now)

    local speed = ask(GetUnitSpeed, "player")
    local onFoot = type(speed) == "number" and speed > 0
    local airborne = ask(IsFalling) and true or false
    if airborne and not state.airborne and not onFoot then
        state.jumps = state.jumps + 1 -- a jump from a standstill: it would have looked like idling
    end
    state.airborne = airborne

    if onFoot or airborne then
        if state.zeroSince and state.moving then
            state.dipsIgnored, state.dipsSince = state.dipsIgnored + 1, state.dipsSince + 1
            -- a strafe: the speed dipped, you never stopped - so that time was moving time after all
            state.upBanked = state.upBanked + state.pending
            state.dipTimeSince = state.dipTimeSince + state.pending
        end
        state.zeroSince, state.pending = nil, 0
        if not state.moving then
            state.moving = true
            state.flippedAt = now
            -- The drain already counting down is not cancelled by setting off - it lands, and the bar
            -- goes on showing it for exactly as long as it could still land.
            state.drainInFlight = state.downBanked > 0
            if state.drainInFlight then
                local owed = Plains:TickLength(state.lostSinceStop and "down" or "firstDown") - state.downBanked
                state.flightUntil = now + math.max(0, math.min(owed, FLIGHT_CAP))
            else
                state.lostSinceStop = false -- nothing owed: the next stop gets the long first wait back
            end
        end
        return
    end
    state.zeroSince = state.zeroSince or now
    if state.moving and (now - state.zeroSince) >= MOVE_GRACE then
        state.moving = false
        state.flippedAt = state.zeroSince -- you stopped when the speed did, not when we believed it
        state.lostSinceStop = false
        state.drainInFlight, state.flightUntil = false, nil
        state.downBanked = state.pending -- standing began when the speed did, so that time counts
        state.pending = 0
    end
end

-- A percent has just come or gone: the clock that earned it starts the next one, keeping any overrun so
-- the ticks do not drift. The OTHER clock is left exactly where it is.
local function tickLanded(step, now)
    local state = Plains.state
    if step > 0 then
        state.lastGainAt = now or GetTime()
        state.upBanked = math.max(0, state.upBanked - Plains:TickLength("up"))
    elseif state.lostSinceStop then
        state.downBanked = math.max(0, state.downBanked - Plains:TickLength("down"))
        if state.moving and state.downBanked > 0 then
            state.drainInFlight = true -- another may still be coming
            state.flightUntil = (GetTime()) + math.max(0, math.min(Plains:TickLength("down") - state.downBanked, FLIGHT_CAP))
        else
            state.drainInFlight, state.flightUntil = false, nil
        end
    else
        state.downBanked = 0 -- the wait before the first one is not the drain's own pace
        state.drainInFlight, state.flightUntil = false, nil
    end
end

-- true while the speed reads zero and we have not yet decided whether that was a strafe or a stop
local function judging()
    local state = Plains.state
    return state.zeroSince ~= nil and state.moving
end

------------------------------------------------------------------------
-- The number: how many stacks the aura carries. Out of combat only - in a fight the client refuses.
------------------------------------------------------------------------
local function readPercent()
    local state = Plains.state
    local lookup = C_UnitAuras and C_UnitAuras.GetAuraDataBySpellName
    if type(lookup) ~= "function" then
        state.lastAnswer = "this client has no C_UnitAuras.GetAuraDataBySpellName"
        return nil, false
    end
    state.lookups = state.lookups + 1
    local ok, count, aura = pack(pcall(lookup, "player", Plains:GetName(), "HELPFUL"))
    if not ok then
        state.unreadable = state.unreadable + 1
        state.lastAnswer = "raised: " .. tostring(count)
        return nil, false
    end
    if count == 0 or aura == nil then
        state.lastAnswer = "not on you"
        return nil, true -- a clear answer: the buff is not there
    end
    if ns.IsSecret(aura) then
        state.unreadable = state.unreadable + 1
        state.lastAnswer = "secret aura"
        return nil, false
    end
    local stacks = aura.applications
    if stacks == nil then
        stacks = aura.charges
    end
    if ns.IsSecret(stacks) then
        state.unreadable = state.unreadable + 1
        state.lastAnswer = "secret stacks"
        return nil, false
    end
    state.reads = state.reads + 1
    if type(stacks) ~= "number" or stacks <= 0 then
        -- the buff is there but says nothing about stacks: all we can honestly show is "it is up"
        state.lastAnswer = "on you, no stack count"
        return 0, true
    end
    state.lastAnswer = "on you, " .. stacks
    return math.min(stacks, MAX_PERCENT), true
end

------------------------------------------------------------------------
-- How long a tick is, measured. A gap is only believed when it is one step in one direction: a jump of
-- several percent is a pause we did not see, not a tick.
------------------------------------------------------------------------
local function remember(direction, seconds)
    local kept = Plains.ticks[direction] or {}
    Plains.ticks[direction] = kept
    -- a tick shorter than half a second is not a tick but a stutter; the wait before the FIRST drain,
    -- though, may honestly be anything from nothing upwards - that is what we are trying to find out
    local floor = direction == "firstDown" and 0 or TICK_LIMITS[1]
    if seconds < floor or seconds > TICK_LIMITS[2] then
        return
    end
    kept[#kept + 1] = seconds
    while #kept > TICK_SAMPLES do
        table.remove(kept, 1)
    end
end

local function median(list)
    if #list == 0 then
        return nil
    end
    local sorted = {}
    for index, value in ipairs(list) do
        sorted[index] = value
    end
    table.sort(sorted)
    return sorted[math.ceil(#sorted / 2)]
end

-- seconds a tick takes in this direction, and where that number comes from
local function soonest(list, ceiling)
    local earliest
    for _, seconds in ipairs(list) do
        if (not ceiling or seconds <= ceiling) and (not earliest or seconds < earliest) then
            earliest = seconds
        end
    end
    return earliest
end

function Plains:TickLength(direction)
    if direction == "up" then
        local measured = median(Plains.ticks.up)
        if measured then
            return measured, "measured"
        end
        return PUBLISHED_TICK, "the published 5 seconds, until a tick has been seen"
    end

    -- Draining takes the SOONEST ever seen, never the middle. The middle is the number that is too slow
    -- half the time, and half the time you lose the percent while the bar still shows time left. Early
    -- and holding at empty is honest; overrunning is not.
    local steady = soonest(Plains.ticks.down)
    if direction == "firstDown" then
        -- a wait many times the steady drain is a stop we mis-saw, not the game being slow
        local first = soonest(Plains.ticks.firstDown, (steady or PUBLISHED_TICK) * 5)
        if first then
            return first, "the soonest seen, and it holds there until it really goes"
        end
        if steady then
            -- the wait before the first percent goes, unseen so far: the steady drain has to stand in
            return steady, "the steady drain, until a first loss has been timed"
        end
    elseif steady then
        return steady, "the soonest seen, and it holds there until it really goes"
    end

    local up = median(Plains.ticks.up)
    if up then
        return up, "the gaining tick, until a drain has been seen"
    end
    return PUBLISHED_TICK, "the published 5 seconds, until a tick has been seen"
end

function Plains:Refresh()
    if InCombatLockdown() then
        return -- the client will not say; what we saw last stands, marked stale
    end
    local percent, clear = readPercent()
    local state = Plains.state
    if not clear then
        return
    end
    local now = GetTime()
    wind(now) -- up to date before the banks are read, whether or not the bar has been drawing
    local before = state.percent
    if percent ~= before then
        -- one step in one direction, with the movement unchanged since: that gap is a tick
        local step = (before and percent) and (percent - before) or nil
        local banked = state.moving and state.upBanked or state.downBanked
        if step == 1 or step == -1 then
            if not state.flippedAt or state.flippedAt <= state.changedAt then
                -- one step, and you have neither set off nor stopped since the last one: a plain tick
                remember(step > 0 and "up" or "down", now - state.changedAt)
            elseif step == 1 then
                -- A gain that spanned a stop. Did the game keep our place or start over? The moving time
                -- banked since the last one says which: about one tick means it kept it, a tick plus
                -- whatever was already banked means it did not. Not fed to the measured ticks either
                -- way - an untested idea must not move the number the bar runs on.
                Plains.resumes[#Plains.resumes + 1] = {
                    at = round(now), banked = round(banked), wall = round(now - state.changedAt),
                    tick = round((Plains:TickLength("up"))),
                }
                while #Plains.resumes > RESUMES_MAX do
                    table.remove(Plains.resumes, 1)
                end
            elseif step == -1 and not state.moving and not state.lostSinceStop then
                -- the first percent to go after standing still: how long the game let you stand
                remember("firstDown", now - state.flippedAt)
            end
            tickLanded(step, now)
        else
            -- the first look at the count, or a jump of several: we have lost the thread, start here
            state.upBanked, state.downBanked, state.lastGainAt = 0, 0, now
        end
        if before and percent then
            Plains.changes[#Plains.changes + 1] = {
                at = math.floor(now * 100) / 100,
                from = before, to = percent,
                -- where the bar WAS when this landed: 1.0 means it had been sitting full and waiting,
                -- anything short of it means the tick beat the bar to it
                bar = math.floor((state.fraction or 0) * 100) / 100,
                banked = round(banked),
                dips = state.dipsSince,
                dipTime = round(state.dipTimeSince),
                moving = state.moving,
                sinceStop = (not state.moving and state.flippedAt) and (math.floor((now - state.flippedAt) * 100) / 100) or nil,
                sinceChange = state.changedAt and (math.floor((now - state.changedAt) * 100) / 100) or nil,
            }
            while #Plains.changes > CHANGES_MAX do
                table.remove(Plains.changes, 1)
            end
        end
        if step and step < 0 and not state.moving then
            state.lostSinceStop = true
        end
        state.dipsSince, state.dipTimeSince = 0, 0
        state.changedAt = now
    end
    if percent then
        state.percent, state.readAt, state.seen = percent, now, true
    else
        state.percent, state.readAt, state.changedAt = nil, now, nil
    end
end

------------------------------------------------------------------------
-- What the bar shows: active, fraction, remaining, dim, text, colour
------------------------------------------------------------------------
-- Out of combat: what the client says. In a fight: what we have counted since it started.
-- `fighting` saves asking the client again: GetProgress already knows, and it is called every frame.
function Plains:Current(fighting)
    local state = Plains.state
    if fighting == nil then
        fighting = InCombatLockdown()
    end
    if fighting then
        return state.estimate
    end
    return state.percent
end

function Plains:GetProgress(now)
    local state = Plains.state
    updateMovement(now)
    local fighting = InCombatLockdown() -- asked once a frame, not four times
    local percent = Plains:Current(fighting)
    if not percent then
        state.fraction = 0
        return false, 0, 0, false, "", nil
    end
    if judging() then
        -- a strafe, or the first idle moments: hold everything exactly where it is
        return true, state.fraction, 0, false, state.heldText or "", GAINING
    end

    -- where the running tick started, and how long it should take. Standing still, the first percent to go
    -- takes longer than the ones after it, so it has a length of its own.
    -- A drain still in flight is what the bar shows, moving or not: that is the window where a percent
    -- used to go with nothing on screen to say it was coming. Once its moment has plainly passed (a whole
    -- tick late) it is written off and the gaining bar comes back.
    if state.drainInFlight and (not state.flightUntil or now >= state.flightUntil) then
        -- it plainly is not coming: the slate is clean and the next stop starts the long wait again
        state.drainInFlight, state.downBanked, state.flightUntil = false, 0, nil
        state.lostSinceStop = false
    end
    local draining = (not state.moving) or state.drainInFlight
    local direction = draining and (state.lostSinceStop and "down" or "firstDown") or "up"
    local length = Plains:TickLength(direction)
    -- gaining counts from the last percent, on the clock; draining counts the time you have stood still
    local elapsed = math.max(0, draining and state.downBanked or (now - (state.lastGainAt or now)))
    local left = math.max(0, length - elapsed)
    local through = math.min(1, elapsed / length)

    -- nothing is coming: at the cap while moving, or at nothing while standing still
    local waiting = (not draining and percent >= MAX_PERCENT) or (draining and percent <= 0)
    local fraction
    if waiting then
        fraction = draining and 0 or 1
    else
        fraction = draining and (1 - through) or through -- down toward the next -1%, up toward the next +1%
    end

    -- In a fight nothing tells us the count changed, so we do the counting: a tick that has run its course
    -- moves the estimate and starts the next one.
    if fighting and not waiting and through >= 1 then
        local step = draining and -1 or 1
        state.estimate = math.max(0, math.min(MAX_PERCENT, (state.estimate or percent) + step))
        state.changedAt = now
        tickLanded(step, now)
        if step < 0 then
            state.lostSinceStop = true
        end
        percent = state.estimate
        fraction = draining and 1 or 0
        left = length -- the next tick begins here, so the countdown starts over too
    end

    local mark = ""
    if fighting then
        mark = state.hits > 0 and " ?" or " ~" -- hit: a guess. Untouched: our own count, and a sound one.
    end
    local text = (percent > 0 and (percent .. "%") or "up")
        .. mark
        .. (waiting and "" or string.format("  %.1f", left))
    state.fraction, state.heldText = fraction, text
    return true, fraction, 0, false, text, draining and DRAINING or GAINING
end

-- While Plainsrunning is up (the bar's "when used"), IN A FIGHT TOO.
--
-- This used to return false in combat, on the grounds that the client shows an addon no auras there and
-- the estimate drifted. The drift was real and it was our fault: the gaining clock counted banked moving
-- time, which ran as much as two seconds fast over a minute. On the wall clock it now tracks the real
-- tick to within a few hundredths, so the estimate is worth showing - which is the whole point of
-- keeping one, and a fight is when a movement-speed buff matters most.
--
-- It is never passed off as certain: GetProgress marks it "~" while nothing has hit us and "?" once
-- something has, and PLAYER_REGEN_ENABLED writes what we counted against the truth (Plains.combats).
function Plains:InUse()
    return Plains:Current() ~= nil
end

function Plains:Describe()
    local state = Plains.state
    local up, upFrom = Plains:TickLength("up")
    local down, downFrom = Plains:TickLength("down")
    return {
        name = Plains:GetName(),
        applies = Plains:Applies(),
        percent = state.percent,
        estimate = state.estimate,
        hits = state.hits,
        combats = Plains.combats,
        seen = state.seen,
        moving = state.moving,
        airborne = state.airborne,
        dipsIgnored = state.dipsIgnored,
        jumps = state.jumps,
        hasIsFalling = type(IsFalling) == "function",
        moveGrace = MOVE_GRACE,
        upBanked = round(state.upBanked), downBanked = round(state.downBanked),
        drainInFlight = state.drainInFlight,
        sinceGain = state.lastGainAt and round(GetTime() - state.lastGainAt) or nil,
        resumes = Plains.resumes,
        measuredFirstDown = Plains.ticks.firstDown,
        dipsSince = state.dipsSince, dipTimeSince = round(state.dipTimeSince),
        tickUp = up, tickUpFrom = upFrom,
        tickDown = down, tickDownFrom = downFrom,
        tickFirstDown = (Plains:TickLength("firstDown")), tickFirstDownFrom = (select(2, Plains:TickLength("firstDown"))),
        measuredUp = Plains.ticks.up, measuredDown = Plains.ticks.down,
        changes = Plains.changes,
        lookups = state.lookups, reads = state.reads, unreadable = state.unreadable,
        lastAnswer = state.lastAnswer,
    }
end

------------------------------------------------------------------------
-- Wiring: the aura is re-read when the game says one changed, and when a fight ends (nothing could be
-- read during it). Movement is asked for by the bar itself, once a frame.
------------------------------------------------------------------------
ns:OnPlayerUnit("UNIT_AURA", function()
    ns.SafeCall(Plains.Refresh, Plains)
end)

-- a hit lands: it costs you some of the buff, and nobody has written down how much
ns:OnPlayerUnit("UNIT_COMBAT", function()
    local state = Plains.state
    if InCombatLockdown() then
        state.hits = state.hits + 1
    end
end)

ns:On("PLAYER_REGEN_DISABLED", function()
    local state = Plains.state
    state.estimate, state.startedAt, state.hits = state.percent, state.percent, 0
end)

ns:On("PLAYER_ENTERING_WORLD", function()
    ns.SafeCall(Plains.Refresh, Plains)
end)

-- The fight is over and the client will talk again: how close was our own counting? Writing that down
-- beside the number of hits is what will one day say what a hit costs.
ns:On("PLAYER_REGEN_ENABLED", function()
    local state = Plains.state
    local estimated = state.estimate
    ns.SafeCall(Plains.Refresh, Plains)
    if estimated then
        Plains.combats[#Plains.combats + 1] = {
            started = state.startedAt, hits = state.hits,
            estimated = estimated, real = state.percent,
            out = state.percent and (estimated - state.percent) or nil,
        }
        while #Plains.combats > COMBATS_MAX do
            table.remove(Plains.combats, 1)
        end
    end
    state.estimate, state.hits = nil, 0
end)

ns:RegisterCommand("plains", "the Plainsrunning readout: '/fct plains' says what it sees, '/fct plains <buff name>' if the buff is called something else here", function(rest)
    local name = string.match(rest or "", "^%s*(.-)%s*$")
    if name ~= "" then
        ns.cdb.plainsName = name
        Plains.state.percent, Plains.state.seen = nil, false
        Plains:Refresh()
        ns:Print("watching the buff called |cffffd100" .. name .. "|r.")
        return
    end
    local info = Plains:Describe()
    ns:Print("Plainsrunning readout: buff |cffffd100" .. info.name .. "|r, " .. (info.applies and "this character has the racial" or "not a tauren - the bar keeps out of the way")
        .. ". Now: " .. (info.percent and (info.percent .. "%") or "not on you") .. ", " .. (info.moving and "moving (gaining)" or "still (draining)") .. ".")
    ns:Print(string.format("tick: +1%% every %.1fs (%s); standing still, the first %% goes after %.1fs (%s) and the rest every %.1fs (%s).",
        info.tickUp, info.tickUpFrom, info.tickFirstDown, info.tickFirstDownFrom, info.tickDown, info.tickDownFrom))
    ns:Print(string.format("two clocks: %.1fs on the clock since the last +1%% (that is what gaining runs on), %.1fs of standing toward the next -1%%.",
        info.sinceGain or 0, info.downBanked))
    local resume = info.resumes[#info.resumes]
    if resume then
        ns:Print(string.format("last gain across a stop: %.1fs of moving (%.1fs on the clock), a tick being %.1fs - %s.",
            resume.banked, resume.wall, resume.tick,
            math.abs(resume.banked - resume.tick) <= 0.75 and "the game kept its place too" or "the game may start over"))
    end
    -- the one line that says whether the bar is running fast or slow
    local gains, late, early, dipped = 0, 0, 0, 0
    for _, change in ipairs(info.changes) do
        if change.to and change.from and change.to > change.from and change.bar then
            gains = gains + 1
            if change.bar >= 0.999 then
                early = early + 1   -- the bar was full and waiting: our clock ran fast
            else
                late = late + 1     -- the tick beat the bar to it: our clock ran slow
            end
            dipped = dipped + (change.dipTime or 0)
        end
    end
    if gains > 0 then
        ns:Print(string.format("of the last %d gains, %d landed with the bar already full (clock fast) and %d beat the bar to it (clock slow); %.1fs of those clocks came from strafe dips.",
            gains, early, late, dipped))
    end
    ns:Print(string.format("strafes ignored: %d, jumps counted as moving: %d%s. The client's last answer: %s.",
        info.dipsIgnored, info.jumps, info.hasIsFalling and "" or " (this client has no IsFalling)", info.lastAnswer))
    local last = info.combats[#info.combats]
    if last then
        ns:Print(string.format("last fight: we counted %s, it really was %s (%s hit(s)) - out by %s.",
            tostring(last.estimated), tostring(last.real), tostring(last.hits), tostring(last.out)))
    end
end)
