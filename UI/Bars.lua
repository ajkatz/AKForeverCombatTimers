-- Bars: the block.
--
--          target cast        ^   the enemy's half grows UP from the seam
--          incoming hit       |
--   ------ seam --------------+-- the block's anchor: this line is what you position, it never moves
--          main hand          |
--          off hand           |   your half grows DOWN
--          ranged             v
--          buff (Slice and Dice ...)
--          your cast
--
-- ... or pinned by its FLOOR ('/fct grow up'): the same picture, the same order, but what you position is
-- the bottom of the block. Rows that come and go push the seam and the upper half up; nothing ever
-- reaches below the line you set.
--
-- ... and, either way, the picture can be REVERSED ('/fct reverse on'): yours stack up from the seam, your
-- cast bar on top, and the enemy's hang below it - the block the other way up.
--
-- What each bar does is BarSettings' business (mode always / when used / never, seconds to linger,
-- width, height, order inside its half). A bar that is switched off, or does not apply to the
-- character, takes no row; every other bar keeps its row while idle, so nothing ever jumps. Bars fade
-- in and out. Plain frames only - nothing here is protected, so combat never gets in the way.
local _, ns = ...

local Swings, Incoming, Casts, Settings = ns.Swings, ns.Incoming, ns.Casts, ns.BarSettings

local Bars = {}
ns.Bars = Bars

local GAP, PAD = 3, 4
local OUT_OF_RANGE_ALPHA = 0.4 -- same cue as Blizzard's bar
local FADE_IN, FADE_OUT = 0.15, 0.4
local SNAP_DISTANCE = 24
local FLAT = "Interface\\Buttons\\WHITE8X8"
local UNKNOWN_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"
local ANCHOR_FRACTION = { LEFT = 0, CENTER = 0.5, RIGHT = 1 }

local COLORS = {
    MH = { 0.85, 0.72, 0.25 },
    OH = { 0.62, 0.55, 0.30 },
    RG = { 0.40, 0.75, 0.40 },
    ENEMY = { 0.80, 0.25, 0.20 },
    CAST = { 0.30, 0.58, 0.95 },
    TCAST = { 0.95, 0.52, 0.15 },
    BUFF = { 0.78, 0.45, 0.90 },
    -- one family, four shades: they sit together and want telling apart at a glance
    DOT1 = { 0.85, 0.35, 0.55 },
    DOT2 = { 0.90, 0.50, 0.35 },
    DOT3 = { 0.70, 0.40, 0.75 },
    DOT4 = { 0.55, 0.45, 0.85 },
    -- urgent by nature: a window is a few seconds to act in
    REACT1 = { 0.95, 0.75, 0.20 },
    REACT2 = { 0.95, 0.55, 0.20 },
    REACT3 = { 0.85, 0.35, 0.20 },
    PLAINS = { 0.45, 0.80, 0.45 }, -- (Plainsrunning recolours it: green while it grows, red while it drains)
}

-- Bars whose content is a "timed thing with a name and an icon": where that thing comes from.
local SOURCES = {
    CAST = function(now) return Casts:Get("player", now) end,
    TCAST = function(now) return Casts:Get("target", now) end,
    BUFF = function(now) return ns.Buffs and ns.Buffs:Get(now) or nil end,
    DOT1 = function(now) return ns.Dots and ns.Dots:Get(1, now) or nil end,
    DOT2 = function(now) return ns.Dots and ns.Dots:Get(2, now) or nil end,
    DOT3 = function(now) return ns.Dots and ns.Dots:Get(3, now) or nil end,
    DOT4 = function(now) return ns.Dots and ns.Dots:Get(4, now) or nil end,
    REACT1 = function(now) return ns.Reactive and ns.Reactive:Get(1, now) or nil end,
    REACT2 = function(now) return ns.Reactive and ns.Reactive:Get(2, now) or nil end,
    REACT3 = function(now) return ns.Reactive and ns.Reactive:Get(3, now) or nil end,
}
local TEST_CYCLES = { ENEMY = 2.0, MH = 2.6, OH = 1.7, RG = 3.0, CAST = 2.5, TCAST = 3.2, BUFF = 9.0,
    PLAINS = 6.0, DOT1 = 12.0, DOT2 = 15.0, DOT3 = 18.0, DOT4 = 24.0,
    REACT1 = 5.0, REACT2 = 5.0, REACT3 = 5.0 }

local root, upper, lower -- the seam (what moves), and the two halves hanging off it
local bars = {}          -- [key] = bar
local testUntil = 0
local layoutSignature

Bars.bars = bars -- read by the tests

