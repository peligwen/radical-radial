-- Offline harness for the RadicalRadial addon.
--
-- Fakes just enough of the WoW API and of the restricted environment to load
-- the addon's files in TOC order, run its snippets, and walk through press /
-- wheel / release / cancel scenarios with assertions. It checks syntax and
-- logic, not the client's real behaviour (binding delivery, combat lockdown,
-- secrets, widget painting): those are the in-game checklist in README.md.
--
-- LibStub and CallbackHandler-1.0 load for real. LibActionButton-1.0 is
-- replaced by a small fake that keeps the library's contract (CreateButton,
-- SetState, GetAction, UpdateAction, the labtype-/labaction- attributes) and
-- runs the real "UpdateState" snippet, extracted from the vendored file, so
-- the secure side is exercised as it will be in game.
--
-- Run with tools/check.py (needs the lupa Python package) or any Lua 5.1+.

math.atan2 = math.atan2 or function(y, x) return math.atan(y, x) end
unpack = unpack or table.unpack

local SCREEN_W, SCREEN_H = 1600, 900
local cursor = { x = 800, y = 450 }
local inCombat = false
local useActionLog = {}      -- slots (or macro text) Blizzard's handler would have used
local bindings = {}          -- key -> { owner, frame, button }
local frameByName = {}
local allFrames = {}
local output = {}

