-- Minimal, deliberately strict stand-in for the WoW client so the addon's logic
-- can run under a plain Lua interpreter. (Same design as the WeaponBuffs mock.)
--
--  * Widgets only answer to real widget API method names: a typo surfaces as
--    "attempt to call a nil value".
--  * Protected frames are modelled: touching one in combat raises an error.
--  * Time and timers are manual: Mock.advance(seconds).
--
-- Not loaded by the game (not in the .toc).
local Mock = {}

local REAL_PRINT = print
local ADDON = "AKForeverCombatTimers"

local WIDGET_METHODS = {
    "SetSize", "SetWidth", "SetHeight", "GetWidth", "GetHeight", "SetPoint", "ClearAllPoints", "SetAllPoints",
    "GetPoint", "Show", "Hide", "IsShown", "IsVisible", "SetShown", "SetAlpha", "GetAlpha", "SetParent", "GetParent",
    -- a Button has a highlight; a mock without one turns "this client is missing a method" into
    -- "every bar is nil", which is a long way from the cause
    "SetHighlightTexture", "SetNormalTexture", "SetPushedTexture", "RegisterForClicks", "Click",
    "SetMovable", "SetClampedToScreen", "SetClampRectInsets", "EnableMouse", "RegisterForDrag", "StartMoving",
    "StopMovingOrSizing", "SetUserPlaced", "SetFrameLevel", "GetFrameLevel", "SetFrameStrata", "SetScript",
    "GetScript", "HookScript", "RegisterEvent", "RegisterUnitEvent", "UnregisterEvent", "CreateTexture",
    "CreateFontString", "SetAttribute", "GetAttribute", "RegisterForClicks",
    "SetTexture", "SetTexCoord", "SetColorTexture", "SetDesaturated", "SetBlendMode", "SetVertexColor",
    "SetText", "GetText", "SetTextColor", "SetJustifyH", "SetJustifyV", "SetWordWrap", "SetFont", "GetFont",
    -- cast bars
    "SetStatusBarTexture", "SetStatusBarColor", "SetMinMaxValues", "SetValue", "SetTimerDuration",
    "UnregisterAllEvents", "IsEventRegistered", "GetName", "SetScale", "GetScale",
    -- the block's seam, the drag tab, the settings window
    "GetLeft", "GetRight", "GetTop", "GetBottom", "GetCenter", "SetBackdrop", "SetBackdropColor", "SetBackdropBorderColor",
}

local PROTECTED_METHODS = {
    SetSize = true, SetWidth = true, SetHeight = true, SetPoint = true, ClearAllPoints = true, SetAllPoints = true,
    Show = true, Hide = true, SetShown = true, SetParent = true, SetAttribute = true, EnableMouse = true,
    StartMoving = true, SetMovable = true,
}

local SECURE_TEMPLATES = { SecureActionButtonTemplate = true }

------------------------------------------------------------------------
-- Widgets
------------------------------------------------------------------------
local function isProtected(widget)
    return widget.__protected or widget.__implicitlyProtected
end

local implementations = {}