------------------------------------------------------------------------
-- Construction
------------------------------------------------------------------------
local function addGhost(bar, parent)
    -- An idle row is empty, click-through space. While the block is unlocked, four faint corner
    -- marks say "a bar appears here". (A frame of its own: the bar itself is hidden while idle.)
    bar.ghost = CreateFrame("Frame", nil, parent)
    for _, point in ipairs({ "TOPLEFT", "TOPRIGHT", "BOTTOMLEFT", "BOTTOMRIGHT" }) do
        for _, size in ipairs({ { 9, 1 }, { 1, 5 } }) do
            local mark = bar.ghost:CreateTexture(nil, "BORDER")
            mark:SetColorTexture(0.55, 0.78, 1, 0.35)
            mark:SetSize(size[1], size[2])
            mark:SetPoint(point, bar.ghost, point, 0, 0)
        end
    end
    bar.ghost:Hide()
end

local function createBar(key, parent)
    local bar = CreateFrame("Frame", nil, parent)
    bar.key, bar.kind, bar.fade = key, "swing", 0

    bar.background = bar:CreateTexture(nil, "BACKGROUND")
    bar.background:SetAllPoints(bar)
    bar.background:SetColorTexture(0, 0, 0, 0.6)

    local color = COLORS[key]
    bar.fill = bar:CreateTexture(nil, "BORDER")
    bar.fill:SetPoint("LEFT", bar, "LEFT", 0, 0)
    bar.fill:SetColorTexture(color[1], color[2], color[3], 0.9)

    bar.spark = bar:CreateTexture(nil, "OVERLAY")
    bar.spark:SetTexture("Interface\\CastingBar\\UI-CastingBar-Spark")
    bar.spark:SetBlendMode("ADD")
    bar.spark:SetPoint("CENTER", bar.fill, "RIGHT", 0, 0)

    bar.label = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    bar.label:SetPoint("LEFT", bar, "LEFT", 4, 0)
    bar.label:SetJustifyH("LEFT")
    bar.label:SetText(Settings.LABELS[key])

    bar.time = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    bar.time:SetPoint("RIGHT", bar, "RIGHT", -4, 0)
    bar.time:SetJustifyH("RIGHT")

    addGhost(bar, parent)
    bar:Hide()
    return bar
end

-- Spell icon, a real StatusBar (the client can drive one from values an addon is not allowed to
-- read), a name, seconds left. Used for casts and for buffs.
local function createTimedBar(key, parent)
    local bar = CreateFrame("Frame", nil, parent)
    bar.key, bar.kind, bar.fade = key, "timed", 0

    bar.background = bar:CreateTexture(nil, "BACKGROUND")
    bar.background:SetAllPoints(bar)
    bar.background:SetColorTexture(0, 0, 0, 0.6)

    bar.icon = bar:CreateTexture(nil, "ARTWORK")
    bar.icon:SetPoint("LEFT", bar, "LEFT", 0, 0)
    bar.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    local color = COLORS[key]
    bar.status = CreateFrame("StatusBar", nil, bar)
    bar.status:SetStatusBarTexture(FLAT)
    bar.status:SetStatusBarColor(color[1], color[2], color[3], 0.9)
    bar.status:SetMinMaxValues(0, 1)
    bar.status:SetValue(0)

    bar.spark = bar.status:CreateTexture(nil, "OVERLAY")
    bar.spark:SetTexture("Interface\\CastingBar\\UI-CastingBar-Spark")
    bar.spark:SetBlendMode("ADD")
    bar.spark:Hide()

    bar.label = bar.status:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    bar.label:SetPoint("LEFT", bar.status, "LEFT", 4, 0)
    bar.label:SetPoint("RIGHT", bar.status, "RIGHT", -34, 0)
    bar.label:SetJustifyH("LEFT")
    bar.label:SetWordWrap(false)

    bar.time = bar.status:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    bar.time:SetPoint("RIGHT", bar.status, "RIGHT", -4, 0)
    bar.time:SetJustifyH("RIGHT")

    addGhost(bar, parent)
    bar:Hide()
    return bar
end

local function applySize(bar, width, height)
    if bar.width == width and bar.height == height then
        return
    end
    bar.width, bar.height = width, height
    bar:SetSize(width, height)
    bar.ghost:SetSize(width, height)
    bar.spark:SetSize(16, height * 2.2)
    if bar.kind == "swing" then
        bar.fill:SetHeight(height)
    else
        bar.icon:SetSize(height, height)
        bar.status:ClearAllPoints()
        bar.status:SetPoint("TOPLEFT", bar, "TOPLEFT", height + 1, 0)
        bar.status:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", 0, 0)
        bar.statusWidth = width - height - 1
    end
end

local function setProgress(bar, active, fraction, remaining, text, color)
    if active then
        bar.fill:SetWidth(math.max(1, bar.width * math.min(1, math.max(0, fraction))))
        bar.fill:Show()
        bar.spark:SetShown(fraction < 1)
        bar.time:SetText(text or string.format("%.1f", remaining))
        if color then
            bar.fill:SetColorTexture(color[1], color[2], color[3], 0.9)
        end
    else
        bar.fill:Hide()
        bar.spark:Hide()
        bar.time:SetText("")
    end
    bar.active = active
    bar.fraction = fraction
end

