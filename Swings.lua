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
    -- How far off was the previous timer? (nil on the first swing, or after a pause)
    local drift = state.endsAt and math.abs(now - state.endsAt) < 1 and (now - state.endsAt) or nil
    state.startedAt, state.duration, state.endsAt = now, swingDuration, now + swingDuration
    state.count = state.count + 1
    ns:Log("swing", { type = swingType.key, duration = swingDuration, drift = drift and math.floor(drift * 1000) / 1000 })
    ns:Fire("SWING_STARTED", swingType.key)
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
end)

ns:On("WEAPON_SLOT_CHANGED", function()
    Swings:UpdateSpeeds("weapon slot")
end)

ns:Listen("LOGIN", function()
    Swings:UpdateSpeeds("login")
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
