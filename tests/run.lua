-- AKForeverCombatTimers scenario tests. Run from the repo root:
--     lua tests/run.lua
-- Every scenario loads a fresh copy of the addon into the mock client, and fails
-- if the addon raised ANY Lua error along the way (caught or not).
package.path = "./tests/?.lua;" .. package.path
local Mock = require("wowmock")

local failures, passed = {}, 0

local function check(condition, message)
    if not condition then
        error(message or "check failed", 2)
    end
end

local function equal(actual, expected, what)
    if actual ~= expected then
        error((what or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
    end
end

local function near(actual, expected, tolerance, what)
    if type(actual) ~= "number" or math.abs(actual - expected) > tolerance then
        error((what or "value") .. ": expected about " .. tostring(expected) .. ", got " .. tostring(actual), 2)
    end
end

local expectForbidden = false

local function scenario(name, fn)
    expectForbidden = false
    local ok, err = xpcall(fn, debug.traceback)
    if ok and #Mock.errors > 0 then
        ok, err = false, "addon raised errors:\n      " .. table.concat(Mock.errors, "\n      ")
    end
    if ok and not expectForbidden and #Mock.forbiddenCalls > 0 then
        ok, err = false, "addon triggered a forbidden action (the client would show the 'blocked' dialog): "
            .. table.concat(Mock.forbiddenCalls, ", ")
    end
    if ok then
        passed = passed + 1
        Mock.realPrint("  ok    " .. name)
    else
        failures[#failures + 1] = name
        Mock.realPrint("  FAIL  " .. name .. "\n      " .. tostring(err):gsub("\n", "\n      "))
    end
end

local MH, OH, RG = 0, 1, 2
local WIDTH = 220

local function start(options, setup)
    options = options or {}
    options.login = false
    local ns, state = Mock.install(options)
    if setup then
        setup(state)
    end
    Mock.login()
    if not options.fade then
        ns.BarSettings:SetBlock("fade", false) -- most scenarios look at WHAT is shown; fading has its own
    end
    Mock.advance(0.1)
    return ns, state
end

-- Let time pass the way the game does: a frame at a time, each with an update of the bars.
local function run(ns, seconds, step)
    step = step or 0.05
    local elapsed = 0
    while elapsed < seconds - 1e-9 do
        local slice = math.min(step, seconds - elapsed)
        Mock.advance(slice)
        ns.Bars:Update()
        elapsed = elapsed + slice
    end
end

local function boar(state, victim)
    state.units.target = { id = "boar", name = "Boar", hostile = true }
    state.units.targettarget = victim or { id = "player", name = "Purrdee" }
    Mock.fire("PLAYER_TARGET_CHANGED")
end

Mock.realPrint("AKForeverCombatTimers tests")

-- Your own swings ---------------------------------------------------------------
scenario("PLAYER_SWING drives the bar: fills across the swing, then goes idle", function()
    local ns = start()
    Mock.swing(2.6, MH)
    local active, fraction, remaining = ns.Swings:GetProgress("MH", Mock.now)
    check(active); near(fraction, 0, 0.001); near(remaining, 2.6, 0.001)

    Mock.advance(1.3)
    ns.Bars:Update()
    near(ns.Bars.bars.MH.fill:GetWidth(), WIDTH / 2, 0.5, "half way")
    equal(ns.Bars.bars.MH.time:GetText(), "1.3")

    Mock.advance(1.4)
    active = ns.Swings:GetProgress("MH", Mock.now)
    equal(active, false, "idle after the swing lands")
    ns.Bars:Update()
    equal(ns.Bars.bars.MH.fill:IsShown(), false)
end)

scenario("main hand, off hand and ranged are timed separately; bars follow what the character can do", function()
    local ns, state = start(nil, function(s) s.attackSpeed.player = { 2.6, 1.8, nil } end)
    Mock.setCombat(true)
    Mock.swing(2.6, MH)
    Mock.advance(0.5)
    Mock.swing(1.8, OH)
    Mock.advance(0.5)
    local _, mainFraction = ns.Swings:GetProgress("MH", Mock.now)
    local _, offFraction = ns.Swings:GetProgress("OH", Mock.now)
    near(mainFraction, 1.0 / 2.6, 0.001); near(offFraction, 0.5 / 1.8, 0.001)
    ns.Bars:Update()
    equal(ns.Bars.bars.OH:IsShown(), true, "off-hand bar while dual wielding")
    equal(ns.Bars.bars.RG:IsShown(), false, "no ranged bar for a melee class that has not shot")

    state.attackSpeed.player = { 2.6, nil, nil }
    Mock.fire("UNIT_ATTACK_SPEED", "player")
    ns.Bars:Update()
    equal(ns.Bars.bars.OH:IsShown(), false, "off-hand bar gone with the off-hand weapon")

    Mock.swing(2.0, RG) -- threw something
    ns.Bars:Update()
    equal(ns.Bars.bars.RG:IsShown(), true, "ranged bar appears around a ranged attack")
    Mock.advance(13)
    ns.Bars:Update()
    equal(ns.Bars.bars.RG:IsShown(), false, "and leaves again")
end)

scenario("hunters: the ranged bar has its row from the start and shows while shooting", function()
    local ns = start({ class = "HUNTER" }, function(s) s.attackSpeed.player = { 2.0, nil, 2.8 } end)
    Mock.setCombat(true)
    ns.Bars:Update()
    equal(ns.Bars.bars.RG.slotted, true, "a row of its own")
    equal(ns.Bars.bars.RG:IsShown(), false, "'when used': nothing to show yet")
    Mock.swing(2.8, RG)
    ns.Bars:Update()
    equal(ns.Bars.bars.RG:IsShown(), true)
end)

scenario("an attack speed change rescales what is left of the running swing", function()
    local ns, state = start(nil, function(s) s.attackSpeed.player = { 2.0, nil, nil } end)
    Mock.swing(2.0, MH)
    Mock.advance(1.0) -- 1.0s left at speed 2.0
    state.attackSpeed.player = { 1.0, nil, nil } -- haste doubles attack speed
    Mock.fire("UNIT_ATTACK_SPEED", "player")
    local active, fraction, remaining = ns.Swings:GetProgress("MH", Mock.now)
    check(active); near(remaining, 0.5, 0.001, "half the time left"); near(fraction, 0.5, 0.001, "same place on the bar")
end)

scenario("out of range dims the bar, like Blizzard's", function()
    local ns = start()
    equal(Mock.rangeChecks[MH], true, "range checks requested from the client")
    Mock.setCombat(true)
    Mock.swing(2.6, MH)
    Mock.fire("PLAYER_SWING_RANGE_UPDATE", MH, false, true)
    ns.Bars:Update()
    near(ns.Bars.bars.MH:GetAlpha(), 0.4, 0.001)
    Mock.fire("PLAYER_SWING_RANGE_UPDATE", MH, true, true)
    ns.Bars:Update()
    equal(ns.Bars.bars.MH:GetAlpha(), 1)
    Mock.fire("PLAYER_SWING_RANGE_UPDATE", MH, false, false) -- no range check made: not "out of range"
    ns.Bars:Update()
    equal(ns.Bars.bars.MH:GetAlpha(), 1)
end)

scenario("secret or nonsense swing payloads are ignored, not fatal", function()
    local ns, state = start()
    Mock.swing(Mock.SECRET, MH)
    equal(ns.Swings.locked, "secret")
    equal((ns.Swings:GetProgress("MH", Mock.now)), false)
    Mock.swing(0, MH); Mock.swing(2.6, 7); Mock.swing(nil, MH)
    equal(ns.Swings.state.MH.count, 0)
    state.attackSpeed.player = Mock.SECRET
    Mock.fire("UNIT_ATTACK_SPEED", "player")
    Mock.swing(2.6, MH)
    equal(ns.Swings.locked, nil)
    check((ns.Swings:GetProgress("MH", Mock.now)))
    equal(ns.Swings:IsAvailable("MH"), true)
end)

scenario("each bar: 'when used' (+ seconds after), 'always' or 'never' - locking no longer decides what shows", function()
    local ns = start()
    local bars = ns.Bars.bars
    ns.Bars:Update()
    equal(AKForeverCombatTimersFrame:IsShown(), true, "unlocked: the block is up for its drag tab ...")
    equal(bars.MH:IsShown(), false, "... but an idle 'when used' bar is not")
    SlashCmdList.AKFOREVERCOMBATTIMERS("lock")
    ns.Bars:Update()
    equal(AKForeverCombatTimersFrame:IsShown(), false, "locked and nothing in use: nothing on screen")
    Mock.setCombat(true)
    ns.Bars:Update()
    equal(bars.MH:IsShown(), false, "being in combat is not 'use' (a caster does not want an idle swing bar)")

    Mock.swing(2.6, MH)
    ns.Bars:Update()
    equal(AKForeverCombatTimersFrame:IsShown(), true); equal(bars.MH:IsShown(), true, "swinging")
    run(ns, 2.6 + 2.8)
    equal(bars.MH:IsShown(), true, "lingers 3 seconds after the swing")
    run(ns, 0.4)
    equal(bars.MH:IsShown(), false, "and goes")

    SlashCmdList.AKFOREVERCOMBATTIMERS("bar mh used 8")
    Mock.swing(2.6, MH)
    run(ns, 2.6 + 7)
    equal(bars.MH:IsShown(), true, "'/fct bar mh used 8'")

    SlashCmdList.AKFOREVERCOMBATTIMERS("bar mh always")
    Mock.advance(60)
    ns.Bars:Update()
    equal(bars.MH:IsShown(), true, "always")
    SlashCmdList.AKFOREVERCOMBATTIMERS("bar mh never")
    ns.Bars:Update()
    equal(bars.MH:IsShown(), false); equal(bars.MH.slotted, false, "never: no row either")

    SlashCmdList.AKFOREVERCOMBATTIMERS("show always") -- the old switch still works: everything that is not 'never'
    ns.Bars:Update()
    equal(bars.ENEMY:IsShown(), true); equal(bars.CAST:IsShown(), true); equal(bars.MH:IsShown(), false)
    equal(bars.CAST.label:GetText(), "Your cast", "an idle 'always' cast bar carries its own name")
    SlashCmdList.AKFOREVERCOMBATTIMERS("test")
    ns.Bars:Update()
    equal(ns.Bars.shownBars, ns.Bars.slots, "test mode moves every bar that has a row")
    for _, command in ipairs({ "bar", "bar reset", "fade", "snap", "anchor", "order", "config", "config" }) do
        SlashCmdList.AKFOREVERCOMBATTIMERS(command)
    end
end)

scenario("fading: bars ease in and out instead of popping; '/fct fade off' makes them pop", function()
    local ns = start({ fade = true })
    SlashCmdList.AKFOREVERCOMBATTIMERS("lock")
    local bar = ns.Bars.bars.MH
    ns.Bars:Update()
    Mock.swing(2.6, MH)
    ns.Bars:Update()
    equal(bar:IsShown(), false, "not yet: no time has passed")
    Mock.advance(0.075)
    ns.Bars:Update()
    equal(bar:IsShown(), true); near(bar:GetAlpha(), 0.5, 0.01, "half way in after half the fade-in time")
    Mock.advance(0.1)
    ns.Bars:Update()
    equal(bar:GetAlpha(), 1)
    run(ns, 2.6 - 0.175 + 3 + 0.2, 0.025) -- swing over, linger over, 0.2 s into the 0.4 s fade-out
    near(bar:GetAlpha(), 0.5, 0.08, "half way out")
    run(ns, 0.5)
    equal(bar:IsShown(), false)
    SlashCmdList.AKFOREVERCOMBATTIMERS("fade off")
    Mock.swing(2.6, MH)
    ns.Bars:Update()
    equal(bar:GetAlpha(), 1, "pops")
end)

scenario("order, sizes and alignment: bars are rearranged within their half, each with its own width and height", function()
    local ns = start(nil, function(s) s.attackSpeed.player = { 2.6, 1.8, nil } end)
    local bars, block = ns.Bars.bars, AKForeverCombatTimersFrame
    ns.Bars:Update()
    local function y(bar) local _, _, _, _, offset = bar:GetPoint(1); return offset end
    equal(bars.MH:GetParent(), block.lower); equal(bars.TCAST:GetParent(), block.upper)
    equal(y(bars.MH), 0, "your first bar hangs directly under the seam")
    check(y(bars.OH) < y(bars.MH) and y(bars.CAST) < y(bars.OH), "yours grow DOWN")
    equal(y(bars.ENEMY), 0, "the enemy's last bar sits on the seam")
    check(y(bars.TCAST) > y(bars.ENEMY), "the enemy's grow UP")

    SlashCmdList.AKFOREVERCOMBATTIMERS("bar cast up")
    SlashCmdList.AKFOREVERCOMBATTIMERS("bar cast up")
    ns.Bars:Update()
    check(y(bars.CAST) > y(bars.OH), "your cast moved above the off hand")
    SlashCmdList.AKFOREVERCOMBATTIMERS("order enemy tcast cast mh oh")
    ns.Bars:Update()
    equal(y(bars.TCAST), 0, "target cast on the seam now, incoming hit above it")
    equal(y(bars.CAST), 0, "your cast first under the seam")
    equal(ns.BarSettings:Move("TCAST", 1), false, "a bar never crosses the seam")

    SlashCmdList.AKFOREVERCOMBATTIMERS("bar cast height 20")
    SlashCmdList.AKFOREVERCOMBATTIMERS("bar cast width 300")
    ns.Bars:Update()
    equal(bars.CAST:GetHeight(), 20); equal(bars.CAST:GetWidth(), 300)
    equal(y(bars.MH), -(20 + 3), "the next row starts under the taller bar")
    equal(block:GetWidth(), 300 + 8, "the block is as wide as its widest bar")
    equal((bars.MH:GetPoint(1)), "TOP", "centred under it by default")
    SlashCmdList.AKFOREVERCOMBATTIMERS("anchor left")
    ns.Bars:Update()
    equal((bars.MH:GetPoint(1)), "TOPLEFT", "left edges lined up")
    equal((block:GetPoint(1)), "LEFT", "and the seam is pinned by its left end")
    Mock.cast("player", { name = "Healing Wave", seconds = 2 })
    Mock.advance(1)
    ns.Bars:Update()
    near(bars.CAST.fraction, 0.5, 0.01, "a resized cast bar still works")
end)

-- The enemy's swings ---------------------------------------------------------------
scenario("auto-watch: hostile target -> its victim; friendly target -> that friendly; else yourself", function()
    local ns, state = start()
    equal(ns.Incoming.watched, "player")

    boar(state)
    equal(ns.Incoming.watched, "player", "the boar is on me")

    state.units.party2 = { id = "tank", name = "Tanky" }
    state.units.targettarget = { id = "tank", name = "Tanky" }
    Mock.fire("UNIT_TARGET", "target")
    equal(ns.Incoming.watched, "party2", "the boar turned to the tank")

    state.units.target = { id = "tank", name = "Tanky" } -- healer targets the tank
    state.units.targettarget = { id = "boar", name = "Boar", hostile = true }
    Mock.fire("PLAYER_TARGET_CHANGED")
    equal(ns.Incoming.watched, "target")

    SlashCmdList.AKFOREVERCOMBATTIMERS("watch party2")
    equal(ns.Incoming.watched, "party2", "explicit choice wins")
    SlashCmdList.AKFOREVERCOMBATTIMERS("watch auto")
    equal(ns.Incoming.watched, "target")

    state.identitySecret = true -- the client refuses to compare units
    state.units.target = { id = "boar", name = "Boar", hostile = true }
    state.units.targettarget = { id = "tank", name = "Tanky" }
    Mock.fire("PLAYER_TARGET_CHANGED")
    equal(ns.Incoming.watched, "player", "falls back to yourself when identities are secret")
end)

scenario("a steady attacker is learned from the hits and the next one is predicted", function()
    local ns, state = start()
    boar(state)
    Mock.setCombat(true)
    for _ = 1, 6 do
        Mock.hit("player", "WOUND", 1)
        Mock.advance(2.2)
    end
    near(ns.Incoming.interval, 2.2, 0.001)
    check(ns.Incoming.confidence > 0.9, "steady rhythm -> confident")
    Mock.hit("player", "DODGE", 0) -- an avoided swing is still a swing
    local active, fraction, remaining = ns.Incoming:GetProgress(Mock.now + 1.1)
    check(active); near(fraction, 0.5, 0.01); near(remaining, 1.1, 0.01)
    check(ns.Incoming.stats.scored >= 4, "predictions were scored")
    -- the very first prediction used the 2.0s default and was 0.2s off; all later ones were exact
    near(ns.Diagnostics:Collect().enemy.meanAbsErrorSeconds, 0, 0.05, "and they were right")
    equal(ns.Incoming.stats.matched, 6, "every swing after the first was predicted")

    ns.Bars:Update()
    equal(ns.Bars.bars.ENEMY.label:GetText(), "Incoming (you)")
    equal(ns.Bars.bars.ENEMY:GetAlpha(), 1)
end)

scenario("only melee swings on the watched unit count", function()
    local ns, state = start()
    boar(state)
    Mock.setCombat(true)
    Mock.hit("player", "WOUND", 4)   -- fire damage
    Mock.hit("player", "HEAL", 2)
    Mock.hit("target", "WOUND", 1)   -- my hit on the boar
    Mock.hit("party1", "WOUND", 1)   -- someone else getting hit
    equal(ns.Incoming.stats.hits, 0)
    Mock.hit("player", "WOUND", 1)
    Mock.hit("player", "WOUND", 1)   -- dual wield / same instant: one swing
    equal(ns.Incoming.stats.hits, 1)
    equal(#ns.Incoming.rawSamples, 6, "every event is sampled for the experiment")
end)

scenario("an irregular rhythm (several attackers) lowers confidence and dims the bar", function()
    local ns, state = start()
    boar(state)
    Mock.setCombat(true)
    for _, gap in ipairs({ 0.9, 2.4, 1.1, 3.0, 0.8, 2.7, 1.6 }) do
        Mock.hit("player", "WOUND", 1)
        Mock.advance(gap)
    end
    Mock.hit("player", "WOUND", 1)
    check(ns.Incoming.confidence < 0.4, "confidence " .. tostring(ns.Incoming.confidence))
    ns.Bars:Update()
    near(ns.Bars.bars.ENEMY:GetAlpha(), 0.4, 0.001)
end)

scenario("two attackers on staggered timers are tracked separately (seen in the beta: errors of +-0.6s)", function()
    local ns, state = start()
    boar(state)
    Mock.setCombat(true)
    -- mob A swings at 0, 2, 4...; mob B at 0.7, 2.7, 4.7...
    local base = Mock.now
    for cycle = 0, 5 do
        Mock.now = base + cycle * 2
        Mock.hit("player")
        Mock.now = base + cycle * 2 + 0.7
        Mock.hit("player")
    end
    equal(#ns.Incoming.tracks, 2, "two tracks")
    equal(ns.Incoming.stats.newAttackers, 2)
    equal(ns.Incoming.stats.matched, 10, "every later swing of both mobs was predicted")
    near(ns.Diagnostics:Collect().enemy.meanAbsErrorSeconds, 0, 0.001)
    check(ns.Incoming.confidence > 0.9)

    -- 10.7 was B's last swing: A is due at 12.0, B at 12.7 -> the bar counts down to A
    local active, _, remaining, _, attackers = ns.Incoming:GetProgress(base + 11.5)
    check(active); near(remaining, 0.5, 0.001); equal(attackers, 2)
    Mock.now = base + 11.5
    ns.Bars:Update()
    equal(ns.Bars.bars.ENEMY.label:GetText(), "Incoming (you)  x2")
end)

scenario("the mob's attack speed is noted before the pull and kept when it turns secret in combat", function()
    local ns, state = start(nil, function(s) s.attackSpeed.target = { 1.8 } end)
    boar(state)
    equal(ns.Incoming.prior, 1.8)
    Mock.setCombat(true)
    state.attackSpeed.target = Mock.SECRET -- measured: secret once the fight is on
    Mock.advance(3)                        -- the 1s ticker re-reads it
    equal(ns.Incoming.prior, 1.8, "a secret answer must not wipe what we knew")
    Mock.hit("player")
    near(ns.Incoming.interval, 1.8, 0.001, "first prediction already uses the real speed")
    Mock.advance(1.8)
    Mock.hit("player")
    near(ns.Incoming.stats.errors[1], 0, 0.001)

    state.units.target = { id = "wolf", name = "Wolf", hostile = true } -- new target, speed unreadable
    Mock.fire("PLAYER_TARGET_CHANGED")
    equal(ns.Incoming.prior, nil, "a different mob: the old speed does not carry over")
end)

scenario("an attacker that was held up re-phases its track; the gap is not learned as a swing speed", function()
    local ns, state = start()
    boar(state)
    Mock.setCombat(true)
    for _ = 1, 4 do
        Mock.hit("player")
        Mock.advance(2.0)
    end
    Mock.advance(1.5) -- stunned: the next swing lands 3.5s after the previous one
    Mock.hit("player")
    equal(ns.Incoming.stats.rephased, 1)
    near(ns.Incoming.interval, 2.0, 0.001, "still a 2.0s swinger")
    local _, _, remaining = ns.Incoming:GetProgress(Mock.now)
    near(remaining, 2.0, 0.001, "and the next swing is expected 2.0s after the late one")
end)

scenario("the timer goes idle when the attacker stops, and resets with a new victim or after combat", function()
    local ns, state = start()
    boar(state)
    Mock.setCombat(true)
    for _ = 1, 4 do
        Mock.hit("player")
        Mock.advance(2.0)
    end
    check((ns.Incoming:GetProgress(Mock.now)), "due any moment")
    Mock.advance(4)
    equal((ns.Incoming:GetProgress(Mock.now)), false, "attacker stopped")

    Mock.hit("player")
    state.units.party2 = { id = "tank", name = "Tanky" }
    state.units.targettarget = { id = "tank", name = "Tanky" }
    Mock.fire("UNIT_TARGET", "target")
    equal(#ns.Incoming.hits, 0, "new victim, fresh model")

    Mock.hit("party2")
    Mock.setCombat(false)
    Mock.advance(4)
    equal(#ns.Incoming.hits, 0, "reset a few seconds after combat")
end)

scenario("secret UNIT_COMBAT payloads are counted, not read", function()
    local ns, state = start()
    boar(state)
    Mock.fire("UNIT_COMBAT", "player", Mock.SECRET, "", Mock.SECRET, Mock.SECRET)
    equal(ns.Incoming.stats.secretEvents, 1)
    equal(ns.Incoming.stats.hits, 0)
end)

scenario("the target's attack speed seeds the timer when the client lets us read it", function()
    local ns, state = start(nil, function(s) s.attackSpeed.target = { 1.5 } end)
    boar(state)
    equal(ns.Incoming.prior, 1.5)
    Mock.hit("player")
    near(ns.Incoming.interval, 1.5, 0.001)

    local secretNs, secretState = start(nil, function(s) s.attackSpeed.target = Mock.SECRET end)
    boar(secretState)
    equal(secretNs.Incoming.prior, nil)
    Mock.hit("player")
    near(secretNs.Incoming.interval, 2.0, 0.001, "falls back to a typical mob until two hits are seen")
end)

-- Taking over from Blizzard ------------------------------------------------------------
scenario("Blizzard's timer is switched off once, announced, and can be brought back", function()
    local ns, state = start()
    equal(state.cvars.showSwingTimer, "0")
    check(ns.db.blizzardTimerWasOn)
    local announced = false
    for _, line in ipairs(Mock.printed) do
        if line:find("Blizzard's swing timer", 1, true) then
            announced = true
        end
    end
    check(announced, "should say so in chat")

    SlashCmdList.AKFOREVERCOMBATTIMERS("blizzard show")
    equal(state.cvars.showSwingTimer, "1")
    Mock.setCombat(true)
    SlashCmdList.AKFOREVERCOMBATTIMERS("blizzard hide")
    equal(state.cvars.showSwingTimer, "1", "not touched in combat")
    Mock.setCombat(false)
    equal(state.cvars.showSwingTimer, "0", "settled after combat")
end)

scenario("a player who had Blizzard's timer off keeps it off when turning ours off", function()
    local ns, state = start(nil, function(s) s.cvars.showSwingTimer = "0" end)
    equal(ns.db.blizzardTimerWasOn, nil)
    SlashCmdList.AKFOREVERCOMBATTIMERS("blizzard show")
    equal(state.cvars.showSwingTimer, "0", "we only restore what we changed")
end)

-- Saved state and diagnostics ------------------------------------------------------------
scenario("one profile per character, the same on a fresh login and after a /reload", function()
    local fresh = start(nil, function(s) s.freshLogin = true end)
    local reloaded = start(nil, function(s) s.freshLogin = false end)
    equal(fresh.characterKey, "Purrdee - TestRealm")
    equal(reloaded.characterKey, fresh.characterKey)
end)

-- Cast bars --------------------------------------------------------------------------
local function slotY(bar)
    local _, _, _, _, y = bar:GetPoint(1)
    return y
end

scenario("cast bars: idle rows stay reserved, so nothing jumps when somebody starts casting", function()
    local ns = start()
    SlashCmdList.AKFOREVERCOMBATTIMERS("lock")
    Mock.setCombat(true)
    Mock.swing(2.6, MH)
    ns.Bars:Update()
    local bars = ns.Bars.bars
    equal(bars.TCAST:IsShown(), false, "idle cast bars are invisible")
    equal(bars.CAST:IsShown(), false)
    equal(bars.MH:IsShown(), true)
    local mainHandAt, castAt = slotY(bars.MH), slotY(bars.CAST)

    Mock.cast("target", { name = "Fireball", texture = 135812, seconds = 3 })
    Mock.cast("player", { name = "Healing Wave", texture = 136052, seconds = 2 })
    Mock.advance(1)
    ns.Bars:Update()
    equal(bars.TCAST:IsShown(), true); equal(bars.CAST:IsShown(), true)
    equal(slotY(bars.MH), mainHandAt, "nothing jumped"); equal(slotY(bars.CAST), castAt)
    equal(bars.TCAST.label:GetText(), "Fireball"); equal(bars.TCAST.icon.__texture, 135812)
    equal(bars.CAST.label:GetText(), "Healing Wave")
    near(bars.CAST.fraction, 0.5, 0.01, "1s into a 2s cast")
    equal(bars.CAST.time:GetText(), "1.0", "time remaining")
    near(bars.TCAST.fraction, 1 / 3, 0.01)

    Mock.castEnd("player")
    Mock.castEnd("target", "UNIT_SPELLCAST_INTERRUPTED")
    ns.Bars:Update()
    equal(bars.CAST:IsShown(), false); equal(bars.TCAST:IsShown(), false)
end)

scenario("unlocked: a small tab to drag the block by; idle rows are click-through space with faint marks", function()
    local ns = start() -- the default: never locked (how the bars have been used so far)
    ns.Bars:Update()
    local block, tab, bars = AKForeverCombatTimersFrame, AKForeverCombatTimersTab, ns.Bars.bars
    local hints = 0
    for _, line in ipairs(Mock.printed) do
        hints = hints + (line:find("/fct lock", 1, true) and 1 or 0)
    end
    equal(hints, 1, "a new character is told once what 'unlocked' means and how to end it")
    equal(ns.cdb.lockHintShown, true, "once per character")
    equal(block.__mouse, false, "the block itself never takes the mouse")
    equal(tab:IsShown(), true); equal(block.seam:IsShown(), true, "the seam shows as a hairline")
    equal(bars.MH:IsShown(), false); equal(bars.MH.ghost:IsShown(), true, "corner marks say where a bar will appear")
    equal(bars.TCAST.ghost:IsShown(), true)
    Mock.cast("player", { name = "Healing Wave", seconds = 2 })
    ns.Bars:Update()
    equal(bars.CAST:IsShown(), true); equal(bars.CAST.ghost:IsShown(), false, "the real bar replaces its marks")
    Mock.castEnd("player")

    -- drag: the client leaves the seam anchored wherever; we read where it is and pin it by its anchor point
    tab:GetScript("OnDragStart")(tab)
    block:ClearAllPoints()
    block:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 100, -300)
    tab:GetScript("OnDragStop")(tab)
    local point, _, relativePoint, x, y = block:GetPoint(1)
    equal(point, "CENTER"); equal(relativePoint, "BOTTOMLEFT")
    near(x, 100 + block:GetWidth() / 2, 0.01); near(y, 768 - 300 - block:GetHeight() / 2, 0.01)
    equal(ns.cdb.position.anchor, "CENTER")

    block:ClearAllPoints() -- dropped a little off the screen's centre line: snaps onto it
    block:SetPoint("CENTER", UIParent, "BOTTOMLEFT", 512 + 15, 200)
    tab:GetScript("OnDragStop")(tab)
    equal(select(4, block:GetPoint(1)), 512)
    SlashCmdList.AKFOREVERCOMBATTIMERS("snap off")
    block:ClearAllPoints()
    block:SetPoint("CENTER", UIParent, "BOTTOMLEFT", 512 + 15, 200)
    tab:GetScript("OnDragStop")(tab)
    equal(select(4, block:GetPoint(1)), 527, "snap off: stays where it was dropped")
    SlashCmdList.AKFOREVERCOMBATTIMERS("center")
    equal(select(4, block:GetPoint(1)), 512)
    SlashCmdList.AKFOREVERCOMBATTIMERS("anchor right") -- another anchor point: the block stays where it is
    near(select(4, block:GetPoint(1)), 512 + block:GetWidth() / 2, 0.01)

    tab:GetScript("OnClick")(tab)
    equal(AKForeverCombatTimersConfig:IsShown(), true, "a click on the tab opens the settings")

    SlashCmdList.AKFOREVERCOMBATTIMERS("lock")
    ns.Bars:Update()
    equal(tab:IsShown(), false); equal(bars.MH.ghost:IsShown(), false, "locked: no tab, no marks - idle rows are just empty")
end)

scenario("a cast that comes from an item shows the ITEM's icon (sharpening stone, bandage, hearthstone ...)", function()
    local STONE, STONE_SPELL, TRINKET, TRINKET_SPELL = 2862, 2828, 11819, 15594
    local ns, state = start({ bags = { [0] = { 6948, STONE } }, worn = { [13] = TRINKET },
        itemSpells = { [STONE] = { spellID = STONE_SPELL, icon = 135248 }, [TRINKET] = { spellID = TRINKET_SPELL, icon = 133434 } } })
    local bar = ns.Bars.bars.CAST
    Mock.cast("player", { name = "Sharpen Blade", texture = 136235, spellID = STONE_SPELL, seconds = 3 }) -- 136235: a placeholder
    ns.Bars:Update()
    equal(bar.icon.__texture, 135248, "the stone's own icon")
    equal(ns.Casts.samples[1].itemIcon, true)
    Mock.castEnd("player")
    Mock.cast("player", { name = "Second Wind", texture = 136235, spellID = TRINKET_SPELL, seconds = 1 })
    ns.Bars:Update()
    equal(bar.icon.__texture, 133434, "worn items too")
    Mock.castEnd("player")
    Mock.cast("player", { name = "Healing Wave", texture = 136052, spellID = 331, seconds = 2 })
    ns.Bars:Update()
    equal(bar.icon.__texture, 136052, "a spell of your own keeps its icon")
    Mock.castEnd("player")

    state.bags[0] = { 6948 } -- the last stone is used up ...
    Mock.fire("BAG_UPDATE_DELAYED")
    Mock.cast("player", { name = "Sharpen Blade", texture = 136235, spellID = STONE_SPELL, seconds = 3 })
    ns.Bars:Update()
    equal(bar.icon.__texture, 136235, "... so there is nothing to look it up with any more")
    Mock.castEnd("player")
    Mock.cast("target", { secret = true, seconds = 2, spellID = STONE_SPELL })
    ns.Bars:Update()
    equal(ns.Bars.bars.TCAST.icon.__texture, Mock.SECRET, "an enemy's cast is secret: its icon goes in untouched")
end)

scenario("cast bars: your cast shows out of combat without dragging the idle swing bars along", function()
    local ns = start()
    SlashCmdList.AKFOREVERCOMBATTIMERS("lock")
    ns.Bars:Update()
    equal(AKForeverCombatTimersFrame:IsShown(), false, "locked, out of combat, nothing going on")
    Mock.cast("player", { name = "Hearthstone", seconds = 10 })
    ns.Bars:Update()
    equal(AKForeverCombatTimersFrame:IsShown(), true)
    equal(ns.Bars.bars.CAST:IsShown(), true)
    equal(ns.Bars.bars.MH:IsShown(), false, "no swing bars for a hearthstone")
    Mock.advance(10.5) -- no STOP event ever arrives: a timed cast still ends
    ns.Bars:Update()
    equal(AKForeverCombatTimersFrame:IsShown(), false)
end)

scenario("cast bars: channels drain, pushback moves the end, a failed OTHER spell does not end the cast", function()
    local ns, state = start()
    Mock.cast("player", { name = "Arcane Missiles", kind = "channel", seconds = 4 })
    Mock.advance(1)
    ns.Bars:Update()
    near(ns.Bars.bars.CAST.fraction, 0.75, 0.01, "a channel counts down")

    Mock.castEnd("player", "UNIT_SPELLCAST_CHANNEL_STOP")
    Mock.cast("player", { name = "Frostbolt", seconds = 2 })
    Mock.advance(1)
    state.casts.player.finish = state.casts.player.finish + 0.5 -- hit while casting
    Mock.fireUnit("UNIT_SPELLCAST_DELAYED", "player", "player", "Cast-1", 116)
    ns.Bars:Update()
    near(ns.Bars.bars.CAST.fraction, 1 / 2.5, 0.01, "pushed back")

    Mock.fireUnit("UNIT_SPELLCAST_FAILED", "player", "player", "Cast-2", 2139) -- mashing another key mid-cast
    ns.Bars:Update()
    equal(ns.Bars.bars.CAST:IsShown(), true, "still casting Frostbolt")
    state.casts.player = nil
    Mock.fireUnit("UNIT_SPELLCAST_FAILED", "player", "player", "Cast-1", 116)
    ns.Bars:Update()
    equal(ns.Bars.bars.CAST:IsShown(), false, "a real failure ends it")
end)

scenario("cast bars: a new target that is already casting is picked up mid-cast", function()
    local ns, state = start()
    state.casts.target = { kind = "cast", name = "Shadow Bolt", texture = 136197, start = Mock.now - 1, finish = Mock.now + 2 }
    boar(state)
    ns.Bars:Update()
    equal(ns.Bars.bars.TCAST.label:GetText(), "Shadow Bolt")
    near(ns.Bars.bars.TCAST.fraction, 1 / 3, 0.01)
    state.casts.target, state.units.target = nil, nil
    Mock.fire("PLAYER_TARGET_CHANGED")
    ns.Bars:Update()
    equal(ns.Bars.bars.TCAST:IsShown(), false)
end)

scenario("secret casts: name, icon and times go into the widgets unread; the client's timer drives the bar", function()
    local ns = start()
    Mock.cast("target", { secret = true, seconds = 3 })
    ns.Bars:Update()
    local bar = ns.Bars.bars.TCAST
    equal(bar:IsShown(), true)
    equal(bar.label:GetText(), Mock.SECRET, "handed over untouched")
    equal(bar.icon.__texture, Mock.SECRET)
    check(bar.status.__timer and bar.status.__timer.duration.__durationObject, "UnitCastingDuration -> SetTimerDuration")
    equal(bar.time:GetText(), Mock.SECRET, "seconds left: the client counts them down into our font string itself")
    equal(Mock.textBindings[1].enabled, true); equal(Mock.textBindings[1].fontString, bar.time)
    equal(Mock.textBindings[1].formatter.breakpoints[1].format, "%.1f", "one decimal, like our own bars")
    equal(ns.Casts.samples[1].seconds, "binding")
    equal(ns.Casts.samples[1].path, "SetTimerDuration")
    equal(ns.Casts.samples[1].secretTimes, true); equal(ns.Casts.samples[1].secretPayloadUnit, true)
    Mock.advance(1)
    ns.Bars:Update() -- nothing to compute per frame: must not touch the secrets
    Mock.castEnd("target")
    ns.Bars:Update()
    equal(bar:IsShown(), false, "the STOP event ends it (we got it although its payload was secret)")
    equal(Mock.textBindings[1].enabled, false, "and the client stops writing into a bar that is gone")
    equal(bar.time:GetText(), "")

    Mock.cast("target", { secret = true, kind = "channel", seconds = 3 })
    ns.Bars:Update()
    equal(bar.status.__timer.direction, 1, "a channel runs on remaining time")
    equal(#Mock.textBindings, 1, "one binding per bar, reused")
end)

scenario("seconds on secret casts: without the text binding the duration formats itself every frame; without that, no seconds", function()
    local ns, state = start({ noTextBinding = true })
    Mock.cast("target", { secret = true, seconds = 3 })
    ns.Bars:Update()
    local bar = ns.Bars.bars.TCAST
    equal(bar.time:GetText(), Mock.SECRET, "duration:FormatRemainingDuration() -> straight into SetText")
    equal(ns.Casts.samples[1].seconds, "format")
    bar.time:SetText("stale")
    Mock.advance(0.1)
    ns.Bars:Update()
    equal(bar.time:GetText(), Mock.SECRET, "refreshed every frame")
    Mock.castEnd("target")
    ns.Bars:Update()
    equal(bar.time:GetText(), "")

    state.noDurationFormatting = true
    Mock.cast("target", { secret = true, seconds = 3 })
    ns.Bars:Update()
    equal(bar.time:GetText(), "", "nothing accepted: the bar still fills, just without seconds")
    equal(ns.Casts.samples[2].seconds, "none")
end)

scenario("seconds on secret casts: a binding that refuses addons falls back too; a readable cast takes the text back", function()
    local ns = start({}, function(s) s.bindingRefusesAddons = true end)
    Mock.cast("player", { secret = true, seconds = 3 }) -- (should the client ever hide our own casts)
    ns.Bars:Update()
    local bar = ns.Bars.bars.CAST
    equal(ns.Casts.samples[1].seconds, "format")
    Mock.castEnd("player")
    Mock.cast("player", { name = "Healing Wave", seconds = 2 })
    Mock.advance(0.5)
    ns.Bars:Update()
    equal(bar.time:GetText(), "1.5", "our own arithmetic again")
    equal(ns.Casts.samples[2].seconds, "numbers")
end)

scenario("secret casts, timer refused: the secret start / end become the bar's bounds and we feed it the clock", function()
    local ns, state = start({}, function(s) s.timerRefusesAddons = true end)
    Mock.cast("target", { secret = true, seconds = 3 })
    ns.Bars:Update()
    local status = ns.Bars.bars.TCAST.status
    equal(status.__min, Mock.SECRET); equal(status.__max, Mock.SECRET)
    equal(status.__value, Mock.now * 1000, "a plain number: milliseconds on the same clock")
    equal(ns.Casts.samples[1].path, "SetMinMaxValues")
    local _ = state
end)

scenario("secret casts, everything refused: a full bar with a plain label - and Blizzard's target bar stays", function()
    local ns = start({}, function(s) s.timerRefusesAddons = true; s.widgetsRefuseSecrets = true end)
    Mock.cast("target", { secret = true, seconds = 3 })
    ns.Bars:Update()
    local bar = ns.Bars.bars.TCAST
    equal(bar.label:GetText(), "Casting"); equal(bar.status.__value, 1)
    equal(ns.Casts.samples[1].path, "refused")
    equal(ns.Casts:IsProven("target"), false)
    Mock.advance(6)
    equal(TargetFrameSpellBar:GetParent(), TargetFrame, "not proven: Blizzard's bar keeps working")
    Mock.advance(130)
    ns.Bars:Update()
    equal(bar:IsShown(), false, "a cast we cannot time is dropped eventually even without a STOP")
end)

scenario("Blizzard's cast bars go only after ours has shown a cast: yours parked while hidden, the target's shrunk - its parent untouched", function()
    local ns = start()
    local home = UIParentBottomManagedFrameContainer
    equal(PlayerCastingBarFrame:GetParent(), home, "untouched until proven")
    Mock.cast("player", { name = "Healing Wave", seconds = 2 })
    ns.Bars:Update()
    equal(ns.db.castProven.player, true)
    equal(PlayerCastingBarFrame:GetParent(), home, "mid-cast their bar is up: moving it now would run Blizzard's OnHide code from our call")
    Mock.castEnd("player")
    Mock.advance(6)
    equal(PlayerCastingBarFrame:GetParent(), AKForeverCombatTimersHidden, "between casts: parked on a frame that is never shown")
    equal(AKForeverCombatTimersHidden:IsShown(), false)
    equal(TargetFrameSpellBar:GetScale(), 1, "the target bar has not proven itself yet")

    Mock.setCombat(true) -- the usual moment for a first enemy cast
    Mock.cast("target", { name = "Fireball", seconds = 2 })
    ns.Bars:Update()
    equal(ns.db.castProven.target, true, "remembered for the next session")
    equal(TargetFrameSpellBar:GetScale(), 1, "nothing of Blizzard's is touched during a fight")
    Mock.setCombat(false)
    check(TargetFrameSpellBar:GetScale() < 0.001, "shrunk to nothing when the fight is over")
    equal(TargetFrameSpellBar:GetParent(), TargetFrame, "and still the target frame's child: Blizzard's AdjustPosition() calls its parent")

    Mock.cast("player", { name = "Healing Wave", seconds = 2 }) -- Blizzard 'shows' its parked bar: nobody sees it
    Mock.castEnd("player")
    PlayerCastingBarFrame:SetParent(home) -- should Blizzard ever re-adopt it
    Mock.advance(6)
    equal(PlayerCastingBarFrame:GetParent(), AKForeverCombatTimersHidden, "the watchdog")

    SlashCmdList.AKFOREVERCOMBATTIMERS("casts blizzard show")
    equal(PlayerCastingBarFrame:GetParent(), home, "straight back home, no /reload")
    equal(TargetFrameSpellBar:GetScale(), 1, "and back to its own size")
    Mock.advance(6)
    equal(PlayerCastingBarFrame:GetParent(), home, "and the watchdog respects that")
    -- The harness fails this scenario if UnregisterAllEvents (v0.3.0) or SetParent on the target's bar
    -- (v0.3.1: "TargetFrame.lua:824: attempt to call a nil value") ever comes back.
end)

scenario("cast bar options: off means no row, no tracking, and Blizzard's bars are left alone", function()
    local ns = start({}, function() end)
    SlashCmdList.AKFOREVERCOMBATTIMERS("casts off")
    Mock.cast("player", { name = "Healing Wave", seconds = 2 })
    ns.Bars:Update()
    equal(ns.Bars.bars.CAST:IsShown(), false)
    equal(ns.Bars.bars.CAST.slotted, false); equal(ns.Bars.bars.TCAST.slotted, false, "no rows for them")
    equal(ns.Casts.current.player, nil, "not even tracked")
    equal(PlayerCastingBarFrame:GetParent(), UIParentBottomManagedFrameContainer)
    SlashCmdList.AKFOREVERCOMBATTIMERS("casts player on")
    ns.Bars:Update()
    equal(ns.Bars.bars.CAST:IsShown(), true, "switched on mid-cast: picked up")
    equal(ns.Bars.bars.CAST.slotted, true); equal(ns.Bars.bars.TCAST.slotted, false)
    SlashCmdList.AKFOREVERCOMBATTIMERS("casts blizzard show")
    SlashCmdList.AKFOREVERCOMBATTIMERS("casts")
    SlashCmdList.AKFOREVERCOMBATTIMERS("test")
    ns.Bars:Update()
    equal(ns.Bars.bars.CAST.label:GetText(), "Your cast", "test mode shows a moving sample")
end)

scenario("the buff bar: Slice and Dice out of combat - readable, with a countdown; cancelled: gone", function()
    local ns = start({ class = "ROGUE" })
    local bar = ns.Bars.bars.BUFF
    ns.Bars:Update()
    equal(bar.slotted, true, "a rogue tracks Slice and Dice by default")
    Mock.buff(5171, "Slice and Dice", 12)
    Mock.advance(3)
    ns.Bars:Update()
    equal(bar:IsShown(), true); equal(bar.label:GetText(), "Slice and Dice"); equal(bar.icon.__texture, 130000 + 5171)
    near(bar.fraction, 0.75, 0.01, "a buff drains"); equal(bar.time:GetText(), "9.0")
    equal(ns.Buffs.samples[1].found, "by spell id"); equal(ns.Buffs.samples[1].path, "numbers")
    equal(ns.Buffs.samples[1].comboPoints, 2, "12 s: two combo points went into it"); equal(ns.Buffs.samples[1].total, 12)
    Mock.unbuff(5171)
    ns.Bars:Update()
    equal(bar:IsShown(), false, "cancelled: gone")

    SlashCmdList.AKFOREVERCOMBATTIMERS("buff remove slice and dice")
    ns.Bars:Update()
    equal(bar.slotted, false, "nothing tracked: no row")
    SlashCmdList.AKFOREVERCOMBATTIMERS("buff add Sprint")
    SlashCmdList.AKFOREVERCOMBATTIMERS("buff")
    ns.Bars:Update()
    equal(bar.slotted, true)
    SlashCmdList.AKFOREVERCOMBATTIMERS("buff reset")
end)

scenario("the buff bar in a FIGHT: auras are off limits there - the bar runs on the combo points spent, put through our curve by the client", function()
    local ns = start({ class = "ROGUE" })
    local bar = ns.Bars.bars.BUFF
    Mock.setCombat(true)
    Mock.comboPoints(1); Mock.advance(1); Mock.comboPoints(2); Mock.advance(1); Mock.comboPoints(3); Mock.advance(1)
    Mock.finisher(5171, "Slice and Dice") -- three points: 15 s
    ns.Bars:Update()
    equal(bar:IsShown(), true, "on the bar at once - not only when the fight is over")
    equal(bar.label:GetText(), "Slice and Dice")
    local made = ns.Buffs.samples[1]
    equal(made.found, "combo points (secret), when the cast was sent"); equal(made.path, "SetMinMaxValues")
    check(issecretvalue(bar.status.__min), "the bar's lower bound is the client's secret - we never saw the number")
    near(Mock.barFraction(bar.status), 1, 0.01, "full at the start")
    run(ns, 7.5, 0.5)
    near(Mock.barFraction(bar.status), 0.5, 0.04, "half way through its 15 seconds")
    equal(bar.time:GetText(), "", "no countdown: nothing can count down from a number we may not read")
    run(ns, 7.0, 0.5)
    near(Mock.barFraction(bar.status), 0.03, 0.04, "nearly empty when it is about to end")

    -- recast with five points while the first one is still up: a new 21 s bar
    Mock.comboPoints(5); Mock.advance(0.2)
    Mock.finisher(5171, "Slice and Dice")
    ns.Bars:Update()
    near(Mock.barFraction(bar.status), 1, 0.01)
    run(ns, 10.5, 0.5)
    near(Mock.barFraction(bar.status), 0.5, 0.04, "21 seconds this time")

    -- the fight ends: auras are readable again - the real one takes over, with numbers
    Mock.setCombat(false)
    ns.Bars:Update()
    local real = ns.Buffs.samples[#ns.Buffs.samples]
    equal(real.found, "the real aura, after the fight"); equal(real.path, "numbers"); equal(real.comboPoints, 5)
    near(tonumber(bar.time:GetText()), 10.5, 0.2, "the countdown is back")

    -- an estimate whose buff ran out during the fight is simply dropped afterwards
    Mock.setCombat(true)
    Mock.unbuff(5171)
    Mock.comboPoints(1); Mock.advance(0.5)
    Mock.finisher(5171, "Slice and Dice") -- 9 s
    run(ns, 12, 0.5)
    equal(bar:IsShown(), true, "in the fight we cannot know it is over (the bar is empty by now) ...")
    near(Mock.barFraction(bar.status), 0, 0.01)
    check(ns.Buffs:Get() ~= nil)
    run(ns, 10, 0.5)
    equal(ns.Buffs:Get(), nil, "... but no Slice and Dice lasts longer than 21 s: the row gives up by itself")
    Mock.comboPoints(1); Mock.advance(0.5)
    Mock.finisher(5171, "Slice and Dice")
    run(ns, 10, 0.5)
    Mock.state.auras[5171] = nil
    Mock.setCombat(false)
    ns.Bars:Update()
    equal(ns.Buffs:Get(), nil, "and when the fight ends with the buff gone, the estimate is dropped at once")
end)

scenario("the buff bar in a fight: no SENT event, a talent that stretches the buff, readable combo points, a client without curves", function()
    local ns = start({ class = "ROGUE" })
    local bar = ns.Bars.bars.BUFF
    Mock.setCombat(true)
    Mock.comboPoints(4); Mock.advance(1)
    Mock.finisher(5171, "Slice and Dice", { noSent = true }) -- the points are already gone when SUCCEEDED arrives
    ns.Bars:Update()
    equal(ns.Buffs.samples[1].found, "combo points (secret), a snapshot from before the cast")
    run(ns, 9, 0.5)
    near(Mock.barFraction(bar.status), 0.5, 0.04, "four points: 18 s")

    -- Improved Slice and Dice: a real aura of 20.7 s = 18 x 1.15 teaches the factor, and the next estimate uses it
    Mock.setCombat(false)
    Mock.state.auras[5171].duration, Mock.state.auras[5171].expirationTime = 20.7, Mock.now + 20.7
    Mock.fireUnit("UNIT_AURA", "player", "player", { isFullUpdate = false })
    Mock.unbuff(5171)
    Mock.buff(5171, "Slice and Dice", 20.7)
    equal(ns.cdb.buffFactors["slice and dice"], 1.15)
    Mock.unbuff(5171)
    Mock.setCombat(true)
    Mock.comboPoints(2); Mock.advance(1)
    Mock.finisher(5171, "Slice and Dice", { seconds = 13.8 })
    run(ns, 6.9, 0.3)
    near(Mock.barFraction(bar.status), 0.5, 0.04, "two points with the talent: 13.8 s, not 12")
    Mock.setCombat(false)

    ns = start({ class = "ROGUE" })
    Mock.state.comboPointsReadable = true -- a client that lets us read them: plain numbers, with a countdown
    Mock.setCombat(true)
    Mock.comboPoints(3); Mock.advance(1)
    Mock.finisher(5171, "Slice and Dice")
    run(ns, 5, 0.5)
    equal(ns.Buffs.samples[1].path, "numbers"); near(tonumber(ns.Bars.bars.BUFF.time:GetText()), 10, 0.2)
    Mock.setCombat(false)

    ns = start({ class = "ROGUE", noCurves = true })
    Mock.setCombat(true)
    Mock.comboPoints(3); Mock.advance(1)
    Mock.finisher(5171, "Slice and Dice")
    Mock.advance(1.5)
    Mock.fireUnit("UNIT_AURA", "player", "player", Mock.SECRET)
    ns.Bars:Update()
    equal(ns.Bars.bars.BUFF:IsShown(), false, "no curve API: nothing in the fight, as before")
    equal(ns.Buffs.samples[1].found, "NOT FOUND"); check(ns.Buffs.estimates.curve:find("no C_CurveUtil", 1, true), ns.Buffs.estimates.curve)
    Mock.setCombat(false)
    ns.Bars:Update()
    equal(ns.Buffs.samples[2].found, "already running", "... and picked up when it ends")

    ns = start({ class = "ROGUE" })
    Mock.state.widgetsRefuseSecrets = true -- a client whose status bar will not take the secret bound
    Mock.setCombat(true)
    Mock.comboPoints(3); Mock.advance(1)
    Mock.finisher(5171, "Slice and Dice")
    ns.Bars:Update()
    equal(ns.Buffs.samples[1].path, "refused", "said so in the report; a full bar with the name is all there is")
    Mock.setCombat(false)
end)

scenario("the buff bar: the report says what a fight allows - the aura list is an error there", function()
    local ns = start({ class = "ROGUE" })
    Mock.setCombat(true)
    Mock.advance(3.5) -- the in-combat probe, once per session
    Mock.setCombat(false); Mock.setCombat(true); Mock.advance(3.5)
    equal(#ns.Buffs.probes, 1)
    equal(ns.Buffs.probes[1].moment, "3s into a fight"); check(ns.Buffs.probes[1].listing:find("^error:"), ns.Buffs.probes[1].listing)
    Mock.comboPoints(2); Mock.advance(1)
    Mock.finisher(5171, "Slice and Dice")
    SlashCmdList.AKFOREVERCOMBATTIMERS("diag")
    local saved = AKForeverCombatTimersDB.diag.buffs
    equal(#saved.probes, 1); equal(saved.estimates.lastKind, "secret"); equal(saved.estimates.sent, 1)
    check(saved.estimates.curve:find("built", 1, true)); check(saved.estimates.snapshots >= 2)
    equal(saved.bar[1].found, "combo points (secret), when the cast was sent")
    Mock.setCombat(false)
end)

scenario("the buff bar: other classes have no row until they track something; a running buff is found at login", function()
    local ns = start({ class = "SHAMAN" })
    ns.Bars:Update()
    equal(ns.Bars.bars.BUFF.slotted, false)
    Mock.buff(324, "Lightning Shield", 600)
    ns.Bars:Update()
    equal(ns.Bars.bars.BUFF:IsShown(), false, "not tracked: not our business")
    SlashCmdList.AKFOREVERCOMBATTIMERS("buff add Lightning Shield")
    Mock.fire("PLAYER_ENTERING_WORLD", false, true)
    Mock.advance(60)
    ns.Bars:Update()
    equal(ns.Bars.bars.BUFF:IsShown(), true); equal(ns.Buffs.samples[1].found, "already running")
    equal(ns.Bars.bars.BUFF.time:GetText(), "9:00", "minutes for the long ones")
end)

scenario("settings window: every button does what the slash commands do", function()
    local ns = start()
    SlashCmdList.AKFOREVERCOMBATTIMERS("config")
    local panel = AKForeverCombatTimersConfig
    equal(panel:IsShown(), true)
    local function click(widget) widget:GetScript("OnClick")(widget, "LeftButton") end
    click(panel.fade); equal(ns.BarSettings:GetBlock("fade"), true, "(the tests start with fading off)")
    click(panel.snap); equal(ns.BarSettings:GetBlock("snapCenter"), false)
    click(panel.anchor); equal(ns.BarSettings:GetBlock("anchor"), "RIGHT")
    click(panel.lock); equal(ns:GetOption("locked"), true); equal(panel.lock:GetText(), "Unlock")
    click(panel.test); click(panel.center); click(panel.reset)
    equal(ns.BarSettings:GetBlock("anchor"), "CENTER", "reset")
    click(panel.close); equal(panel:IsShown(), false)
end)

scenario("settings survive a session; the old position and switches are carried over; the beta bridge is recognised", function()
    local db = { loads = 3, chars = { ["Purrdee - TestRealm"] = {
        options = { locked = true, visibility = "always", showEnemy = false, castTarget = false },
        position = { point = "TOP", relativePoint = "TOP", x = 5, y = -50 }, -- how v0.3 stored it
    } } }
    local ns = start({ db = db, bridge = { version = 1, table = db } })
    equal(ns.db.loads, 4)
    equal(ns.savedStateSource, "bridge addon")
    local point, _, relativePoint, x, y = AKForeverCombatTimersFrame:GetPoint(1)
    equal(point, "CENTER"); equal(relativePoint, "BOTTOMLEFT")
    near(x, 512 + 5, 0.01, "same place on the screen")
    near(y, 768 - 50 - 4 - 2 * 17 + 1.5, 0.01, "the seam is where the gap between 'incoming' and 'main hand' was")
    equal(ns.cdb.position.point, nil, "stored the new way from now on")
    equal(ns.BarSettings:GetMode("ENEMY"), "never", "/fct enemy off, carried over")
    equal(ns.BarSettings:GetMode("TCAST"), "never")
    equal(ns.BarSettings:GetMode("MH"), "always", "'/fct show always', carried over")
    equal(ns.cdb.options.visibility, nil); equal(ns.cdb.options.locked, true)

    ns.BarSettings:Set("MH", "width", 260)
    ns.BarSettings:Move("CAST", -1)
    local again = start({ db = db })
    equal(again.BarSettings:Get("MH", "width"), 260)
    equal(again.BarSettings:GetOrder()[#again.BarSettings:GetOrder()], "PLAINS", "your cast moved up: the Plainsrunning bar is last now")
end)

local PLAINSRUNNING = 20550

-- the block fades its bars in and out; two frames of it is all it takes to have one on screen
local function draw(ns)
    for _ = 1, 2 do
        Mock.advance(0.2)
        ns.Bars:Update()
    end
end

-- Really stopping: the speed goes to zero and stays there past the grace. Time passes, as it must.
local function halt(ns)
    Mock.setSpeed(0)
    for _ = 1, 4 do
        Mock.advance(0.15)
        ns.Bars:Update()
    end
end

-- a character running with the buff on, the bar already faded in and the tick clock just started
local function running(stacks)
    local ns = start()
    Mock.setSpeed(7)
    draw(ns)                                    -- (the first frame is where "moving" flips)
    Mock.stackingBuff(PLAINSRUNNING, "Plainsrunning", stacks)
    ns.Bars:Update()
    return ns, ns.Bars.bars.PLAINS
end

scenario("Plainsrunning: the bar is the tick - it fills toward the next +1% while you keep moving", function()
    local ns, bar = running(12)
    check(bar and bar.active, "there it is")
    near(bar.fraction, 0, 0.01, "the tick has just started")
    equal(bar.time:GetText(), "12%  5.0", "how much you have, and how far the next 1% is")
    equal(ns.Plains.state.moving, true)

    Mock.advance(2.5)
    ns.Bars:Update()
    near(bar.fraction, 0.5, 0.01, "half way to the next tick")
    equal(bar.time:GetText(), "12%  2.5")

    Mock.advance(2.5)
    ns.Bars:Update()
    near(bar.fraction, 1, 0.01, "full: the tick is due")

    -- and it lands: the count goes up and the bar starts again
    Mock.stackingBuff(PLAINSRUNNING, "Plainsrunning", 13)
    ns.Bars:Update()
    near(bar.fraction, 0, 0.01, "a fresh tick")
    equal(bar.time:GetText(), "13%  5.0")
end)

scenario("Plainsrunning: stand still and the bar counts DOWN toward the next -1%", function()
    local ns, bar = running(12)
    halt(ns) -- 0.45s of standing: past the grace
    equal(ns.Plains.state.moving, false)
    near(bar.fraction, 1 - 0.45 / 5, 0.02, "draining from full - and honest about the time already stood")

    Mock.advance(2.05)
    ns.Bars:Update()
    near(bar.fraction, 0.5, 0.02, "half way to losing one")
    equal(bar.time:GetText(), "12%  2.5")

    Mock.stackingBuff(PLAINSRUNNING, "Plainsrunning", 11)
    ns.Bars:Update()
    near(bar.fraction, 1, 0.01, "it went; the next one starts full again")

    -- nothing left to lose: the bar sits empty and says nothing about a tick
    Mock.stackingBuff(PLAINSRUNNING, "Plainsrunning", 0)
    ns.Bars:Update()
    near(bar.fraction, 0, 0.01)
    equal(bar.time:GetText(), "up")
end)

scenario("Plainsrunning: the gaining cycle runs on the clock, and a pause neither resets it nor stops it", function()
    -- Measured on the live client: four gains that spanned a stop landed 4.96 to 5.05 seconds apart on
    -- the CLOCK while holding only 1.0 to 4.2 seconds of moving inside them. The cycle does not care how
    -- much of it you spent moving - so a pause must not send the bar back to nothing, and must not freeze
    -- it either.
    local ns, bar = running(12)
    ns.Plains.ticks.down = { 1, 1, 1 }      -- this client's measured drain
    ns.Plains.ticks.firstDown = { 1, 1, 1 }
    Mock.advance(3)
    ns.Bars:Update()
    near(bar.fraction, 0.6, 0.02, "three seconds into a five second cycle")

    halt(ns) -- 0.6s of standing: the bar is the drain's now
    equal(ns.Plains.state.moving, false)
    near(bar.fraction, 1 - 0.45 / 1, 0.05, "counting down, not up")

    -- set off again: the drain still owed goes on showing until its moment passes
    Mock.setSpeed(7)
    ns.Bars:Update()
    equal(ns.Plains.state.drainInFlight, true, "a percent may still go: keep saying so")
    Mock.advance(0.6)
    ns.Bars:Update()

    -- and once it plainly is not coming, the gaining cycle is back - where the clock left it
    equal(ns.Plains.state.drainInFlight, false)
    near(bar.fraction, 4.2 / 5, 0.05, "three seconds, six tenths stood still, six tenths since")
    check(bar.fraction > 0.5, "nowhere near back to nothing, which is what it used to do")

    Mock.advance(0.8)
    ns.Bars:Update()
    near(bar.fraction, 1, 0.02, "five seconds after the last percent, however they were spent")
end)

scenario("Plainsrunning: a percent that arrives while you are already standing still still restarts the cycle", function()
    -- one of the measured gains landed a second AFTER the player stopped: the cycle was still running
    local ns, bar = running(12)
    ns.Plains.ticks.down = { 1, 1, 1 }
    ns.Plains.ticks.firstDown = { 1, 1, 1 }
    Mock.advance(3)
    ns.Bars:Update()
    halt(ns)
    Mock.stackingBuff(PLAINSRUNNING, "Plainsrunning", 13) -- it lands anyway
    near(ns.Plains.state.lastGainAt, GetTime(), 0.01, "the cycle counts from here now")

    Mock.setSpeed(7)
    Mock.advance(1.1) -- past the window in which a drain could still have landed
    ns.Bars:Update()
    near(bar.fraction, 1.1 / 5, 0.05, "so setting off again starts a fresh one, not a full bar")
end)

scenario("Plainsrunning: a percent going while you are already moving again is still shown coming", function()
    -- Measured: a percent went 0.96s after the one before it while the player was moving and the bar was
    -- showing a gain three quarters full. Setting off does not cancel the drain already on its way.
    local ns, bar = running(12)
    ns.Plains.ticks.down = { 1, 1, 1 }
    ns.Plains.ticks.firstDown = { 1, 1, 1 }

    halt(ns)
    Mock.stackingBuff(PLAINSRUNNING, "Plainsrunning", 11) -- the first one goes while you stand
    equal(ns.Plains.state.lostSinceStop, true)

    Mock.setSpeed(7) -- and off you go again, with another already counting down
    Mock.advance(0.3)
    ns.Bars:Update()
    equal(ns.Plains.state.drainInFlight, true)
    check(bar.fraction < 0.8, "the bar is still counting DOWN, not filling up: " .. tostring(bar.fraction))
    equal(select(6, ns.Plains:GetProgress(GetTime()))[1], 0.85, "and it is still the draining colour")

    -- it lands, exactly as the report said it does
    Mock.stackingBuff(PLAINSRUNNING, "Plainsrunning", 10)
    ns.Bars:Update()
    check(true, "no surprise: the bar was showing it coming")
end)

scenario("Plainsrunning: the draining clock is its own, and starts fresh at every stop", function()
    local ns, bar = running(12)
    ns.Plains.ticks.down = { 4 }
    ns.Plains.ticks.firstDown = { 4 }

    halt(ns)
    Mock.advance(2)
    ns.Bars:Update()
    near(ns.Plains.state.downBanked, 2.45, 0.02, "well into the wait")

    -- setting off does not cancel the percent already on its way: it is still shown coming
    Mock.setSpeed(7)
    ns.Bars:Update()
    equal(ns.Plains.state.drainInFlight, true, "2.45 of a four second drain stood: it may still land")
    near(ns.Plains.state.downBanked, 2.45, 0.02, "so its clock is still running")

    -- ... but not for ever: once its moment has passed the slate is clean
    Mock.advance(1.6)
    ns.Bars:Update()
    equal(ns.Plains.state.drainInFlight, false)
    near(ns.Plains.state.downBanked, 0, 0.01)

    halt(ns)
    near(ns.Plains.state.downBanked, 0.45, 0.02, "and standing again is a fresh wait, not a resumed one")
    near(bar.fraction, 1 - 0.45 / 4, 0.02)
end)

scenario("Plainsrunning: a gain that spanned a stop is written down - does the game keep its place too?", function()
    local ns, bar = running(12)
    Mock.advance(3)
    ns.Bars:Update()
    halt(ns)             -- a pause part way through the tick
    Mock.setSpeed(7)
    ns.Bars:Update()
    Mock.advance(2)
    ns.Bars:Update()
    Mock.stackingBuff(PLAINSRUNNING, "Plainsrunning", 13)

    equal(#ns.Plains.ticks.up, 0, "an untested idea must not move the number the bar runs on")
    local seen = ns.Plains.resumes[1]
    check(seen, "but it IS written down")
    near(seen.banked, 5, 0.2, "five seconds of actual moving")
    check(seen.wall > 5.4, "and longer than that on the clock: the stop is the difference")
    equal(seen.tick, 5)
end)

scenario("Plainsrunning: a drain counts down to the SOONEST seen, never the middle", function()
    local ns, bar = running(12)
    -- three drains measured: 1.0, 3.0, 3.0. The middle is 3 - and on the 1.0 seconds you would lose the
    -- percent with two seconds still showing on the bar.
    ns.Plains.ticks.down = { 1, 3, 3 }
    ns.Plains.ticks.firstDown = { 1, 3, 3 }
    near(ns.Plains:TickLength("down"), 1, 0.01, "the bar may be early; it may never overrun")
    near(ns.Plains:TickLength("firstDown"), 1, 0.01)

    halt(ns)
    near(bar.fraction, 1 - 0.45 / 1, 0.03, "already more than a third gone")
    Mock.advance(1)
    ns.Bars:Update()
    near(bar.fraction, 0, 0.01, "empty: any moment now")
    equal(bar.time:GetText(), "12%  0.0")
    Mock.advance(3)
    ns.Bars:Update()
    near(bar.fraction, 0, 0.01, "and it waits there rather than pretending a fresh tick began")
end)

scenario("Plainsrunning: at the cap the bar is simply full - nothing is coming", function()
    local ns, bar = running(30)
    Mock.advance(2)
    ns.Bars:Update()
    near(bar.fraction, 1, 0.01)
    equal(bar.time:GetText(), "30%", "no countdown to a tick that cannot happen")
end)

scenario("Plainsrunning: how long a tick takes is measured on this client, not assumed", function()
    local ns, bar = running(10)
    equal(ns.Plains:TickLength("up"), 5, "the published 5 seconds, to begin with")
    check(select(2, ns.Plains:TickLength("up")):find("published", 1, true))

    -- three gains, four seconds apart: that is what this client does
    for stacks = 11, 13 do
        Mock.advance(4)
        Mock.stackingBuff(PLAINSRUNNING, "Plainsrunning", stacks)
        ns.Bars:Update()
    end
    near(ns.Plains:TickLength("up"), 4, 0.01, "measured")
    equal(select(2, ns.Plains:TickLength("up")), "measured")
    near(bar.fraction, 0, 0.01)
    equal(bar.time:GetText(), "13%  4.0", "and the countdown uses it")

    -- the drain has its own pace; until one is seen the gaining tick stands in
    near(ns.Plains:TickLength("down"), 4, 0.01)
    halt(ns)
    Mock.stackingBuff(PLAINSRUNNING, "Plainsrunning", 12) -- the first one to go: measured on its own
    ns.Bars:Update()
    near(ns.Plains.ticks.firstDown[1], 0.45, 0.02, "how long the game let us stand before it took one")
    near(ns.Plains:TickLength("down"), 4, 0.01, "and that gap is NOT the drain's own pace")
    Mock.advance(2)
    Mock.stackingBuff(PLAINSRUNNING, "Plainsrunning", 11)
    ns.Bars:Update()
    near(ns.Plains:TickLength("down"), 2, 0.01, "one percent to the next: that is the drain's pace")
    check(select(2, ns.Plains:TickLength("down")):find("soonest", 1, true), "a drain never runs on the middle of what we saw")

    -- a jump of several percent is a pause we did not see, not a tick
    Mock.advance(9)
    Mock.stackingBuff(PLAINSRUNNING, "Plainsrunning", 3)
    ns.Bars:Update()
    near(ns.Plains:TickLength("down"), 2, 0.01, "still 2: an eight-point jump taught it nothing")
end)

scenario("Plainsrunning: the first percent takes longer to go than the ones after it, and the bar counts it down at ITS pace", function()
    local ns, bar = running(12)
    -- what this client does, measured earlier: 1 second between percents, 3 before the first one goes
    ns.Plains.ticks.down = { 1, 1, 1 }
    ns.Plains.ticks.firstDown = { 3.4, 3, 4.1 }
    near(ns.Plains:TickLength("firstDown"), 3, 0.01, "the earliest one ever seen, not the middle")
    check(select(2, ns.Plains:TickLength("firstDown")):find("soonest", 1, true))

    halt(ns) -- 0.45s of standing
    near(bar.fraction, 1 - 0.45 / 3, 0.02, "counting the FIRST percent down over three seconds, not one")
    equal(bar.time:GetText(), "12%  2.6")

    -- it empties, and the percent has still not gone: it HOLDS there rather than starting over
    Mock.advance(3)
    ns.Bars:Update()
    near(bar.fraction, 0, 0.01, "empty: any moment now")
    equal(bar.time:GetText(), "12%  0.0")
    Mock.advance(2)
    ns.Bars:Update()
    near(bar.fraction, 0, 0.01, "still empty - it never pretends a fresh tick began")

    Mock.stackingBuff(PLAINSRUNNING, "Plainsrunning", 11) -- there it goes
    ns.Bars:Update()
    equal(ns.Plains.state.lostSinceStop, true)
    near(bar.fraction, 1, 0.02, "and now the steady drain: a fresh, full second")
    equal(bar.time:GetText(), "11%  1.0")
    Mock.advance(0.5)
    ns.Bars:Update()
    near(bar.fraction, 0.5, 0.02)

    -- set off again: a percent may still be on its way, so the steady drain is still what is shown
    Mock.setSpeed(7)
    ns.Bars:Update()
    equal(ns.Plains.state.drainInFlight, true)
    equal(ns.Plains.state.lostSinceStop, true, "still the steady drain until that one lands or does not")

    -- and once you have stopped again, the long first wait is back
    halt(ns)
    equal(ns.Plains.state.lostSinceStop, false)
    near(bar.fraction, 1 - 0.45 / 3, 0.02, "the long one again")
end)

scenario("Plainsrunning: a wait many times the drain is a stop we mis-saw, and is thrown out", function()
    local ns = running(12)
    ns.Plains.ticks.down = { 1, 1 }
    ns.Plains.ticks.firstDown = { 17.6, 1.7, 2.1 }
    near(ns.Plains:TickLength("firstDown"), 1.7, 0.01, "17.6 seconds is not the game being slow")
end)

scenario("Plainsrunning: every stack change is written down for the report", function()
    local ns = running(12)
    Mock.advance(5)
    Mock.stackingBuff(PLAINSRUNNING, "Plainsrunning", 13)
    halt(ns)
    Mock.advance(1.5)
    Mock.stackingBuff(PLAINSRUNNING, "Plainsrunning", 12)
    local changes = ns.Plains.changes
    equal(#changes, 2)
    equal(changes[1].from, 12); equal(changes[1].to, 13); equal(changes[1].moving, true)
    equal(changes[2].to, 12); equal(changes[2].moving, false)
    near(changes[2].sinceStop, 1.95, 0.05, "how long after stopping the first one went")
end)

scenario("Plainsrunning: each tick records where the bar WAS, and how much of its clock was strafe dips", function()
    local ns, bar = running(12)
    -- run five seconds, but strafe twice on the way: the speed dips without you ever stopping
    Mock.advance(2)
    ns.Bars:Update()
    for _ = 1, 2 do
        Mock.setSpeed(0)
        Mock.advance(0.2)  -- under the grace: a strafe, not a stop
        ns.Bars:Update()
        Mock.setSpeed(7)
        Mock.advance(0.2)
        ns.Bars:Update()
    end
    equal(ns.Plains.state.dipsSince, 2, "two dips since the last change")
    check(ns.Plains.state.dipTimeSince > 0.3, "and the time they handed to the gaining clock is counted")

    Mock.advance(2.2)
    ns.Bars:Update()
    Mock.stackingBuff(PLAINSRUNNING, "Plainsrunning", 13)
    local landed = ns.Plains.changes[#ns.Plains.changes]
    equal(landed.dips, 2)
    check(landed.dipTime > 0.3, "written down beside the tick it may have thrown off")
    check(landed.bar ~= nil, "and where the bar was when it landed: full means our clock ran fast")
    equal(ns.Plains.state.dipsSince, 0, "the count starts again at every change")
end)

scenario("Plainsrunning: with no first loss timed yet, the steady drain stands in for it", function()
    local ns, bar = running(12)
    ns.Plains.ticks.down = { 2, 2 }
    equal(select(2, ns.Plains:TickLength("firstDown")), "the steady drain, until a first loss has been timed")
    near(ns.Plains:TickLength("firstDown"), 2, 0.01)
    halt(ns)
    near(bar.fraction, 1 - 0.45 / 2, 0.02)
end)

scenario("Plainsrunning: jumping on the spot is not standing still - the buff builds and the bar keeps filling", function()
    local ns, bar = running(12)
    Mock.advance(2)
    ns.Bars:Update()
    near(bar.fraction, 0.4, 0.02)

    -- a jump from a standstill: no ground speed at all for a whole second
    Mock.setSpeed(0)
    Mock.setFalling(true)
    for _ = 1, 5 do
        Mock.advance(0.2)
        ns.Bars:Update()
    end
    equal(ns.Plains.state.moving, true, "off the ground is moving, whatever the speed says")
    equal(ns.Plains.state.jumps, 1)
    near(bar.fraction, 0.6, 0.02, "and the tick kept counting up through the jump")

    -- landing, and now really standing: the grace has to pass before it counts
    Mock.setFalling(false)
    equal(ns.Plains.state.moving, true)
    halt(ns)
    equal(ns.Plains.state.moving, false, "landed and stood still: now it drains")
    equal(ns.Plains.state.jumps, 1, "landing is not another jump")
end)

scenario("Plainsrunning: a client with no IsFalling just goes by the speed", function()
    local ns = start()
    _G.IsFalling = nil -- an older client without it
    Mock.setSpeed(7)
    draw(ns)
    Mock.stackingBuff(PLAINSRUNNING, "Plainsrunning", 12)
    ns.Bars:Update()
    equal(ns.Plains.state.moving, true)
    equal(ns.Plains:Describe().hasIsFalling, false, "and the report says so")
    halt(ns)
    equal(ns.Plains.state.moving, false)
end)

scenario("Plainsrunning: strafing is not stopping - the tick carries on, and the bar never restarts", function()
    local ns, bar = running(12)
    Mock.advance(2)
    ns.Bars:Update()
    near(bar.fraction, 0.4, 0.02, "two of the five seconds")

    -- a change of direction: the client reports zero speed for two frames
    Mock.strafe(ns, 2)
    equal(ns.Plains.state.moving, true, "still moving, as far as the game is concerned")
    equal(ns.Plains.state.dipsIgnored, 1)
    near(bar.fraction, 0.41, 0.02, "the tick carried on - it did not start over")

    Mock.advance(2.9)
    ns.Bars:Update()
    near(bar.fraction, 1, 0.02, "and it still comes due on time")

    -- several strafes in a row are still not a stop
    for _ = 1, 4 do
        Mock.strafe(ns, 3)
    end
    equal(ns.Plains.state.moving, true)
    equal(ns.Plains.state.dipsIgnored, 5)
end)

scenario("Plainsrunning: the first idle moments hold the bar still - the gaining tick must not seem to carry on", function()
    local ns, bar = running(12)
    Mock.advance(2)
    ns.Bars:Update()
    local held = bar.fraction
    near(held, 0.4, 0.02)

    -- you stopped, but it could still be a strafe: nothing moves until we know
    Mock.setSpeed(0)
    Mock.advance(0.15)
    ns.Bars:Update()
    near(bar.fraction, held, 0.001, "held exactly where it was")
    equal(bar.time:GetText(), "12%  3.0", "and so is the text")
    Mock.advance(0.15)
    ns.Bars:Update()
    near(bar.fraction, held, 0.001, "still held")
    equal(ns.Plains.state.moving, true)

    -- past the grace it is a stop, and the drain clock counts from when the speed really went
    Mock.advance(0.25)
    ns.Bars:Update()
    equal(ns.Plains.state.moving, false)
    near(bar.fraction, 1 - 0.40 / 5, 0.02, "counting down, from the moment you actually stopped")
end)

scenario("Plainsrunning in a fight: the client says nothing, so we keep the count ourselves", function()
    local ns, bar = running(25)
    equal(bar.time:GetText(), "25%  5.0")

    Mock.setCombat(true)
    equal(ns.Plains.state.estimate, 25, "the fight starts from what we last knew")
    Mock.advance(1)
    ns.Bars:Update()
    equal(bar.time:GetText(), "25% ~  4.0", "'~': our own count, and a sound one - nothing has hit us")

    -- the gaining tick comes round: nothing told us, so we count it ourselves
    Mock.advance(4)
    ns.Bars:Update()
    equal(ns.Plains.state.estimate, 26)
    equal(bar.time:GetText(), "26% ~  5.0", "and the next tick starts")
    near(bar.fraction, 0, 0.02)

    -- standing still in a fight drains it just the same
    halt(ns)
    Mock.advance(5)
    ns.Bars:Update()
    equal(ns.Plains.state.estimate, 25, "one gone")
    equal(ns.Plains.state.lostSinceStop, true)
    equal(ns.Plains.state.moving, false)
end)

scenario("Plainsrunning in a fight: once something hits you the count is only a guess, and says so", function()
    local ns, bar = running(25)
    Mock.setCombat(true)
    Mock.advance(1)
    ns.Bars:Update()
    equal(bar.time:GetText(), "25% ~  4.0")

    Mock.fireUnit("UNIT_COMBAT", "player", "player", "WOUND", "", 40, 1)
    equal(ns.Plains.state.hits, 1)
    ns.Bars:Update()
    check(bar.time:GetText():find("?", 1, true), "a hit takes some of the buff, and nobody knows how much")
    check(not bar.time:GetText():find("~", 1, true))
end)

scenario("Plainsrunning: when the fight ends the truth is read back and kept beside our guess", function()
    local ns, bar = running(25)
    Mock.setCombat(true)
    Mock.advance(5)
    ns.Bars:Update()
    equal(ns.Plains.state.estimate, 26, "we counted one on")
    Mock.fireUnit("UNIT_COMBAT", "player", "player", "WOUND", "", 40, 1)

    Mock.stackingBuff(PLAINSRUNNING, "Plainsrunning", 18) -- what it really was all along
    Mock.setCombat(false)
    ns.Bars:Update()
    equal(ns.Plains.state.percent, 18, "out of the fight the client talks again")
    equal(ns.Plains.state.estimate, nil)
    local last = ns.Plains.combats[#ns.Plains.combats]
    equal(last.started, 25); equal(last.hits, 1); equal(last.estimated, 26); equal(last.real, 18)
    equal(last.out, 8, "eight percent unaccounted for, across one hit - that is the number to collect")
    check(bar.time:GetText():find("18%%", 1, false))
end)

scenario("Plainsrunning: gone, not a tauren, or the buff is called something else here", function()
    local ns, bar = running(12)
    Mock.stackingBuff(PLAINSRUNNING, nil)
    draw(ns)
    check(not ns.Plains:InUse(), "gone")
    check(not bar:IsShown(), "and the row faded out with it")

    ns = start({ race = "Orc" })
    check(not ns.Plains:Applies(), "no racial, no row")
    check(not ns.Bars.HasRow("PLAINS"))

    ns = start()
    SlashCmdList.AKFOREVERCOMBATTIMERS("plains Plainstriding")
    equal(ns.Plains:GetName(), "Plainstriding", "the name can be changed if a client calls it something else")
    Mock.setSpeed(7)
    draw(ns)
    Mock.stackingBuff(PLAINSRUNNING, "Plainstriding", 30)
    ns.Bars:Update()
    equal(ns.Bars.bars.PLAINS.time:GetText(), "30%")
    SlashCmdList.AKFOREVERCOMBATTIMERS("plains")
    check(#Mock.printed > 0)
end)

scenario("diagnostics, slash commands and logout run; the report is SavedVariables-safe", function()
    local ns, state = start()
    boar(state)
    Mock.setCombat(true)
    Mock.swing(2.6, MH)
    Mock.hit("player")
    Mock.cast("target", { secret = true, seconds = 3 }) -- secrets must never reach the saved report
    Mock.cast("player", { name = "Healing Wave", seconds = 2 })
    Mock.buff(5171, "Slice and Dice", 21)               -- in combat: its aura data is secret
    ns.Bars:Update()
    for _, command in ipairs({ "", "debug", "debug", "enemy", "enemy", "unlock", "lock", "reset", "show", "blizzard", "casts", "watch focus", "watch", "diag" }) do
        SlashCmdList.AKFOREVERCOMBATTIMERS(command)
    end
    Mock.fire("PLAYER_LOGOUT")

    local function assertPlain(value, path)
        local kind = type(value)
        if kind == "table" then
            for k, v in pairs(value) do
                check(type(k) == "string" or type(k) == "number", path .. ": bad key type " .. type(k))
                assertPlain(v, path .. "." .. tostring(k))
            end
        else
            check(kind == "string" or kind == "number" or kind == "boolean", path .. ": " .. kind .. " cannot be saved")
        end
    end
    assertPlain(AKForeverCombatTimersDB, "AKForeverCombatTimersDB")
    local diag = AKForeverCombatTimersDB.diag
    equal(diag.api["C_SwingTimer.EnableRangeCheck"], "function")
    equal(next(diag.blockedActions), nil, "no blocked actions")
    equal(diag.enemy.unitCombatEvents, 1)
    equal(diag.player.swings.MH.count, 1)
    equal(#diag.casts.samples, 2)
    equal(diag.casts.samples[1].secretName, true); equal(diag.casts.samples[1].path, "SetTimerDuration")
    equal(diag.casts.samples[2].secretTimes, false); equal(diag.casts.samples[2].path, "numbers")
    equal(diag.casts.proven.player, true)
end)

scenario("the buff experiment: what an addon gets to see of Slice and Dice, out of combat and in a fight", function()
    start({ class = "ROGUE" })
    Mock.buff(5171, "Slice and Dice", 12)                    -- out of combat
    Mock.unbuff(5171)
    Mock.setCombat(true)
    Mock.buff(5171, "Slice and Dice", 21)                    -- in a fight
    Mock.buff(2983, "Sprint", 15, { neverSecret = true })    -- a spell Blizzard flagged "never secret"
    Mock.buff(1752, "Sinister Strike", 0)                    -- not a buff we watch
    SlashCmdList.AKFOREVERCOMBATTIMERS("diag")
    local samples = AKForeverCombatTimersDB.diag.buffs.samples
    equal(#samples, 3)
    equal(samples[1].combat, false); equal(samples[1].lookup.returned, 1)
    equal(samples[1].lookup.aura.duration, 12, "readable out of combat")
    equal(samples[1].lookupInstance.setTimerDuration, "accepted")

    equal(samples[2].combat, true)
    equal(samples[2].lookup.returned, 0, "by spell id the client returns NOTHING while the aura is secret")
    local added = samples[2].added1
    equal(samples[2].addedCount, 1)
    equal(added.aura.spellId, "<secret>"); equal(added.aura.expirationTime, "<secret>")
    equal(added.instance.duration, "secret object", "but the event names the instance, and its duration object ...")
    equal(added.instance.setTimerDuration, "accepted", "... can drive a bar")
    equal(samples[2].secrecy.spellSecretNow[1], true)

    equal(samples[3].spell, "Sprint"); equal(samples[3].lookup.returned, 1, "a never-secret spell stays readable in combat")
end)

scenario("a blocked action is recorded by name (and the harness catches it)", function()
    expectForbidden = true
    local ns = start()
    equal(#Mock.forbiddenCalls, 0, "a normal session triggers none")
    ns:On("COMBAT_LOG_EVENT_UNFILTERED", function() end) -- what v0.1.0's probe did
    equal(#Mock.forbiddenCalls, 1)
    equal(ns.blockedActions[1].fn, "Frame:RegisterEvent()")
    equal(ns.blockedActions[1].event, "ADDON_ACTION_FORBIDDEN")
    Mock.fire("ADDON_ACTION_BLOCKED", "SomeOtherAddon", "Frame:Show()")
    equal(#ns.blockedActions, 1, "other addons' blocks are not ours")
end)

scenario("renamed from ForeverSwingTimers: /fct is the command, /fst still works", function()
    start()
    equal(SLASH_AKFOREVERCOMBATTIMERS2, "/fct"); equal(SLASH_AKFOREVERCOMBATTIMERS3, "/fst")
    SlashCmdList.AKFOREVERCOMBATTIMERS("")
    local listed = false
    for _, line in ipairs(Mock.printed) do
        listed = listed or line:find("/fct ", 1, true) ~= nil
    end
    check(listed, "the command list speaks of /fct")
end)

scenario("survives a client that dropped an event", function()
    local ns = start({ unknownEvents = { PLAYER_SWING_RANGE_UPDATE = true, COMBAT_LOG_EVENT_UNFILTERED = true } })
    check(ns.unknownEvents.PLAYER_SWING_RANGE_UPDATE)
    Mock.swing(2.6, MH)
    check((ns.Swings:GetProgress("MH", Mock.now)))
end)

Mock.realPrint(string.format("\n%d passed, %d failed", passed, #failures))
os.exit(#failures == 0 and 0 or 1)