local function showFraction(bar, fraction, remaining)
    bar.status:SetValue(fraction)
    bar.spark:ClearAllPoints()
    bar.spark:SetPoint("CENTER", bar.status, "LEFT", bar.statusWidth * fraction, 0)
    bar.spark:SetShown(fraction > 0 and fraction < 1)
    bar.time:SetText(remaining >= 60 and string.format("%d:%02d", math.floor(remaining / 60), math.floor(remaining % 60))
        or string.format("%.1f", remaining))
    bar.fraction = fraction
end

------------------------------------------------------------------------
-- Seconds left on a cast we may not read (every enemy cast: measured 2026-09-19, the target's casts
-- are secret in and out of combat). The client can do the counting for us, from the same duration
-- object that drives the bar:
--   1. a duration text binding (C_DurationUtil.CreateDurationTextBinding): the client itself keeps
--      writing the formatted remaining time into our font string;
--   2. else duration:FormatRemainingDuration(formatter) every frame - the string it returns may be
--      secret and goes straight into FontString:SetText, never looked at;
--   3. else no seconds, as before. /fct diag records which one the client took.
------------------------------------------------------------------------
local secondsFormatter -- nil: not tried yet, false: this client has none

local function getSecondsFormatter()
    if secondsFormatter == nil then
        secondsFormatter = false
        local create = C_StringUtil and C_StringUtil.CreateNumericRuleFormatter
        if type(create) == "function" then
            local ok, formatter = pcall(create)
            if ok and not ns.IsSecret(formatter) and formatter ~= nil
                and pcall(formatter.SetBreakpoints, formatter, { { threshold = 0, step = 0.1, format = "%.1f" } }) then
                secondsFormatter = formatter
            end
        end
    end
    return secondsFormatter or nil
end

local countdownBar -- (plain functions + an upvalue instead of closures: this runs every frame)
local function writeFormattedCountdown()
    countdownBar.time:SetText(countdownBar.countdown.duration:FormatRemainingDuration(countdownBar.countdown.formatter))
end

local function releaseCountdown(bar)
    if bar.bindingActive then
        bar.bindingActive = false
        pcall(bar.binding.Disable, bar.binding)
    end
    bar.countdown = nil
end

-- "binding" | "format" | "none"
local function startCountdown(bar, cast)
    releaseCountdown(bar)
    local formatter = cast.hasDuration and getSecondsFormatter()
    if not formatter then
        return "none"
    end
    if not bar.binding and C_DurationUtil and type(C_DurationUtil.CreateDurationTextBinding) == "function" then
        local ok, binding = pcall(C_DurationUtil.CreateDurationTextBinding)
        if ok and not ns.IsSecret(binding) and binding ~= nil and pcall(function()
            binding:SetFontString(bar.time)
            binding:SetFormatter(formatter)
            binding:SetUpdateInterval(0.05)
            binding:SetZeroDurationText("")
            binding:SetExpiredText("")
        end) then
            bar.binding = binding
        end
    end
    if bar.binding and pcall(function()
        bar.binding:SetDuration(cast.duration)
        bar.binding:Enable()
    end) then
        bar.bindingActive = true
        return "binding"
    end
    bar.countdown = { duration = cast.duration, formatter = formatter }
    countdownBar = bar
    if pcall(writeFormattedCountdown) then
        return "format"
    end
    bar.countdown = nil
    return "none"
end

-- A new (or pushed back) cast: hand name, icon and - when we may not read them - the times to the
-- widgets. Name and icon may be secret: they go straight in, inside a pcall, and are never looked at.
local function armCastBar(bar, cast)
    if not pcall(bar.label.SetText, bar.label, cast.name) then
        bar.label:SetText(cast.fallbackLabel or (cast.kind == "channel" and "Channeling" or "Casting"))
    end
    if not pcall(bar.icon.SetTexture, bar.icon, cast.texture) then
        bar.icon:SetTexture(UNKNOWN_ICON)
    end
    local status = bar.status
    local seconds = "numbers"
    if cast.timesReadable then
        releaseCountdown(bar) -- our own arithmetic writes the seconds
        status:SetMinMaxValues(0, 1)
        bar.path = "numbers"
    else
        bar.spark:Hide()
        bar.time:SetText("")
        bar.fraction = nil
        seconds = startCountdown(bar, cast)
        local direction = Enum and Enum.StatusBarTimerDirection
        local interpolation = Enum and Enum.StatusBarInterpolation and Enum.StatusBarInterpolation.Immediate or 0
        direction = direction and (cast.drains and direction.RemainingTime or direction.ElapsedTime) or 0
        if cast.hasDuration and status.SetTimerDuration
            and pcall(status.SetTimerDuration, status, cast.duration, interpolation, direction) then
            bar.path = "SetTimerDuration" -- the client animates the bar by itself
        elseif pcall(status.SetMinMaxValues, status, cast.secretStart, cast.secretEnd) then
            bar.path = "SetMinMaxValues"  -- we feed it the clock every frame
        else
            status:SetMinMaxValues(0, 1)
            status:SetValue(1)
            bar.path = "refused"          -- a full bar with the spell's name is all we can do
        end
    end
    cast.owner:ReportPath(cast, bar.path, seconds)
