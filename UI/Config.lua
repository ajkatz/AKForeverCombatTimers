-- Config: the settings window ('/fct config', or click the blue 'timers' tab while unlocked).
-- One line per bar - order, when it shows, how long it lingers, its size - and the block's own
-- settings underneath. Everything here only calls BarSettings / Bars; the slash commands do the same.
local _, ns = ...

local Settings, Bars = ns.BarSettings, ns.Bars

local Config = {}
ns.Config = Config

local ROW_HEIGHT, PAD, WIDTH = 22, 12, 470
local panel
local rows = {} -- [key] = row

local function button(parent, text, width, onClick)
    local widget = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    widget:SetSize(width, 18)
    widget:SetText(text)
    widget:SetScript("OnClick", function()
        ns.SafeCall(onClick)
    end)
    return widget
end

-- [-] value [+]
local function stepper(parent, width, read, write, step)
    local group = CreateFrame("Frame", nil, parent)
    group:SetSize(width, 18)
    group.minus = button(group, "-", 18, function() write(read() - step) end)
    group.minus:SetPoint("LEFT", group, "LEFT", 0, 0)
    group.plus = button(group, "+", 18, function() write(read() + step) end)
    group.plus:SetPoint("RIGHT", group, "RIGHT", 0, 0)
    group.value = group:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    group.value:SetPoint("CENTER", group, "CENTER", 0, 0)
    return group
end

local function createRow(key)
    local row = CreateFrame("Frame", nil, panel)
    row:SetSize(WIDTH - PAD * 2, ROW_HEIGHT)
    row.up = button(row, "^", 18, function() Settings:Move(key, -1) end)
    row.up:SetPoint("LEFT", row, "LEFT", 0, 0)
    row.down = button(row, "v", 18, function() Settings:Move(key, 1) end)
    row.down:SetPoint("LEFT", row.up, "RIGHT", 2, 0)
    row.label = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.label:SetPoint("LEFT", row.down, "RIGHT", 6, 0)
    row.label:SetWidth(84)
    row.label:SetJustifyH("LEFT")
    row.mode = button(row, "", 82, function() Settings:CycleMode(key) end)
    row.mode:SetPoint("LEFT", row.label, "RIGHT", 4, 0)
    row.after = stepper(row, 66, function() return Settings:Get(key, "after") end,
        function(value) Settings:Set(key, "after", value) end, 1)
    row.after:SetPoint("LEFT", row.mode, "RIGHT", 8, 0)
    row.width = stepper(row, 72, function() return Settings:Get(key, "width") end,
        function(value) Settings:Set(key, "width", value) end, 10)
    row.width:SetPoint("LEFT", row.after, "RIGHT", 8, 0)
    row.height = stepper(row, 62, function() return Settings:Get(key, "height") end,
        function(value) Settings:Set(key, "height", value) end, 1)
    row.height:SetPoint("LEFT", row.width, "RIGHT", 8, 0)
    return row
end

function Config:Refresh()
    if not panel or not panel:IsShown() then
        return
    end
    local y = -(PAD + 34)
    local lastGroup
    for _, key in ipairs(Settings:GetOrder()) do
        local row = rows[key]
        local group = Settings.GROUPS[key]
        if lastGroup and group ~= lastGroup then
            panel.seam:ClearAllPoints()
            panel.seam:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD, y - 3)
            panel.seam:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -PAD, y - 3)
            y = y - 8 -- the seam: enemy bars above it grow up, yours below it grow down
        end
        lastGroup = group
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD, y)
        y = y - ROW_HEIGHT

        local mode = Settings:GetMode(key)
        local label = Settings.LABELS[key]
        if key == "BUFF" and ns.Buffs then
            local tracked = ns.Buffs:GetTracked()
            label = #tracked > 0 and tracked[1] or "Buff (none)"
        end
        row.label:SetText(label)
        row.mode:SetText(Settings.MODE_LABELS[mode])
        row.after.value:SetText(mode == "used" and ("+" .. Settings:Get(key, "after") .. "s") or "-")
        row.after:SetAlpha(mode == "used" and 1 or 0.35)
        row.width.value:SetText(Settings:Get(key, "width"))
        row.height.value:SetText(Settings:Get(key, "height"))
    end
    panel.anchor:SetText("Align: " .. string.lower(Settings:GetBlock("anchor")))
    panel.fade:SetText("Fade: " .. (Settings:GetBlock("fade") and "on" or "off"))
    panel.snap:SetText("Snap: " .. (Settings:GetBlock("snapCenter") and "on" or "off"))
    panel.lock:SetText(ns:GetOption("locked") and "Unlock" or "Lock")
    panel:SetHeight(-y + PAD + 52)
