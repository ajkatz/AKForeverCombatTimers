-- Takes over from Blizzard's built-in swing timer.
--
-- Blizzard's bar has a proper off switch - the "showSwingTimer" CVar, the same
-- setting as the checkbox in the game options - so we flip that instead of
-- fighting its frames. We remember that it was on, say so once in chat, and
-- '/fct blizzard show' puts it back.
local _, ns = ...

local CVAR = "showSwingTimer"

local function getCVar()
    local get = (C_CVar and C_CVar.GetCVar) or GetCVar
    local ok, value = pcall(get, CVAR)
    if ok and not ns.IsSecret(value) then
        return value
    end
    return nil
end

local function setCVar(value)
    local set = (C_CVar and C_CVar.SetCVar) or SetCVar
    local ok, err = pcall(set, CVAR, value)
    if not ok then
        ns:Log("blizzard_cvar_failed", tostring(err))
    end
    return ok
end

local pending = false

local function apply()
    if InCombatLockdown() then
        pending = true -- CVars can be locked in combat; settle it afterwards
        return
    end
    pending = false
    local current = getCVar()
    if current == nil then
        ns:Log("blizzard_cvar_missing", CVAR)
        return
    end
    if ns:GetOption("hideBlizzard") then
        if current == "1" and setCVar("0") then
            ns.db.blizzardTimerWasOn = true
            ns:Log("blizzard_timer", "hidden")
            if not ns.db.blizzardNoticeShown then
                ns.db.blizzardNoticeShown = true
                ns:Print("turned off Blizzard's swing timer so you don't see two. |cffffd100/fct blizzard show|r brings it back.")
            end
        end
    elseif ns.db.blizzardTimerWasOn and current == "0" and setCVar("1") then
        ns.db.blizzardTimerWasOn = nil
        ns:Log("blizzard_timer", "restored")
    end
end

ns:Listen("LOGIN", apply)

ns:Listen("COMBAT_END", function()
    if pending then
        apply()
    end
end)

ns:Listen("OPTION_CHANGED", function(_, key)
    if key == "hideBlizzard" then
        apply()
    end
end)

