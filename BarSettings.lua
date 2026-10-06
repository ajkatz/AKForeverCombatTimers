-- BarSettings: what each bar of the block should do - kept per character.
--
--   per bar   mode    "always" | "used" (while in use, and `after` seconds longer) | "never"
--             after   seconds a "used" bar stays once it is no longer in use
--             width, height
--   block     order   the bars top to bottom. The block has two halves around a SEAM that never
--                     moves: the enemy's bars (target cast, incoming hit) grow UP from it, yours
--                     (main hand, off hand, ranged, your cast) grow DOWN. Bars are reordered
--                     within their half.
--             grow    "down" (the seam is pinned: yours hang under it, the enemy's stack above it) | "up"
--                     (the FLOOR is pinned: the same order, but the bottom of your half sits on the anchor
--                     and rows that come push the seam and the enemy's half up - nothing of yours ever
--                     reaches below the line you set)
--             reverse false | true: the block the other way up - yours stack UP from the seam, your cast
--                     bar on top, the enemy's hang below. Independent of grow: what is pinned is one
--                     question, which way the picture reads is another
--             anchor  LEFT | CENTER | RIGHT: which point of the seam is pinned to the screen - and
--                     how bars of different widths line up
--             fade    bars fade in and out instead of popping
--             snapCenter  a block dropped near the screen's centre line snaps onto it
--
-- A bar that is "never", or does not apply to the character (no off-hand weapon), takes no row.
-- Every other bar keeps its row while idle, so nothing ever jumps.
local _, ns = ...

local BarSettings = {}
ns.BarSettings = BarSettings

BarSettings.KEYS = { "TCAST", "ENEMY", "MH", "OH", "RG", "BUFF",
    "DOT1", "DOT2", "DOT3", "DOT4", "REACT1", "REACT2", "REACT3", "PLAINS", "CAST" }
BarSettings.LABELS = {
    TCAST = "Target cast", ENEMY = "Incoming hit", MH = "Main hand", OH = "Off hand", RG = "Ranged",
    BUFF = "Buff", PLAINS = "Plainsrunning", CAST = "Your cast",
    -- only ever seen on an empty row: an active one wears the spell's own name
    DOT1 = "DoT 1", DOT2 = "DoT 2", DOT3 = "DoT 3", DOT4 = "DoT 4",
    REACT1 = "Reactive 1", REACT2 = "Reactive 2", REACT3 = "Reactive 3",
}
BarSettings.MODES = { "always", "used", "never" }
BarSettings.MODE_LABELS = { always = "Always", used = "When used", never = "Never" }
BarSettings.ANCHORS = { "LEFT", "CENTER", "RIGHT" }
BarSettings.GROWS = { "down", "up" }
-- A DoT lands on THEM, but it is your spell and your business to keep up - so it belongs with your own
-- bars rather than with the two things the enemy is doing to you.
BarSettings.GROUPS = { TCAST = "enemy", ENEMY = "enemy", MH = "own", OH = "own", RG = "own", BUFF = "own",
    DOT1 = "own", DOT2 = "own", DOT3 = "own", DOT4 = "own",
    REACT1 = "own", REACT2 = "own", REACT3 = "own",
    PLAINS = "own", CAST = "own" }

local BAR_DEFAULTS = { mode = "used", after = 3, width = 220, height = 14 }
local BAR_OVERRIDES = {
    TCAST = { after = 0 },
    CAST = { after = 0 },
    BUFF = { after = 0 },
    PLAINS = { after = 0 }, -- Plainsrunning is a ramp, not a timer: there while the buff is, gone with it

    -- a DoT that has run out is worth a moment's glance, but not a lingering row
    DOT1 = { after = 1 }, DOT2 = { after = 1 }, DOT3 = { after = 1 }, DOT4 = { after = 1 },
    -- a window that closed is over: the ability is gone from the bar the moment it is gone from you
    REACT1 = { after = 0 }, REACT2 = { after = 0 }, REACT3 = { after = 0 },

    RG = { after = 10 }, -- a melee class that threw something: keep it up for a while
}
local BLOCK_DEFAULTS = { anchor = "CENTER", fade = true, snapCenter = true, grow = "down", reverse = false }
local LIMITS = { after = { 0, 60 }, width = { 60, 600 }, height = { 6, 60 } }

local ALIASES = {
    tcast = "TCAST", target = "TCAST", targetcast = "TCAST",
    enemy = "ENEMY", incoming = "ENEMY", hit = "ENEMY",
    mh = "MH", main = "MH", mainhand = "MH",
    oh = "OH", off = "OH", offhand = "OH",
    rg = "RG", ranged = "RG", range = "RG",
    cast = "CAST", mycast = "CAST", player = "CAST",
    buff = "BUFF", snd = "BUFF",
    plains = "PLAINS", plainsrunning = "PLAINS", run = "PLAINS", speed = "PLAINS",
    dot = "DOT1", dot1 = "DOT1", dot2 = "DOT2", dot3 = "DOT3", dot4 = "DOT4",
    react = "REACT1", react1 = "REACT1", react2 = "REACT2", react3 = "REACT3", reactive = "REACT1",
}

local isKey, isMode, isAnchor = {}, {}, {}
for _, key in ipairs(BarSettings.KEYS) do isKey[key] = true end
for _, mode in ipairs(BarSettings.MODES) do isMode[mode] = true end
for _, anchor in ipairs(BarSettings.ANCHORS) do isAnchor[anchor] = true end

local function store()
    ns.cdb.bars = ns.cdb.bars or {}
    return ns.cdb.bars
end

local function changed()
    ns:Fire("BARS_CHANGED")
end

-- "mh", "Off", "RANGED" ... -> "MH", "OH", "RG"
function BarSettings:Resolve(name)
    name = string.lower(tostring(name or ""))
    return ALIASES[name] or (isKey[string.upper(name)] and string.upper(name)) or nil
end

------------------------------------------------------------------------
-- Per bar
------------------------------------------------------------------------
function BarSettings:Get(key, field)
    local saved = ns.cdb and ns.cdb.bars and ns.cdb.bars[key]
    local value = type(saved) == "table" and saved[field] or nil
    if value == nil then
        value = BAR_OVERRIDES[key] and BAR_OVERRIDES[key][field]
    end
    if value == nil then
        value = BAR_DEFAULTS[field]
    end
    return value
end

function BarSettings:GetMode(key)
    return self:Get(key, "mode")
end

function BarSettings:Set(key, field, value)
    if not isKey[key] then
        return false
    end
    if field == "mode" then
        if not isMode[value] then
            return false
        end
    else
        local limits = LIMITS[field]
        value = tonumber(value)
        if not limits or not value then
            return false
        end
        value = math.max(limits[1], math.min(limits[2], math.floor(value + 0.5)))
    end
    local bars = store()
    bars[key] = type(bars[key]) == "table" and bars[key] or {}
    if bars[key][field] == value then
        return true
    end
    bars[key][field] = value
    changed()
    return true
end

function BarSettings:CycleMode(key)
    local current = self:GetMode(key)
    for index, mode in ipairs(self.MODES) do
        if mode == current then
            return self:Set(key, "mode", self.MODES[index % #self.MODES + 1])
        end
    end
    return self:Set(key, "mode", "used")
end

------------------------------------------------------------------------
-- The block
------------------------------------------------------------------------
function BarSettings:GetOrder()
    local saved = ns.cdb and ns.cdb.bars and ns.cdb.bars.order
    local order, seen = {}, {}
    if type(saved) == "table" then
        for _, key in ipairs(saved) do
            if isKey[key] and not seen[key] then
                order[#order + 1], seen[key] = key, true
            end
        end
    end
    for _, key in ipairs(self.KEYS) do -- anything a saved order does not mention keeps its usual place at the end
        if not seen[key] then
            order[#order + 1] = key
        end
    end
    local halves = {} -- top to bottom: the enemy's half, then yours
    for _, group in ipairs({ "enemy", "own" }) do
        for _, key in ipairs(order) do
            if self.GROUPS[key] == group then
                halves[#halves + 1] = key
            end
        end
    end
    return halves
end

function BarSettings:SetOrder(keys)
    local order, seen = {}, {}
    for _, key in ipairs(keys) do
        if isKey[key] and not seen[key] then
            order[#order + 1], seen[key] = key, true
        end
    end
    if #order == 0 then
        return false
    end
    store().order = order
    store().order = self:GetOrder() -- completed with the bars that were not named
    changed()
    return true
end

-- delta: -1 = one row up, +1 = one row down. Bars move within their half, and past bars that have no
-- row right now (off hand without an off-hand weapon, a buff bar that tracks nothing): one click is one
-- visible step.
function BarSettings:Move(key, delta)
    local order = self:GetOrder()
    local hasRow = ns.Bars and ns.Bars.HasRow
    for index, candidate in ipairs(order) do
        if candidate == key then
            local target = index + delta
            while order[target] and self.GROUPS[order[target]] == self.GROUPS[key]
                and hasRow and not hasRow(order[target]) do
                target = target + delta
            end
            if not order[target] or self.GROUPS[order[target]] ~= self.GROUPS[key] then
                return false
            end
            table.remove(order, index)
            table.insert(order, target, key)
            store().order = order
            changed()
            return true
        end
    end
    return false
end

function BarSettings:GetBlock(field)
    local saved = ns.cdb and ns.cdb.bars
    if type(saved) == "table" and saved[field] ~= nil then
        return saved[field] -- (`false` is a real answer for fade / snapCenter)
    end
    return BLOCK_DEFAULTS[field]
end

function BarSettings:SetBlock(field, value)
    if field == "anchor" then
        value = string.upper(tostring(value or ""))
        if not isAnchor[value] then
            return false
        end
    elseif field == "fade" or field == "snapCenter" or field == "reverse" then
        value = value and true or false
    elseif field == "grow" then
        value = string.lower(tostring(value or ""))
        if value ~= "down" and value ~= "up" then
            return false
        end
    else
        return false
    end
    if self:GetBlock(field) == value then
        return true
    end
    store()[field] = value
    changed()
    return true
end

function BarSettings:Reset()
    ns.cdb.bars = nil
    changed()
end

------------------------------------------------------------------------
-- The switches this replaces (showEnemy, castPlayer, castTarget, visibility): carried over once.
------------------------------------------------------------------------
ns:Listen("DB_READY", function()
    local options = ns.cdb.options
    if type(options) ~= "table" then
        return
    end
    local function never(option, key)
        if options[option] == false then
            BarSettings:Set(key, "mode", "never")
        end
        options[option] = nil
    end
    never("showEnemy", "ENEMY")
    never("castPlayer", "CAST")
    never("castTarget", "TCAST")
    if options.visibility == "always" then
        for _, key in ipairs(BarSettings.KEYS) do
            if BarSettings:GetMode(key) ~= "never" then
                BarSettings:Set(key, "mode", "always")
            end
        end
    end
    options.visibility = nil
end)

------------------------------------------------------------------------
-- Slash commands (the settings panel, UI/Config.lua, calls the same functions)
------------------------------------------------------------------------
local function describe(key)
    local mode = BarSettings:GetMode(key)
    local text = BarSettings.LABELS[key] .. ": " .. BarSettings.MODE_LABELS[mode]
    if mode == "used" then
        text = text .. " +" .. BarSettings:Get(key, "after") .. "s"
    end
    return text .. ", " .. BarSettings:Get(key, "width") .. "x" .. BarSettings:Get(key, "height")
end

ns:RegisterCommand("bar", "'/fct bar mh always|used|never [seconds]', '... after 5', '... width 260', '... height 18', '... up|down'; '/fct bar' lists, '/fct bar reset'", function(rest)
    local name, what, value = string.match(string.lower(rest or ""), "^(%S*)%s*(%S*)%s*(%S*)$")
    if name == "reset" then
        BarSettings:Reset()
        ns:Print("bars back to their defaults.")
        return
    end
    local key = BarSettings:Resolve(name)
    if not key then
        ns:Print("bars, top to bottom (names: tcast, enemy, mh, oh, rg, buff, cast):")
        for _, each in ipairs(BarSettings:GetOrder()) do
            print("   " .. describe(each))
        end
        return
    end
    local ok = true
    if what == "always" or what == "used" or what == "never" then
        ok = BarSettings:Set(key, "mode", what)
        if ok and what == "used" and value ~= "" then
            ok = BarSettings:Set(key, "after", value)
        end
    elseif what == "after" or what == "width" or what == "height" then
        ok = BarSettings:Set(key, what, value)
    elseif what == "up" or what == "down" then
        ok = BarSettings:Move(key, what == "up" and -1 or 1)
        if not ok then
            ns:Print(BarSettings.LABELS[key], "is already at that end of its half (enemy bars stay above the seam, yours below).")
            return
        end
    elseif what ~= "" then
        ok = false
    end
    ns:Print(ok and describe(key) or "usage: /fct bar <name> always | used [seconds] | never | after N | width N | height N | up | down")
end)

ns:RegisterCommand("order", "the bars top to bottom, e.g. '/fct order tcast enemy cast mh oh rg buff' (each stays in its half)", function(rest)
    local keys = {}
    for word in string.gmatch(rest or "", "%S+") do
        keys[#keys + 1] = BarSettings:Resolve(word)
    end
    if #keys > 0 then
        BarSettings:SetOrder(keys)
    end
    local labels = {}
    for index, key in ipairs(BarSettings:GetOrder()) do
        labels[index] = BarSettings.LABELS[key]
    end
    ns:Print("top to bottom:", table.concat(labels, " | "))
end)

ns:RegisterCommand("fade", "'on' (default) or 'off': bars fade in and out instead of popping", function(rest)
    local mode = string.lower(rest or "")
    if mode == "on" or mode == "off" then
        BarSettings:SetBlock("fade", mode == "on")
    end
    ns:Print("fading:", BarSettings:GetBlock("fade") and "on" or "off")
end)

ns:RegisterCommand("reverse", "'off' (default) or 'on': the block the other way up - your bars stack up from the seam with your cast bar on top, the enemy's hang below", function(rest)
    local mode = string.lower(rest or "")
    if mode == "on" or mode == "off" then
        BarSettings:SetBlock("reverse", mode == "on")
    end
    ns:Print("reverse:", BarSettings:GetBlock("reverse") and "on - yours stack up from the seam, the enemy's hang below" or "off - the enemy's above the seam, yours below")
end)

ns:RegisterCommand("anchor", "'left', 'center' or 'right': which point of the seam is pinned, and how bars of different widths line up", function(rest)
    if rest and rest ~= "" and not BarSettings:SetBlock("anchor", rest == "centre" and "center" or rest) then
        ns:Print("usage: /fct anchor left | center | right")
        return
    end
    ns:Print("anchor:", string.lower(BarSettings:GetBlock("anchor")))
end)

ns:RegisterCommand("grow", "'down' (default): the seam is pinned - your bars hang under it, the enemy's stack above it; 'up': the floor is pinned - the same order, but the bottom of your bars sits where you put the block and rows that come push everything up", function(rest)
    if rest and rest ~= "" and not BarSettings:SetBlock("grow", rest) then
        ns:Print("usage: /fct grow down | up")
        return
    end
    ns:Print("grow:", BarSettings:GetBlock("grow"), BarSettings:GetBlock("grow") == "up" and "- the floor is pinned: the block grows up from the bottom of your bars" or "- the seam is pinned: your bars hang under it")
end)

ns:RegisterCommand("snap", "'on' (default) or 'off': a block dropped near the screen's centre line snaps onto it", function(rest)
    local mode = string.lower(rest or "")
    if mode == "on" or mode == "off" then
        BarSettings:SetBlock("snapCenter", mode == "on")
    end
    ns:Print("snap to centre:", BarSettings:GetBlock("snapCenter") and "on" or "off")
end)

-- The switches from before v0.3.5 keep working: they set modes now.
ns:RegisterCommand("show", "'always' or 'used': every bar that is not switched off (older: 'combat' = used)", function(rest)
    local mode = string.lower(rest or "")
    mode = mode == "combat" and "used" or mode
    if mode ~= "always" and mode ~= "used" then
        ns:Print("usage: /fct show always | used   - or per bar: /fct bar mh always")
        return
    end
    for _, key in ipairs(BarSettings.KEYS) do
        if BarSettings:GetMode(key) ~= "never" then
            BarSettings:Set(key, "mode", mode)
        end
    end
    ns:Print("all bars:", BarSettings.MODE_LABELS[mode])
end)

ns:RegisterCommand("enemy", "toggle the incoming-hit bar", function()
    BarSettings:Set("ENEMY", "mode", BarSettings:GetMode("ENEMY") == "never" and "used" or "never")
    ns:Print("incoming-hit bar:", BarSettings.MODE_LABELS[BarSettings:GetMode("ENEMY")])
end)