end

local function setIdleLook(bar)
    bar.status:SetMinMaxValues(0, 1)
    bar.status:SetValue(0)
    bar.spark:Hide()
    bar.label:SetText((ns.Dots and ns.Dots:SlotLabel(bar.key))
        or (ns.Reactive and ns.Reactive:SlotLabel(bar.key)) or Settings.LABELS[bar.key])
    bar.icon:SetTexture(nil)
    bar.fraction = nil
end

-- true while there is something to show
local function updateTimedBar(bar, now, testing)
    if testing then
        local cycle = TEST_CYCLES[bar.key]
        local elapsed = (now - (testUntil - 15)) % cycle
        if bar.serial ~= "test" then
            bar.serial = "test"
            releaseCountdown(bar)
            bar.status:SetMinMaxValues(0, 1)
            bar.label:SetText(Settings.LABELS[bar.key])
            bar.icon:SetTexture(UNKNOWN_ICON)
        end
        if bar.key == "BUFF" then
            showFraction(bar, 1 - elapsed / cycle, cycle - elapsed) -- buffs drain
        else
            showFraction(bar, elapsed / cycle, cycle - elapsed)
        end
        return true
    end
    local state = SOURCES[bar.key](now)
    if not state then
        if bar.serial ~= nil then
            bar.serial, bar.idleLook = nil, false
            releaseCountdown(bar) -- the client must not keep writing into a bar that is done
            bar.time:SetText("")
        end
        -- An "always" bar stays up while idle: empty, under its own name. (A "when used" bar keeps showing
        -- what it last showed while it lingers and fades.)
        if not bar.idleLook and Settings:GetMode(bar.key) == "always" then
            setIdleLook(bar)
            bar.idleLook = true
        end
        return false
    end
    bar.idleLook = false
    if bar.serial ~= state.serial then
        bar.serial = state.serial
        armCastBar(bar, state)
    end
    if bar.path == "numbers" then
        showFraction(bar, state.owner:GetProgress(state, now))
    else
        if bar.path == "SetMinMaxValues" then
            -- a plain number against secret bounds: the clock for a cast, its own scale for a buff estimate
            pcall(bar.status.SetValue, bar.status, state.clock and state.clock(now) or now * 1000)
        end
        if bar.countdown then
            countdownBar = bar
            if not pcall(writeFormattedCountdown) then
                bar.countdown = nil
                bar.time:SetText("")
            end
        end
    end
    return true
end

------------------------------------------------------------------------
-- What to show
------------------------------------------------------------------------
local function watchedLabel(attackers)
    local unit = Incoming.watched
    local count = (attackers or 0) > 1 and ("  x" .. attackers) or "" -- several attackers: the bar shows the next hit of any
    if unit == "player" then
        return "Incoming (you)" .. count
    end
    local ok, name = pcall(UnitName, unit)
    if ok and type(name) == "string" and not ns.IsSecret(name) then
        return "Incoming (" .. name .. ")" .. count
    end
    return "Incoming" .. count
end

-- active, fraction, remaining, dim
local function progressFor(key, now, testing)
    if testing then
        local cycle = TEST_CYCLES[key]
        local elapsed = (now - (testUntil - 15)) % cycle
        return true, elapsed / cycle, cycle - elapsed, false
    end
    if key == "ENEMY" then
        local active, fraction, remaining, confidence = Incoming:GetProgress(now)
        return active, fraction, remaining, confidence < 0.4
    elseif key == "PLAINS" then
        return ns.Plains:GetProgress(now)
    end
    local active, fraction, remaining = Swings:GetProgress(key, now)
    return active, fraction, remaining, Swings.state[key].outOfRange
end

local function inUse(key, now)
    if key == "PLAINS" then
        return ns.Plains:InUse()
    elseif key == "ENEMY" then
        return (Incoming:GetProgress(now)) and true or false
    elseif SOURCES[key] then
        return SOURCES[key](now) ~= nil
    end
    return (Swings:GetProgress(key, now)) and true or false
end

-- Does this bar mean anything for this character right now?
local function applies(key, now)
    if key == "OH" then
        return Swings:IsAvailable(key)
    elseif key == "RG" then
        if Swings:IsAvailable(key) then
            return true
        end
        -- no ranged speed on record, yet the client just timed a ranged attack (something thrown): give
        -- it a row for as long as that bar lingers
        local idle = Swings:SecondsSinceActivity(key, now)
        return idle ~= nil and idle < math.max(10, Settings:Get(key, "after"))
    elseif key == "BUFF" then
        return ns.Buffs ~= nil and ns.Buffs:HasTracked()
    elseif string.find(key, "^DOT%d$") then
        return ns.Dots ~= nil and ns.Dots:SlotLabel(key) ~= nil
    elseif string.find(key, "^REACT%d$") then
        return ns.Reactive ~= nil and ns.Reactive:SlotLabel(key) ~= nil
    elseif key == "PLAINS" then
        return ns.Plains ~= nil and ns.Plains:Applies()
    end
    return true