------------------------------------------------------------------------
-- Blizzard's cast bars (yours, and the one under the target frame).
--
-- Neither has a working off switch on this build: the player's has none, and the
-- target's "showTargetCastbar" CVar is tested with `GetCVar(...) and ...` in
-- GameRulesUtil - the string "0" is true in Lua, so the bar shows regardless.
--
-- So each one is taken off the screen in the way ITS code tolerates, using plain
-- widget calls only - nothing is written onto Blizzard's frames, no event or script
-- of theirs is touched - and '/fct casts blizzard show' puts both straight back:
--
--   player  PARKED: re-parented to a frame that is never shown (how AKForeverActionBars
--           hides Blizzard's action bars; proven on this client). Its code never asks
--           for its parent. Only done while the bar is hidden, so that none of
--           Blizzard's OnShow / OnHide code (the managed-frame container) runs on our
--           account. Parked it stays: the container only re-adopts it when it becomes
--           VISIBLE, which it cannot under a hidden parent.
--   target  SHRUNK to nothing with SetScale. It must keep its parent:
--           TargetSpellBarMixin:AdjustPosition() calls self:GetParent():
--           ShouldAnchorSpellBarToAuraContainer() on every aura change. Blizzard never
--           sets this bar's scale, and SetScale has no restriction in the API docs.
--
-- What was tried first, and what the game said (2026-09-19):
--   * v0.3.0: bar:IsEventRegistered() answers addon code with a SECRET boolean on
--     these frames, and testing a secret in an `if` is an error. Lesson: whatever a
--     getter on one of BLIZZARD's frames returns may be secret - ns.IsSecret first.
--     UnregisterAllEvents() was dropped with it: the API docs tie it to "forbidden
--     aspects" (EventRegistrations), a security model we cannot predict.
--   * v0.3.1 parked the TARGET bar too: "TargetFrame.lua:824: attempt to call a nil
--     value" inside Blizzard's aura layout - the GetParent() call above. Lesson:
--     before re-parenting one of Blizzard's frames, grep ITS code for GetParent().
--
-- Evidence first: a bar is only hidden once OUR bar for that unit has really
-- displayed a cast on this client (Casts:ReportPath) - if the client refused to
-- show us enemy casts, Blizzard's target bar simply stays.
------------------------------------------------------------------------
local CAST_BARS = {
    player = { frame = "PlayerCastingBarFrame", bar = "CAST", how = "park" },
    target = { frame = "TargetFrameSpellBar", bar = "TCAST", how = "shrink" },
}
local CAST_WATCHDOG_SECONDS = 5
local TINY_SCALE = 0.0001

local hiddenParent = CreateFrame("Frame", "AKForeverCombatTimersHidden", UIParent)
hiddenParent:Hide()

local originalParents = {} -- [frame] = the first parent we saw: home. Kept on OUR side.
local normalScales = {}    -- [frame] = the scale it had before we shrank it
local castBarsPending = false
ns.hiddenCastBars = {}     -- [unit] = "park" | "shrink" while hidden (for /fct diag)

local function wantsHidden(unit, info)
    return ns:GetOption("hideBlizzardCastBars") and ns.BarSettings:GetMode(info.bar) ~= "never" and ns.Casts:IsProven(unit) and true or false
end

-- A getter on one of Blizzard's frames: the value, and whether the client let us read it.
local function read(fn, ...)
    if type(fn) ~= "function" then
        return nil, false
    end
    local ok, value = pcall(fn, ...)
    if not ok or ns.IsSecret(value) then
        return nil, false
    end
    return value, true
end

local function mark(unit, how)
    if ns.hiddenCastBars[unit] == how then
        return
    end
    ns.hiddenCastBars[unit] = how
    ns:Log("blizzard_castbar", { unit = unit, hidden = how or false })
    if how and not ns.db.castBarNoticeShown then
        ns.db.castBarNoticeShown = true
        ns:Print("Blizzard's cast bars are hidden now that ours has shown a cast. |cffffd100/fct casts blizzard show|r brings them back.")
    end
end

local hiders = {}

function hiders.park(unit, bar, hide)
    local parent, readable = read(bar.GetParent, bar)
    if not readable then
        return
    end
    local parked = parent == hiddenParent
    if hide == parked then
        mark(unit, parked and "park" or nil)
        return
    end
    -- Moving a SHOWN bar in or out of a hidden parent would fire its OnHide / OnShow - Blizzard's
    -- managed-frame code - from our call. Wait until it is hidden (the watchdog comes back).
    local shown, known = read(bar.IsShown, bar)
    if not known or shown then
        return
    end
    if hide then
        originalParents[bar] = originalParents[bar] or parent or UIParent
        if pcall(bar.SetParent, bar, hiddenParent) then
            mark(unit, "park")
        end
    elseif pcall(bar.SetParent, bar, originalParents[bar] or UIParent) then
        mark(unit, nil)
    end
end

function hiders.shrink(unit, bar, hide)
    local scale, readable = read(bar.GetScale, bar)
    if not readable or type(scale) ~= "number" then
        return
    end
    local setScale = bar.SetScaleBase or bar.SetScale -- (an Edit Mode system keeps the raw method as SetScaleBase)
    local shrunk = scale < TINY_SCALE * 100
    if hide and not shrunk then
        normalScales[bar] = scale
        if pcall(setScale, bar, TINY_SCALE) then
            mark(unit, "shrink")
        end
    elseif not hide and shrunk then
        if pcall(setScale, bar, normalScales[bar] or 1) then
            mark(unit, nil)
        end
    else
        mark(unit, shrunk and "shrink" or nil)
    end
end

local function applyCastBars()
    if InCombatLockdown() then
        castBarsPending = true -- nothing here is urgent enough to do next to protected frames in a fight
        return
    end
    castBarsPending = false
    for unit, info in pairs(CAST_BARS) do
        local bar = _G[info.frame]
        if type(bar) == "table" and bar.GetParent then
            hiders[info.how](unit, bar, wantsHidden(unit, info))
        end
    end
end

ns:Listen("LOGIN", function()
    applyCastBars()
    C_Timer.NewTicker(CAST_WATCHDOG_SECONDS, function()
        if not InCombatLockdown() then
            ns.SafeCall(applyCastBars)
        end
    end)
end)

ns:Listen("CAST_PROVEN", applyCastBars)

ns:Listen("COMBAT_END", function()
    if castBarsPending then
        applyCastBars()
    end
end)

ns:Listen("OPTION_CHANGED", function(_, key)
    if key == "hideBlizzardCastBars" then
        applyCastBars()
    end
end)

ns:Listen("BARS_CHANGED", applyCastBars) -- one of our cast bars was switched on or off

ns:RegisterCommand("blizzard", "'hide' (default) or 'show' Blizzard's own swing timer", function(rest)
    local mode = string.lower(rest or "")
    if mode ~= "hide" and mode ~= "show" then
        ns:Print("usage: /fct blizzard hide | show   (now: " .. (ns:GetOption("hideBlizzard") and "hide" or "show") .. ")")
        return
    end
    ns:SetOption("hideBlizzard", mode == "hide")
    ns:Print("Blizzard's swing timer:", mode == "hide" and "hidden" or "shown")
end)