function implementations.SetScript(self, name, fn) self.__scripts[name] = fn end
function implementations.GetScript(self, name) return self.__scripts[name] end
function implementations.RegisterEvent(self, event)
    if Mock.unknownEvents[event] then
        error("Attempt to register unknown event \"" .. event .. "\"")
    end
    -- Like the Forever client: some events are reserved for Blizzard's UI. The
    -- call does not error (pcall sees nothing) - it is refused, and the client
    -- raises ADDON_ACTION_FORBIDDEN plus a dialog blaming the addon.
    if Mock.forbiddenEvents[event] then
        Mock.forbiddenCalls[#Mock.forbiddenCalls + 1] = "RegisterEvent(" .. event .. ")"
        Mock.fire("ADDON_ACTION_FORBIDDEN", ADDON, "Frame:RegisterEvent()")
        return
    end
    self.__events[event] = true
end
function implementations.RegisterUnitEvent(self, event, unit) self.__unitEvents[event] = unit end
function implementations.UnregisterEvent(self, event) self.__events[event] = nil; self.__unitEvents[event] = nil end
-- Measured in the game (2026-09-19): on BLIZZARD's cast bars a "ConstSecretAccessor" such as
-- IsEventRegistered answers addon code with a SECRET boolean - and an `if` on a secret is an error.
-- UnregisterAllEvents on them is tied to the undocumented "forbidden aspects" model: house rule, never.
function implementations.UnregisterAllEvents(self)
    if self.__blizzard then
        Mock.forbiddenCalls[#Mock.forbiddenCalls + 1] = "UnregisterAllEvents() on Blizzard's " .. tostring(self.__name)
            .. " (forbidden-aspect model: park it with SetParent instead)"
        return
    end
    self.__events, self.__unitEvents = {}, {}
end
function implementations.IsEventRegistered(self, event)
    if self.__blizzard then
        return Mock.SECRET
    end
    return (self.__events[event] or self.__unitEvents[event]) and true or false
end
-- Measured in the game (2026-09-19, "TargetFrame.lua:824: attempt to call a nil value"): Blizzard's
-- TargetSpellBarMixin:AdjustPosition() calls methods on self:GetParent() at every aura change, so
-- that bar must never be given another parent.
function implementations.SetParent(self, parent)
    if self.__keepParent and parent ~= self.__parent then
        Mock.forbiddenCalls[#Mock.forbiddenCalls + 1] = "SetParent() on Blizzard's " .. tostring(self.__name)
            .. " (its own code calls methods on GetParent(): hide it another way)"
        return
    end
    self.__parent = parent
end
function implementations.GetName(self) return self.__name end
function implementations.SetScale(self, scale)
    assert(type(scale) == "number" and scale > 0, "SetScale: scale must be > 0")
    self.__scale = scale
end
function implementations.GetScale(self) return self.__scale or 1 end

-- Widgets that take a value for DISPLAY accept a secret (API docs: "SecretArguments =
-- AllowedWhenTainted"): FontString:SetText, Texture:SetTexture, StatusBar:SetMinMaxValues / SetValue.
-- The tests can make the client stricter than its documentation.
local function refuseIfStrict(what, ...)
    if Mock.state.widgetsRefuseSecrets then
        for i = 1, select("#", ...) do
            local value = (select(i, ...))
            if value == Mock.SECRET or (type(value) == "table" and rawget(value, "__secretObject")) then
                error(what .. ": secret values are not allowed")
            end
        end
    end
end
function implementations.SetTexture(self, texture)
    refuseIfStrict("SetTexture", texture)
    self.__texture = texture
end
function implementations.SetMinMaxValues(self, low, high)
    refuseIfStrict("SetMinMaxValues", low, high)
    self.__min, self.__max, self.__timer = low, high, nil
end
function implementations.SetValue(self, value)
    refuseIfStrict("SetValue", value)
    self.__value = value
end
-- StatusBar:SetTimerDuration is documented "AllowedWhenUntainted": whether an addon may hand it a
-- duration object that carries secret times is exactly what is unknown - the tests cover both answers.
function implementations.SetTimerDuration(self, duration, interpolation, direction)
    if type(duration) ~= "table" or not duration.__durationObject then
        error("SetTimerDuration: expected a LuaDurationObject")
    end
    if Mock.state.timerRefusesAddons then
        error("SetTimerDuration: secret values are only allowed from untainted code")
    end
    self.__timer = { duration = duration, direction = direction }
end
function implementations.SetAttribute(self, key, value) self.__attributes[key] = value end
function implementations.GetAttribute(self, key) return self.__attributes[key] end
function implementations.Show(self) self.__shown = true end
function implementations.Hide(self) self.__shown = false end
function implementations.SetShown(self, shown) self.__shown = shown and true or false end
function implementations.IsShown(self) return self.__shown end
-- IsShown is this frame's own flag; IsVisible also needs every ancestor shown, which is what the real
-- client means by it. A mock that treats them as the same can call a frame visible inside a hidden
-- parent, and then a bar that never appears looks fine in the tests.
function implementations.IsVisible(self)
    local frame = self
    while frame do
        if not frame.__shown then
            return false
        end
        frame = frame.__parent
    end
    return true
end
function implementations.GetParent(self) return self.__parent end
function implementations.SetText(self, text)
    refuseIfStrict("SetText", text)
    self.__text = text
end
function implementations.GetText(self) return self.__text end
function implementations.SetAlpha(self, alpha) self.__alpha = alpha end
function implementations.GetAlpha(self) return self.__alpha or 1 end
function implementations.SetSize(self, width, height) self.__width, self.__height = width, height end
function implementations.SetWidth(self, width) self.__width = width end
function implementations.SetHeight(self, height) self.__height = height end
function implementations.GetWidth(self) return self.__width or 0 end
function implementations.GetHeight(self) return self.__height or 0 end
function implementations.EnableMouse(self, enabled) self.__mouse = enabled and true or false end
function implementations.GetFont() return "Fonts\\FRIZQT__.TTF", 12, "" end
function implementations.ClearAllPoints(self) self.__points = {} end
function implementations.GetPoint(self, index)
    local point = self.__points[index or 1]
    if not point then
        return "CENTER", nil, "CENTER", 0, 0
    end
    return point[1], point[2], point[3], point[4], point[5]
end

local function anchorTo(self, target)
    if type(target) == "table" and isProtected(self) then
        target.__implicitlyProtected = true
    end
end

function implementations.SetPoint(self, point, relativeTo, relativePoint, x, y)
    if type(relativeTo) ~= "table" then
        relativeTo, relativePoint, x, y = nil, point, relativeTo, relativePoint
    end
    anchorTo(self, relativeTo)
    self.__points[#self.__points + 1] = { point, relativeTo, relativePoint, x or 0, y or 0 }
end

function implementations.SetAllPoints(self, target)
    anchorTo(self, target or self.__parent)
end

local function fractions(point)
    point = point or "CENTER"
    return (point:find("LEFT") and 0) or (point:find("RIGHT") and 1) or 0.5,
        (point:find("BOTTOM") and 0) or (point:find("TOP") and 1) or 0.5
end

-- left, bottom, width, height
local function rectOf(frame)
    if frame == _G.UIParent then
        return 0, 0, 1024, 768
    end
    local anchor = frame.__points[1]
    if not anchor then
        return nil
    end
    local left, bottom, width, height = rectOf(anchor[2] or _G.UIParent)
    if not left then
        return nil
    end
    local fx, fy = fractions(anchor[1])
    local rx, ry = fractions(anchor[3] or anchor[1])
    local w, h = frame.__width or 0, frame.__height or 0
    return left + rx * width + anchor[4] - fx * w, bottom + ry * height + anchor[5] - fy * h, w, h
end
function implementations.GetLeft(self) return (rectOf(self)) end
function implementations.GetRight(self)
    local left, _, width = rectOf(self)
    return left and left + width
end
function implementations.GetBottom(self)
    local _, bottom = rectOf(self)
    return bottom
end
function implementations.GetTop(self)
    local _, bottom, _, height = rectOf(self)
    return bottom and bottom + height
end
function implementations.GetCenter(self)
    local left, bottom, width, height = rectOf(self)
    if left then
        return left + width / 2, bottom + height / 2
    end
end

local newWidget

function implementations.CreateTexture(self) return newWidget("Texture", nil, self) end
function implementations.CreateFontString(self) return newWidget("FontString", nil, self) end

local function noop() end

local methodTable = {}
for _, name in ipairs(WIDGET_METHODS) do
    local implementation = implementations[name] or noop
    if PROTECTED_METHODS[name] then
        methodTable[name] = function(self, ...)
            if Mock.state.inCombat and isProtected(self) then
                error("ADDON_ACTION_BLOCKED: " .. name .. "() on protected frame in combat", 2)
            end
            return implementation(self, ...)
        end
    else
        methodTable[name] = implementation
    end
end

local widgetMeta = { __index = methodTable }

function newWidget(kind, name, parent, template)
    local widget = setmetatable({
        __kind = kind, __name = name, __parent = parent, __scripts = {}, __events = {}, __unitEvents = {},
        __attributes = {}, __points = {}, __shown = true,
    }, widgetMeta)
    if template and SECURE_TEMPLATES[template] then
        widget.__protected = true
        if parent then
            parent.__implicitlyProtected = true
        end
    end
    return widget
end

------------------------------------------------------------------------
-- Time and events
------------------------------------------------------------------------
function Mock.advance(seconds)
    local target = Mock.now + seconds
    while true do
        local nextIndex, nextTimer
        for index, timer in ipairs(Mock.timers) do
            if timer.at <= target and (not nextTimer or timer.at < nextTimer.at) then
                nextIndex, nextTimer = index, timer
            end
        end
        if not nextTimer then
            break
        end
        Mock.now = math.max(Mock.now, nextTimer.at)
        if nextTimer.every then
            nextTimer.at = nextTimer.at + nextTimer.every
        else
            table.remove(Mock.timers, nextIndex)
        end
        nextTimer.fn()
    end
    Mock.now = target
end

function Mock.fire(event, ...)
    local frames = {}
    for i, frame in ipairs(Mock.frames) do
        frames[i] = frame
    end
    for _, frame in ipairs(frames) do
        local unit = frame.__unitEvents[event]
        if frame.__events[event] or (unit and unit == (...)) then
            local handler = frame.__scripts.OnEvent
            if handler then
                handler(frame, event, ...)
            end
        end
    end
end

function Mock.setCombat(inCombat)
    Mock.state.inCombat = inCombat
    Mock.fire(inCombat and "PLAYER_REGEN_DISABLED" or "PLAYER_REGEN_ENABLED")
end

------------------------------------------------------------------------
-- Install globals + load the addon in .toc order
------------------------------------------------------------------------
local function readToc(root)
    local files = {}
    for line in io.lines(root .. "/" .. ADDON .. ".toc") do
        line = line:gsub("\r", ""):gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" and line:sub(1, 1) ~= "#" then
            files[#files + 1] = (line:gsub("\\", "/"))
        end
    end
    return files
end

function Mock.install(options)
    options = options or {}
    Mock.SECRET = setmetatable({}, { __tostring = function() return "<secret>" end })
    Mock.now = 1000
    Mock.timers = {}
    Mock.frames = {}
    Mock.errors = {}
    Mock.printed = {}
    Mock.rangeChecks = {}
    Mock.unknownEvents = options.unknownEvents or {}
    Mock.forbiddenEvents = { COMBAT_LOG_EVENT_UNFILTERED = true, COMBAT_LOG_EVENT = true }
    Mock.forbiddenCalls = {}
    Mock.state = {
        inCombat = false,
        freshLogin = false,     -- no realm slot yet (older clients, on a fresh login)
        playerName = "Purrdee",
        surname = nil,          -- a WoW: Forever surname: "Purrdee Bubson"
        build70170 = false,     -- the surname in the realm slot, as the client does since Oct 1 2026
        coldLogin = false,      -- no name at all until PLAYER_LOGIN
        normalizedRealm = true, -- false: no GetNormalizedRealmName(), only the spaced GetRealmName()
        playerClass = options.class or "WARRIOR",
        playerRace = options.race or "Tauren",
        speed = 0,
        attackSpeed = { player = { 2.6, nil, nil } }, -- [unit] = { mainHand, offHand, ranged } or Mock.SECRET
        units = {},  -- [token] = { id = "boar", name = "Boar", hostile = true }  (player is implicit)
        cvars = { showSwingTimer = "1" },
        combatLogRestricted = true,
    }
    local state = Mock.state

    local G = _G
    G.unpack = table.unpack
    G.print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do
            parts[i] = tostring((select(i, ...)))
        end
        Mock.printed[#Mock.printed + 1] = table.concat(parts, " ")
    end
    G.issecretvalue = function(value)
        return value == Mock.SECRET or (type(value) == "table" and rawget(value, "__secretObject") == true)
    end
    G.geterrorhandler = function()
        return function(err)
            Mock.errors[#Mock.errors + 1] = tostring(err)
        end
    end
    G.GetTime = function() return Mock.now end
    G.InCombatLockdown = function() return state.inCombat end
    G.date = os.date
    G.GetBuildInfo = function() return "1.60.1", "69893", "Sep 17 2026", 16001 end
    G.UISpecialFrames = {}
    G.SlashCmdList = {}
    G.AKForeverCombatTimersDB = options.db
    G.AKForeverCombatTimers_SavedStateBridge = options.bridge

    G.Enum = { PlayerSwingType = { MainHand = 0, OffHand = 1, Ranged = 2 } }

    G.CreateFrame = function(kind, name, parent, template)
        local widget = newWidget(kind, name, parent, template)
        Mock.frames[#Mock.frames + 1] = widget
        if name then
            G[name] = widget
        end
        return widget
    end
    G.UIParent = newWidget("Frame", "UIParent")
    G.UIParent:SetSize(1024, 768)

    G.C_Timer = {
        After = function(delay, fn)
            Mock.timers[#Mock.timers + 1] = { at = Mock.now + delay, fn = fn }
        end,
        NewTicker = function(interval, fn)
            local ticker = { at = Mock.now + interval, fn = fn, every = interval }
            Mock.timers[#Mock.timers + 1] = ticker
            return ticker
        end,
    }
    G.C_AddOns = { GetAddOnMetadata = function() return "0.1.0-test" end }
    G.C_SwingTimer = {
        EnableRangeCheck = function(swingType, enable) Mock.rangeChecks[swingType] = enable end,
        IsTargetWithinSwingRange = function() return true end,
    }
    G.C_CVar = {
        GetCVar = function(name) return state.cvars[name] end,
        SetCVar = function(name, value)
            if state.inCombat then
                error("CVar " .. name .. " is locked in combat")
            end
            state.cvars[name] = tostring(value)
            return true
        end,
    }
    G.C_CombatLog = { IsCombatLogRestricted = function() return state.combatLogRestricted end }

    -- Units -----------------------------------------------------------------
    local function unitInfo(unit)
        if unit == "player" then
            return { id = "player", name = state.playerName, friendly = true }
        end
        return state.units[unit]
    end
    G.UnitExists = function(unit) return unitInfo(unit) ~= nil end
    -- a unit's nameplate frame, or nothing: state.plates[unit] = { GetName = function() return "NamePlate3" end }
    state.plates = {}
    G.C_NamePlate = {
        GetNamePlateForUnit = function(unit) return state.plates[unit] end,
        GetNamePlates = function() local list = {} for _, plate in pairs(state.plates) do list[#list + 1] = plate end return list end,
    }
    G.UnitIsDeadOrGhost = function(unit) return state.dead[unit] == true end -- no secret flag on this one
    -- The player's name as the client gives it: state.surname adds a WoW: Forever surname; state.build70170
    -- puts it in the realm slot, as the client does since Oct 1 2026 (UnitFullName("player") -> "Purrdee",
    -- "Bubson"; before: "Purrdee Bubson", "TestRealm"); state.freshLogin: no realm slot yet; state.coldLogin:
    -- no name at all until PLAYER_LOGIN.
    local function playerName()
        if state.coldLogin then
            return nil, nil
        end
        local name, slot = state.playerName, nil
        if state.surname and state.build70170 then
            slot = state.surname
        else
            if state.surname then
                name = name .. " " .. state.surname
            end
            if not state.freshLogin then
                slot = "TestRealm"
            end
        end
        return name, slot
    end
    G.UnitName = function(unit)
        if unit == "player" then
            local name, slot = playerName()
            if state.build70170 then
                return name, slot
            end
            return name
        end
        local info = unitInfo(unit)
        return info and info.name
    end
    G.UnitFullName = function(unit)
        if unit == "player" then
            return playerName()
        end
        if state.freshLogin then
            return G.UnitName(unit), nil
        end
        return G.UnitName(unit), "TestRealm"
    end
    G.GetRealmName = function() return "Test Realm" end
    G.GetNormalizedRealmName = function()
        if state.normalizedRealm == false then
            return nil -- a client without it: the spaced GetRealmName(), squeezed, must do
        end
        return "TestRealm"
    end
    G.UnitClass = function() return "Player Class", state.playerClass end
    G.UnitRace = function() return state.playerRace, state.playerRace end
    G.GetUnitSpeed = function() return state.speed or 0 end
    G.IsFalling = function() return state.falling and true or false end
    G.UnitIsUnit = function(a, b)
        local infoA, infoB = unitInfo(a), unitInfo(b)
        if state.identitySecret then
            return Mock.SECRET
        end
        return infoA ~= nil and infoB ~= nil and infoA.id == infoB.id
    end
    G.UnitCanAttack = function(_, unit)
        local info = unitInfo(unit)
        return info ~= nil and info.hostile == true
    end
    G.UnitIsFriend = function(_, unit)
        local info = unitInfo(unit)
        return info ~= nil and not info.hostile
    end
    G.UnitAffectingCombat = function() return state.inCombat end
    G.IsInRaid = function() return state.inRaid or false end
    G.IsInGroup = function() return state.inGroup or state.inRaid or false end
    G.GetNumGroupMembers = function() return (state.inGroup or state.inRaid) and 5 or 0 end
    G.UnitAttackSpeed = function(unit)
        local speeds = state.attackSpeed[unit]
        if speeds == Mock.SECRET then
            return Mock.SECRET, Mock.SECRET, Mock.SECRET
        end
        if not speeds then
            return 0
        end
        return speeds[1], speeds[2], speeds[3]
    end
    -- Casts ----------------------------------------------------------------
    -- state.casts[unit] = { kind = "cast"|"channel", name, texture, start, finish (seconds), secret = bool }
    -- secret: the client hands out values an addon may pass on but not read (times in ms, like the real API).
    state.casts = {}
    local function castInfo(unit, kind)
        local cast = state.casts[unit]
        if not cast or cast.kind ~= kind then
            return -- nothing at all: "MayReturnNothing"
        end
        if cast.secret then
            local S = Mock.SECRET
            return S, S, S, S, S, S, S, S, S
        end
        if kind == "channel" then -- (no cast id in UnitChannelInfo: the spell id is its 8th value)
            return cast.name, cast.name, cast.texture, cast.start * 1000, cast.finish * 1000, false, false, cast.spellID or 1
        end
        return cast.name, cast.name, cast.texture, cast.start * 1000, cast.finish * 1000, false, "Cast-1", false, cast.spellID or 1
    end
    G.UnitCastingInfo = function(unit) return castInfo(unit, "cast") end
    G.UnitChannelInfo = function(unit) return castInfo(unit, "channel") end
    local function castDuration(unit, kind)
        local cast = state.casts[unit]
        if cast and cast.kind == kind and not state.noDurationObjects then
            -- documented "SecretReturns": the object itself counts as a secret value
            return {
                __durationObject = true, __secretObject = true, cast = cast,
                -- the text it formats carries the secret times: a secret string
                FormatRemainingDuration = function(self, formatter)
                    assert(type(formatter) == "table" and formatter.__formatter, "expected a NumericFormatter")
                    if state.noDurationFormatting then
                        error("FormatRemainingDuration: not available to addons")
                    end
                    return Mock.SECRET
                end,
            }
        end
    end
    G.UnitCastingDuration = function(unit) return castDuration(unit, "cast") end
    G.UnitChannelDuration = function(unit) return castDuration(unit, "channel") end
    if options.noDurationApi then
        G.UnitCastingDuration, G.UnitChannelDuration = nil, nil
    end
    -- Items: what is in the bags / worn, and the spell an item's "use" casts ------------------
    state.bags = options.bags or {}           -- [bag] = { itemID, itemID, ... }
    state.worn = options.worn or {}           -- [slot] = itemID
    state.itemSpells = options.itemSpells or {} -- [itemID] = { spellID = , icon = }
    G.C_Container = {
        GetContainerNumSlots = function(bag) return state.bags[bag] and #state.bags[bag] or 0 end,
        GetContainerItemID = function(bag, slot) return state.bags[bag] and state.bags[bag][slot] end,
    }
    G.GetInventoryItemID = function(_, slot) return state.worn[slot] end
    G.C_Item = {
        GetItemSpell = function(itemID)
            local item = state.itemSpells[itemID]
            if item then
                return "Use " .. itemID, item.spellID
            end
        end,
        GetItemIconByID = function(itemID) return state.itemSpells[itemID] and state.itemSpells[itemID].icon end,
    }

    -- Auras ---------------------------------------------------------------
    -- Blizzard's rule: aura data is secret while combat restrictions are in effect (unless the spell is
    -- flagged never-secret); lookups by spell id then return NOTHING. state.auras[spellID] = { ... }.
    state.auras, state.spellNames = {}, options.spellNames or {}
    -- a GUID to file an enemy under, and the debuffs standing on one
    state.guids = options.guids or { player = "Player-0-0-0-0-1" }
    state.dead = {} -- [unit] = true once it has died
    state.secretGUIDs = options.secretGUIDs or false
    state.unitAuras = {} -- [unit] = { { name, duration, expirationTime, icon, mine } }
    local function auraSecret(aura) return state.inCombat and not aura.neverSecret end
    local function auraView(aura)
        if not auraSecret(aura) then
            return { auraInstanceID = aura.auraInstanceID, spellId = aura.spellId, name = aura.name, duration = aura.duration,
                expirationTime = aura.expirationTime, applications = aura.applications, isFromPlayerOrPlayerPet = true }
        end
        local S = Mock.SECRET
        return { auraInstanceID = aura.auraInstanceID, spellId = S, name = S, duration = S, expirationTime = S,
            applications = aura.applications and S or nil, isFromPlayerOrPlayerPet = S }
    end
    local function auraByInstance(id)
        for _, aura in pairs(state.auras) do
            if aura.auraInstanceID == id then
                return aura
            end
        end
    end
    G.C_Spell = {
        GetSpellName = function(spellID) return state.spellNames[spellID] end,
        GetSpellTexture = function(spellID) return 130000 + spellID end,
    }
    -- One creature, one name. A unit the client is protecting has no readable GUID, and then a DoT
    -- on it cannot be filed at all - which the addon treats as "do not guess", not as an error.
    G.UnitGUID = function(unit)
        if state.secretGUIDs then
            return Mock.SECRET
        end
        return state.guids[unit]
    end

    G.C_UnitAuras = {
        -- Debuffs on somebody else. Refuses in a fight, the same way the player's own auras were
        -- measured to on this client.
        GetAuraDataByIndex = function(unit, index, filter)
            if state.inCombat and not state.aurasOpenInCombat then
                error("GetAuraDataByIndex(): Auras cannot be accessed when secret while tainted by 'AKForeverCombatTimers'")
            end
            local list = state.unitAuras[unit]
            local aura = list and list[index]
            if not aura then
                return nil
            end
            if filter == "HARMFUL|PLAYER" and aura.mine == false then
                return { name = "somebody else's", duration = 5, expirationTime = Mock.now + 5 }
            end
            return { name = aura.name, duration = aura.duration,
                expirationTime = aura.expirationTime, icon = aura.icon }
        end,
        -- MEASURED on the 1.60.1 client: plain out of combat, an ERROR in a fight
        GetUnitAuraInstanceIDs = function()
            if state.inCombat and not state.aurasOpenInCombat then
                error("GetUnitAuraInstanceIDs(): Auras cannot be accessed when secret while tainted by 'AKForeverCombatTimers'")
            end
            local ids = {}
            for _, aura in pairs(state.auras) do
                ids[#ids + 1] = aura.auraInstanceID
            end
            for _, id in ipairs(state.otherAuraIDs or {}) do
                ids[#ids + 1] = id
            end
            return ids
        end,
        GetAuraDataBySpellName = function(_, name)
            for _, aura in pairs(state.auras) do
                if aura.name == name and not auraSecret(aura) then
                    return auraView(aura)
                end
            end
        end,
        GetPlayerAuraBySpellID = function(spellID)
            local aura = state.auras[spellID]
            if aura and not auraSecret(aura) then
                return auraView(aura)
            end
        end,
        GetAuraDataByAuraInstanceID = function(_, id)
            local aura = auraByInstance(id)
            return aura and auraView(aura) or nil
        end,
        GetAuraDuration = function(_, id)
            local aura = auraByInstance(id)
            if aura then
                return { __durationObject = true, __secretObject = auraSecret(aura) or nil, aura = aura }
            end
        end,
    }
    G.C_Secrets = {
        GetSpellAuraSecrecy = function(spellID) return state.auras[spellID] and state.auras[spellID].neverSecret and 0 or 2 end,
        ShouldSpellAuraBeSecret = function(spellID) return state.auras[spellID] ~= nil and auraSecret(state.auras[spellID]) end,
        ShouldAurasBeSecret = function() return state.inCombat end,
        HasSecretRestrictions = function() return state.inCombat end,
        ShouldUnitAuraInstanceBeSecret = function(_, id) local aura = auraByInstance(id); return aura ~= nil and auraSecret(aura) end,
    }
    Mock.auraView = auraView

    -- The client can count a duration down into a font string by itself (docs: DurationTextBinding).
    Mock.textBindings = {}
    G.C_StringUtil = {
        CreateNumericRuleFormatter = function()
            return { __formatter = true, SetBreakpoints = function(self, breakpoints) self.breakpoints = breakpoints end }
        end,
    }
    G.C_DurationUtil = {
        CreateDurationTextBinding = function()
            local binding = { enabled = false }
            function binding:SetFontString(fontString) self.fontString = fontString end
            function binding:SetFormatter(formatter)
                assert(type(formatter) == "table" and formatter.__formatter, "expected a NumericFormatter")
                self.formatter = formatter
            end
            function binding:SetUpdateInterval(seconds) self.interval = seconds end
            function binding:SetZeroDurationText(text) self.zeroText = text end
            function binding:SetExpiredText(text) self.expiredText = text end
            function binding:SetDuration(duration)
                assert(type(duration) == "table" and duration.__durationObject, "expected a LuaDurationObject")
                if state.bindingRefusesAddons then
                    error("SetDuration: secret values are only allowed from untainted code")
                end
                self.duration = duration
            end
            function binding:Enable()
                self.enabled = true
                self.fontString.__text = Mock.SECRET -- from now on the CLIENT writes the (secret) countdown
            end
            function binding:Disable() self.enabled = false end
            Mock.textBindings[#Mock.textBindings + 1] = binding
            return binding
        end,
    }
    if options.noTextBinding then
        G.C_DurationUtil = nil
    end
    -- Combo points: secret (measured) - but UnitPowerPercent puts them through a curve of OURS and hands
    -- back the (secret) result. Secret numbers are objects here, so that the mock's status bar can still
    -- work out how full it is (Mock.barFraction) - the addon cannot: issecretvalue() says true.
    state.comboPoints = options.comboPoints or 0
    G.Enum.PowerType = { Energy = 3, ComboPoints = 4 }
    G.Enum.LuaCurveType = { Linear = 0, Step = 1 }
    local function evaluate(curve, x)
        local points = curve.__points
        if #points == 0 then
            return 0
        end
        table.sort(points, function(a, b) return a[1] < b[1] end)
        if x <= points[1][1] then
            return points[1][2]
        end
        for index = 2, #points do
            local left, right = points[index - 1], points[index]
            if x <= right[1] then
                return left[2] + (right[2] - left[2]) * (x - left[1]) / (right[1] - left[1])
            end
        end
        return points[#points][2]
    end
    G.C_CurveUtil, G.UnitPowerPercent = nil, nil -- (globals outlive an install: a client without them must not inherit them)
    if not options.noCurves then
        G.C_CurveUtil = { CreateCurve = function()
            return { __points = {}, SetType = function(self, kind) self.__type = kind end,
                AddPoint = function(self, x, y) self.__points[#self.__points + 1] = { x, y } end }
        end }
        G.UnitPowerPercent = function(unit, powerType, _, curve)
            assert(unit == "player" and powerType == 4, "UnitPowerPercent: only the player's combo points are modelled")
            local fraction = state.comboPoints / 5
            local result = curve and evaluate(curve, fraction) or fraction
            if state.comboPointsReadable then
                return result
            end
            return { __secretObject = true, __value = result }
        end
    end
    -- how full a status bar is - looking inside secret bounds, which only the mock can
    function Mock.barFraction(status)
        local function plain(value) return type(value) == "table" and value.__value or value end
        local low, high, value = plain(status.__min), plain(status.__max), plain(status.__value)
        if type(low) ~= "number" or type(high) ~= "number" or type(value) ~= "number" or high == low then
            return nil
        end
        return math.max(0, math.min(1, (value - low) / (high - low)))
    end
    G.Enum.StatusBarTimerDirection = { ElapsedTime = 0, RemainingTime = 1 }
    G.Enum.StatusBarInterpolation = { Immediate = 0, ExponentialEaseOut = 1 }

    -- Blizzard's own cast bars: the player's lives in a managed container, the target's hangs off the
    -- (protected) target frame.
    G.UIParentBottomManagedFrameContainer = G.CreateFrame("Frame", "UIParentBottomManagedFrameContainer", G.UIParent)
    G.TargetFrame = G.CreateFrame("Button", "TargetFrame", G.UIParent)
    G.TargetFrame.__protected = true
    for name, parent in pairs({ PlayerCastingBarFrame = G.UIParentBottomManagedFrameContainer, TargetFrameSpellBar = G.TargetFrame }) do
        local bar = G.CreateFrame("StatusBar", name, parent)
        bar.__blizzard = true
        bar.__shown = false -- only up while that unit casts (Mock.cast / Mock.castEnd)
    end
    G.TargetFrameSpellBar.__keepParent = true
    Mock.blizzardCastBars = { player = G.PlayerCastingBarFrame, target = G.TargetFrameSpellBar }

    -- Load the addon exactly as the client would.
    local root = options.root or "."
    local ns = {}
    for _, file in ipairs(readToc(root)) do
        local chunk, err = loadfile(root .. "/" .. file)
        if not chunk then
            error("cannot load " .. file .. ": " .. tostring(err))
        end
        chunk(ADDON, ns)
    end
    Mock.ns = ns

    if options.login ~= false then
        Mock.login()
    end
    return ns, state
end

function Mock.login()
    Mock.fire("ADDON_LOADED", ADDON)
    Mock.state.coldLogin = false -- by PLAYER_LOGIN the client knows who you are
    Mock.fire("PLAYER_LOGIN")
    Mock.fire("PLAYER_ENTERING_WORLD", true, false)
end

-- Convenience used by the scenarios ------------------------------------
function Mock.swing(duration, swingType)
    Mock.fire("PLAYER_SWING", duration, swingType or 0)
end

function Mock.hit(unit, action, school)
    Mock.fire("UNIT_COMBAT", unit, action or "WOUND", "", 100, school or 1)
end

-- A unit event: routed by the unit the frame registered for; the payload is a separate matter (the
-- client may hand out a SECRET unit / spell id and still deliver the event to the right frames).
function Mock.fireUnit(event, unit, ...)
    local frames = {}
    for i, frame in ipairs(Mock.frames) do
        frames[i] = frame
    end
    for _, frame in ipairs(frames) do
        if frame.__unitEvents[event] == unit and frame.__scripts.OnEvent then
            frame.__scripts.OnEvent(frame, event, ...)
        end
    end
end

-- spec: { name, texture, seconds, kind = "cast" | "channel", secret = true }
function Mock.cast(unit, spec)
    spec = spec or {}
    Mock.state.casts[unit] = {
        kind = spec.kind or "cast", name = spec.name or "Fireball", texture = spec.texture or 135812,
        start = Mock.now, finish = Mock.now + (spec.seconds or 2), secret = spec.secret, spellID = spec.spellID,
    }
    local event = spec.kind == "channel" and "UNIT_SPELLCAST_CHANNEL_START" or "UNIT_SPELLCAST_START"
    local S = spec.secret and Mock.SECRET
    if Mock.blizzardCastBars[unit] then
        Mock.blizzardCastBars[unit].__shown = true -- Blizzard's own bar comes up for the cast (seen or not)
    end
    Mock.fireUnit(event, unit, S or unit, S or "Cast-1", S or (spec.spellID or 133))
end

-- event: UNIT_SPELLCAST_STOP (default), _INTERRUPTED, _CHANNEL_STOP, ...
function Mock.castEnd(unit, event)
    local cast = Mock.state.casts[unit]
    local S = cast and cast.secret and Mock.SECRET
    Mock.state.casts[unit] = nil
    if Mock.blizzardCastBars[unit] then
        Mock.blizzardCastBars[unit].__shown = false
    end
    Mock.fireUnit(event or "UNIT_SPELLCAST_STOP", unit, S or unit, S or "Cast-1", S or 133)
end

-- The player casts a self buff: UNIT_SPELLCAST_SUCCEEDED (own casts are never secret), then UNIT_AURA.
-- options: neverSecret, auraFirst (the aura event beats the cast event), secretEvent (UNIT_AURA's payload is secret)
-- A stacking, duration-less buff - Plainsrunning and its like. `stacks` nil takes it away again.
function Mock.stackingBuff(spellID, name, stacks)
    local state = Mock.state
    state.spellNames[spellID] = name
    if stacks then
        state.auras[spellID] = { auraInstanceID = 100 + spellID % 50, spellId = spellID, name = name,
            duration = 0, expirationTime = 0, applications = stacks, neverSecret = true }
    else
        state.auras[spellID] = nil
    end
    Mock.fireUnit("UNIT_AURA", "player", "player", { isFullUpdate = true })
end

-- The player starts or stops moving (the bar asks for this once a frame; no event is involved).
function Mock.setSpeed(speed)
    Mock.state.speed = speed
end

-- Off the ground. A jump from a standstill reads zero speed the whole way up and down.
function Mock.setFalling(falling)
    Mock.state.falling = falling and true or nil
end

-- A strafe or a change of direction: the client reports zero speed for a frame or two, then carries on.
-- (`frames` of them, a 60th of a second apart, the way the bar would see it.)
function Mock.strafe(ns, frames)
    local speed = Mock.state.speed
    Mock.state.speed = 0
    for _ = 1, (frames or 2) do
        Mock.advance(1 / 60)
        ns.Bars:Update()
    end
    Mock.state.speed = speed
    Mock.advance(1 / 60)
    ns.Bars:Update()
end

function Mock.buff(spellID, name, seconds, options)
    options = options or {}
    local state = Mock.state
    state.spellNames[spellID] = name
    local existing = state.auras[spellID]
    state.auras[spellID] = { auraInstanceID = existing and existing.auraInstanceID or (100 + spellID % 50), spellId = spellID,
        name = name, duration = seconds, expirationTime = Mock.now + seconds, neverSecret = options.neverSecret }
    local aura = state.auras[spellID]
    local info = existing and { isFullUpdate = false, updatedAuraInstanceIDs = { aura.auraInstanceID } }
        or { isFullUpdate = false, addedAuras = { Mock.auraView(aura) } }
    if options.secretEvent then
        info = Mock.SECRET
    end
    if options.auraFirst then
        Mock.fireUnit("UNIT_AURA", "player", "player", info)
        Mock.fireUnit("UNIT_SPELLCAST_SUCCEEDED", "player", "player", "Cast-9", spellID)
    else
        Mock.fireUnit("UNIT_SPELLCAST_SUCCEEDED", "player", "player", "Cast-9", spellID)
        Mock.fireUnit("UNIT_AURA", "player", "player", info)
    end
end

-- The player builds combo points ...
function Mock.comboPoints(points)
    Mock.state.comboPoints = points
    Mock.fireUnit("UNIT_POWER_FREQUENT", "player", "player", "COMBO_POINTS")
end

-- ... and spends them on a finisher that buffs (Slice and Dice): SENT while the points are still there, then
-- the points go, then SUCCEEDED, then a UNIT_AURA whose payload is secret in a fight.
-- options: noSent (a client without that event), seconds (the aura's real duration)
function Mock.finisher(spellID, name, options)
    options = options or {}
    local state = Mock.state
    state.spellNames[spellID] = name
    if not options.noSent then
        Mock.fireUnit("UNIT_SPELLCAST_SENT", "player", "player", "Target", "Cast-9", spellID)
    end
    local seconds = options.seconds or ({ 9, 12, 15, 18, 21 })[math.max(1, state.comboPoints)]
    Mock.comboPoints(0)
    state.auras[spellID] = { auraInstanceID = 100 + spellID % 50, spellId = spellID, name = name, duration = seconds,
        expirationTime = Mock.now + seconds }
    Mock.fireUnit("UNIT_SPELLCAST_SUCCEEDED", "player", "player", "Cast-9", spellID)
    Mock.fireUnit("UNIT_AURA", "player", "player", state.inCombat and Mock.SECRET or { isFullUpdate = false })
end

-- The buff runs out / is cancelled.
function Mock.unbuff(spellID)
    local aura = Mock.state.auras[spellID]
    Mock.state.auras[spellID] = nil
    Mock.fireUnit("UNIT_AURA", "player", "player", { isFullUpdate = false, removedAuraInstanceIDs = { aura and aura.auraInstanceID } })
end

function Mock.realPrint(...)
    REAL_PRINT(...)
end

return Mock
