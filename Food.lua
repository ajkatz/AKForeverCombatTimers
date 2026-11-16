-- Well Fed: the count-up while you eat buff food.
--
-- WHY. The user, 2026-11-13: "similarly for the count up for the sleeping bag / plains running i'd like to get
-- a count up for when buff food is consumed and getting the well fed buff". Buff food says so in its own
-- words ("If you spend at least 10 seconds eating you will become well fed ..."): eat that long and the Well
-- Fed buff comes. A bar that fills over those seconds shows when it will land - and a refresh too, eating
-- again while still Well Fed (the buff's expiry moving later is the refresh).
--
-- HOW. Out of combat (where the client lets an addon at the player's auras), on every aura change:
--   * eating (the "Food" / "Food & Drink" buff) comes on: if its spell's description speaks of being well
--     fed, the count-up starts - over the seconds the description names, else the gap measured the last
--     time, else 10;
--   * Well Fed comes on (or its expiry moves later, eating while Well Fed): the bar fills, flashes full a
--     moment and lets go; the gap is measured for next time;
--   * eating stops before that: the bar goes.
-- Food whose description the client has not loaded yet is asked for (C_Spell.RequestLoadSpellData) and
-- looked at again when it arrives; food that does not make you well fed gets no bar. Nothing runs on a timer
-- of its own: the bar asks GetProgress once a frame.
--
-- ONLY AT THE END. The user, 2026-11-15: "have a count up until your food buff hits when you are eating" -
-- the bar came only as the full "Well Fed" at the end (the saved report: 2 meals, 2 landings, 10 s each). So
-- the eating buff's words were not telling us it was buff food - not loaded, or silent about it; which, the
-- report did not say. Now, in this order:
--   * a food that made you well fed before is buff food (remembered by the eating buff's id, for the whole
--     account), whatever its words;
--   * the words of the eating buff OR of the cast that began the meal (the item's use spell) naming Well Fed;
--   * a food eaten past the mark with no Well Fed is plain (remembered too);
--   * words that are there and silent about Well Fed: plain - unless silent words have made you well fed
--     before (remembered), then they prove nothing;
--   * anything else is a GUESS: the count-up shows, and no Well Fed three seconds past the mark takes it
--     away and remembers the food as plain. Words that arrive meanwhile settle it.
-- And every meal leaves a note for '/fct food' and the report: the ids, what the words said, why.
local _, ns = ...

local Food = {}
ns.Food = Food

local EATING = { "Food", "Food & Drink" }
local WELL_FED = "Well Fed"
local DEFAULT_SECONDS = 10
local SHOW_FULL = 5   -- seconds the full bar stays once Well Fed lands
local ROW_FOR = 30    -- seconds the row stays after that
local KEEP = 5        -- measured gaps kept
local MARK_GRACE = 3  -- seconds past the mark with no Well Fed: a guess was plain food
local CAST_WINDOW = 2 -- seconds before the eating buff in which a cast of yours counts as the food's use
local CASTS_KEPT = 3
local RETRY = 1       -- seconds between looks at words that were not there yet
local SNIPPET = 160   -- characters of the food's words kept for the report
local COLOR = { 0.90, 0.60, 0.25 }

Food.state = { eatingAt = nil, eatingID = nil, buffFood = nil, words = nil, fedAt = nil, fedBefore = nil,
    lastAnswer = "not read yet", starts = 0, lands = 0 }
Food.casts = {} -- your last casts: { id, at }
Food.last = nil -- the last meal, for '/fct food' and the report

local function plainNumber(value)
    return not ns.IsSecret(value) and type(value) == "number" and value or nil
end

-- the first aura by one of these names: { id, expires } or nil; second value false when unclear
local function readByName(names)
    local lookup = C_UnitAuras and C_UnitAuras.GetAuraDataBySpellName
    if type(lookup) ~= "function" then
        return nil, false
    end
    for _, name in ipairs(names) do
        local ok, aura = pcall(lookup, "player", name, "HELPFUL")
        if not ok or ns.IsSecret(aura) then
            return nil, false
        end
        if type(aura) == "table" then
            if ns.AnySecret(aura.spellId, aura.expirationTime) then
                return nil, false
            end
            return { id = aura.spellId, expires = aura.expirationTime, name = name }, true
        end
    end
    return nil, true
end

-- a spell's words: true (they name Well Fed), false (they are there and do not), nil (not loaded yet); the
-- seconds they name; and the words themselves
local function describe(spellID)
    local get = C_Spell and C_Spell.GetSpellDescription
    if type(spellID) ~= "number" or type(get) ~= "function" then
        return nil
    end
    local ok, text = pcall(get, spellID)
    if not ok or ns.IsSecret(text) or type(text) ~= "string" or text == "" then
        local request = C_Spell and C_Spell.RequestLoadSpellData
        if type(request) == "function" then
            pcall(request, spellID)
        end
        return nil
    end
    local lower = string.lower(text)
    if not string.find(lower, "well[%s%-]?fed") then -- "well fed", "Well-Fed"
        return false, nil, text
    end
    return true, tonumber(string.match(lower, "(%d+) seconds? eating") or string.match(lower, "eating for (%d+) sec")
        or string.match(lower, "at least (%d+) sec")), text
end

-- what the account remembers of foods, by the eating buff's id: true (made you well fed), false (plain)
local function foods()
    if type(ns.db) ~= "table" then
        return {}
    end
    if type(ns.db.fedFoods) ~= "table" then
        ns.db.fedFoods = {}
    end
    return ns.db.fedFoods
end

-- the words of the eating buff and of the casts that began the meal: true if any names Well Fed, nil while
-- one of them is not loaded yet, false when all are there and silent; and the seconds named
local function readWords(state)
    local said, seconds, unread, snippet = false, nil, false, nil
    local ids = { state.eatingID }
    for _, id in ipairs(state.castIDs or {}) do
        if id ~= state.eatingID then
            ids[#ids + 1] = id
        end
    end
    for _, id in ipairs(ids) do
        local verdict, named, text = describe(id)
        if verdict == nil then
            unread = true
        elseif verdict then
            said, seconds = true, seconds or named
        end
        if text and (verdict or not snippet) then
            snippet = string.sub(text, 1, SNIPPET)
        end
    end
    if said then
        return true, seconds, snippet
    end
    if unread then
        return nil, nil, snippet
    end
    return false, nil, snippet
end

local WORDS = { [true] = "name Well Fed", [false] = "silent about Well Fed" }

-- buff food or not, and why (see ONLY AT THE END)
local function judge(state)
    local words, seconds, snippet = readWords(state)
    state.wordsSay = words
    if words then
        state.words = seconds
    end
    local known = foods()[state.eatingID]
    local silentBefore = type(ns.db) == "table" and ns.db.fedWordsSilent == true
    if known == true then
        state.buffFood, state.guess, state.why = true, false, "it made you well fed before"
    elseif words == true then
        state.buffFood, state.guess, state.why = true, false, "its words name Well Fed"
    elseif known == false then
        state.buffFood, state.guess, state.why = false, false, "no Well Fed came the last time"
    elseif words == false and not silentBefore then
        state.buffFood, state.guess, state.why = false, false, "its words name no Well Fed"
    else
        state.buffFood, state.guess = true, true
        state.why = words == false and "a guess: silent words have made you well fed before"
            or "a guess: its words are not readable yet"
    end
    Food.last = { id = state.eatingID, casts = state.castIDs, words = WORDS[words] or "not readable", text = snippet,
        buffFood = state.buffFood, guess = state.guess, why = state.why, at = date and date("%H:%M:%S") or nil }
end

-- while eating, before Well Fed: words that were not there are looked at again, and a guess that has run
-- three seconds past the mark was plain food
local function settle(state, now)
    if not state.eatingAt or state.fedAt then
        return
    end
    if state.wordsSay == nil and now - (state.askedAt or 0) >= RETRY then
        state.askedAt = now
        judge(state)
    end
    if state.guess and state.buffFood and now - state.eatingAt > Food:Seconds() + MARK_GRACE then
        foods()[state.eatingID] = false
        state.buffFood, state.guess, state.why = false, false, "no Well Fed by the mark: plain food"
        if Food.last then
            Food.last.buffFood, Food.last.guess, Food.last.why = false, false, state.why
        end
    end
end

local function median(list)
    if type(list) ~= "table" or #list == 0 then
        return nil
    end
    local sorted = {}
    for i, v in ipairs(list) do sorted[i] = v end
    table.sort(sorted)
    return sorted[math.floor((#sorted + 1) / 2)]
end

-- the seconds from the first bite to Well Fed
function Food:Seconds()
    local state = Food.state
    local measured = median(ns.cdb and ns.cdb.fedGaps)
    return state.words or measured or DEFAULT_SECONDS, (state.words and "the food's words") or (measured and "measured") or "assumed"
end

local function stopEating(state)
    state.eatingAt, state.eatingID, state.buffFood, state.words, state.fedBefore = nil, nil, nil, nil, nil
    state.guess, state.why, state.wordsSay, state.castIDs, state.askedAt = nil, nil, nil, nil, nil
end

-- your casts in the moments before the eating buff came: the food's use among them
local function castsBefore(now)
    local ids = {}
    for _, cast in ipairs(Food.casts) do
        if now - cast.at <= CAST_WINDOW then
            ids[#ids + 1] = cast.id
        end
    end
    return ids
end

function Food:Refresh()
    if InCombatLockdown() then
        return
    end
    local state = Food.state
    local eating, clear = readByName(EATING)
    local fed, fedClear = readByName({ WELL_FED })
    if not clear or not fedClear then
        state.lastAnswer = "not readable"
        return
    end
    local now = GetTime()
    state.lastAnswer = (eating and ("eating (" .. tostring(eating.id) .. ")") or "not eating") .. (fed and ", well fed" or "")
    if eating and not state.eatingAt then
        state.eatingAt, state.eatingID, state.fedAt = now, eating.id, nil
        state.fedBefore = fed and plainNumber(fed.expires) or false
        state.words, state.castIDs, state.askedAt = nil, castsBefore(now), now
        judge(state)
        state.starts = state.starts + 1
    elseif not eating and state.eatingAt then
        settle(state, now) -- a guess eaten past the mark is remembered as plain even with no bar looking
        stopEating(state)
        return
    end
    if not state.eatingAt or state.fedAt then
        return
    end
    -- Well Fed came, or moved later while eating: landed
    local landed = fed and (state.fedBefore == false or state.fedBefore == nil
        or (plainNumber(fed.expires) and fed.expires > state.fedBefore + 1))
    if not landed then
        settle(state, now)
    end
    if landed then
        state.fedAt = now
        if type(state.eatingID) == "number" then
            foods()[state.eatingID] = true -- whatever the words said: this food makes you well fed
        end
        if state.wordsSay == false and type(ns.db) == "table" then
            ns.db.fedWordsSilent = true -- its words were there and silent: silent words prove nothing here
        end
        state.buffFood, state.guess = true, false
        state.lands = state.lands + 1
        if Food.last then
            Food.last.landed = math.floor((now - state.eatingAt) * 10 + 0.5) / 10
            Food.last.shownFromStart = Food.last.buffFood == true
            Food.last.buffFood, Food.last.guess = true, false
        end
        local gap = now - state.eatingAt
        if ns.cdb and gap >= 1 and gap <= 60 then
            local gaps = type(ns.cdb.fedGaps) == "table" and ns.cdb.fedGaps or {}
            gaps[#gaps + 1] = math.floor(gap * 10 + 0.5) / 10
            while #gaps > KEEP do table.remove(gaps, 1) end
            ns.cdb.fedGaps = gaps
        end
    end
end

-- the client loaded a spell's words: while the meal's are still missing, look again
function Food:Loaded(spellID)
    local state = Food.state
    if state.eatingAt and not state.fedAt and state.wordsSay == nil then
        judge(state)
    end
end

-- a cast of yours: kept a moment, the food's use spell may be the one whose words name Well Fed
function Food:Cast(spellID)
    if ns.IsSecret(spellID) or type(spellID) ~= "number" then
        return
    end
    local casts = Food.casts
    casts[#casts + 1] = { id = spellID, at = GetTime() }
    while #casts > CASTS_KEPT do
        table.remove(casts, 1)
    end
end

-- active, fraction, remaining, dim, text, color - as the bar wants it
function Food:GetProgress(now)
    local state = Food.state
    settle(state, now)
    if state.fedAt then
        if now - state.fedAt < SHOW_FULL then
            return true, 1, 0, false, "Well Fed", COLOR
        end
        return false, 0, 0, false, "", nil
    end
    if not state.eatingAt or state.buffFood ~= true then
        return false, 0, 0, false, "", nil
    end
    local seconds = Food:Seconds()
    local elapsed = math.max(0, now - state.eatingAt)
    local shown = math.floor(elapsed)
    return true, math.min(1, elapsed / seconds), math.max(0, seconds - elapsed), false,
        string.format("%d:%02d", math.floor(shown / 60), shown % 60), COLOR
end

function Food:InUse(now)
    return (Food:GetProgress(now or GetTime()))
end

function Food:Applies(now)
    local state = Food.state
    now = now or GetTime()
    settle(state, now)
    return (state.eatingAt ~= nil and state.buffFood == true) or (state.fedAt ~= nil and now - state.fedAt < SHOW_FULL + ROW_FOR)
end

function Food:Describe()
    local state = Food.state
    local seconds, from = Food:Seconds()
    return { eating = state.eatingAt ~= nil, eatingID = state.eatingID, buffFood = state.buffFood, seconds = seconds,
        secondsFrom = from, measured = ns.cdb and ns.cdb.fedGaps, lastAnswer = state.lastAnswer,
        starts = state.starts, lands = state.lands, guess = state.guess, why = state.why,
        last = Food.last, foods = type(ns.db) == "table" and ns.db.fedFoods or nil,
        wordsSilent = type(ns.db) == "table" and ns.db.fedWordsSilent or nil }
end

ns:OnPlayerUnit("UNIT_SPELLCAST_SUCCEEDED", function(_, _, _, spellID)
    ns.SafeCall(Food.Cast, Food, spellID)
end)

ns:RegisterCommand("food", "the buff food count-up: what the last meal was taken for and why, and the foods remembered", function()
    local info = Food:Describe()
    local last = info.last
    if not last then
        ns:Print("buff food count-up: no meal seen since you logged in. Eat something (out of combat) and ask again.")
    else
        ns:Print("buff food count-up - the last meal (" .. tostring(last.at) .. "): eating buff |cffffd100" .. tostring(last.id) .. "|r"
            .. (last.casts and #last.casts > 0 and (", casts just before: " .. table.concat(last.casts, ", ")) or "")
            .. "; its words: " .. tostring(last.words) .. ". Taken for "
            .. (last.buffFood and "buff food" or "plain food") .. " - " .. tostring(last.why) .. "."
            .. (last.landed and (" Well Fed came after " .. last.landed .. " s"
                .. (last.shownFromStart and "." or " - the count-up had not shown; it will the next time.")) or ""))
        if last.text then
            print("   the words: \"" .. last.text .. "\"")
        end
    end
    local yes, no = {}, {}
    for id, makes in pairs(info.foods or {}) do
        local list = makes and yes or no
        list[#list + 1] = tostring(id)
    end
    table.sort(yes); table.sort(no)
    ns:Print("remembered: " .. (#yes > 0 and ("buff food " .. table.concat(yes, ", ")) or "no buff food yet")
        .. (#no > 0 and ("; plain food " .. table.concat(no, ", ")) or "")
        .. ". The count runs over " .. info.seconds .. " s (" .. info.secondsFrom .. ").")
end)

ns:OnPlayerUnit("UNIT_AURA", function()
    ns.SafeCall(Food.Refresh, Food)
end)
ns:On("PLAYER_ENTERING_WORLD", function()
    ns.SafeCall(Food.Refresh, Food)
end)
ns:On("PLAYER_REGEN_ENABLED", function()
    ns.SafeCall(Food.Refresh, Food)
end)
ns:On("SPELL_DATA_LOAD_RESULT", function(_, spellID, success)
    if success then
        ns.SafeCall(Food.Loaded, Food, spellID)
    end
end)