end

local function create()
    panel = CreateFrame("Frame", "AKForeverCombatTimersConfig", UIParent, "BackdropTemplate")
    panel:SetSize(WIDTH, 300)
    panel:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
    panel:SetFrameStrata("DIALOG")
    panel:EnableMouse(true)
    panel:SetMovable(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", panel.StartMoving)
    panel:SetScript("OnDragStop", panel.StopMovingOrSizing)
    if panel.SetBackdrop then
        panel:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 } })
        panel:SetBackdropColor(0, 0, 0, 0.92)
    end
    table.insert(UISpecialFrames, "AKForeverCombatTimersConfig") -- Escape closes it

    panel.title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    panel.title:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD, -PAD)
    panel.title:SetText("Combat timers")
    panel.header = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    panel.header:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD, -(PAD + 18))
    panel.header:SetText("order        bar                      shows                  lingers          width            height")

    panel.seam = panel:CreateTexture(nil, "ARTWORK")
    panel.seam:SetColorTexture(0.55, 0.78, 1, 0.6)
    panel.seam:SetHeight(1)

    for _, key in ipairs(Settings.KEYS) do
        rows[key] = createRow(key)
    end

    local function footer(text, width, onClick, anchorTo, x)
        local widget = button(panel, text, width, onClick)
        if anchorTo then
            widget:SetPoint("LEFT", anchorTo, "RIGHT", x or 4, 0)
        end
        return widget
    end
    panel.anchor = footer("", 92, function()
        local anchors = Settings.ANCHORS
        for index, anchor in ipairs(anchors) do
            if anchor == Settings:GetBlock("anchor") then
                Settings:SetBlock("anchor", anchors[index % #anchors + 1])
                return
            end
        end
    end)
    panel.anchor:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", PAD, PAD + 22)
    panel.center = footer("Centre on screen", 112, function() Bars:CenterHorizontally() end, panel.anchor)
    panel.snap = footer("", 74, function() Settings:SetBlock("snapCenter", not Settings:GetBlock("snapCenter")) end, panel.center)
    panel.fade = footer("", 74, function() Settings:SetBlock("fade", not Settings:GetBlock("fade")) end, panel.snap)

    panel.lock = footer("", 70, function() ns:SetOption("locked", not ns:GetOption("locked")) end)
    panel.lock:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", PAD, PAD)
    panel.test = footer("Test bars", 80, function() Bars:StartTest() end, panel.lock)
    panel.reset = footer("Reset bars", 84, function() Settings:Reset() end, panel.test)
    panel.close = footer("Close", 64, function() panel:Hide() end)
    panel.close:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -PAD, PAD)
    panel:Hide()
end

function Config:Toggle()
    if not panel then
        create()
    end
    panel:SetShown(not panel:IsShown())
    self:Refresh()
end

ns:Listen("BARS_CHANGED", function()
    Config:Refresh()
end)

ns:Listen("OPTION_CHANGED", function()
    Config:Refresh()
end)

ns:RegisterCommand("config", "open / close the settings window (order, when each bar shows, sizes, alignment, fading)", function()
    Config:Toggle()
end)
