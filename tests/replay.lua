-- Replays REAL hit data saved by the game through the enemy-swing model and reports
-- how well it predicted. Run from the repo root:
--     lua tests/replay.lua "<path to SavedVariables\ForeverCombatTimers.lua>"
-- The saved file holds the first ~120 UNIT_COMBAT events of a session
-- (ForeverCombatTimersDB.diag.enemy.rawSamples), timestamps included.
package.path = "./tests/?.lua;" .. package.path
local Mock = require("wowmock")

local path = arg and arg[1]
assert(path, "usage: lua tests/replay.lua <SavedVariables file>")
dofile(path)
local samples = ForeverCombatTimersDB.diag.enemy.rawSamples
local prior = tonumber(arg[2]) -- optional: the attack speed the game showed out of combat

local ns, state = Mock.install({ class = "ROGUE" })
if prior then
    state.attackSpeed.target = { prior }
end
state.units.target = { id = "mob", name = "Mob", hostile = true }
state.units.targettarget = { id = "player", name = "Purrdee" }
Mock.fire("PLAYER_TARGET_CHANGED")
Mock.setCombat(true)
if prior then
    state.attackSpeed.target = Mock.SECRET -- like the real client: secret once the fight is on
end

local fed = 0
for _, sample in ipairs(samples) do
    if sample.unit == "player" then
        Mock.now = sample.t
        Mock.hit("player", sample.action, sample.school)
        fed = fed + 1
    end
end

local errors = ns.Incoming.stats.errors
local absSum, within = 0, { 0, 0, 0 }
local sorted = {}
for i, err in ipairs(errors) do
    local a = math.abs(err)
    absSum = absSum + a
    sorted[i] = a
    if a <= 0.10 then within[1] = within[1] + 1 end
    if a <= 0.25 then within[2] = within[2] + 1 end
    if a <= 0.50 then within[3] = within[3] + 1 end
end
table.sort(sorted)
Mock.realPrint(string.format("events on player fed: %d   hits timed: %d   predictions scored: %d", fed, ns.Incoming.stats.hits, #errors))
if #errors > 0 then
    Mock.realPrint(string.format("mean abs error %.3fs   median abs error %.3fs   worst %.3fs", absSum / #errors, sorted[math.ceil(#sorted / 2)], sorted[#sorted]))
    Mock.realPrint(string.format("within 0.10s: %d/%d   within 0.25s: %d/%d   within 0.50s: %d/%d", within[1], #errors, within[2], #errors, within[3], #errors))
end
Mock.realPrint("addon errors during replay: " .. #Mock.errors)