end

------------------------------------------------------------------------
-- Layout: rows hang off the seam. Only redone when something about it changed.
------------------------------------------------------------------------
-- Does this bar have a row at the moment? (BarSettings:Move steps over the ones that do not.)
function Bars.HasRow(key)
    return bars[key] ~= nil and bars[key].slotted == true
end

function Bars:GetBlockWidth()
    return self.blockWidth or (220 + PAD * 2)
end

-- Seconds between two checks of whether the layout needs redoing. Measured on the test client: the
-- CHECK - walking every bar, asking its settings, building a signature to compare - was two thirds of
-- what an idle frame cost, sixty times a second, to answer a question whose answer changes when a bar
-- appears or goes away. A sixth of a second late is not something an eye catches. Anything that really
-- changes a setting clears layoutSignature, and that is taken as "now, please".
local LAYOUT_INTERVAL = 0.15
local lastLayoutAt

function Bars:Layout(now, force)
    now = now or GetTime()
    if not force and layoutSignature ~= nil and lastLayoutAt and (now - lastLayoutAt) < LAYOUT_INTERVAL then
        return false
    end
    lastLayoutAt = now
    local order = Settings:GetOrder()
    local anchor = Settings:GetBlock("anchor")
    local floor = Settings:GetBlock("grow") == "up"      -- the bottom of the block is what is pinned, not the seam
    local reversed = Settings:GetBlock("reverse") == true -- yours above the seam, the enemy's below
    local parts = { anchor .. (floor and " up" or " down") .. (reversed and " reversed" or "") }
    for index, key in ipairs(order) do
        local bar = bars[key]
        bar.slotted = Settings:GetMode(key) ~= "never" and applies(key, now)
        parts[index + 1] = bar.slotted and (key .. Settings:Get(key, "width") .. "x" .. Settings:Get(key, "height")) or "-"
    end
    local signature = table.concat(parts, " ")
    self.order = order
    if signature == layoutSignature then
        return false
    end
    layoutSignature = signature

    local widest, halves = 0, { enemy = {}, own = {} }
    for _, key in ipairs(order) do
        local bar = bars[key]
        if bar.slotted then
            applySize(bar, Settings:Get(key, "width"), Settings:Get(key, "height"))
            widest = math.max(widest, bar.width)
            table.insert(halves[Settings.GROUPS[key]], bar)
        else
            bar.fade = 0
            bar:Hide()
            bar.ghost:Hide()
        end
    end
    self.blockWidth = math.max(widest, 60) + PAD * 2
    root:SetSize(self.blockWidth, GAP)

    local function place(bar, container, edge, offset)
        for _, frame in ipairs({ bar, bar.ghost }) do
            if frame:GetParent() ~= container then
                frame:SetParent(container) -- (reversing the block moves a half to the other side of the seam)
            end
            frame:ClearAllPoints()
            if anchor == "LEFT" then
                frame:SetPoint(edge .. "LEFT", container, edge .. "LEFT", PAD, offset)
            elseif anchor == "RIGHT" then
                frame:SetPoint(edge .. "RIGHT", container, edge .. "RIGHT", -PAD, offset)
            else
                frame:SetPoint(edge, container, edge, 0, offset)
            end
        end
    end
    -- the halves from the seam outward, whatever is pinned. Plain: yours below the seam (your first bar
    -- directly under it), the enemy's above (its LAST bar on the seam). Reversed: the enemy's below (last
    -- bar directly under the seam), yours above (first bar on it) - the block the other way up.
    local below, above = {}, {}
    if reversed then
        for index = #halves.enemy, 1, -1 do
            below[#below + 1] = halves.enemy[index]
        end
        for _, bar in ipairs(halves.own) do
            above[#above + 1] = bar
        end
    else
        for _, bar in ipairs(halves.own) do
            below[#below + 1] = bar
        end
        for index = #halves.enemy, 1, -1 do
            above[#above + 1] = halves.enemy[index]
        end
    end
    local down = 0
    for _, bar in ipairs(below) do
        place(bar, lower, "TOP", -down)
        down = down + bar.height + GAP
    end
    local up = 0
    for _, bar in ipairs(above) do
        place(bar, upper, "BOTTOM", up)
        up = up + bar.height + GAP
    end
    lower:SetHeight(math.max(1, down - GAP + PAD))
    upper:SetHeight(math.max(1, up - GAP + PAD))
    -- what is pinned to the anchor: the seam (both halves hang off the root), or the floor (the lower half
    -- stands on the root and the upper rides on top of it, so every row that comes pushes upward)
    lower:ClearAllPoints()
    upper:ClearAllPoints()
    if floor then
        lower:SetPoint("BOTTOMLEFT", root, "BOTTOMLEFT", 0, 0)
        lower:SetPoint("BOTTOMRIGHT", root, "BOTTOMRIGHT", 0, 0)
        upper:SetPoint("BOTTOMLEFT", lower, "TOPLEFT", 0, 0)
        upper:SetPoint("BOTTOMRIGHT", lower, "TOPRIGHT", 0, 0)
        root:SetClampRectInsets(0, 0, math.max(1, up + down), -1) -- the whole block stands above the anchor
    else
        upper:SetPoint("BOTTOMLEFT", root, "TOPLEFT", 0, 0)
        upper:SetPoint("BOTTOMRIGHT", root, "TOPRIGHT", 0, 0)
        lower:SetPoint("TOPLEFT", root, "BOTTOMLEFT", 0, 0)
        lower:SetPoint("TOPRIGHT", root, "BOTTOMRIGHT", 0, 0)
        root:SetClampRectInsets(0, 0, math.max(1, up), -math.max(1, down)) -- keep both halves on the screen
    end
    self.slots = #halves.own + #halves.enemy
    self.ownRows, self.enemyRows = #halves.own, #halves.enemy
    return true
end

------------------------------------------------------------------------
-- Update: every frame, from a driver that is never hidden
------------------------------------------------------------------------
function Bars:Update()
    if not root then
        return
    end
    local now = GetTime()
    local dt = math.max(0, now - (self.lastUpdate or now))
    self.lastUpdate = now
    local testing = now < testUntil
    local unlocked = not ns:GetOption("locked")
    local fading = Settings:GetBlock("fade")
    self:Layout(now)

    local shown = 0
    for _, key in ipairs(self.order) do
        local bar = bars[key]
        if bar.slotted then
            local using = testing or inUse(key, now)
            if using then
                bar.lastUse = now
            end
            local wanted = using or Settings:GetMode(key) == "always"
                or (bar.lastUse ~= nil and now - bar.lastUse < Settings:Get(key, "after")) -- (+0 s: gone at once)
            local target = wanted and 1 or 0
            if bar.fade ~= target then
                if fading then
                    local step = dt / (wanted and FADE_IN or FADE_OUT)
                    bar.fade = wanted and math.min(1, bar.fade + step) or math.max(0, bar.fade - step)
                else
                    bar.fade = target
                end
            end
            local visible = bar.fade > 0
            if visible then
                shown = shown + 1
                local dim = false
                if bar.kind == "swing" then
                    local active, fraction, remaining, text, color
                    active, fraction, remaining, dim, text, color = progressFor(key, now, testing)
                    setProgress(bar, active, fraction, remaining, text, color)
                    if key == "ENEMY" then
                        local _, _, _, _, attackers = Incoming:GetProgress(now)
                        bar.label:SetText(watchedLabel(attackers))
                    end
                else
                    -- SafeCall: cast and aura data is the part of this client we know least about. A surprise
                    -- is recorded once for /fct diag - never an error every frame.
                    ns.SafeCall(updateTimedBar, bar, now, testing)
                end
                bar:SetAlpha(bar.fade * (dim and OUT_OF_RANGE_ALPHA or 1))
            elseif bar.kind == "timed" and bar.serial ~= nil then
                ns.SafeCall(updateTimedBar, bar, now, testing) -- let it notice that its cast / buff is over
            end
            if bar:IsShown() ~= visible then
                bar:SetShown(visible)
            end
            bar.ghost:SetShown(unlocked and not visible)
        end
    end
    self.shownBars = shown
    local blockVisible = shown > 0 or unlocked
    if root:IsShown() ~= blockVisible then
        root:SetShown(blockVisible)
    end
end

------------------------------------------------------------------------
-- Position: the seam's anchor point, in screen coordinates (from the bottom left corner)
------------------------------------------------------------------------
local function screenSize()
    local width, height = UIParent:GetWidth(), UIParent:GetHeight()
    if not width or width <= 0 then
        width, height = 1024, 768
    end
    return width, height
end

local function anchorFraction()
    return ANCHOR_FRACTION[Settings:GetBlock("anchor")] or 0.5
end

-- v0.3 saved { point, relativePoint, x, y } for the whole block's frame: work out where that put the seam.
local function migratePosition(old)
    local screenWidth, screenHeight = screenSize()
    local function fractions(point)
        point = tostring(point or "CENTER")
        return (point:find("LEFT") and 0) or (point:find("RIGHT") and 1) or 0.5,
            (point:find("BOTTOM") and 0) or (point:find("TOP") and 1) or 0.5
    end
    local width, height = 228, 90 -- the old block: 220 wide bars, five rows of 14 + 3
    local px, py = fractions(old.point)
    local rx, ry = fractions(old.relativePoint or old.point)
    local left = rx * screenWidth + (old.x or 0) - px * width
    local top = ry * screenHeight + (old.y or 0) - py * height + height
    return { x = left + width / 2, y = top - PAD - 2 * (14 + GAP) + GAP / 2, anchor = "CENTER" }
end

function Bars:GetPosition()
    local position = ns.cdb.position
    if type(position) == "table" and position.point then
        position = migratePosition(position)
        ns.cdb.position = position
    end
    if type(position) ~= "table" or type(position.x) ~= "number" or type(position.y) ~= "number" then
        local screenWidth, screenHeight = screenSize()
        return screenWidth / 2 + (anchorFraction() - 0.5) * self:GetBlockWidth(), screenHeight / 2 - 150
    end
    -- saved for another anchor point: same block, other reference
    local savedFraction = ANCHOR_FRACTION[position.anchor or "CENTER"] or 0.5
    return position.x + (anchorFraction() - savedFraction) * self:GetBlockWidth(), position.y
end

function Bars:SetPosition(x, y)
    ns.cdb.position = { x = x, y = y, anchor = Settings:GetBlock("anchor") }
    self:ApplyPosition()
end

function Bars:ApplyPosition()
    if not root then
        return
    end
    local x, y = self:GetPosition()
    root:ClearAllPoints()
    root:SetPoint(Settings:GetBlock("anchor"), UIParent, "BOTTOMLEFT", x, y)
end

-- The block's horizontal centre, given the anchor point's x.
local function centreOf(x)
    return x + (0.5 - anchorFraction()) * Bars:GetBlockWidth()
end

function Bars:CenterHorizontally()
    local _, y = self:GetPosition()
    local screenWidth = screenSize()
    self:SetPosition(screenWidth / 2 + (anchorFraction() - 0.5) * self:GetBlockWidth(), y)
end

-- After a drag the client has anchored the seam wherever it liked: read where it is, store that.
local function saveDraggedPosition()
    local left, right = root:GetLeft(), root:GetRight()
    local _, y = root:GetCenter()
    if not (left and right and y) then
        return
    end
    local x = left + (right - left) * anchorFraction()
    local screenWidth = screenSize()
    if Settings:GetBlock("snapCenter") and math.abs(centreOf(x) - screenWidth / 2) <= SNAP_DISTANCE then
        x = screenWidth / 2 + (anchorFraction() - 0.5) * Bars:GetBlockWidth()
    end
    Bars:SetPosition(x, y)
end

------------------------------------------------------------------------
-- Construction
------------------------------------------------------------------------
local function applyLock()
    local unlocked = not ns:GetOption("locked")
    root.tab:SetShown(unlocked)
    root.seam:SetShown(unlocked)
    root.guide:Hide()
end

local function create()
    root = CreateFrame("Frame", "AKForeverCombatTimersFrame", UIParent)
    root:SetSize(220 + PAD * 2, GAP)
    root:SetMovable(true)
    root:SetClampedToScreen(true)
    root:EnableMouse(false) -- the block never takes the mouse: idle rows are empty space you can click through

    upper = CreateFrame("Frame", nil, root)
    upper:SetPoint("BOTTOMLEFT", root, "TOPLEFT", 0, 0)
    upper:SetPoint("BOTTOMRIGHT", root, "TOPRIGHT", 0, 0)
    lower = CreateFrame("Frame", nil, root)
    lower:SetPoint("TOPLEFT", root, "BOTTOMLEFT", 0, 0)
    lower:SetPoint("TOPRIGHT", root, "BOTTOMRIGHT", 0, 0)
    root.upper, root.lower = upper, lower

    -- While unlocked: the seam as a hairline, and a small tab to drag the block by (click it: settings).
    root.seam = root:CreateTexture(nil, "ARTWORK")
    root.seam:SetColorTexture(0.55, 0.78, 1, 0.45)
    root.seam:SetPoint("LEFT", root, "LEFT", 0, 0)
    root.seam:SetPoint("RIGHT", root, "RIGHT", 0, 0)
    root.seam:SetHeight(1)

    local guide = CreateFrame("Frame", nil, UIParent) -- the screen's centre line, while dragging
    guide:SetPoint("TOP", UIParent, "TOP", 0, 0)
    guide:SetPoint("BOTTOM", UIParent, "BOTTOM", 0, 0)
    guide:SetWidth(1)
    guide.line = guide:CreateTexture(nil, "OVERLAY")
    guide.line:SetAllPoints(guide)
    guide.line:SetColorTexture(0.2, 1, 0.4, 0.5)
    guide:Hide()
    root.guide = guide

    local tab = CreateFrame("Button", "AKForeverCombatTimersTab", root)
    tab:SetSize(52, 14)
    tab:SetPoint("RIGHT", root, "LEFT", -6, 0)
    tab.tint = tab:CreateTexture(nil, "BACKGROUND")
    tab.tint:SetAllPoints(tab)
    tab.tint:SetColorTexture(0.1, 0.4, 0.8, 0.55)
    tab.text = tab:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    tab.text:SetPoint("CENTER", tab, "CENTER", 0, 0)
    tab.text:SetText("timers")
    tab:RegisterForDrag("LeftButton")
    tab:SetScript("OnDragStart", function()
        if Settings:GetBlock("snapCenter") then
            guide:Show()
        end
        root:StartMoving()
    end)
    tab:SetScript("OnDragStop", function()
        root:StopMovingOrSizing()
        root:SetUserPlaced(false) -- position lives in our own saved variables
        guide:Hide()
        saveDraggedPosition()
    end)
    tab:SetScript("OnClick", function()
        if ns.Config then
            ns.Config:Toggle()
        end
    end)
    tab:SetScript("OnEnter", function(self)
        if GameTooltip then
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText("Drag: move the timers\nClick: settings\n/fct lock hides this tab")
            GameTooltip:Show()
        end
    end)
    tab:SetScript("OnLeave", function()
        if GameTooltip then
            GameTooltip:Hide()
        end
    end)
    -- A lock button under the tab. Unlocking is a typed command, but stopping should be a click:
    -- needing to remember "/fct lock" to put things back is how a block ends up left unlocked.
    local lock = CreateFrame("Button", "AKForeverCombatTimersLock", tab)
    lock:SetSize(52, 14)
    lock:SetPoint("TOP", tab, "BOTTOM", 0, -3)
    lock.tint = lock:CreateTexture(nil, "BACKGROUND")
    lock.tint:SetAllPoints(lock)
    lock.tint:SetColorTexture(0.75, 0.2, 0.2, 0.85)
    lock.text = lock:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lock.text:SetPoint("CENTER", lock, "CENTER", 0, 0)
    lock.text:SetText("lock")
    lock:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    lock:SetScript("OnClick", function()
        ns:SetOption("locked", true)
        ns:Print("locked. |cffffd100/fct unlock|r brings the drag tab back.")
    end)
    tab.lock = lock

    root.tab = tab

    for _, key in ipairs(Settings.KEYS) do
        local parent = Settings.GROUPS[key] == "enemy" and upper or lower
        bars[key] = SOURCES[key] and createTimedBar(key, parent) or createBar(key, parent)
    end

    Bars:Layout()
    Bars:ApplyPosition()
    applyLock()
    -- Once per character: a new character starts unlocked, and what that means is not obvious.
    if not ns:GetOption("locked") and not ns.cdb.lockHintShown then
        ns.cdb.lockHintShown = true
        ns:Print("the block is unlocked: drag the blue 'timers' tab to place it, click it for the settings. "
            .. "The red |cffffd100lock|r button under it hides the tab and the row marks - after that a "
            .. "bar only shows while something is happening. (|cffffd100/fct lock|r does the same.)")
    end

    local driver = CreateFrame("Frame") -- never hidden: a hidden block could not wake itself up
    driver:SetScript("OnUpdate", function()
        Bars:Update()
    end)
    Bars:Update()
end

ns:Listen("LOGIN", create)

ns:Listen("OPTION_CHANGED", function(_, key)
    if root and key == "locked" then
        applyLock()
    end
end)

-- The layout check is throttled (see LAYOUT_INTERVAL), so the things that really change WHICH bars
-- belong on the block say so instead of being polled for: a weapon on or off, an aura coming or going,
-- and walking into the world. Clearing the signature is the "look again now" flag.
local function invalidate()
    layoutSignature = nil
end

ns:On("PLAYER_EQUIPMENT_CHANGED", invalidate)
ns:On("PLAYER_ENTERING_WORLD", invalidate)
ns:OnPlayerUnit("UNIT_AURA", invalidate)
ns:OnPlayerUnit("UNIT_ATTACK_SPEED", invalidate) -- an off hand put away changes the speeds, not the slot
ns:On("PLAYER_SWING", invalidate) -- something thrown earns the ranged row a place at once

ns:Listen("BARS_CHANGED", function()
    if root then
        layoutSignature = nil
        Bars:Layout()
        Bars:ApplyPosition()
    end
end)

function Bars:StartTest(seconds)
    testUntil = GetTime() + (seconds or 15)
end

ns:RegisterCommand("lock", "hide the drag tab and the row marks", function()
    ns:SetOption("locked", true)
    ns:Print("locked. /fct unlock brings the drag tab back.")
end)

ns:RegisterCommand("unlock", "show the drag tab (drag it to move the block, click it for the settings)", function()
    ns:SetOption("locked", false)
    Bars:StartTest()
    ns:Print("unlocked - drag the blue 'timers' tab, click it for settings. Test bars for 15 seconds.")
end)

ns:RegisterCommand("test", "show moving test bars for 15 seconds", function()
    Bars:StartTest()
end)

ns:RegisterCommand("center", "centre the block horizontally on the screen", function()
    Bars:CenterHorizontally()
    ns:Print("centred.")
end)

ns:RegisterCommand("reset", "move the block back to the default position", function()
    ns.cdb.position = nil
    Bars:ApplyPosition()
end)
