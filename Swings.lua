-- Swings: the player's own swing timers.
--
-- WoW: Forever has a first-class API for this - no combat log guessing:
--   PLAYER_SWING(swingDuration, swingType)               a swing of that type started
--   PLAYER_SWING_RANGE_UPDATE(swingType, inRange, checksRange)
--   C_SwingTimer.EnableRangeCheck(swingType, enable)
-- Blizzard's own bar is nothing more than GetTime() arithmetic on PLAYER_SWING,
-- and so is this. On top of that, a change in attack speed (haste procs, slows)
-- rescales whatever is left of the running swing.
local _, ns = ...

local Swings = {}
ns.Swings = Swings

local SwingType = (Enum and Enum.PlayerSwingType) or {}

Swings.TYPES = {
    { key = "MH", id = SwingType.MainHand or 0, label = "Main Hand" },
    { key = "OH", id = SwingType.OffHand or 1, label = "Off Hand" },
    { key = "RG", id = SwingType.Ranged or 2, label = "Ranged" },
}
Swings.BY_KEY, Swings.BY_ID = {}, {}
for order, swingType in ipairs(Swings.TYPES) do
    swingType.order = order
    Swings.BY_KEY[swingType.key] = swingType
    Swings.BY_ID[swingType.id] = swingType
end

-- [key] = { startedAt, duration, endsAt, speed, outOfRange, count, available }
Swings.state = { MH = { count = 0 }, OH = { count = 0 }, RG = { count = 0 } }
Swings.locked = nil -- reason, while the client hands us values we may not read

