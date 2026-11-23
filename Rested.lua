-- Well Rested: the count-up for the Cozy Sleeping Bag.
--
-- WHY. The user, 2026-11-11: "i want the combat timers addon to do a count up (like for plainswalking) when
-- getting the sleeping bag buff". The bag (item 211527, "Unroll Bag"): "Resting inside for at least one
-- minute will provide a bonus to experience earned, stacking up to 3 times." The buff is called "Well Rested"
-- (the user's word). Chosen with the user: a bar that fills over each minute toward the next stack, with the
-- stacks and the time beside it - "1/3  0:41" - full and done at 3/3.
--
-- HOW. Like Plainsrunning, the aura is read by name (C_UnitAuras.GetAuraDataBySpellName) whenever the game
-- says an aura changed - out of combat, where the client lets an addon read the player's auras. The minute
-- counts from the moment the last stack landed. If the client gives no stack count, a refreshed buff (its
-- expiry moved) is taken as the next stack. No stack a while after the minute was up means you got out of
-- the bag: the bar goes. Nothing runs on a timer of its own; the bar asks GetProgress once a frame.
--
-- THE FIRST MINUTE. The user, 2026-11-11: "is there a way to track that you are starting to get the buff
-- before stack 1?" - and: a "you feel rested" comes in chat when it starts to count. The probe, measured in
-- the bag the same day: cast Unroll Bag (429961) 22:32:24, the resting flag on (PLAYER_UPDATE_RESTING,
-- IsResting() true - that is the chat line) 22:32:32, Well-Rested (429959, 1 stack, 2 h) 22:33:32 - exactly
-- a minute after resting. So resting coming on shortly after the bag's cast starts the count-up at 0/3. The
-- cast is asked for so that walking into an inn or a city (resting too) starts nothing.
--
-- A RELOAD. The first try in the game, 23:44: the bag cast, a /reload a second later, resting 8 s after the
-- cast - and no bar until the first stack: the reload had forgotten the cast. So the cast and the moment you
-- lay down are kept in the character's saved data (GetTime runs on across a reload), and a reload while you
-- lie in the bag picks the 0/3 count-up up again where it was.
--
-- SOMEBODY ELSE'S BAG. The user, 2026-11-12: "you don't have to be the person that rolls out the bag to be
-- the one to get the buff" - and only the bag says "You feel rested" in chat; inns and cities say nothing.
-- So that chat line starts the count-up, whoever unrolled the bag; your own cast plus resting still does
-- too. Which chat event carries the line is not measured yet: a handful are listened to, and the probe logs
-- the one it came on.
--
-- ASKING. The user, 2026-11-12: lying down in a bag, the resting flag came on and no bar showed - "maybe for
-- the start of the sleeping bag we can note when rest started and have a place to prompt the user: did you
-- just sit in a sleeping bag? yes check keeps the bar and the x gets rid of it". So resting coming on with no
-- other sign (no chat line heard, no bag cast of yours) starts the 0/3 count-up too, with the bar asking
-- "Sleeping bag?" and a check and an X. No answer keeps it counting (an inn's bar goes by itself 75 s on, no
-- stack having come); a sure start (the chat line, your cast) never asks. Resting that comes with a loading
-- screen (logging in, a hearth or a portal into a city) or a flight into a city asks nothing; resting going
-- off before the first stack (up again, out of the inn) drops the bar.
--
-- A REFRESH AT 3/3. The user, 2026-11-13: lying down at 3/3 showed no count-up - "that is missing the use
-- case of i have the buff and want to refresh it. it is good to see when it is going to hit the minute ...
-- we don't need to track beyond that first tick in this case". So lying down at 3/3 counts the minute up
-- too ("3/3  0:41"); the refresh that comes at the minute (the buff's expiry pushed later, the stacks
-- staying 3) fills the bar, it flashes full a moment and lets go. Getting up first (resting off), or no
-- refresh by the minute and a little more, drops it.
--
-- THE NAME. The buff is "Well-Rested", with a hyphen (the probe); it is read by its spell id first, the name
-- only as the fallback (or when you named another buff with '/fct rested <name>').
--
-- AT 60. The user, 2026-11-15: "after level 60 stop showing the well rested buff and all stuff associated with
-- that timer/bar". The bag's bonus is to experience earned, and at 60 there is none to earn. So from level 60
-- on nothing here runs: no bar, no "Sleeping bag?", nothing read, started, kept or logged (Rested:Retired).
-- The level is the client's (UnitLevel), or the one PLAYER_LEVEL_UP just named - the event comes a moment
-- before UnitLevel follows - whichever is higher; a level the client will not give leaves everything on.
--
-- A STEP IS GETTING UP. The user, 2026-11-18: "for the well rested tracking in fct we only want to track that
-- if the user is laying down. if the user actively moving/running we know they aren't getting the well rested
-- buff so its the easiest tell". The client has no call for "lying down", but it says when the feet start to
-- move (PLAYER_STARTED_MOVING; GetUnitSpeed where it is readable). So a step while a count-up runs ends it at
-- once instead of waiting for the resting flag or the 75 seconds: at 0/3 the bar goes; with a stack or two the
-- buff stays and the count-up to the next stack stops, until the next stack lands or you lie down again; the
-- minute toward a refresh at 3/3 is dropped. And resting that comes on while you are moving - walking into
-- an inn or a city - is no bag: the bar does not ask. A step in the first two seconds after lying down is
-- taken for the lying down itself (whether settling onto the bag counts as a step is not measured yet; the
-- probe logs every step that ends a count-up).
local _, ns = ...

local Rested = {}
ns.Rested = Rested

local DEFAULT_NAME = "Well-Rested"
local BUFF_ID = 429959  -- Well-Rested (the probe, 2026-11-11)
local BAG_CAST = 429961 -- Unroll Bag
local BAG_TO_REST = 30  -- seconds from the bag's cast to resting that still count as lying down (measured: 8)
local CAST_TO_REST = 8  -- the measured gap, for a reload that came after resting but before we heard it
local LOAD_QUIET = 5     -- seconds after a loading screen when resting coming on is the place, not a bag
local START_WORDS = "you feel rested" -- the bag's chat line (inns and cities print none: the user)
local START_EVENTS = { "CHAT_MSG_SYSTEM", "CHAT_MSG_EMOTE", "CHAT_MSG_TEXT_EMOTE", "CHAT_MSG_MONSTER_EMOTE",
    "CHAT_MSG_MONSTER_SAY", "CHAT_MSG_MONSTER_WHISPER", "CHAT_MSG_RAID_BOSS_EMOTE", "CHAT_MSG_RAID_BOSS_WHISPER",
    "CHAT_MSG_RESTRICTED", "UI_INFO_MESSAGE" }
local MAX_STACKS = 3
local MINUTE = 60     -- a stack for every minute resting inside
local GRACE = 15      -- seconds past the minute with no stack: you got up, the count-up stops
local SHOW_FULL = 5   -- seconds the full bar stays at 3/3 before it lets go
local SETTLE = 2      -- seconds after lying down in which a step is the lying down itself (A STEP IS GETTING UP)
local ROW_FOR = 90    -- seconds after the last stack the bar keeps its row
local COLOR = { 0.45, 0.65, 0.95 }
local RETIRE_LEVEL = 60 -- from here on the bag's experience bonus is worth nothing (AT 60)

Rested.state = { stacks = nil, at = nil, expires = nil, counted = false, seen = false,
    reads = 0, gains = 0, lastAnswer = "not read yet", unsure = false, loadedAt = GetTime() }

-- level 60 and up: the whole count-up is off (AT 60)
function Rested:Retired()
    local level = Rested.state.level -- what PLAYER_LEVEL_UP named, if it has come this session
    if type(UnitLevel) == "function" then
        local ok, read = pcall(UnitLevel, "player")
        if ok and not ns.IsSecret(read) and type(read) == "number" and read > (level or 0) then
            level = read
        end
    end
    return level ~= nil and level >= RETIRE_LEVEL
end

function Rested:GetName()
    local saved = ns.cdb and ns.cdb.restedName
    return (type(saved) == "string" and saved ~= "" and saved) or DEFAULT_NAME
end

-- stacks (nil = no count from the client), expiry; or nil when the buff is not on you; second value false
-- when the client gave no clear answer
local function readAura()
    local state = Rested.state
    local byID = C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID
    local lookup = C_UnitAuras and C_UnitAuras.GetAuraDataBySpellName
    local ok, aura
    if Rested:GetName() == DEFAULT_NAME and type(byID) == "function" then
        ok, aura = pcall(byID, BUFF_ID)
    end
    if not ok or aura == nil then
        if type(lookup) ~= "function" then
            state.lastAnswer = "this client has no C_UnitAuras.GetAuraDataBySpellName"
            return nil, false
        end
        ok, aura = pcall(lookup, "player", Rested:GetName(), "HELPFUL")
    end
    if not ok then
        state.lastAnswer = "raised: " .. tostring(aura)
        return nil, false
    end
    if aura == nil then
        state.lastAnswer = "not on you"
        return nil, true
    end
    if ns.IsSecret(aura) or type(aura) ~= "table" then
        state.lastAnswer = "secret aura"
        return nil, false
    end
    local stacks, expires = aura.applications, aura.expirationTime
    if ns.AnySecret(stacks, expires) then
        state.lastAnswer = "secret stacks"
        return nil, false
    end
    state.reads = state.reads + 1
    state.lastAnswer = "on you, " .. tostring(stacks) .. " stack(s)"
    return { stacks = (type(stacks) == "number" and stacks > 0) and stacks or nil, expires = expires }, true
end

function Rested:Refresh()
    if InCombatLockdown() or Rested:Retired() then
        return
    end
    local aura, clear = readAura()
    if not clear then
        return
    end
    local state = Rested.state
    local now = GetTime()
    if not aura then
        if state.stacks == 0 then
            return -- lying down: the first stack has not come yet
        end
        state.stacks, state.at, state.expires, state.counted = nil, nil, nil, false
        return
    end
    state.seen = true
    local pushed = type(aura.expires) == "number" and type(state.expires) == "number" and state.expires > 0
        and aura.expires > state.expires + 1
    if state.refreshing and pushed and (aura.stacks == nil or aura.stacks >= MAX_STACKS) then
        -- lying down at 3/3: the minute's refresh landed - full, a moment, then done
        state.stacks, state.at, state.refreshing = MAX_STACKS, now, false
        state.refreshes = (state.refreshes or 0) + 1
        if ns.cdb then
            ns.cdb.restedRefresh = nil
        end
    elseif state.stacks == nil or state.stacks == 0 then
        -- just got it: the first stack, and the first minute toward the next starts now
        state.stacks, state.at, state.counted = aura.stacks or 1, now, aura.stacks == nil
        state.gains, state.up = state.gains + 1, false
    elseif aura.stacks then
        if aura.stacks > state.stacks then
            state.at, state.up = now, false -- (a stack after a step: back in the bag)
            state.gains = state.gains + 1
        end
        state.stacks, state.counted = aura.stacks, false
    elseif type(aura.expires) == "number" and type(state.expires) == "number" and state.expires > 0
        and aura.expires > state.expires then
        -- no count from the client: a refresh (the expiry pushed later) is the next stack
        state.stacks = math.min(MAX_STACKS, state.stacks + 1)
        state.at, state.counted, state.up = now, true, false
        state.gains = state.gains + 1
    end
    state.expires = aura.expires
end

-- stacks, seconds since the last one, still growing; nil when the buff is not on you
function Rested:Current(now)
    local state = Rested.state
    if not state.stacks or not state.at or Rested:Retired() then
        return nil
    end
    local elapsed = math.max(0, now - state.at)
    local growing = (state.stacks < MAX_STACKS or state.refreshing == true) and elapsed <= MINUTE + GRACE
        and not state.up -- (a step took you out of the bag: nothing more is coming)
    return state.stacks, elapsed, growing
end

function Rested:InUse(now)
    local stacks, elapsed, growing = Rested:Current(now or GetTime())
    if not stacks then
        return false
    end
    return growing or (stacks >= MAX_STACKS and elapsed < SHOW_FULL)
end

-- a row only around the bag: from the first stack until a while after the last
function Rested:Applies(now)
    local stacks, elapsed = Rested:Current(now or GetTime())
    return stacks ~= nil and elapsed < ROW_FOR
end

-- active, fraction, remaining, dim, text, color - as the bar wants it
function Rested:GetProgress(now)
    local stacks, elapsed, growing = Rested:Current(now)
    if not stacks then
        return false, 0, 0, false, "", nil
    end
    if stacks >= MAX_STACKS and not Rested.state.refreshing then
        return true, 1, 0, false, MAX_STACKS .. "/" .. MAX_STACKS, COLOR
    end
    if not growing then
        return false, 0, 0, false, "", nil
    end
    local shown = math.floor(math.min(elapsed, MINUTE))
    local text = string.format("%d/%d  %d:%02d", stacks, MAX_STACKS, math.floor(shown / 60), shown % 60)
    return true, math.min(1, elapsed / MINUTE), math.max(0, MINUTE - elapsed), false, text, COLOR
end

-- lying down: the next minute starts now - 0/3 with no buff yet; with a stack or two left from before, the
-- minute toward the next one starts over; at 3/3 the minute toward the refresh (A REFRESH AT 3/3)
local function layDown(state, unsure)
    if state.stacks == nil then
        state.stacks, state.expires, state.counted = 0, nil, false
    end
    state.at, state.unsure = GetTime(), unsure == true
    state.laidAt, state.up = state.at, false
    state.refreshing = state.stacks >= MAX_STACKS
    if ns.cdb then
        ns.cdb.restedLayAt, ns.cdb.restedUnsure = state.at, state.unsure or nil
        ns.cdb.restedRefresh = state.refreshing or nil
    end
    state.started = (state.started or 0) + 1
end

local function getUp(state)
    state.stacks, state.at, state.expires, state.counted, state.unsure = nil, nil, nil, false, false
    state.refreshing, state.up = false, false
    if ns.cdb then
        ns.cdb.restedLayAt, ns.cdb.restedUnsure, ns.cdb.restedRefresh = nil, nil, nil
    end
end

-- are the feet moving: the client's own events say (kept in state.moving), and the speed where it is readable
local function moving()
    if Rested.state.moving then
        return true
    end
    if type(GetUnitSpeed) == "function" then
        local ok, speed = pcall(GetUnitSpeed, "player")
        if ok and not ns.IsSecret(speed) and type(speed) == "number" and speed > 0 then
            return true
        end
    end
    return false
end

-- the feet started to move: out of the bag, whatever was counting (A STEP IS GETTING UP)
function Rested:Stepped()
    local state = Rested.state
    state.moving = true
    if Rested:Retired() or not state.stacks or not state.at then
        return false
    end
    local now = GetTime()
    if state.laidAt and now - state.laidAt < SETTLE then
        return false -- settling onto the bag
    end
    local was = state.stacks
    if state.stacks == 0 then
        getUp(state) -- up before the first stack
    elseif state.refreshing then
        state.refreshing, state.at = false, now - ROW_FOR -- up before the refresh: nothing more to count
        if ns.cdb then
            ns.cdb.restedRefresh, ns.cdb.restedLayAt = nil, nil
        end
    elseif state.stacks < MAX_STACKS and not state.up and now - state.at <= MINUTE + GRACE then
        state.up = true -- the buff stays; the count-up to the next stack stops
        if ns.cdb then
            ns.cdb.restedLayAt = nil
        end
    else
        return false
    end
    state.steps = (state.steps or 0) + 1
    if Rested.Stepped_note then
        Rested.Stepped_note(was)
    end
    return true
end

-- the bar is asking "Sleeping bag?" (resting came on with no other sign, and no stack yet)
function Rested:Unsure()
    local state = Rested.state
    return state.unsure == true and state.stacks == 0
end

-- the check: yes, a sleeping bag - the bar stays
function Rested:Confirm()
    Rested.state.unsure = false
    if ns.cdb then
        ns.cdb.restedUnsure = nil
    end
end

-- the X: no bag - the bar goes
function Rested:Dismiss()
    if Rested.state.stacks == 0 then
        getUp(Rested.state)
    end
end

-- a chat line: "You feel rested." - somebody's bag, yours or not
function Rested:Heard(text)
    if ns.IsSecret(text) or type(text) ~= "string" or not string.find(string.lower(text), START_WORDS, 1, true)
        or Rested:Retired() then
        return false
    end
    layDown(Rested.state)
    return true
end

-- your cast: the bag's is remembered, to tell lying down from walking into an inn
function Rested:Cast(spellID)
    if not ns.IsSecret(spellID) and spellID == BAG_CAST and not Rested:Retired() then
        Rested.state.bagAt = GetTime()
        if ns.cdb then
            ns.cdb.restedBagAt, ns.cdb.restedLayAt = Rested.state.bagAt, nil
        end
    end
end

-- the bag's cast, from this session or from before a reload
local function bagAt()
    local saved = ns.cdb and ns.cdb.restedBagAt
    return Rested.state.bagAt or (type(saved) == "number" and saved or nil)
end

-- the resting flag came on: shortly after the bag's cast, you lay down - the first minute starts now (0/3)
function Rested:Started(resting)
    local state = Rested.state
    if ns.IsSecret(resting) or Rested:Retired() then
        return false
    end
    local now = GetTime()
    if not resting then
        if state.stacks == 0 then
            getUp(state) -- up again before the first stack, or out of the inn
        elseif state.refreshing then
            state.refreshing, state.at = false, now - ROW_FOR -- up before the refresh: nothing more to count
            if ns.cdb then
                ns.cdb.restedRefresh = nil
            end
        end
        return false
    end
    local cast = bagAt()
    if cast and now - cast <= BAG_TO_REST then
        layDown(state)
        return true
    end
    -- no other sign: a bag, or an inn? The bar asks - unless a loading screen or a flight brought you here,
    -- or your own feet did (walking into an inn or a city: A STEP IS GETTING UP)
    local onTaxi = type(UnitOnTaxi) == "function" and UnitOnTaxi("player")
    if state.stacks == nil and now - (state.loadedAt or 0) > LOAD_QUIET and not (onTaxi and not ns.IsSecret(onTaxi))
        and not moving() then
        layDown(state, true)
        return true
    end
    return false
end

-- after a reload: still lying in the bag with no stack yet - the 0/3 count-up goes on from when you lay down
function Rested:Resume()
    local state = Rested.state
    if Rested:Retired() then
        return false
    end
    if state.stacks == MAX_STACKS and ns.cdb and ns.cdb.restedRefresh and type(ns.cdb.restedLayAt) == "number"
        and type(IsResting) == "function" then
        local resting, lay = IsResting(), ns.cdb.restedLayAt
        local age = GetTime() - lay
        if not ns.IsSecret(resting) and resting and age >= 0 and age <= MINUTE + GRACE then
            state.at, state.refreshing = lay, true -- still lying down at 3/3: the minute toward the refresh goes on
            return true
        end
        ns.cdb.restedRefresh = nil
        return false
    end
    if state.stacks ~= nil or type(IsResting) ~= "function" then
        return false
    end
    local resting = IsResting()
    if ns.IsSecret(resting) or not resting then
        return false
    end
    local now = GetTime()
    local lay = ns.cdb and ns.cdb.restedLayAt
    if type(lay) ~= "number" then
        local cast = bagAt()
        lay = cast and (cast + CAST_TO_REST) or nil
    end
    if not lay or now - lay < 0 or now - lay > MINUTE + GRACE then
        return false
    end
    state.stacks, state.at, state.expires, state.counted = 0, lay, nil, false
    state.unsure = ns.cdb and ns.cdb.restedUnsure == true or false
    return true
end

function Rested:Describe()
    local state = Rested.state
    return {
        name = Rested:GetName(), stacks = state.stacks, counted = state.counted, seen = state.seen,
        since = state.at and math.floor((GetTime() - state.at) * 10) / 10 or nil,
        reads = state.reads, gains = state.gains, lastAnswer = state.lastAnswer, started = state.started,
        unsure = state.unsure, refreshing = state.refreshing, refreshes = state.refreshes,
        retired = Rested:Retired(), steps = state.steps, up = state.up, moving = state.moving,
    }
end

-- a level gained: the one that retires the count-up takes down what was counting, and what a reload would
-- pick up again
ns:On("PLAYER_LEVEL_UP", function(_, level)
    if ns.IsSecret(level) or type(level) ~= "number" then
        return
    end
    Rested.state.level = level
    if level >= RETIRE_LEVEL then
        getUp(Rested.state)
        if ns.cdb then
            ns.cdb.restedBagAt = nil
        end
    end
end)

ns:OnPlayerUnit("UNIT_AURA", function()
    ns.SafeCall(Rested.Refresh, Rested)
end)

ns:On("PLAYER_ENTERING_WORLD", function()
    Rested.state.loadedAt = GetTime()
    ns.SafeCall(Rested.Refresh, Rested)
    ns.SafeCall(Rested.Resume, Rested)
end)

ns:On("PLAYER_REGEN_ENABLED", function()
    ns.SafeCall(Rested.Refresh, Rested)
end)

ns:OnPlayerUnit("UNIT_SPELLCAST_SUCCEEDED", function(_, _, _, spellID)
    ns.SafeCall(Rested.Cast, Rested, spellID)
end)

for _, event in ipairs(START_EVENTS) do
    ns:On(event, function(_, first, second)
        -- UI_INFO_MESSAGE is (type, text); the chat events (text, ...)
        local ok, heard = ns.SafeCall(Rested.Heard, Rested, event == "UI_INFO_MESSAGE" and second or first)
        if ok and heard and Rested.Heard_note then
            Rested.Heard_note(event, event == "UI_INFO_MESSAGE" and second or first)
        end
    end)
end

ns:On("PLAYER_UPDATE_RESTING", function()
    if type(IsResting) == "function" then
        ns.SafeCall(Rested.Started, Rested, IsResting())
    end
end)

ns:On("PLAYER_STARTED_MOVING", function()
    ns.SafeCall(Rested.Stepped, Rested)
end)

ns:On("PLAYER_STOPPED_MOVING", function()
    Rested.state.moving = false
end)

------------------------------------------------------------------------
-- The probe ('/fct rested probe'). The user, 2026-11-11: "is there a way to track that you are starting to
-- get the buff before stack 1?" Well Rested lands only after the first minute inside, and what the client
-- shows during that minute - an aura of its own while you lie in the bag, the bag's cast, the resting flag -
-- is not written down anywhere. So: keep a short log of every buff and debuff that comes or goes, every cast
-- and channel of yours, and the resting flag, and show it. Read-only; out of combat only (where the client
-- lets an addon at the player's auras); nothing looked at before ns.IsSecret cleared it. The log is kept in
-- the character's saved data, so a /reload puts it on disk.
------------------------------------------------------------------------
local PROBE_KEEP = 40     -- log lines kept
local PROBE_SHOW = 600    -- seconds back the command shows

local probe = { auras = nil } -- auras: instanceID -> { name, id } as last read (nil = not read yet)

local function probeLog()
    local cdb = ns.cdb
    if type(cdb.restedProbe) ~= "table" then
        cdb.restedProbe = {}
    end
    return cdb.restedProbe
end

local function note(entry)
    if Rested:Retired() then
        return -- nothing left to find out about the bag
    end
    entry.t = math.floor(GetTime() * 10) / 10
    entry.at = date("%H:%M:%S")
    local log = probeLog()
    log[#log + 1] = entry
    while #log > PROBE_KEEP do
        table.remove(log, 1)
    end
end

local function plain(value)
    if ns.IsSecret(value) then
        return "<secret>"
    end
    local kind = type(value)
    if kind == "number" or kind == "string" or kind == "boolean" then
        return value
    end
    return nil
end

-- every aura on you (buffs and debuffs) by instance id, or nil when the client gives no clear answer
local function readAllAuras()
    local api = C_UnitAuras
    if type(api) ~= "table" or type(api.GetUnitAuraInstanceIDs) ~= "function"
        or type(api.GetAuraDataByAuraInstanceID) ~= "function" then
        return nil
    end
    local seen = {}
    for _, filter in ipairs({ "HELPFUL", "HARMFUL" }) do
        local ok, ids = pcall(api.GetUnitAuraInstanceIDs, "player", filter)
        if not ok or ns.IsSecret(ids) or type(ids) ~= "table" then
            return nil
        end
        for _, id in ipairs(ids) do
            if not ns.IsSecret(id) and seen[id] == nil then
                local fine, aura = pcall(api.GetAuraDataByAuraInstanceID, "player", id)
                if fine and type(aura) == "table" and not ns.IsSecret(aura) then
                    seen[id] = {
                        name = plain(aura.name), id = plain(aura.spellId), stacks = plain(aura.applications),
                        duration = plain(aura.duration), harmful = filter == "HARMFUL" or nil,
                    }
                end
            end
        end
    end
    return seen
end

function Rested:ProbeAuras()
    if InCombatLockdown() then
        return
    end
    local now = readAllAuras()
    if not now then
        return
    end
    local was = probe.auras
    probe.auras = now
    if not was then
        return -- the first look: what you already wear is no news
    end
    for id, aura in pairs(now) do
        if not was[id] then
            note({ what = aura.harmful and "debuff on" or "buff on", name = aura.name, id = aura.id,
                stacks = aura.stacks, duration = aura.duration })
        elseif was[id].stacks ~= aura.stacks then
            note({ what = "stacks", name = aura.name, id = aura.id, stacks = aura.stacks })
        end
    end
    for id, aura in pairs(was) do
        if not now[id] then
            note({ what = aura.harmful and "debuff off" or "buff off", name = aura.name, id = aura.id })
        end
    end
end

local function spellName(spellID)
    local get = C_Spell and C_Spell.GetSpellName
    if ns.IsSecret(spellID) or type(spellID) ~= "number" or type(get) ~= "function" then
        return nil
    end
    local ok, name = pcall(get, spellID)
    return ok and plain(name) or nil
end

local function noteCast(what)
    return function(_, _, _, spellID)
        note({ what = what, name = spellName(spellID), id = plain(spellID) })
    end
end

ns:OnPlayerUnit("UNIT_AURA", function()
    ns.SafeCall(Rested.ProbeAuras, Rested)
end)
ns:On("PLAYER_ENTERING_WORLD", function()
    probe.auras = nil
    ns.SafeCall(Rested.ProbeAuras, Rested)
end)
ns:On("PLAYER_REGEN_ENABLED", function()
    ns.SafeCall(Rested.ProbeAuras, Rested)
end)
ns:OnPlayerUnit("UNIT_SPELLCAST_SUCCEEDED", noteCast("cast"))
ns:OnPlayerUnit("UNIT_SPELLCAST_CHANNEL_START", noteCast("channel start"))
ns:OnPlayerUnit("UNIT_SPELLCAST_CHANNEL_STOP", noteCast("channel stop"))
Rested.Heard_note = function(event, text)
    note({ what = "chat " .. event, name = plain(text) })
end
Rested.Stepped_note = function(stacks)
    note({ what = "step", name = "up at " .. tostring(stacks) .. "/" .. MAX_STACKS .. " - the count-up ends" })
end
ns:On("PLAYER_UPDATE_RESTING", function()
    local resting = type(IsResting) == "function" and plain(IsResting()) or nil
    note({ what = "resting", name = tostring(resting) .. (Rested.state.stacks == 0 and (Rested.state.unsure and " - 0/3, asking 'Sleeping bag?'" or " - lying down: 0/3") or "") })
end)

-- the log's lines as the chat shows them, newest last
function Rested:ProbeLines(now)
    now = now or GetTime()
    local lines = {}
    for _, entry in ipairs(probeLog()) do
        if type(entry.t) == "number" and now - entry.t <= PROBE_SHOW then
            local extra = {}
            if entry.id ~= nil then extra[#extra + 1] = "id " .. tostring(entry.id) end
            if entry.stacks ~= nil and entry.stacks ~= 0 then extra[#extra + 1] = tostring(entry.stacks) .. " stack(s)" end
            if type(entry.duration) == "number" and entry.duration > 0 then extra[#extra + 1] = entry.duration .. "s" end
            lines[#lines + 1] = string.format("%5ds ago  %s  |cffffd100%s|r%s", math.floor(now - entry.t + 0.5),
                entry.what, tostring(entry.name or "?"), #extra > 0 and ("  (" .. table.concat(extra, ", ") .. ")") or "")
        end
    end
    return lines
end

local function printProbe()
    local lines = Rested:ProbeLines()
    if #lines == 0 then
        ns:Print("probe: nothing came or went in the last " .. (PROBE_SHOW / 60) .. " minutes (out of combat, buffs, debuffs, casts, resting).")
    else
        ns:Print("probe - the last " .. (PROBE_SHOW / 60) .. " minutes, newest last:")
        for _, text in ipairs(lines) do
            print("   " .. text)
        end
    end
    local wearing = {}
    for _, aura in pairs(readAllAuras() or {}) do
        wearing[#wearing + 1] = tostring(aura.name) .. (aura.harmful and " (debuff)" or "")
    end
    table.sort(wearing)
    ns:Print("on you now: " .. (#wearing > 0 and table.concat(wearing, ", ") or (InCombatLockdown() and "(in a fight: not readable)" or "nothing readable"))
        .. ". Kept in your saved data - |cffffd100/reload|r puts it on disk.")
end

ns:RegisterCommand("rested", "the sleeping bag count-up: '/fct rested' says what it sees, '/fct rested probe' lists what came and went lately (buffs, casts, resting), '/fct rested <buff name>' if the buff is called something else", function(rest)
    local name = string.match(rest or "", "^%s*(.-)%s*$")
    if Rested:Retired() then
        ns:Print("sleeping bag count-up: off from level " .. RETIRE_LEVEL .. " - the bag's bonus is to experience, and there is none left to earn.")
        return
    end
    if name == "probe" then
        printProbe()
        return
    end
    if name ~= "" then
        ns.cdb.restedName = name
        Rested.state.stacks, Rested.state.at = nil, nil
        Rested:Refresh()
        ns:Print("watching the buff called |cffffd100" .. name .. "|r for the sleeping bag.")
        return
    end
    local info = Rested:Describe()
    ns:Print("sleeping bag count-up: buff |cffffd100" .. info.name .. "|r - "
        .. (info.stacks and (info.stacks .. "/" .. MAX_STACKS .. ", " .. tostring(info.since) .. "s since the last stack" .. (info.counted and " (counted by us: no stack count from the client)" or ""))
            or "not on you")
        .. ". The client's last answer: " .. info.lastAnswer .. ".")
end)