local realPrint = print
function print(...)
	local parts = {}
	for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
	output[#output + 1] = table.concat(parts, " ")
	if os.getenv("HARNESS_VERBOSE") then realPrint(...) end
end

local function ReadFile(path)
	local fh = assert(io.open(path, "r"), "cannot open " .. path)
	local text = fh:read("*a")
	fh:close()
	return text
end

-------------------------------------------------------------------------------
-- Fake regions and frames
-------------------------------------------------------------------------------

local Region = {}
Region.__index = Region
local function NewRegion(kind)
	return setmetatable({ kind = kind, shown = true, color = {}, text = "" }, Region)
end
function Region:SetPoint() end
function Region:SetAllPoints() end
function Region:ClearAllPoints() end
function Region:SetSize(w, h) self.w, self.h = w, h end
function Region:SetTexCoord() end
function Region:SetColorTexture(r, g, b, a) self.color = { r, g, b, a } end
function Region:SetTexture(t) self.texture = t end
function Region:SetVertexColor(r, g, b) self.vertex = { r, g, b } end
function Region:Show() self.shown = true end
function Region:Hide() self.shown = false end
function Region:IsShown() return self.shown end
function Region:SetText(t) self.text = t end
function Region:GetText() return self.text end
function Region:SetFont() end
function Region:SetJustifyH() end
function Region:SetJustifyV() end
function Region:SetWidth(w) self.w = w end
function Region:SetHeight(h) self.h = h end
function Region:SetTextColor() end
function Region:SetAlpha(a) self.alpha = a end
function Region:SetShown(v) self.shown = v and true or false end
function Region:SetFormattedText(fmt, ...) self.text = fmt:format(...) end
function Region:SetWordWrap() end
function Region:SetDrawLayer() end

local Frame = {}
Frame.__index = Frame

local function NewFrame(kind, name, parent, template)
	local f = setmetatable({
		kind = kind, name = name, parent = parent, template = template or "",
		attributes = {}, scripts = {}, hooks = {}, framerefs = {},
		shown = true, w = 0, h = 0, cx = SCREEN_W / 2, cy = SCREEN_H / 2, scale = 1,
		clicks = {}, mouse = true, protected = (template or ""):find("Secure") ~= nil,
		wheel = (template or ""):find("SecureHandlerMouseWheel") ~= nil,   -- the template's OnLoad enables it
	}, Frame)
	if name then frameByName[name] = f; _G[name] = f end
	allFrames[#allFrames + 1] = f
	-- Children the client's templates provide and the addon reaches for.
	local t = template or ""
	if t:find("UISliderTemplateWithLabels") then
		f.Text, f.Low, f.High = NewRegion("fontstring"), NewRegion("fontstring"), NewRegion("fontstring")
	end
	if t:find("UICheckButtonTemplate") then f.Text = NewRegion("fontstring") end
	if t:find("ButtonFrameTemplate") then
		f.Inset = NewFrame("Frame", nil, f)
		f.CloseButton = NewFrame("Button", nil, f)
		f.TitleContainer = { TitleText = NewRegion("fontstring") }
	end
	return f
end

function Frame:GetName() return self.name end
function Frame:SetSize(w, h) self.w, self.h = w, h end
function Frame:SetWidth(w) self.w = w end
function Frame:SetHeight(h) self.h = h end
function Frame:GetWidth() return self.w end
function Frame:GetHeight() return self.h end
function Frame:SetAllPoints(other)
	local o = other or self.parent
	self.w, self.h, self.cx, self.cy = o.w, o.h, o.cx, o.cy
end
function Frame:ClearAllPoints() end
function Frame:SetPoint(point, rel, relpoint, x, y)
	if rel == "$cursor" then
		self.cx, self.cy = cursor.x, cursor.y
	elseif type(rel) == "table" and point == "CENTER" and relpoint == "CENTER" then
		self.cx, self.cy = rel.cx + (x or 0), rel.cy + (y or 0)
	end
end
function Frame:GetCenter() return self.cx, self.cy end
function Frame:GetRect() return self.cx - self.w / 2, self.cy - self.h / 2, self.w, self.h end
function Frame:GetEffectiveScale() return self.scale end
function Frame:SetScale(s) self.scale = s end
function Frame:GetScale() return self.scale end
function Frame:SetParent(p) self.parent = p end
function Frame:GetParent() return self.parent end
function Frame:SetFrameStrata() end
function Frame:SetFrameLevel() end
function Frame:SetAlpha(a) self.alpha = a end
function Frame:EnableMouse(v) self.mouse = v end
function Frame:EnableMouseWheel(v) self.wheel = v and true or false end
function Frame:IsMouseWheelEnabled() return self.wheel end
function Frame:RegisterForDrag() end
function Frame:SetChecked(v) self.checked = v end
function Frame:LockHighlight() self.highlightLocked = true end
function Frame:UnlockHighlight() self.highlightLocked = false end
-- Widget methods the options window uses. Only methods the client has are
-- listed, so a typo in the addon still fails here.
function Frame:SetMovable() end
function Frame:SetClampedToScreen() end
function Frame:StartMoving() end
function Frame:StopMovingOrSizing() end
function Frame:SetToplevel() end
function Frame:Raise() end
function Frame:EnableKeyboard(v) self.keyboard = v end
function Frame:SetText(t) self.text = t end
function Frame:GetText() return self.text end
function Frame:GetFontString() self.fontString = self.fontString or NewRegion("fontstring") return self.fontString end
function Frame:SetEnabled(v) self.enabled = v and true or false end
function Frame:Enable() self.enabled = true end
function Frame:Disable() self.enabled = false end
function Frame:IsEnabled() return self.enabled ~= false end
function Frame:SetShown(v) if v then self:Show() else self:Hide() end end
function Frame:GetChecked() return self.checked and true or false end
function Frame:SetOrientation() end
function Frame:SetMinMaxValues(lo, hi) self.min, self.max = lo, hi end
function Frame:GetMinMaxValues() return self.min, self.max end
function Frame:SetValueStep(step) self.step = step end
function Frame:SetObeyStepOnDrag() end
function Frame:SetValue(v)
	v = math.max(self.min or -math.huge, math.min(self.max or math.huge, v))
	self.sliderValue = v
	if self.scripts.OnValueChanged then self.scripts.OnValueChanged(self, v, false) end
end
function Frame:GetValue() return self.sliderValue end
function Frame:SetTitle(t) self.title = t end
function Frame:SetHitRectInsets() end
function Frame:SetID(id) self.id = id end
function Frame:GetID() return self.id end
function Frame:SetNormalFontObject() end
function Frame:SetFontObject() end
local RunSnippet   -- defined below
local function RunHooks(frame, name, ...)
	for _, hook in ipairs(frame.hooks[name] or {}) do hook(frame, ...) end
end
function Frame:Show()
	local was = self.shown
	self.shown = true
	if not was then
		if self.attributes._onshow then RunSnippet(self.attributes._onshow, self, self) end
		if self.scripts.OnShow then self.scripts.OnShow(self) end
		RunHooks(self, "OnShow")
	end
end
function Frame:Hide()
	local was = self.shown
	self.shown = false
	if was then
		if self.attributes._onhide then RunSnippet(self.attributes._onhide, self, self) end
		if self.scripts.OnHide then self.scripts.OnHide(self) end
		RunHooks(self, "OnHide")
	end
end
function Frame:IsShown() return self.shown end
function Frame:RegisterForClicks(...) self.clicks = { ... } end
function Frame:RegisterEvent(event) self.events = self.events or {}; self.events[event] = true end
function Frame:UnregisterEvent() end
function Frame:SetScript(name, fn) self.scripts[name] = fn end
function Frame:GetScript(name) return self.scripts[name] end
function Frame:HookScript(name, fn)
	local provided = self.scripts[name]
		or (self.template:find("ShowHide") and (name == "OnShow" or name == "OnHide"))
		or (self.template:find("SecureActionButton") and name == "OnClick")
		or (self.template:find("SecureHandlerClick") and name == "OnClick")
		or (self.template:find("SecureHandlerMouseWheel") and name == "OnMouseWheel")
	assert(provided, "HookScript on " .. tostring(self.name) .. " without a " .. name .. " handler to hook")
	self.hooks[name] = self.hooks[name] or {}
	table.insert(self.hooks[name], fn)
end
-- The client lowercases attribute names: SetAttribute("Open", x) and
-- SetAttribute("open", y) write the same attribute, and OnAttributeChanged
-- receives the lower-case name. Modelling that is what catches a snippet
-- attribute named like a state flag.
function Frame:SetAttribute(name, value)
	name = string.lower(name)
	self.attributes[name] = value
	if self.scripts.OnAttributeChanged then self.scripts.OnAttributeChanged(self, name, value) end
end
function Frame:GetAttribute(name) return self.attributes[string.lower(name)] end
function Frame:CreateTexture() return NewRegion("texture") end
function Frame:CreateFontString() return NewRegion("fontstring") end
function Frame:SetCooldown(start, duration, modRate) self.cooldown = { start, duration, modRate } end
function Frame:Clear() self.cooldown = nil end

-- Restricted-environment handle methods (the fake handle is the frame itself)
function Frame:GetFrameRef(label) return self.framerefs[label] end
function Frame:GetMousePosition()
	local l, b, w, h = self:GetRect()
	local x, y = cursor.x - l, cursor.y - b
	if x < 0 or x > w or y < 0 or y > h then return nil end
	return x / w, y / h
end
function Frame:SetBindingClick(priority, key, name, button)
	bindings[key] = { owner = self, frame = frameByName[name], button = button }
end
function Frame:ClearBindings()
	for key, b in pairs(bindings) do if b.owner == self then bindings[key] = nil end end
end
function Frame:RegisterAutoHide(duration)
	assert(self.shown, "RegisterAutoHide on a hidden frame does nothing useful")
	local l, b, w, h = self:GetRect()
	assert(cursor.x >= l and cursor.x <= l + w and cursor.y >= b and cursor.y <= b + h,
		"RegisterAutoHide: the cursor must start inside the frame's rect or the countdown never starts")
	self.autoHide = duration
end
function Frame:UnregisterAutoHide() self.autoHide = nil end
function Frame:CallMethod(method, ...)
	local fn = self[method]
	assert(type(fn) == "function", "CallMethod: no method " .. tostring(method))
	fn(self, ...)
end

-------------------------------------------------------------------------------
-- Restricted environment emulation
-------------------------------------------------------------------------------

local barState = { page = 1, bonus = false, bonusIndex = 7, vehicle = false, override = false, temp = false }
local unitState = { mouseover = nil }   -- nil, or { dead = bool, attack = bool, assist = bool }

local currentControl   -- the header whose environment is running

local function RestrictedEnv(self, control, args)
	local env = {
		self = self, control = control,
		floor = math.floor, deg = math.deg, math = math, tostring = tostring, tonumber = tonumber,
		print = print, select = select, format = string.format,
		HasVehicleActionBar = function() return barState.vehicle end,
		GetVehicleBarIndex = function() return 12 end,
		HasOverrideActionBar = function() return barState.override end,
		GetOverrideBarIndex = function() return 14 end,
		HasTempShapeshiftActionBar = function() return barState.temp end,
		GetTempShapeshiftBarIndex = function() return 13 end,
		HasBonusActionBar = function() return barState.bonus end,
		GetBonusBarIndex = function() return barState.bonusIndex end,
		GetActionBarPage = function() return barState.page end,
		GetActionInfo = function(slot) return "spell", 1000 + slot, nil end,
		IsPressHoldReleaseSpell = function() return false end,
		UnitExists = function(unit) return unitState[unit] ~= nil end,
		UnitIsDead = function(unit) return unitState[unit] ~= nil and unitState[unit].dead or false end,
		PlayerCanAttack = function(unit) return unitState[unit] ~= nil and unitState[unit].attack or false end,
		PlayerCanAssist = function(unit) return unitState[unit] ~= nil and unitState[unit].assist or false end,
	}
	for k, v in pairs(args or {}) do env[k] = v end
	setmetatable(env, { __index = function(_, k)
		error("snippet used a name that is not in the restricted environment: " .. tostring(k), 2)
	end })
	return env
end

function RunSnippet(body, self, control, args, ...)
	local chunk, err = load(body, "snippet", "t", RestrictedEnv(self, control, args))
	assert(chunk, err)
	local previous = currentControl
	currentControl = control
	local results = { chunk(...) }
	currentControl = previous
	return unpack(results, 1, 4)
end

-- handle:RunAttribute(name, ...): self is the handle, control stays the
-- header whose snippet is running (or the frame itself for _onshow/_onhide).
function Frame:RunAttribute(name, ...)
	local body = self:GetAttribute(name)
	assert(type(body) == "string", "RunAttribute(" .. tostring(name) .. "): Invalid snippet body")
	return RunSnippet(body, self, currentControl or self, nil, ...)
end

-- SecureActionButton_OnClick, reduced to what the addon relies on. Like
-- SecureTemplates.lua, it drops the click when the button's "unit" names a
-- unit that does not exist; that check silently skipped target captures.
local function SecureActionButtonClick(frame, button, down)
	local useOnKeyDown = frame:GetAttribute("useOnKeyDown")
	local clickAction = (down and useOnKeyDown) or (not down and not useOnKeyDown)
	if not clickAction then return end
	local unit = frame:GetAttribute("unit")
	if unit and unit ~= "none" and not unitState[unit] then return end
	local kind = frame:GetAttribute("type")
	if kind == "action" then
		table.insert(useActionLog, { action = frame:GetAttribute("action"), unit = unit, button = button })
	elseif kind == "macro" then
		local text = frame:GetAttribute("macrotext")
		table.insert(useActionLog, { macrotext = text, button = button })
		-- the capture macros: "/focus [@mouseover,exists,nodead]", "/target ..."
		local cmd = text and text:match("^/(%a+) %[@mouseover,exists,nodead%]$")
		if cmd then
			local m = unitState.mouseover
			if m and not m.dead then unitState[cmd] = m end
		end
	end
end

function Frame:Click(button, down)
	local suppressed = false
	if self.wrap then
		local newbutton = RunSnippet(self.wrap.pre, self, self.wrap.header, { button = button, down = down })
		if newbutton == false then suppressed = true end
		if newbutton then button = tostring(newbutton) end
	end
	if not suppressed then
		if self.template:find("SecureActionButtonTemplate") then
			SecureActionButtonClick(self, button, down)
		elseif self.template:find("SecureHandlerClickTemplate") then
			RunSnippet(self.attributes._onclick, self, self, { button = button, down = down })
		elseif self.scripts.OnClick then
			-- a CheckButton flips its state before OnClick runs
			if self.kind == "CheckButton" and not down then self.checked = not self.checked end
			self.scripts.OnClick(self, button, down)
		end
	end
	-- HookScript hooks run after the script handler returns, whatever it did.
	RunHooks(self, "OnClick", button, down)
end

-- One wheel notch delivered to this frame: the client hands it to the topmost
-- wheel-enabled frame under the cursor, and only a shown frame can be that.
function Frame:MouseWheel(delta)
	assert(self.shown and self.wheel, "MouseWheel on a frame that cannot receive it")
	if self.template:find("SecureHandlerMouseWheelTemplate") then
		RunSnippet(self.attributes._onmousewheel, self, self, { delta = delta })
	elseif self.scripts.OnMouseWheel then
		self.scripts.OnMouseWheel(self, delta)
	end
	RunHooks(self, "OnMouseWheel", delta)
end

-------------------------------------------------------------------------------
-- Global WoW API stubs
-------------------------------------------------------------------------------

UIParent = NewFrame("Frame", "UIParent")
UIParent.w, UIParent.h, UIParent.cx, UIParent.cy = SCREEN_W, SCREEN_H, SCREEN_W / 2, SCREEN_H / 2

function CreateFrame(kind, name, parent, template) return NewFrame(kind, name, parent, template) end
function SecureHandlerSetFrameRef(frame, label, ref) frame.framerefs[label] = ref end
function SecureHandlerWrapScript(frame, script, header, pre, post)
	assert(script == "OnClick")
	frame.wrap = { header = header, pre = pre, post = post }
end
function SecureHandlerExecute(frame, body)
	assert(not inCombat, "SecureHandlerExecute in combat")
	return RunSnippet(body, frame, frame)
end
function SetOverrideBindingClick(owner, priority, key, name, button)
	bindings[key] = { owner = owner, frame = frameByName[name], button = button }
end
function ClearOverrideBindings(owner)
	for key, b in pairs(bindings) do if b.owner == owner then bindings[key] = nil end end
end
function InCombatLockdown() return inCombat end
function UnitExists(unit) return unitState[unit] ~= nil end
function UnitIsUnit(a, b) return unitState[a] ~= nil and unitState[a] == unitState[b] end
function GetCursorPosition() return cursor.x, cursor.y end
function GetBuildInfo() return "1.60.1", "70009", "Sep 24 2026", 16001 end
function securecallfunction(fn, ...) return fn(...) end
function strsplit(sep, text)
	local parts = {}
	for part in (text .. sep):gmatch("(.-)" .. sep:gsub("%p", "%%%0")) do parts[#parts + 1] = part end
	return unpack(parts)
end
function geterrorhandler() return error end
WOW_PROJECT_ID = 1
WOW_PROJECT_MAINLINE = 1
SlashCmdList = {}
UISpecialFrames = {}
StaticPopupDialogs = {}
local lastPopup
function StaticPopup_Show(which) lastPopup = which return which end
YES, NO = "Yes", "No"
local settingsRegistered = {}
Settings = {
	RegisterCanvasLayoutCategory = function(frame, name)
		settingsRegistered.canvas, settingsRegistered.name = frame, name
		return { name = name, ID = 1 }
	end,
	RegisterAddOnCategory = function(category) settingsRegistered.category = category end,
	OpenToCategory = function() end,
}
function ButtonFrameTemplate_HidePortrait() end
function ButtonFrameTemplate_HideButtonBar() end
function HideUIPanel() end
local modifiers = { alt = false, ctrl = false, shift = false }
function IsAltKeyDown() return modifiers.alt end
function IsControlKeyDown() return modifiers.ctrl end
function IsShiftKeyDown() return modifiers.shift end
local MOUSE_BUTTONS = { LeftButton = "BUTTON1", RightButton = "BUTTON2", MiddleButton = "BUTTON3" }
function GetConvertedKeyOrButton(input)   -- BindingUtil.lua
	local n = input:match("^Button(%d+)$")
	return MOUSE_BUTTONS[input] or (n and ("BUTTON" .. n)) or input
end
function CreateKeyChordStringUsingMetaKeyState(key)   -- BindingUtil.lua, without META
	local chord = {}
	if IsAltKeyDown() then chord[#chord + 1] = "ALT" end
	if IsControlKeyDown() then chord[#chord + 1] = "CTRL" end
	if IsShiftKeyDown() then chord[#chord + 1] = "SHIFT" end
	chord[#chord + 1] = key
	return table.concat(chord, "-")
end
local baseBindings = { B = "TOGGLEBACKPACK" }
function GetBindingAction(key) return baseBindings[key] or "" end
BINDING_NAME_TOGGLEBACKPACK = "Toggle Backpack"
local rangeChecks = {}   -- slot -> true once EnableActionRangeCheck(slot, true) was called
C_ActionBar = {
	EnableActionRangeCheck = function(slot, enable) rangeChecks[slot] = enable or nil end,
	HasAction = function(slot) return slot >= 1 and slot <= 180 and slot % 5 ~= 0 end,
	GetActionTexture = function(slot) return 100000 + slot end,
	GetActionCooldown = function(slot) return { startTime = 0, duration = 0, isActive = false, modRate = 1 } end,
	GetActionBarPage = function() return barState.page end,
	HasBonusActionBar = function() return barState.bonus end,
	GetBonusBarIndex = function() return barState.bonusIndex end,
}

-------------------------------------------------------------------------------
-- Fake LibActionButton-1.0 (contract only; the real UpdateState snippet)
-------------------------------------------------------------------------------

local LABButton = {}

function LABButton:SetStateFromHandlerInsecure(state, kind, action)
	state = tostring(state)
	self.state_types[state] = kind or "empty"
	self.state_actions[state] = action
end

function LABButton:SetState(state, kind, action)
	if not state then state = self:GetAttribute("state") end
	state = tostring(state)
	self:SetStateFromHandlerInsecure(state, kind, action)
	self:UpdateState(state)
end

function LABButton:UpdateState(state)
	if not state then state = self:GetAttribute("state") end
	state = tostring(state)
	self:SetAttribute("labtype-" .. state, self.state_types[state])
	self:SetAttribute("labaction-" .. state, self.state_actions[state])
	if state ~= tostring(self:GetAttribute("state")) then return end
	assert(not inCombat, "LibActionButton UpdateState (insecure) in combat")
	RunSnippet(self:GetAttribute("UpdateState"), self, self.header, nil, self:GetAttribute("state"))
	self:UpdateAction()
end

function LABButton:GetAction(state)
	if not state then state = self:GetAttribute("state") end
	state = tostring(state)
	return self.state_types[state] or "empty", self.state_actions[state]
end

function LABButton:UpdateAction(force)
	local kind, action = self:GetAction()
	if force or kind ~= self._state_type or action ~= self._state_action then
		self._state_type, self._state_action = kind, action
		self.updates = (self.updates or 0) + 1
		if kind == "action" and C_ActionBar.HasAction(action) then
			self.icon:SetTexture(C_ActionBar.GetActionTexture(action))
			self.icon:Show()
			self:UpdateUsable()
		else
			self.icon:Hide()
		end
	end
end

function LABButton:UpdateConfig(config) self.config = config end

-- The library polls IsActionInRange; the 12.x client gives it nothing usable.
function LABButton:IsInRange() return nil end

function LABButton:UpdateUsable()
	if self.outOfRange then self.icon:SetVertexColor(0.8, 0.1, 0.1) else self.icon:SetVertexColor(1, 1, 1) end
end

local function InstallFakeLAB(path)
	local source = ReadFile(path)
	local minor = tonumber(source:match('local MINOR_VERSION = (%d+)'))
	local updateState = source:match('SetAttribute%("UpdateState", %[%[(.-)%]%]%)')
	assert(minor and updateState, "could not extract the UpdateState snippet from " .. path)

	local lib = LibStub:NewLibrary("LibActionButton-1.0", minor)
	lib.callbacks = { RegisterCallback = function() end, UnregisterCallback = function() end, Fire = function() end }
	lib.updateStateSnippet = updateState
	lib.buttons = {}

	-- The library's OnUpdate range loop (every 0.2 s over the buttons that
	-- have an action), reduced to the tint.
	function lib.RangeTick()
		for _, button in ipairs(lib.buttons) do
			if button._state_type == "action" and C_ActionBar.HasAction(button._state_action) then
				local inRange = button:IsInRange()
				local oldRange = button.outOfRange
				button.outOfRange = (inRange == false)
				if oldRange ~= button.outOfRange then button:UpdateUsable() end
			end
		end
	end

	function lib:CreateButton(id, name, header, config)
		assert(type(name) == "string" and type(header) == "table", "CreateButton: bad arguments")
		assert(header.template:find("SecureHandler"), "CreateButton: header must be a secure handler frame")
		local button = NewFrame("CheckButton", name, header, "ActionButtonTemplate, SecureActionButtonTemplate")
		button.icon, button.HotKey, button.Count, button.Name = NewRegion("texture"), NewRegion("fontstring"), NewRegion("fontstring"), NewRegion("fontstring")
		button.cooldown = NewFrame("Cooldown", nil, button)
		button.w, button.h = 45, 45
		button.id, button.header = id, header
		button.state_types, button.state_actions = {}, {}
		for k, v in pairs(LABButton) do button[k] = v end
		button:SetAttribute("state", 0)
		button:SetAttribute("UpdateState", updateState)
		button:UpdateConfig(config)
		button:UpdateAction(true)
		table.insert(lib.buttons, button)
		return button
	end
end

-------------------------------------------------------------------------------
-- Load the addon in TOC order
-------------------------------------------------------------------------------

local ns = {}
local loadedFiles = {}
for line in ReadFile("RadicalRadial/RadicalRadial.toc"):gmatch("[^\r\n]+") do
	if not line:match("^#") and line:match("%S") then
		local path = "RadicalRadial/" .. line:gsub("\\", "/"):gsub("%s+$", "")
		if path:find("LibActionButton") then
			InstallFakeLAB(path)
		else
			local chunk, err = loadfile(path)
			assert(chunk, err)
			chunk("RadicalRadial", ns)
		end
		loadedFiles[#loadedFiles + 1] = path
	end
end
assert(#loadedFiles >= 6, "TOC lists too few files")

-------------------------------------------------------------------------------
-- Scenario helpers
-------------------------------------------------------------------------------

local header = frameByName.RadicalRadialHeader
local ring   = frameByName.RadicalRadialRing
local opener = frameByName.RadicalRadialOpener1
local function slice(i) return frameByName["RadicalRadialSlice" .. i] end
local function AutoHideExpires()
	assert(ring.autoHide, "ring is not registered for auto-hide")
	ring:Hide()          -- the hover driver hides the frame securely; _onhide does the rest
end
local function trigger(i) return RadicalRadialDB.triggers[i] end

local function Fire(event, ...)
	local delivered = 0
	for _, f in ipairs(allFrames) do
		if f.events and f.events[event] and f.scripts.OnEvent then
			f.scripts.OnEvent(f, event, ...)
			delivered = delivered + 1
		end
	end
	assert(delivered > 0, "no frame registered for " .. event)
end
local function MoveTo(x, y) cursor.x, cursor.y = x, y end
local function Press(key)
	local b = assert(bindings[key], "no binding for " .. key)
	b.frame:Click(b.button, true)
end
local function Release(key)
	local b = bindings[key]      -- may be gone already (Escape clears its own binding on the down)
	if b then b.frame:Click(b.button, false) end
end
local function Wheel(dir) Press(dir); Release(dir) end
-- A wheel notch the way the client routes it: to the ring while the cursor is
-- over it (the topmost wheel-enabled frame there), otherwise to the bindings.
local function Scroll(dir)
	local ring = frameByName.RadicalRadialRing
	local l, b, w, h = ring:GetRect()
	local over = ring.shown and ring.wheel and cursor.x >= l and cursor.x <= l + w and cursor.y >= b and cursor.y <= b + h
	if over then ring:MouseWheel(dir == "MOUSEWHEELUP" and 1 or -1) else Wheel(dir) end
end
local function Uses() return #useActionLog end
local function LastUse() return useActionLog[#useActionLog] end
local function LastSlot() local u = LastUse() return u and u.action end
local function AssertSlots(base)
	for i = 1, 12 do
		local got = slice(i):GetAttribute("action")
		assert(got == base + i - 1, ("slice %d has slot %s, expected %d"):format(i, tostring(got), base + i - 1))
		assert(slice(i)._state_action == got, ("slice %d insecure side has %s"):format(i, tostring(slice(i)._state_action)))
	end
end
local function Label() return ns.label.text end
local function OutputContains(needle)
	for _, line in ipairs(output) do if line:find(needle, 1, true) then return true end end
	return false
end
local function rr(command) SlashCmdList.RADICALRADIAL(command) end

local function OpenAt(x, y) MoveTo(x, y); Press("BUTTON4") end
local function ReleaseAt(x, y) MoveTo(x, y); Release("BUTTON4") end

-------------------------------------------------------------------------------
-- Scenarios
-------------------------------------------------------------------------------

local scenarios = {}
local function scenario(name, fn) scenarios[#scenarios + 1] = { name = name, fn = fn } end

scenario("load: binding, slices on Bar 1, one LAB state per action page, label", function()
	Fire("ADDON_LOADED", "RadicalRadial")
	Fire("PLAYER_LOGIN")
	assert(bindings.BUTTON4, "BUTTON4 not bound")
	assert(bindings.BUTTON4.frame == opener and bindings.BUTTON4.button == "LeftButton")
	assert(opener:GetAttribute("barcount") == 2 and opener:GetAttribute("mode") == "hold" and opener:GetAttribute("autohide") == 3)
	assert(frameByName.RadicalRadialOpener2:GetAttribute("barcount") == 0, "unused openers must be inert")
	assert(header:GetAttribute("radius") == 120)
	assert(ring.w == 328 and ring.h == 328, "ring frame not sized to the ring square")
	assert(ring.attributes._onhide and ring.framerefs.header == header, "ring _onhide not wired")
	assert(header:GetAttribute("pageofbar2") == 6 and header:GetAttribute("pageofbar8") == 15)
	AssertSlots(1)
	for p = 1, 15 do
		assert(slice(3):GetAttribute("labtype-" .. p) == "action", "state " .. p .. " missing")
		assert(slice(3):GetAttribute("labaction-" .. p) == (p - 1) * 12 + 3, "state " .. p .. " wrong slot")
	end
	assert(slice(3):GetAttribute("labtype-16") == nil, "too many states")
	assert(Label() == "Bar 1", "label is " .. Label())
	assert(not ring:IsShown())
	assert(slice(5).icon.shown == false, "empty slot 5 should hide its icon")
	assert(slice(1).icon.shown == true and slice(1).icon.texture == 100001)
	assert(slice(1).header == frameByName.RadicalRadialVisual, "slices must use the visual frame as their LAB header")
	assert(slice(1).mouse == false, "slices must not take the mouse")
end)

scenario("press opens the ring at the cursor and installs wheel and Escape bindings", function()
	OpenAt(800, 450)
	assert(ring:IsShown(), "ring not shown")
	assert(ring.cx == 800 and ring.cy == 450, "ring not at cursor")
	assert(header:GetAttribute("open") == true)
	assert(bindings.MOUSEWHEELUP and bindings.MOUSEWHEELDOWN and bindings.ESCAPE, "temporary bindings missing")
	assert(opener:GetAttribute("type") == nil, "down click must not set an action")
	assert(Uses() == 0, "down click fired an action")
end)

scenario("wheel cycles bars and wraps; the insecure side repaints", function()
	local painted = slice(1).updates
	Wheel("MOUSEWHEELDOWN")
	assert(header:GetAttribute("page") == 2)
	AssertSlots(61)
	assert(slice(1).updates == painted + 1, "UpdateAction not called on page change")
	assert(slice(1).icon.texture == 100061, "icon not repainted")
	assert(Label() == "Bar 2", "label is " .. Label())
	Wheel("MOUSEWHEELDOWN")
	assert(header:GetAttribute("page") == 1)
	AssertSlots(1)
	Wheel("MOUSEWHEELUP")
	assert(header:GetAttribute("page") == 2)
	AssertSlots(61)
end)

scenario("release toward outer north fires Bar 2 slot 65 and closes", function()
	ReleaseAt(800, 550)
	assert(Uses() == 1 and LastSlot() == 65, "expected slot 65, got " .. tostring(LastSlot()))
	assert(LastUse().unit == nil, "bar ring slices must not carry a unit")
	assert(not ring:IsShown(), "ring still shown")
	assert(header:GetAttribute("open") == false)
	assert(not bindings.MOUSEWHEELUP and not bindings.MOUSEWHEELDOWN and not bindings.ESCAPE, "temporary bindings not cleared")
	assert(bindings.BUTTON4, "trigger binding was cleared")
end)

scenario("each open resets to page 1", function()
	OpenAt(800, 450)
	assert(header:GetAttribute("page") == 1)
	AssertSlots(1)
	ReleaseAt(801, 451)
end)

scenario("geometry: inner and outer sectors", function()
	local cases = {
		{ 0, 40, 1 }, { 40, 0, 2 }, { 0, -40, 3 }, { -40, 0, 4 },    -- inner N E S W
		{ 0, 100, 5 }, { 70, 70, 6 }, { 100, 0, 7 }, { 70, -70, 8 }, -- outer N NE E SE
		{ 0, -100, 9 }, { -70, -70, 10 }, { -100, 0, 11 }, { -70, 70, 12 },
		{ 0, 67, 5 }, { 0, 65, 1 },                                  -- tier boundary at 0.55 R = 66
		{ 28, 30, 1 }, { 30, 28, 2 },                                -- inner sector boundary at 45 degrees
		{ 0, 400, 5 }, { -700, 0, 11 },                              -- far outside the ring still selects
	}
	for _, c in ipairs(cases) do
		local before = Uses()
		OpenAt(800, 450)
		ReleaseAt(800 + c[1], 450 + c[2])
		assert(Uses() == before + 1, ("offset (%d,%d): nothing fired"):format(c[1], c[2]))
		assert(LastSlot() == c[3], ("offset (%d,%d): expected slot %d, got %s"):format(c[1], c[2], c[3], tostring(LastSlot())))
	end
end)

scenario("release in the dead zone cancels", function()
	local before = Uses()
	OpenAt(800, 450)
	ReleaseAt(803, 452)
	assert(Uses() == before, "dead zone fired an action")
	assert(opener:GetAttribute("type") == nil)
	assert(not ring:IsShown())
end)

scenario("Escape cancels; the later release does nothing", function()
	local before = Uses()
	OpenAt(800, 450)
	Press("ESCAPE"); Release("ESCAPE")
	assert(not ring:IsShown(), "Escape did not close the ring")
	assert(header:GetAttribute("open") == false)
	ReleaseAt(800, 550)
	assert(Uses() == before, "release after Escape fired an action")
end)

scenario("Bar 1 follows bonus bar, vehicle and override pages; unknown pages fall back", function()
	barState.bonus = true
	OpenAt(800, 450); AssertSlots(73); ReleaseAt(800, 450)
	barState.bonus = false
	barState.vehicle = true
	OpenAt(800, 450); AssertSlots(133); ReleaseAt(800, 450)
	barState.vehicle = false
	barState.override = true
	OpenAt(800, 450); AssertSlots(157); ReleaseAt(800, 450)
	barState.override = false
	barState.temp = true
	OpenAt(800, 450); AssertSlots(145); ReleaseAt(800, 450)
	barState.temp = false
	barState.page = 3
	OpenAt(800, 450); AssertSlots(25); ReleaseAt(800, 450)
	barState.page = 1
	-- a bonus bar index outside the 15 pages falls back to page 1 instead of emptying the ring
	barState.bonus, barState.bonusIndex = true, 16
	OpenAt(800, 450); AssertSlots(1); ReleaseAt(800, 450)
	barState.bonus, barState.bonusIndex = false, 7
	-- Bar 2 in the cycle is fixed regardless of stance
	barState.bonus = true
	OpenAt(800, 450); Wheel("MOUSEWHEELDOWN"); AssertSlots(61); ReleaseAt(800, 450)
	barState.bonus = false
end)

scenario("all eight bars resolve to their action pages", function()
	rr("bars 1 2 3 4 5 6 7 8")
	local bases = { 1, 61, 49, 25, 37, 145, 157, 169 }
	OpenAt(800, 450)
	for page, base in ipairs(bases) do
		assert(header:GetAttribute("page") == page)
		AssertSlots(base)
		assert(Label() == "Bar " .. page, "label is " .. Label())
		Wheel("MOUSEWHEELDOWN")
	end
	assert(header:GetAttribute("page") == 1, "did not wrap")
	ReleaseAt(800, 450)
	rr("bars 1 2")
end)

scenario("presentation highlight follows the cursor", function()
	OpenAt(800, 450)
	MoveTo(800, 550)
	ring.scripts.OnUpdate(ring)
	for i = 1, 12 do
		assert((slice(i).highlightLocked == true) == (i == 5), "highlight wrong on slice " .. i)
	end
	MoveTo(801, 451)
	ring.scripts.OnUpdate(ring)
	for i = 1, 12 do assert(not slice(i).highlightLocked) end
	MoveTo(900, 450)
	ring.scripts.OnUpdate(ring)
	assert(slice(7).highlightLocked)
	ReleaseAt(900, 450)
	assert(not slice(7).highlightLocked, "highlight not cleared on close")
end)

scenario("slash commands: bars, scale, status, preview, debug, bind, reset", function()
	rr("bars 1 2 3")
	assert(opener:GetAttribute("barcount") == 3)
	OpenAt(800, 450); Wheel("MOUSEWHEELDOWN"); Wheel("MOUSEWHEELDOWN"); AssertSlots(49); ReleaseAt(800, 450)

	rr("scale 1.4")
	assert(header:GetAttribute("radius") == 168, "radius " .. tostring(header:GetAttribute("radius")))
	assert(frameByName.RadicalRadialVisual.scale == 1.4)
	assert(math.abs(ring.w - 328 * 1.4) < 0.001, "ring frame does not follow the scale")
	OpenAt(800, 450); ReleaseAt(800, 500)   -- r = 50: inner at scale 1.4, outer at scale 1
	assert(LastSlot() == 1, "scaled geometry: expected slot 1, got " .. tostring(LastSlot()))
	rr("scale 9")
	assert(RadicalRadialDB.scale == 2, "scale not clamped")
	rr("scale 1")

	rr("status")
	assert(OutputContains("secure snippets: |cff33ff33OK|r"), "status did not report snippets OK")
	assert(OutputContains("client paging: GetPage=1"), "status did not report the paging state")

	rr("preview"); assert(ring:IsShown())
	rr("preview"); assert(not ring:IsShown())

	rr("debug"); assert(RadicalRadialDB.debug == true and header:GetAttribute("debug") == true)
	OpenAt(800, 450); ReleaseAt(800, 550)
	assert(OutputContains("opener 1 click: LeftButton down"), "debug hook output missing")
	assert(OutputContains("RR secure|r press: trigger 1 opened the none ring at cursor"))
	assert(OutputContains("RR secure|r release: slice 5"))
	rr("debug"); assert(RadicalRadialDB.debug == false)

	rr("bind SHIFT-BUTTON5")
	assert(bindings["SHIFT-BUTTON5"] and not bindings.BUTTON4, "rebind failed")
	rr("bind none")
	assert(not bindings["SHIFT-BUTTON5"], "bind none did not clear")
	rr("reset")
	assert(trigger(1).key == "BUTTON4" and RadicalRadialDB.scale == 1 and #trigger(1).bars == 2 and #RadicalRadialDB.triggers == 1)
	assert(bindings.BUTTON4 and header:GetAttribute("radius") == 120)
end)

scenario("hold mode never arms auto-hide; every hide path resets the open state", function()
	OpenAt(800, 450)
	assert(ring.autoHide == nil, "hold mode registered auto-hide")
	ring:Hide()   -- e.g. /rr preview toggled by hand, or any other hide
	assert(header:GetAttribute("open") == false and not bindings.ESCAPE, "_onhide did not reset the state")
	ReleaseAt(800, 550)
	assert(LastSlot() ~= 5 or Uses() == 0 or not ring:IsShown())
end)

scenario("tap mode: a dead-zone release keeps the ring open, the next release fires, a dead-zone press cancels", function()
	rr("mode tap")
	assert(opener:GetAttribute("mode") == "tap")
	local before = Uses()
	OpenAt(800, 450)
	ReleaseAt(801, 451)
	assert(ring:IsShown() and header:GetAttribute("open") == true, "tap did not keep the ring open")
	assert(bindings.MOUSEWHEELUP and bindings.ESCAPE, "bindings dropped while the ring stayed open")
	assert(Uses() == before, "tap fired an action")
	Wheel("MOUSEWHEELDOWN")
	AssertSlots(61)
	MoveTo(800, 550); Press("BUTTON4")
	assert(ring:IsShown(), "second press closed the ring outside the dead zone")
	Release("BUTTON4")
	assert(Uses() == before + 1 and LastSlot() == 65, "second release did not fire slot 65")
	assert(not ring:IsShown() and header:GetAttribute("open") == false)
	-- tap, then a press in the dead zone cancels without firing
	OpenAt(800, 450); ReleaseAt(800, 450)
	assert(ring:IsShown())
	MoveTo(802, 449); Press("BUTTON4")
	assert(not ring:IsShown() and header:GetAttribute("open") == false, "dead-zone press did not cancel")
	Release("BUTTON4")
	assert(Uses() == before + 1, "cancel fired an action")
	-- hold-and-release still works in tap mode
	OpenAt(800, 450); ReleaseAt(900, 450)
	assert(Uses() == before + 2 and LastSlot() == 7)
	rr("mode hold")
end)

scenario("tap mode arms auto-hide on open; expiry cleans up state and bindings", function()
	rr("mode tap"); rr("autohide 2")
	OpenAt(800, 450)
	assert(ring.autoHide == 2, "auto-hide not registered")
	ReleaseAt(800, 450)
	assert(ring:IsShown())
	AutoHideExpires()
	assert(not ring:IsShown() and header:GetAttribute("open") == false, "state not reset after auto-hide")
	assert(not bindings.MOUSEWHEELUP and not bindings.ESCAPE, "bindings survived auto-hide")
	assert(ring.autoHide == nil, "auto-hide registration not dropped")
	assert(bindings.BUTTON4, "trigger binding lost")
	local before = Uses()
	ReleaseAt(800, 550)
	assert(Uses() == before, "release after auto-hide fired")
	rr("autohide 0")
	OpenAt(800, 450)
	assert(ring.autoHide == nil, "autohide 0 still registered")
	ReleaseAt(800, 450); Press("ESCAPE"); Release("ESCAPE")
	rr("mode hold"); rr("autohide 3")
end)

scenario("a second trigger has its own bars and mode; pressing it over another ring cancels", function()
	rr("2 bind BUTTON5"); rr("2 bars 3 4"); rr("2 mode tap")
	assert(#RadicalRadialDB.triggers == 2 and trigger(2).key == "BUTTON5" and trigger(2).mode == "tap")
	assert(bindings.BUTTON5 and bindings.BUTTON5.frame == frameByName.RadicalRadialOpener2)
	assert(frameByName.RadicalRadialOpener2:GetAttribute("barcount") == 2 and frameByName.RadicalRadialOpener2:GetAttribute("bar1") == 3)
	local before = Uses()
	MoveTo(800, 450); Press("BUTTON5")
	assert(ring:IsShown() and header:GetAttribute("active") == 2)
	AssertSlots(49)
	assert(Label() == "Bar 3", "label is " .. Label())
	Wheel("MOUSEWHEELDOWN"); AssertSlots(25)
	MoveTo(800, 550); Release("BUTTON5")
	assert(Uses() == before + 1 and LastSlot() == 29, "trigger 2 release fired " .. tostring(LastSlot()))
	-- trigger 1's ring is open; trigger 2's press cancels it and fires nothing
	OpenAt(800, 450)
	MoveTo(800, 550); Press("BUTTON5")
	assert(not ring:IsShown() and header:GetAttribute("open") == false, "second trigger did not cancel")
	Release("BUTTON5"); Release("BUTTON4")
	assert(Uses() == before + 1, "cancelling fired an action")
	-- trigger 1 is unaffected
	OpenAt(800, 450); AssertSlots(1); ReleaseAt(800, 550)
	assert(LastSlot() == 5)
	rr("triggers")
	assert(OutputContains("trigger 2: BUTTON5 | bars 3 4 | harm none | help none | capture focus | mode tap"), "triggers listing missing")
	rr("2 remove")
	assert(#RadicalRadialDB.triggers == 1 and not bindings.BUTTON5, "remove failed")
	rr("1 remove")
	assert(#RadicalRadialDB.triggers == 1, "trigger 1 must survive remove")
	-- addressing trigger 3 creates an unbound trigger 2 in between
	rr("3 bind F")
	assert(#RadicalRadialDB.triggers == 3 and trigger(2).key == "" and bindings.F.frame == frameByName.RadicalRadialOpener3)
	rr("3 remove"); rr("2 remove")
	assert(#RadicalRadialDB.triggers == 1)
end)

local function Mouseover(kind)
	if kind == "enemy" then unitState.mouseover = { attack = true }
	elseif kind == "friend" then unitState.mouseover = { assist = true }
	elseif kind == "dead enemy" then unitState.mouseover = { attack = true, dead = true }
	else unitState.mouseover = nil end
end

scenario("context: over an enemy the harm ring opens, the press captures focus, slices aim at it", function()
	rr("harm 3")
	assert(opener:GetAttribute("harmcount") == 1 and opener:GetAttribute("harm1") == 3 and opener:GetAttribute("capture") == "focus")
	Mouseover("enemy")
	local before = Uses()
	OpenAt(800, 450)
	assert(Uses() == before + 1 and LastUse().macrotext == "/focus [@mouseover,exists,nodead]", "down click did not run the capture macro")
	assert(ring:IsShown() and header:GetAttribute("context") == "harm" and header:GetAttribute("unit") == "focus")
	AssertSlots(49)
	for i = 1, 12 do assert(slice(i):GetAttribute("unit") == "focus", "slice " .. i .. " not aimed at focus") end
	assert(Label() == "Bar 3 · enemy @focus", "label is " .. Label())
	ReleaseAt(800, 550)
	assert(Uses() == before + 2 and LastSlot() == 53 and LastUse().unit == "focus", "release did not fire slot 53 on focus")
	assert(opener:GetAttribute("useOnKeyDown") == false, "useOnKeyDown left on")
	-- the next plain open is aimed at nothing again
	Mouseover(nil)
	OpenAt(800, 450)
	assert(header:GetAttribute("context") == "none" and header:GetAttribute("unit") == nil)
	AssertSlots(1)
	for i = 1, 12 do assert(slice(i):GetAttribute("unit") == nil, "unit not cleared on slice " .. i) end
	assert(Label() == "Bar 1", "label is " .. Label())
	ReleaseAt(800, 450)
end)

scenario("context: a friend with no help ring, a dead enemy and no mouseover all open the normal bars without capture", function()
	local before = Uses()
	for _, kind in ipairs({ "friend", "dead enemy", nil }) do
		Mouseover(kind)
		OpenAt(800, 450)
		assert(Uses() == before, "capture ran for " .. tostring(kind))
		assert(header:GetAttribute("context") == "none" and header:GetAttribute("unit") == nil, "context wrong for " .. tostring(kind))
		AssertSlots(1)
		ReleaseAt(800, 450)
	end
	rr("help 4")
	Mouseover("friend")
	OpenAt(800, 450)
	assert(Uses() == before + 1 and LastUse().macrotext:find("^/focus"))
	assert(header:GetAttribute("context") == "help")
	AssertSlots(25)
	assert(Label() == "Bar 4 · friend @focus", "label is " .. Label())
	ReleaseAt(800, 550)
	assert(LastSlot() == 29 and LastUse().unit == "focus")
	Mouseover(nil)
	rr("help none")
	assert(opener:GetAttribute("helpcount") == 0)
end)

scenario("context: capture target uses /target, capture none skips the macro but keeps the ring", function()
	rr("harm 3 4"); rr("capture target")
	Mouseover("enemy")
	local before = Uses()
	OpenAt(800, 450)
	assert(LastUse().macrotext == "/target [@mouseover,exists,nodead]")
	assert(header:GetAttribute("unit") == "target" and slice(1):GetAttribute("unit") == "target")
	-- the wheel cycles within the context list
	Wheel("MOUSEWHEELDOWN"); AssertSlots(25); assert(Label() == "Bar 4 · enemy @target")
	Wheel("MOUSEWHEELDOWN"); AssertSlots(49)
	ReleaseAt(800, 550)
	assert(LastSlot() == 53 and LastUse().unit == "target")

	rr("capture none")
	before = Uses()
	OpenAt(800, 450)
	assert(Uses() == before, "capture none ran a macro")
	assert(header:GetAttribute("context") == "harm" and header:GetAttribute("unit") == nil)
	AssertSlots(49)
	assert(Label() == "Bar 3 · enemy", "label is " .. Label())
	ReleaseAt(800, 550)
	assert(LastSlot() == 53 and LastUse().unit == nil)

	-- an Escape after a capturing press leaves useOnKeyDown off for the release
	rr("capture focus")
	before = Uses()
	OpenAt(800, 450)
	assert(Uses() == before + 1)
	Press("ESCAPE"); Release("ESCAPE")
	ReleaseAt(800, 550)
	assert(Uses() == before + 1, "release after Escape fired")
	assert(opener:GetAttribute("useOnKeyDown") == false)

	Mouseover(nil)
	rr("harm none")
	rr("triggers")
	assert(OutputContains("trigger 1: BUTTON4 | bars 1 2 | harm none | help none | capture focus | mode hold"))
end)

scenario("old saved variables migrate to the triggers list", function()
	local current = RadicalRadialDB
	RadicalRadialDB = { trigger = "F", bars = { 3, 4 }, scale = 1.5, debug = false }
	ns.LoadDB()
	assert(RadicalRadialDB.trigger == nil and RadicalRadialDB.bars == nil, "old keys not removed")
	assert(#RadicalRadialDB.triggers == 1 and trigger(1).key == "F" and trigger(1).bars[2] == 4)
	assert(trigger(1).mode == "hold" and trigger(1).autohide == 3, "trigger defaults not filled")
	ns.ApplyConfig()
	assert(bindings.F and bindings.F.frame == opener and not bindings.BUTTON4)
	assert(header:GetAttribute("radius") == 180)
	MoveTo(800, 450); Press("F"); AssertSlots(49); Release("F")
	-- garbage in the saved trigger is clamped
	RadicalRadialDB = { triggers = { { key = "none", bars = { 0, 9, "5" }, mode = "hover", autohide = -1 } } }
	ns.LoadDB()
	assert(trigger(1).key == "" and #trigger(1).bars == 1 and trigger(1).bars[1] == 5 and trigger(1).mode == "hold" and trigger(1).autohide == 0)
	RadicalRadialDB = current
	ns.LoadDB(); ns.ApplyConfig()
	assert(bindings.BUTTON4 and not bindings.F)
end)

scenario("config changes in combat wait for combat to end; paging still works in combat", function()
	local before = header:GetAttribute("radius")
	inCombat = true
	rr("scale 1.2")
	assert(RadicalRadialDB.scale == 1.2)
	assert(header:GetAttribute("radius") == before, "applied config in combat")
	OpenAt(800, 450); Wheel("MOUSEWHEELDOWN"); AssertSlots(61); ReleaseAt(800, 550)
	assert(LastSlot() == 65)
	inCombat = false
	Fire("PLAYER_REGEN_ENABLED")
	assert(header:GetAttribute("radius") == 144, "pending config not applied")
	rr("scale 1")
end)

scenario("snippets never touch a name outside the restricted environment", function()
	-- RestrictedEnv errors on any unknown global, so a full press/wheel/release
	-- pass with debug on exercises every branch of every snippet.
	rr("debug")
	OpenAt(800, 450); Wheel("MOUSEWHEELDOWN"); Wheel("MOUSEWHEELUP"); ReleaseAt(800, 550)
	OpenAt(800, 450); ReleaseAt(800, 450)
	OpenAt(800, 450); Press("ESCAPE"); Release("ESCAPE"); ReleaseAt(800, 450)
	rr("harm 3"); Mouseover("enemy")
	OpenAt(800, 450); Wheel("MOUSEWHEELDOWN"); ReleaseAt(800, 550)
	Mouseover(nil); rr("harm none")
	rr("mode tap")
	OpenAt(800, 450); ReleaseAt(800, 450); MoveTo(800, 550); Press("BUTTON4"); Release("BUTTON4")
	OpenAt(800, 450); ReleaseAt(800, 450); Press("BUTTON4"); Release("BUTTON4")
	rr("mode hold")
	rr("debug")
end)

-------------------------------------------------------------------------------
-- Options window
-------------------------------------------------------------------------------

local cfg = frameByName.RadicalRadialConfig
local cui = ns.configUI
local function ClickUI(widget) widget:Click("LeftButton", false) end
local function Bars(t) return table.concat(t, " ") end

scenario("options window: /rr opens it, it mirrors the saved variables, Escape-close and Options entries exist", function()
	rr("reset")
	assert(not cfg:IsShown())
	rr("")
	assert(cfg:IsShown(), "/rr did not open the window")
	assert(cui.key.text == "BUTTON4", "key button shows " .. tostring(cui.key.text))
	assert(cui.bars[1].checked and cui.bars[2].checked and not cui.bars[3].checked)
	assert(cui.modeHold.checked and not cui.modeTap.checked)
	assert(cui.capFocus.checked)
	assert(cui.scale.sliderValue == 1 and cui.autohide.sliderValue == 3)
	assert(cui.panel.shown and not cui.missing.shown)
	assert(not cui.remove.shown, "trigger 1 must not offer removal")
	assert(cui.status.text:find("immediately"))
	assert(UISpecialFrames[1] == "RadicalRadialConfig", "not closable with Escape")
	assert(settingsRegistered.name == "Radical Radial" and settingsRegistered.category, "no Options entry")
	rr("config"); assert(not cfg:IsShown())
	RadicalRadial_OnAddonCompartmentClick(); assert(cfg:IsShown())
end)

scenario("options window: bar boxes keep the wheel order, the last bar stays, context boxes, radios and sliders apply", function()
	ClickUI(cui.bars[5])
	assert(Bars(trigger(1).bars) == "1 2 5", "order " .. Bars(trigger(1).bars))
	assert(opener:GetAttribute("barcount") == 3 and opener:GetAttribute("bar3") == 5)
	ClickUI(cui.bars[1])
	assert(Bars(trigger(1).bars) == "2 5")
	assert(opener:GetAttribute("bar1") == 2 and cui.barsText.text:find("2, 5"))
	ClickUI(cui.bars[2]); ClickUI(cui.bars[5])
	assert(Bars(trigger(1).bars) == "5", "last bar was removed")
	assert(cui.bars[5].checked, "box for the last bar must stay ticked")
	assert(OutputContains("a trigger needs at least one bar"))
	ClickUI(cui.harm[3]); ClickUI(cui.harm[4])
	assert(Bars(trigger(1).harm) == "3 4" and opener:GetAttribute("harmcount") == 2)
	ClickUI(cui.harm[3])
	assert(Bars(trigger(1).harm) == "4" and opener:GetAttribute("harm1") == 4)
	ClickUI(cui.help[2])
	assert(trigger(1).help[1] == 2 and cui.help[2].checked)
	ClickUI(cui.modeTap)
	assert(trigger(1).mode == "tap" and opener:GetAttribute("mode") == "tap" and cui.modeTap.checked and not cui.modeHold.checked)
	assert(cui.autohide.enabled == true, "auto-hide slider must be enabled in tap mode")
	cui.autohide:SetValue(2); cui.autohide.scripts.OnMouseUp(cui.autohide)
	assert(trigger(1).autohide == 2 and opener:GetAttribute("autohide") == 2)
	ClickUI(cui.modeHold)
	assert(trigger(1).mode == "hold" and cui.autohide.enabled == false, "auto-hide slider must be disabled in hold mode")
	ClickUI(cui.capTarget)
	assert(trigger(1).capture == "target" and opener:GetAttribute("capture") == "target")
	cui.scale:SetValue(1.4); cui.scale.scripts.OnMouseUp(cui.scale)
	assert(RadicalRadialDB.scale == 1.4 and header:GetAttribute("radius") == 168)
	ClickUI(cui.debug)
	assert(RadicalRadialDB.debug == true and header:GetAttribute("debug") == true)
	ClickUI(cui.debug)
	assert(RadicalRadialDB.debug == false)
	rr("bars 1 2"); rr("harm none"); rr("help none"); rr("capture focus"); rr("scale 1")
	assert(cui.bars[1].checked and not cui.bars[5].checked and not cui.harm[4].checked and cui.capFocus.checked,
		"slash changes must refresh the window")
end)

scenario("options window: key capture takes chords, thumb buttons and Escape, refuses left and right, names overridden bindings", function()
	ClickUI(cui.key)
	assert(cui.capturing and cfg.keyboard == true and cui.hint.shown, "capture did not start")
	cfg.scripts.OnKeyDown(cfg, "LSHIFT")
	assert(cui.capturing, "a modifier alone must not end the capture")
	modifiers.shift = true
	cfg.scripts.OnKeyDown(cfg, "F")
	modifiers.shift = false
	assert(trigger(1).key == "SHIFT-F" and bindings["SHIFT-F"] and not bindings.BUTTON4, "chord not bound")
	assert(not cui.capturing and cfg.keyboard == false and cui.key.text == "SHIFT-F")

	ClickUI(cui.key)
	cui.key:Click("Button5", true)
	assert(trigger(1).key == "BUTTON5" and bindings.BUTTON5, "mouse button not bound")

	ClickUI(cui.key)
	cfg.scripts.OnMouseDown(cfg, "LeftButton")
	assert(trigger(1).key == "BUTTON5" and not cui.capturing)
	assert(OutputContains("left and right mouse buttons cannot be triggers"))

	ClickUI(cui.key)
	cfg.scripts.OnKeyDown(cfg, "ESCAPE")
	assert(trigger(1).key == "BUTTON5" and not cui.capturing and cfg.keyboard == false, "Escape must cancel")

	ClickUI(cui.key)
	cfg.scripts.OnKeyDown(cfg, "B")
	assert(trigger(1).key == "B" and OutputContains("B was bound to Toggle Backpack"))

	ClickUI(cui.clear)
	assert(trigger(1).key == "" and not bindings.B and cui.key.text == "Click to bind")
	rr("bind BUTTON4")
	assert(bindings.BUTTON4)
end)

scenario("options window: adding, selecting and removing triggers, one key per trigger, reset asks first", function()
	ClickUI(cui.triggerButtons[2])
	assert(cui.selected == 2 and cui.missing.shown and not cui.panel.shown)
	assert(cui.triggerButtons[2].text == "+ Trigger 2")
	ClickUI(cui.addButton)
	assert(trigger(2) and trigger(2).key == "" and cui.panel.shown and cui.remove.shown)
	assert(frameByName.RadicalRadialOpener2:GetAttribute("barcount") == 2)
	ClickUI(cui.key)
	cui.key:Click("Button4", true)
	assert(trigger(2).key == "BUTTON4" and trigger(1).key == "", "the key must move to trigger 2")
	assert(bindings.BUTTON4.frame == frameByName.RadicalRadialOpener2)
	assert(OutputContains("trigger 1 gives up BUTTON4"))
	ClickUI(cui.remove)
	assert(not trigger(2) and cui.missing.shown)
	assert(frameByName.RadicalRadialOpener2:GetAttribute("barcount") == 0 and not bindings.BUTTON4)
	ClickUI(cui.triggerButtons[1])
	assert(cui.panel.shown and cui.key.text == "Click to bind")
	ClickUI(cui.reset)
	assert(lastPopup == "RADICALRADIAL_RESET" and trigger(1).key == "", "reset must ask first")
	StaticPopupDialogs.RADICALRADIAL_RESET.OnAccept()
	assert(trigger(1).key == "BUTTON4" and bindings.BUTTON4 and cui.key.text == "BUTTON4")
end)

scenario("options window: in combat a change is saved and shown as pending, then applied when combat ends", function()
	inCombat = true
	Fire("PLAYER_REGEN_DISABLED")
	assert(cui.status.text:find("In combat") and cui.preview.enabled == false)
	ClickUI(cui.bars[3])
	assert(Bars(trigger(1).bars) == "1 2 3" and opener:GetAttribute("barcount") == 2, "secure side changed in combat")
	assert(cui.bars[3].checked, "window must show the saved change")
	ClickUI(cui.key)
	assert(not cui.capturing and OutputContains("not in combat"))
	inCombat = false
	Fire("PLAYER_REGEN_ENABLED")
	assert(opener:GetAttribute("barcount") == 3 and cui.status.text:find("immediately") and cui.preview.enabled == true)
	rr("bars 1 2")
	rr("config"); assert(not cfg:IsShown())
end)

scenario("wheel over the ring goes to the ring's own secure handler; outside its rect the binding still pages", function()
	rr("debug")
	OpenAt(800, 450)
	assert(ring.wheel == true and ring.mouse == false, "the ring must take the wheel but not clicks")
	assert(ring:GetFrameRef("header") == header)
	ring:MouseWheel(-1)   -- wheel down: next bar
	assert(header:GetAttribute("page") == 2, "ring wheel did not page"); AssertSlots(61); assert(Label() == "Bar 2")
	assert(OutputContains("page 2 (wheel via ring)") and OutputContains("ring wheel: -1"), "ring path not reported")
	ring:MouseWheel(1)    -- wheel up: previous bar
	assert(header:GetAttribute("page") == 1); AssertSlots(1)
	-- past the ring's edge no wheel-enabled frame is under the cursor, so the override binding fires
	MoveTo(800 + ring.w, 450)
	Scroll("MOUSEWHEELDOWN")
	assert(header:GetAttribute("page") == 2 and OutputContains("page 2 (wheel via binding)"), "binding fallback failed"); AssertSlots(61)
	MoveTo(800, 450)
	Scroll("MOUSEWHEELUP")
	assert(header:GetAttribute("page") == 1); AssertSlots(1)
	ReleaseAt(800, 450)
	assert(not ring:IsShown() and not pcall(ring.MouseWheel, ring, -1), "a hidden ring must not receive the wheel")
	assert(header:GetAttribute("page") == 1)
	rr("debug")
end)

scenario("range: slices tint from ACTION_RANGE_CHECK_UPDATE and ask the client to watch the slots they show", function()
	local LAB = LibStub("LibActionButton-1.0")
	rangeChecks = {}
	OpenAt(800, 450)
	LAB.RangeTick()
	for i = 1, 12 do
		if C_ActionBar.HasAction(i) then assert(rangeChecks[i] == true, "slot " .. i .. " not watched") end
	end
	assert(rangeChecks[5] == nil, "an empty slot must not be watched")
	assert(slice(3).outOfRange == false and slice(3).icon.vertex[1] == 1, "slice 3 tinted before any report")
	Fire("ACTION_RANGE_CHECK_UPDATE", 3, false, true)
	LAB.RangeTick()
	assert(slice(3).outOfRange == true and slice(3).icon.vertex[1] == 0.8, "slice 3 not tinted red")
	assert(slice(1).icon.vertex[1] == 1, "slice 1 tinted without a report")
	Fire("ACTION_RANGE_CHECK_UPDATE", 3, true, true)
	LAB.RangeTick()
	assert(slice(3).icon.vertex[1] == 1, "slice 3 still red back in range")
	-- a report for a slot on another bar applies once the wheel shows it
	Fire("ACTION_RANGE_CHECK_UPDATE", 63, false, true)
	Scroll("MOUSEWHEELDOWN"); LAB.RangeTick()
	assert(slice(3)._state_action == 63 and slice(3).icon.vertex[1] == 0.8, "slot 63 not red after paging")
	assert(rangeChecks[63] == true, "slot 63 not watched after paging")
	-- an action that stops checking range loses the tint
	Fire("ACTION_RANGE_CHECK_UPDATE", 63, false, false); LAB.RangeTick()
	assert(slice(3).icon.vertex[1] == 1, "tint kept for an action without a range")
	ReleaseAt(800, 450)
	-- the client's flag is shared with Blizzard's bars, so it is asserted again on every open
	rangeChecks = {}
	OpenAt(800, 450); LAB.RangeTick()
	assert(rangeChecks[1] == true, "watch not asserted again on open")
	ReleaseAt(800, 450)
end)

scenario("context: a capture still runs when the unit of the last release is gone", function()
	rr("harm 3"); rr("capture target")
	Mouseover("enemy")
	OpenAt(800, 450); ReleaseAt(800, 550)
	assert(opener:GetAttribute("unit") == "target" and unitState.target ~= nil, "first capture did not aim the opener")
	unitState.target = nil      -- the target died or was cleared
	Mouseover("enemy")          -- another enemy under the cursor
	local before = Uses()
	OpenAt(800, 450)
	assert(Uses() == before + 1 and LastUse().macrotext == "/target [@mouseover,exists,nodead]",
		"capture skipped: the opener's stale unit blocked the click")
	assert(unitState.target == unitState.mouseover, "target not captured")
	ReleaseAt(800, 550)
	assert(LastSlot() == 53 and LastUse().unit == "target")
	-- the same with focus
	rr("capture focus")
	unitState.focus = nil
	Mouseover("enemy")
	before = Uses()
	OpenAt(800, 450)
	assert(Uses() == before + 1 and unitState.focus == unitState.mouseover, "focus capture skipped")
	ReleaseAt(800, 550)
	assert(LastSlot() == 53 and LastUse().unit == "focus")
	-- a cancelled release leaves the opener aimed at nothing
	Mouseover("enemy")
	OpenAt(800, 450); ReleaseAt(800, 450)
	assert(opener:GetAttribute("unit") == nil, "cancel left the opener aimed")
	Mouseover(nil); rr("harm none"); rr("capture focus")
end)

scenario("debug: a capturing press reports what it left behind", function()
	rr("debug"); rr("harm 3"); rr("capture target")
	unitState.target = nil
	Mouseover("enemy")
	OpenAt(800, 450)
	assert(OutputContains("after capture: target the mouseover, focus"), "capture report missing")
	ReleaseAt(800, 450)
	Mouseover(nil); rr("harm none"); rr("capture focus"); rr("debug")
	assert(not RadicalRadialDB.debug)
end)

-------------------------------------------------------------------------------
-- Run
-------------------------------------------------------------------------------

local failures = 0
for _, s in ipairs(scenarios) do
	local ok, err = pcall(s.fn)
	realPrint((ok and "PASS  " or "FAIL  ") .. s.name .. (ok and "" or ("\n      " .. tostring(err))))
	if not ok then failures = failures + 1 end
end
realPrint(("%d scenarios, %d failed"):format(#scenarios, failures))
return failures