-- THE AIM. A bow, gun, crossbow or thrown weapon does not fire the moment its cycle is up: the last half
-- second of every cycle is the shot being aimed, and the hunter must stand still for it - move, and the
-- shot waits (measured on a gun of 2.09 s: a cycle after a step in the aim came about half a second late).
-- PLAYER_SWING names only the whole cycle, so the cycle is shown in TWO PHASES from this constant: the
-- WAIT (the cycle less the aim) fills the bar as a swing does, then the AIM fills it again, quickly, as a
-- cast of half a second - the room before it is the hunter's for a cast or a step. A wand has no aim.
Swings.AIM_SECONDS = 0.5
-- THE FIRST SHOT. The client's first PLAYER_SWING of an engagement comes WITH the first shot (measured over 31
-- engagements of a 2.09 s gun: the first-to-second gap is a whole cycle, like every later one), so the half
-- second of aiming before that shot has no swing event of its own. It has START_AUTOREPEAT_SPELL, fired as
-- Auto Shot is switched on: from it an aim-only bar of AIM_SECONDS runs until the first swing takes over,
-- or STOP_AUTOREPEAT_SPELL ends it. THE COOLDOWN IS THE GAME'S: a stop does not end it, and a switch-on
-- while it runs picks the cycle up where it stands - its wait, then the aim - never an aim before the
-- cooldown is up, and never one that began before the switch-on (measured 2026-10-19: a rule that aimed at
-- once on a switch-on saw the shot come 1.5 s and 4.1 s after its "aimed"). While the shooting is off the
-- bar is down; a switch-on with no cycle running aims from that moment. How long the first swing takes to
-- come after each switch-on is measured and kept (0.63 s with no cycle running: the aim plus the server's
-- answer).
Swings.autoRepeat = { active = false, startedAt = nil, starts = 0, firstSwingAfter = {}, pendingFirst = false, aimLags = {}, aimsInterrupted = 0 }
-- THE AIM FOLLOWS THE FEET. The cooldown's end is not the shot: the half second of aiming only runs while the
-- hunter stands still, a step restarts it, and the shot comes when it is done - so the aim phase begins at
-- the cooldown's end or the last step, whichever is later, and once done the bar holds full ("aimed") until
-- the shot's own event, for AIM_PATIENCE at most (out of range, say). THE FEET ARE HEARD, NOT READ:
-- GetUnitSpeed is SecretWhenUnitStatsRestricted - a secret in a fight on this client (measured 2026-10-19: no
-- step seen after the first shot of a fight, every aim lag equal to the cycle's drift) - so the client's own
-- PLAYER_STARTED_MOVING / PLAYER_STOPPED_MOVING events say when the feet move, GetUnitSpeed adds its word
-- where it is readable, and IsFalling (no secret marker) makes a jump a step. How long the shot came after
-- the aim was done is measured and kept (the server's answer, if this is right).
local AIM_PATIENCE = 10
Swings.movement = { moving = false, changedAt = nil, starts = 0, stops = 0 }

local function isMoving()
    if Swings.movement.moving then
        return true
    end
    local ok, speed = pcall(GetUnitSpeed, "player")
    if ok and not ns.IsSecret(speed) and type(speed) == "number" and speed > 0 then
        return true
    end
    if type(IsFalling) == "function" then
        local okFall, falling = pcall(IsFalling)
        if okFall and falling == true then
            return true
        end
    end
    return false
end
Swings.ranged = { kind = nil, itemID = nil } -- what hangs in the ranged slot, by its weapon class
local RANGED_KINDS = { [2] = "bow", [3] = "gun", [16] = "thrown", [18] = "crossbow", [19] = "wand" } -- Weapon subclasses
local AIMED_KINDS = { bow = true, gun = true, crossbow = true, thrown = true, wand = true } -- a wand winds up the same half second

------------------------------------------------------------------------
-- Attack speeds and which swing types apply
------------------------------------------------------------------------
-- mainHand, offHand, ranged - or nil when the client will not say
local function readSpeeds()
    local ok, mainHand, offHand, ranged = pcall(UnitAttackSpeed, "player")
    if not ok or ns.AnySecret(mainHand, offHand, ranged) then
        return nil
    end
    return { MH = mainHand, OH = offHand, RG = ranged }
end

local function isPositive(value)
    return type(value) == "number" and value > 0
end

-- the ranged weapon's kind from the item in slot 18 (readable: item information carries no secret marker)
function Swings:UpdateRangedKind(reason)
    local getID = type(GetInventoryItemID) == "function" and GetInventoryItemID or nil
    local instant = (type(C_Item) == "table" and type(C_Item.GetItemInfoInstant) == "function" and C_Item.GetItemInfoInstant)
        or (type(GetItemInfoInstant) == "function" and GetItemInfoInstant) or nil
    local kind, itemID
    if getID and instant then
        local ok, id = pcall(getID, "player", 18)
        if ok and not ns.IsSecret(id) and type(id) == "number" and id > 0 then
            itemID = id
            local okInfo, _, _, _, _, _, classID, subclassID = pcall(instant, id)
            if okInfo and not ns.AnySecret(classID, subclassID) and classID == 2 then
                kind = RANGED_KINDS[subclassID]
            end
        end
    end
    if self.ranged.kind ~= kind or self.ranged.itemID ~= itemID then
        self.ranged.kind, self.ranged.itemID = kind, itemID
        ns:Log("ranged_weapon", { kind = kind or "none", item = itemID, why = reason })
    end
    return kind
end

-- A WAND winds up the same half second (measured 2026-10-19: a wand's first shot came 0.63 / 0.67 s after the
-- switch-on, a gun's 0.63 / 0.64 s), and shoots every wand speed after - the gun's model under the word
-- "Wind-up". Whether a step delays a wand's shot the way it delays a gun's is still to be seen: shots that
-- come while the feet move are counted (autoRepeat.shotsWhileMoving).
function Swings:IsWand()
    return self.ranged.kind == "wand"
end

-- the seconds of aim at the end of a swing of this type, nil when there is none (melee, nothing)
function Swings:AimSeconds(key)
    if key ~= "RG" or not AIMED_KINDS[self.ranged.kind or ""] then
        return nil
    end
    return self.AIM_SECONDS
end

-- The running swing in phases: active, the phase's fraction, the phase's seconds left, the phase - "wait"
-- then "aim" for a weapon that aims, nil (one plain phase) for everything else - and a note on the aim:
-- "moving" (a step: the aim waits for the feet) or "held" (aimed: the shot is the server's now).
function Swings:GetPhasedProgress(key, now)
    local aim = self:AimSeconds(key)
    local state = self.state[key]
    if not aim or not state.startedAt or not isPositive(state.duration) or (state.duration <= aim and not state.aimOnly) then
        local active, fraction, remaining = self:GetProgress(key, now)
        return active, fraction, remaining, nil
    end
    if state.cancelled then
        return false, 0, 0, nil
    end
    local waitEnd = state.aimOnly and state.startedAt or (state.startedAt + state.duration - aim)
    local moving = isMoving()
    if moving then
        if state.aimSince and now >= waitEnd then
            self.autoRepeat.aimsInterrupted = self.autoRepeat.aimsInterrupted + 1 -- a step into a running aim
        end
        state.lastMoveAt, state.aimSince = now, nil
    end
    if now < waitEnd then
        local wait = waitEnd - state.startedAt
        return true, (now - state.startedAt) / wait, waitEnd - now, "wait"
    end
    if now - waitEnd > AIM_PATIENCE then
        return false, 1, 0, nil -- no shot for this long: out of range, or the shooting stopped unsaid
    end
    local phase = self:IsWand() and "windup" or "aim"
    if moving then
        return true, 0, aim, phase, "moving"
    end
    local since = math.max(waitEnd, state.lastMoveAt or 0, self.autoRepeat.startedAt or 0) -- never before the switch-on either
    state.aimSince = since
    local progress = now - since
    if progress >= aim then
        return true, 1, 0, phase, "held"
    end
    return true, progress / aim, aim - progress, phase
end

function Swings:UpdateSpeeds(reason)
    local speeds = readSpeeds()
    if not speeds then
        ns:Log("speeds_unreadable", reason)
        return
    end
    local now = GetTime()
    for key, state in pairs(self.state) do
        local newSpeed, oldSpeed = speeds[key], state.speed
        state.available = isPositive(newSpeed)

        -- Rescale what is left of a running swing, the way the game does.
        if isPositive(newSpeed) and isPositive(oldSpeed) and newSpeed ~= oldSpeed and state.endsAt and state.endsAt > now then
            local factor = newSpeed / oldSpeed
            local remaining = (state.endsAt - now) * factor
            state.duration = state.duration * factor
            state.endsAt = now + remaining
            state.startedAt = state.endsAt - state.duration
            ns:Log("swing_rescaled", { type = key, from = oldSpeed, to = newSpeed })
        end
        state.speed = newSpeed
    end
    ns:Fire("SWINGS_CHANGED")
end

-- A swing type "applies" when the character can make that kind of attack at all.
function Swings:IsAvailable(key)
    local state = self.state[key]
    if state.available ~= nil then
        return state.available
    end
    return key == "MH" or state.count > 0 -- speeds unreadable: trust what we have seen
end

------------------------------------------------------------------------
-- Queries for the UI
------------------------------------------------------------------------
-- active, fraction (0 -> 1 across the swing), remaining seconds
function Swings:GetProgress(key, now)
    local state = self.state[key]
    if not state.endsAt or not state.duration or state.duration <= 0 then
        return false, 0, 0
    end
    local remaining = state.endsAt - now
    if remaining <= 0 then
        return false, 1, 0
    end
    return true, 1 - remaining / state.duration, remaining
end

-- Seconds since this swing type last finished or started; nil if never seen.
function Swings:SecondsSinceActivity(key, now)
    local state = self.state[key]
    if not state.endsAt then
        return nil
    end
    return math.max(0, now - state.endsAt)
end

------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------
ns:On("PLAYER_SWING", function(_, swingDuration, swingTypeID)
    if ns.AnySecret(swingDuration, swingTypeID) then
        if Swings.locked ~= "secret" then
            Swings.locked = "secret"
            ns:Log("swing_secret", "PLAYER_SWING payload is secret")
        end
        return
    end
    Swings.locked = nil
    local swingType = Swings.BY_ID[swingTypeID]
    if not swingType or not isPositive(swingDuration) then
        ns:Log("swing_ignored", { duration = swingDuration, type = swingTypeID })
        return
    end

    local now = GetTime()
    local state = Swings.state[swingType.key]
    -- How far off was the previous timer? (nil on the first swing, or after a pause - or after an aim-only bar)
    local drift = not state.aimOnly and state.endsAt and math.abs(now - state.endsAt) < 1 and (now - state.endsAt) or nil
    local sinceStart
    if swingType.key == "RG" and Swings.autoRepeat.pendingFirst and Swings.autoRepeat.startedAt then
        -- the first shot of the engagement: how long after Auto Shot was switched on did it come?
        sinceStart = math.floor((now - Swings.autoRepeat.startedAt) * 1000) / 1000
        Swings.autoRepeat.pendingFirst = false
        table.insert(Swings.autoRepeat.firstSwingAfter, 1, sinceStart)
        Swings.autoRepeat.firstSwingAfter[9] = nil
    end
    local aimLag
    if swingType.key == "RG" and state.aimSince then
        -- the shot against the aim as the bar had it: how long after the aim was done did it come?
        aimLag = math.floor((now - (state.aimSince + Swings.AIM_SECONDS)) * 1000) / 1000
        table.insert(Swings.autoRepeat.aimLags, 1, aimLag)
        Swings.autoRepeat.aimLags[9] = nil
    end
    if swingType.key == "RG" and Swings.movement.moving and state.startedAt and now >= (state.aimOnly and state.startedAt or (state.startedAt + state.duration - Swings.AIM_SECONDS)) then
        Swings.autoRepeat.shotsWhileMoving = (Swings.autoRepeat.shotsWhileMoving or 0) + 1 -- a shot the feet should have held
    end
    state.aimOnly, state.aimSince, state.cancelled = nil, nil, nil
    state.startedAt, state.duration, state.endsAt = now, swingDuration, now + swingDuration
    state.count = state.count + 1
    ns:Log("swing", { type = swingType.key, duration = swingDuration, drift = drift and math.floor(drift * 1000) / 1000, sinceAutoShot = sinceStart, aimLag = aimLag })
    ns:Fire("SWING_STARTED", swingType.key)
end)

ns:On("PLAYER_STARTED_MOVING", function()
    local now = GetTime()
    Swings.movement.moving, Swings.movement.changedAt = true, now
    Swings.movement.starts = Swings.movement.starts + 1
    local state = Swings.state.RG
    if state.aimSince then
        Swings.autoRepeat.aimsInterrupted = Swings.autoRepeat.aimsInterrupted + 1 -- a step into a running aim
    end
    state.lastMoveAt, state.aimSince = now, nil
end)

ns:On("PLAYER_STOPPED_MOVING", function()
    local now = GetTime()
    Swings.movement.moving, Swings.movement.changedAt = false, now
    Swings.movement.stops = Swings.movement.stops + 1
    Swings.state.RG.lastMoveAt = now -- the feet stopped here: the half second runs from this moment at the earliest
end)

ns:On("START_AUTOREPEAT_SPELL", function()
    local now = GetTime()
    local auto = Swings.autoRepeat
    auto.active, auto.startedAt, auto.pendingFirst = true, now, true
    auto.starts = auto.starts + 1
    local aim = Swings:AimSeconds("RG")
    local state = Swings.state.RG
    local running = state.endsAt ~= nil and state.endsAt > now and not state.aimOnly -- the last shot's cooldown still runs
    if aim and running then
        state.aimSince, state.cancelled = nil, nil -- the cycle picked up where it stands: its wait, then the aim
        auto.resumed = (auto.resumed or 0) + 1
        ns:Fire("SWING_STARTED", "RG")
    elseif aim then
        state.startedAt, state.duration, state.endsAt, state.aimOnly = now, aim, now + aim, true
        state.aimSince, state.cancelled = nil, nil
        ns:Fire("SWING_STARTED", "RG")
    end
    ns:Log("autoshot_start", { aim = aim ~= nil, wand = Swings:IsWand() or nil, cycleRunning = running })
end)

ns:On("STOP_AUTOREPEAT_SPELL", function()
    local now = GetTime()
    local auto = Swings.autoRepeat
    auto.active, auto.pendingFirst = false, false
    auto.stops = (auto.stops or 0) + 1
    local state = Swings.state.RG
    local cut = state.startedAt ~= nil and not state.cancelled and (state.endsAt == nil or state.endsAt > now or state.aimSince ~= nil or (state.aimOnly ~= nil))
    if cut then
        state.cancelled, state.aimSince = true, nil -- nothing fires while it is off: the bar goes; the cooldown runs on
        if state.aimOnly then
            state.endsAt, state.aimOnly = now, nil -- an aim-only bar has no cooldown to keep
        end
    end
    ns:Log("autoshot_stop", { cycleCut = cut })
end)

ns:On("PLAYER_SWING_RANGE_UPDATE", function(_, swingTypeID, isInRange, checksRange)
    if ns.AnySecret(swingTypeID, isInRange, checksRange) then
        return
    end
    local swingType = Swings.BY_ID[swingTypeID]
    if swingType then
        Swings.state[swingType.key].outOfRange = (checksRange and not isInRange) and true or false
        ns:Fire("SWINGS_CHANGED")
    end
end)

ns:OnPlayerUnit("UNIT_ATTACK_SPEED", function()
    Swings:UpdateSpeeds("UNIT_ATTACK_SPEED")
end)

ns:On("PLAYER_EQUIPMENT_CHANGED", function(_, invSlot)
    if invSlot == 16 or invSlot == 17 or invSlot == 18 then
        Swings:UpdateSpeeds("equipment")
    end
    if invSlot == 18 then
        Swings:UpdateRangedKind("equipment")
    end
end)

ns:On("WEAPON_SLOT_CHANGED", function()
    Swings:UpdateSpeeds("weapon slot")
end)

ns:Listen("LOGIN", function()
    Swings:UpdateSpeeds("login")
    Swings:UpdateRangedKind("login")
    -- Ask the client to tell us about range, like Blizzard's bar does.
    if C_SwingTimer and C_SwingTimer.EnableRangeCheck then
        for _, swingType in ipairs(Swings.TYPES) do
            local ok, err = pcall(C_SwingTimer.EnableRangeCheck, swingType.id, true)
            if not ok then
                ns:Log("range_check_failed", { type = swingType.key, err = tostring(err) })
            end
        end
    end
end)
