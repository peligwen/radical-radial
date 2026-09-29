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
-- SetState with its action/spell/item/macro/empty kinds, GetAction,
-- UpdateAction, the labtype-/labaction- attributes) and runs the real
-- "UpdateState" snippet, extracted from the vendored file, so the secure
-- side is exercised as it will be in game. The cursor (GetCursorInfo and the
-- pickup functions), macros, mounts and action slots are faked far enough
-- for the ring editor and the bar-to-ring copy.
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
function Region:SetAtlas(name) self.atlas = name end

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
function Frame:SetPropagateKeyboardInput(v)
	assert(not inCombat, "SetPropagateKeyboardInput is protected in combat")
	self.propagate = v
end
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
function Frame:SetHighlightTexture(t) self.highlightTexture = t end
-- EditBox
function Frame:SetAutoFocus(v) self.autoFocus = v end
function Frame:SetMaxLetters(n) self.maxLetters = n end
function Frame:SetFocus() self.focused = true end
function Frame:ClearFocus() self.focused = false end
function Frame:HasFocus() return self.focused == true end
function Frame:HighlightText() self.highlighted = true end
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
-- Shown, with every ancestor shown: a child of a hidden frame keeps its own
-- flag but is not visible (and takes no mouse).
function Frame:IsVisible() return self.shown and (self.parent == nil or self.parent:IsVisible()) end
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
-- unit that does not exist (that check silently skipped target captures),
-- runs a named "macro" before it looks at "macrotext", and ignores a type
-- it has no action for ("empty").
local function SecureActionButtonClick(frame, button, down)
	local useOnKeyDown = frame:GetAttribute("useOnKeyDown")
	local clickAction = (down and useOnKeyDown) or (not down and not useOnKeyDown)
	if not clickAction then return end
	local unit = frame:GetAttribute("unit")
	if unit and unit ~= "none" and not unitState[unit] then return end
	local kind = frame:GetAttribute("type")
	if kind == "action" then
		table.insert(useActionLog, { action = frame:GetAttribute("action"), unit = unit, button = button })
	elseif kind == "spell" then
		table.insert(useActionLog, { spell = frame:GetAttribute("spell"), unit = unit, button = button })
	elseif kind == "item" then
		table.insert(useActionLog, { item = frame:GetAttribute("item"), unit = unit, button = button })
	elseif kind == "macro" then
		local macro = frame:GetAttribute("macro")
		if macro then
			table.insert(useActionLog, { macro = macro, button = button })
			return
		end
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
local lastPopup, lastPopupData
function StaticPopup_Show(which, text1, text2, data) lastPopup, lastPopupData = which, data return which end
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
function HideUIPanel(panel) if panel then panel:Hide() end end
-- The client names the player from ADDON_LOADED on; the realm has a space.
local playerName = "Tester"   -- nil: the client cannot name the player yet
function UnitName(unit) return unit == "player" and playerName or nil end
function GetRealmName() return "Forever Beta" end
local now = 0
function GetTime() return now end
local function Tick() now = now + 0.05 end
-- C_Timer.After: callbacks run when the scenario ticks the clock.
local timers = {}
C_Timer = { After = function(delay, fn) timers[#timers + 1] = fn end }
local function RunTimers()
	local due = timers
	timers = {}
	for _, fn in ipairs(due) do fn() end
end
local hooks = {}
function hooksecurefunc(name, fn)
	hooks[name] = hooks[name] or {}
	table.insert(hooks[name], fn)
end
-- The panel manager as the addon meets it on Forever: opening a panel also
-- closes every frame on the UISpecialFrames list (what Escape does), then
-- the post-hooks run.
UIPanelWindows = { SpellBookFrame = { area = "left" }, GameMenuFrame = { area = "center" }, WorldMapFrame = { area = "full" } }
for name in pairs(UIPanelWindows) do CreateFrame("Frame", name):Hide() end
function CloseSpecialWindows()
	local found
	for _, name in ipairs(UISpecialFrames) do
		local f = frameByName[name]
		if f and f:IsShown() then found = true; HideUIPanel(f) end
	end
	return found
end
function ShowUIPanel(panel)
	CloseSpecialWindows()
	panel:Show()
	for _, fn in ipairs(hooks.ShowUIPanel or {}) do fn(panel) end
end
-- The client's menu system (11.0+): a tree of descriptions the scenario can walk.
local lastMenu
local function MenuDescription(text, callback)
	local d = { text = text, callback = callback, children = {} }
	function d:CreateTitle(t) local c = MenuDescription(t) c.title = true table.insert(self.children, c) return c end
	function d:CreateButton(t, cb) local c = MenuDescription(t, cb) table.insert(self.children, c) return c end
	return d
end
MenuUtil = { CreateContextMenu = function(owner, generator)
	lastMenu = MenuDescription("root")
	generator(owner, lastMenu)
	return lastMenu
end }
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
local function HasAction(slot) return slot >= 1 and slot <= 180 and slot % 5 ~= 0 end
C_ActionBar = {
	EnableActionRangeCheck = function(slot, enable) rangeChecks[slot] = enable or nil end,
	HasAction = HasAction,
	GetActionTexture = function(slot) return 100000 + slot end,
	GetActionCooldown = function(slot) return { startTime = 0, duration = 0, isActive = false, modRate = 1 } end,
	GetActionBarPage = function() return barState.page end,
	HasBonusActionBar = function() return barState.bonus end,
	GetBonusBarIndex = function() return barState.bonusIndex end,
	IsHarmfulAction = function(slot) return HasAction(slot) and slot % 2 == 1 end,
	IsHelpfulAction = function(slot) return HasAction(slot) and slot % 2 == 0 end,
}
-- What the action slots hold: spells unless listed here.
local actionInfo = { [2] = { "item", 6948 }, [4] = { "macro", 1 }, [6] = { "summonmount", 7 }, [8] = { "flyout", 3 } }
function GetActionInfo(slot)
	if not HasAction(slot) then return nil end
	local info = actionInfo[slot]
	if info then return info[1], info[2] end
	return "spell", 1000 + slot
end
-- The cursor: nil, or the values GetCursorInfo returns.
local cursorInfo
function GetCursorInfo() if cursorInfo then return unpack(cursorInfo) end end
function ClearCursor() cursorInfo = nil end
local macros = { "Mount up", "Heal me" }
local macroBodies = { "/say Mount up", "/say Heal me" }
local macroLimit = 120
function GetMacroIndexByName(name)
	for i, n in ipairs(macros) do if n == name then return i end end
	return 0
end
function GetMacroInfo(x)
	local index = tonumber(x) or GetMacroIndexByName(x)
	if not macros[index] then return nil end
	return macros[index], 400000 + index, macroBodies[index]
end
function GetNumMacros() return #macros, 0 end
-- CreateMacro returns the new index, or nil when the macro list is full;
-- both are blocked in combat.
function CreateMacro(name, icon, body, perCharacter)
	assert(not inCombat, "CreateMacro in combat")
	assert(type(name) == "string" and #name <= 16 and type(icon) == "string" and type(body) == "string", "CreateMacro: bad arguments")
	if #macros >= macroLimit then return nil end
	macros[#macros + 1] = name
	macroBodies[#macros] = body
	return #macros
end
function EditMacro(x, name, icon, body)
	assert(not inCombat, "EditMacro in combat")
	local index = tonumber(x) or GetMacroIndexByName(x)
	assert(macros[index], "EditMacro: no such macro")
	macros[index], macroBodies[index] = name, body
	return index
end
function PickupMacro(x)
	local index = tonumber(x) or GetMacroIndexByName(x)
	if macros[index] then cursorInfo = { "macro", index } end
end
local SECRET = setmetatable({}, { __tostring = function() return "secret" end })
function issecretvalue(v) return v == SECRET end
local spellRange, itemRange, rangeAsked = {}, {}, {}   -- id -> answer; id -> unit last asked about
C_Spell = {
	GetSpellTexture = function(id) return 200000 + id end,
	GetSpellName = function(id) return "Spell " .. id end,
	PickupSpell = function(id) cursorInfo = { "spell", 0, 0, id } end,   -- slot, bank, then the spell id
	IsSpellInRange = function(id, unit) rangeAsked[id] = unit return spellRange[id] end,
}
C_Item = {
	GetItemIconByID = function(id) return 300000 + id end,
	GetItemNameByID = function(id) return "Item " .. id end,
	PickupItem = function(id) cursorInfo = { "item", id, "|Hitem:" .. id .. "|h" } end,
	IsItemInRange = function(item, unit) rangeAsked[item] = unit return itemRange[item] end,
}
C_MountJournal = {
	GetMountInfoByID = function(id) return "Mount " .. id, 500 + id, 600000 + id end,
}
C_Texture = {
	GetAtlasInfo = function(name) if name:find("^UI%-HUD%-ActionBar%-IconFrame") then return { width = 45, height = 45 } end end,
}
local tooltip = { lines = {} }
GameTooltip = tooltip
function tooltip:SetOwner(owner, anchor) self.owner, self.anchor = owner, anchor end
function tooltip:SetSpellByID(id) self.spell = id end
function tooltip:SetItemByID(id) self.item = id end
function tooltip:SetText(text) self.text = text end
function tooltip:AddLine() end
function tooltip:ClearLines() self.spell, self.item, self.text = nil, nil, nil end
function tooltip:Show() self.shown = true end
function tooltip:Hide() self.shown = false; self:ClearLines() end

-------------------------------------------------------------------------------
-- Fake LibActionButton-1.0 (contract only; the real UpdateState snippet)
-------------------------------------------------------------------------------

local LABButton = {}
local LAB_KINDS = { empty = true, action = true, spell = true, item = true, macro = true, custom = true }

-- The library's own checks, so the addon cannot hand it a kind or a value
-- the real thing would refuse; item ids become "item:ID" as in r160.
function LABButton:SetStateFromHandlerInsecure(state, kind, action)
	state = tostring(state)
	kind = kind or "empty"
	assert(LAB_KINDS[kind], "SetStateAction: unknown action type: " .. tostring(kind))
	assert(kind == "empty" or action ~= nil, "SetStateAction: an action is required for non-empty states")
	assert(action == nil or type(action) == "number" or type(action) == "string", "SetStateAction: invalid action data type")
	if kind == "item" and tonumber(action) then action = "item:" .. action end
	self.state_types[state] = kind
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

function LABButton:HasAction()
	local kind = self._state_type
	if kind == "action" then return C_ActionBar.HasAction(self._state_action) end
	return kind == "spell" or kind == "item" or kind == "macro"
end

function LABButton:UpdateAction(force)
	local kind, action = self:GetAction()
	if force or kind ~= self._state_type or action ~= self._state_action then
		self._state_type, self._state_action = kind, action
		self.updates = (self.updates or 0) + 1
		local icon
		if kind == "action" and C_ActionBar.HasAction(action) then
			icon = C_ActionBar.GetActionTexture(action)
		elseif kind == "spell" then
			icon = C_Spell.GetSpellTexture(action)
		elseif kind == "item" then
			icon = C_Item.GetItemIconByID(tonumber(action:match("^item:(%d+)")))
		elseif kind == "macro" then
			icon = select(2, GetMacroInfo(action))
		end
		if icon then
			self.icon:SetTexture(icon)
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
			if button:HasAction() then
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
local clicker = frameByName.RadicalRadialClicker
local function macroOpener(i) return frameByName["RadicalRadialMacro" .. i] end
local function OverRing()
	local l, b, w, h = ring:GetRect()
	return ring.shown and cursor.x >= l and cursor.x <= l + w and cursor.y >= b and cursor.y <= b + h
end
-- A wheel notch the way the client routes it: to the clicker while it is
-- shown and the cursor is over the ring, else to the ring (the topmost
-- wheel-enabled frame there), otherwise to the bindings.
local function Scroll(dir)
	local delta = dir == "MOUSEWHEELUP" and 1 or -1
	if OverRing() and clicker:IsVisible() then clicker:MouseWheel(delta)
	elseif OverRing() and ring.wheel then ring:MouseWheel(delta)
	else Wheel(dir) end
end
-- "/click RadicalRadialMacro<i>" as the client runs it (SlashCommands.lua):
-- one click on the named button, up unless the macro says "1".
local function MacroClick(i, down)
	local button = macroOpener(i)
	assert(button and button.kind == "Button", "/click: no button called RadicalRadialMacro" .. i)
	button:Click("LeftButton", down and true or false)
end
-- A mouse click on the waiting ring: lands on the clicker only while it is
-- shown with the cursor over it (elsewhere the click goes to the world).
local function ClickRing(button)
	assert(clicker:IsVisible() and OverRing(), "ClickRing: the clicker is not under the cursor")
	clicker:Click(button or "LeftButton", true)
	clicker:Click(button or "LeftButton", false)
end
local function Uses() return #useActionLog end
local function LastUse() return useActionLog[#useActionLog] end
local function LastSlot() local u = LastUse() return u and u.action end
local function AssertSlots(base)
	for i = 1, 12 do
		local got = slice(i):GetAttribute("action")
		assert(got == base + i - 1, ("slice %d has slot %s, expected %d"):format(i, tostring(got), base + i - 1))
		assert(slice(i)._state_action == got, ("slice %d insecure side has %s"):format(i, tostring(slice(i)._state_action)))
		assert(slice(i):GetAttribute("subring") == nil, "a bar slice must not open a nested ring")
	end
	local page = math.floor((base - 1) / 12) + 1
	for i = 13, ns.MAX_SLICES do
		assert(slice(i):GetAttribute("labtype-" .. page) == "empty", "slice " .. i .. " must be empty on a bar page")
	end
end
-- Which slices a layout shows, where, and at what scale (the page snippet
-- places them; the insecure PlaceSlices uses the same formulas).
local function AssertLayout(inner, outer)
	assert(header:GetAttribute("incount") == inner and header:GetAttribute("outcount") == outer,
		("header says %s + %s, expected %d + %d"):format(tostring(header:GetAttribute("incount")), tostring(header:GetAttribute("outcount")), inner, outer))
	local visual = frameByName.RadicalRadialVisual
	for i = 1, ns.MAX_SLICES do
		if i <= inner + outer then
			assert(slice(i).shown, "slice " .. i .. " hidden in a " .. inner .. "+" .. outer .. " layout")
			local angle, fraction, size = ns.SlicePolar(i, inner, outer)
			local sc = size / 45
			assert(math.abs(slice(i).scale - sc) < 1e-9, ("slice %d scale %s, expected %s"):format(i, tostring(slice(i).scale), tostring(sc)))
			local ex = math.sin(math.rad(angle)) * 120 * fraction / sc
			local ey = math.cos(math.rad(angle)) * 120 * fraction / sc
			assert(math.abs((slice(i).cx - visual.cx) - ex) < 1e-6 and math.abs((slice(i).cy - visual.cy) - ey) < 1e-6,
				("slice %d at (%.1f, %.1f), expected (%.1f, %.1f)"):format(i, slice(i).cx - visual.cx, slice(i).cy - visual.cy, ex, ey))
		else
			assert(not slice(i).shown, "slice " .. i .. " shown in a " .. inner .. "+" .. outer .. " layout")
			assert(slice(i):GetAttribute("subring") == nil, "a hidden slice must not keep a nested ring")
		end
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
	for k = 1, ns.MAX_RINGS do
		assert(slice(3):GetAttribute("labtype-" .. (15 + k)) == "empty", "custom ring state " .. k .. " missing")
	end
	assert(slice(3):GetAttribute("labtype-" .. (16 + ns.MAX_RINGS)) == nil, "too many states")
	assert(header:GetAttribute("pageofbar9") == 16 and header:GetAttribute("pageofbar" .. (8 + ns.MAX_RINGS)) == 15 + ns.MAX_RINGS)
	assert(Label() == "Bar 1", "label is " .. Label())
	assert(not ring:IsShown())
	assert(slice(5).icon.shown == false, "empty slot 5 should hide its icon")
	assert(slice(1).icon.shown == true and slice(1).icon.texture == 100001)
	assert(slice(1).header == frameByName.RadicalRadialVisual, "slices must use the visual frame as their LAB header")
	assert(slice(1).mouse == false, "slices must not take the mouse")
	AssertLayout(4, 8)
	assert(opener:GetAttribute("layout") == 408 and opener:GetAttribute("clickfire") == false)
	assert(macroOpener(1) and macroOpener(1).wrap and macroOpener(1):GetAttribute("trigger") == 1, "macro opener 1 missing")
	assert(macroOpener(4) and not frameByName.RadicalRadialMacro5, "one macro opener per possible trigger")
	assert(clicker and clicker.parent == ring and not clicker.shown and clicker.mouse and clicker.wheel and clicker.wrap, "clicker not wired")
	assert(clicker:GetFrameRef("header") == header and header:GetFrameRef("clicker") == clicker and header:GetFrameRef("visual") == frameByName.RadicalRadialVisual)
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
		{ 0, 83, 5 }, { 0, 80, 1 }, { 0, 67, 1 },                    -- tier boundary at 0.68 R = 81.6, past the inner icons (they end at 66)
		{ 28, 30, 1 }, { 30, 28, 2 },                                -- inner sector boundary at 45 degrees
		{ 0, 190, 5 }, { -190, 0, 11 },                              -- past the icons but inside the cancel radius (1.6 R = 192) still selects
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

scenario("cancel radius: past it a release cancels in hold mode, a tap cancels in tap mode; the ring dims; slider and /rr outer set it", function()
	assert(header:GetAttribute("outer") == 1.6 and RadicalRadialDB.outer == 1.6, "default cancel radius missing")
	local before = Uses()
	OpenAt(800, 450); ReleaseAt(800, 650)   -- r = 200 > 192
	assert(Uses() == before, "release past the cancel radius fired an action")
	assert(not ring:IsShown() and header:GetAttribute("open") == false, "release past the cancel radius did not close the ring")
	assert(opener:GetAttribute("type") == nil)
	-- the presentation dims the ring out there and highlights nothing
	OpenAt(800, 450)
	MoveTo(800, 650); ring.scripts.OnUpdate(ring)
	assert(ns.visual.alpha == 0.45, "ring not dimmed past the cancel radius")
	for i = 1, 12 do assert(not slice(i).highlightLocked, "slice highlighted past the cancel radius") end
	MoveTo(800, 550); ring.scripts.OnUpdate(ring)
	assert(ns.visual.alpha == 1 and slice(5).highlightLocked, "ring still dimmed back inside")
	ReleaseAt(800, 550)
	assert(Uses() == before + 1 and LastSlot() == 5)
	-- tap mode: the opening release past the radius cancels, and so does a later press there
	rr("mode tap")
	OpenAt(800, 450); ReleaseAt(800, 650)
	assert(Uses() == before + 1 and not ring:IsShown(), "tap mode: release past the cancel radius did not cancel")
	OpenAt(800, 450); ReleaseAt(800, 450)
	assert(ring:IsShown())
	MoveTo(800, 650); Press("BUTTON4")
	assert(not ring:IsShown() and header:GetAttribute("open") == false, "tap mode: press past the cancel radius did not cancel")
	Release("BUTTON4")
	assert(Uses() == before + 1, "tap cancel fired an action")
	rr("mode hold")
	-- a wider radius takes the same release
	rr("outer 2")
	assert(RadicalRadialDB.outer == 2 and header:GetAttribute("outer") == 2)
	OpenAt(800, 450); ReleaseAt(800, 650)
	assert(Uses() == before + 2 and LastSlot() == 5, "r = 200 must select at 2 x the radius")
	rr("outer 9"); assert(RadicalRadialDB.outer == 3, "not clamped high")
	rr("outer 1"); assert(RadicalRadialDB.outer == 1.2, "not clamped low")
	rr("outer x"); assert(RadicalRadialDB.outer == 1.2, "garbage changed the value")
	-- the slider commits like the slash command, and /rr status reports it
	rr("config")
	ns.configUI.outer:SetValue(2.5); ns.configUI.outer.scripts.OnMouseUp(ns.configUI.outer)
	assert(RadicalRadialDB.outer == 2.5 and header:GetAttribute("outer") == 2.5, "slider did not apply")
	rr("outer 1.6")
	assert(ns.configUI.outer.sliderValue == 1.6, "slash change must refresh the slider")
	rr("config")
	rr("status"); assert(OutputContains("cancel radius: 1.6 x ring radius"), "status does not report the cancel radius")
	rr("debug")
	OpenAt(800, 450); ReleaseAt(800, 650)
	assert(OutputContains("release: cancelled past the cancel radius (r=200)"), "debug line missing")
	rr("debug")
	assert(Uses() == before + 2)
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
	assert(bindings.BUTTON4 and header:GetAttribute("radius") == 120 and RadicalRadialDB.outer == 1.6)
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
	RadicalRadialDB = { outer = 0.3, triggers = { { key = "none", bars = { 0, 9, "5" }, mode = "hover", autohide = -1 } } }
	ns.LoadDB()
	assert(trigger(1).key == "" and #trigger(1).bars == 1 and trigger(1).bars[1] == 5 and trigger(1).mode == "hold" and trigger(1).autohide == 0)
	assert(RadicalRadialDB.outer == 1.2, "saved cancel radius not clamped")
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
	-- layouts, nested rings, the macro opener and the clicker
	rr("layout 8+8"); OpenAt(800, 450); ReleaseAt(800, 490); rr("layout 4+8")
	rr("ring add Potions"); rr("ring set Potions 5 item 6948"); rr("ring add Menu"); rr("ring set Menu 1 ring Potions"); rr("bars 1 Menu")
	OpenAt(800, 450); Scroll("MOUSEWHEELDOWN"); ReleaseAt(800, 490); Scroll("MOUSEWHEELDOWN"); Press("ESCAPE"); Release("ESCAPE")
	OpenAt(800, 450); Scroll("MOUSEWHEELDOWN"); ReleaseAt(800, 490); MoveTo(801, 491); Press("BUTTON4"); Release("BUTTON4"); Press("BUTTON4"); Release("BUTTON4")
	MoveTo(800, 450); MacroClick(1); Scroll("MOUSEWHEELDOWN"); MoveTo(800, 490); MacroClick(1); MoveTo(800, 590); MacroClick(1)
	MoveTo(800, 450); MacroClick(1); MoveTo(800, 550); ClickRing("LeftButton")
	MoveTo(800, 450); MacroClick(1); ClickRing("RightButton")
	MoveTo(800, 450); MacroClick(1); MoveTo(800, 700); MacroClick(1)
	rr("harm 3"); Mouseover("enemy"); MoveTo(800, 450); MacroClick(1); MoveTo(800, 550); MacroClick(1); Mouseover(nil); rr("harm none")
	rr("ring remove Menu"); rr("ring remove Potions"); rr("bars 1 2")
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
	assert(settingsRegistered.name == "Radical Radial" and settingsRegistered.category, "no Options entry")
	rr("config"); assert(not cfg:IsShown())
	RadicalRadial_OnAddonCompartmentClick(); assert(cfg:IsShown())
	-- Escape: the window's own key handler out of combat (keys otherwise pass
	-- through), Blizzard's list in combat; opening the spellbook, which
	-- empties that list on Forever, leaves the window alone out of combat.
	assert(#UISpecialFrames == 0, "must not sit on UISpecialFrames out of combat")
	assert(cfg.keyboard == true and cfg.propagate == true, "keys must reach the window and pass through")
	cfg.scripts.OnKeyDown(cfg, "P"); Tick(); RunTimers()
	assert(cfg.propagate == true and cfg:IsShown(), "an ordinary key must pass through")
	ShowUIPanel(SpellBookFrame)
	assert(cfg:IsShown() and SpellBookFrame:IsShown(), "the spellbook closed the window")
	cfg.scripts.OnKeyDown(cfg, "ESCAPE")
	assert(not cfg:IsShown() and cfg.propagate == false, "Escape must close the window and not reach the game")
	Tick(); RunTimers()
	assert(cfg.propagate == true, "propagation not restored after Escape")
	-- Should the client still close it while opening a panel, it comes back;
	-- not for the game menu or a full-screen panel.
	rr("config"); assert(cfg:IsShown())
	cfg:Hide(); ShowUIPanel(SpellBookFrame)
	assert(cfg:IsShown(), "window not put back after a same-tick close")
	Tick(); cfg:Hide(); Tick(); ShowUIPanel(SpellBookFrame)
	assert(not cfg:IsShown(), "a window closed earlier must stay closed")
	rr("config"); cfg:Hide(); ShowUIPanel(GameMenuFrame)
	assert(not cfg:IsShown(), "the game menu must not bring the window back")
	rr("config"); cfg:Hide(); ShowUIPanel(WorldMapFrame)
	assert(not cfg:IsShown(), "a full-screen panel must not bring the window back")
	Tick(); GameMenuFrame:Hide(); WorldMapFrame:Hide(); SpellBookFrame:Hide()
	-- in combat: on the list, the handler leaves the key alone
	rr("config"); assert(cfg:IsShown())
	inCombat = true; Fire("PLAYER_REGEN_DISABLED")
	assert(UISpecialFrames[1] == "RadicalRadialConfig", "must join UISpecialFrames in combat")
	cfg.scripts.OnKeyDown(cfg, "ESCAPE")
	assert(cfg:IsShown() and cfg.propagate == true, "in combat the handler must leave Escape to the client")
	assert(CloseSpecialWindows() and not cfg:IsShown(), "the client's Escape path must close it")
	inCombat = false; Fire("PLAYER_REGEN_ENABLED")
	assert(#UISpecialFrames == 0, "must leave UISpecialFrames after combat")
	Tick(); RunTimers()
	rr("config"); assert(cfg:IsShown())
end)

scenario("options window: bar boxes keep the wheel order, the last bar stays, context boxes, radios and sliders apply", function()
	ClickUI(cui.bars[5])
	assert(Bars(trigger(1).bars) == "1 2 5", "order " .. Bars(trigger(1).bars))
	assert(opener:GetAttribute("barcount") == 3 and opener:GetAttribute("bar3") == 5)
	ClickUI(cui.bars[1])
	assert(Bars(trigger(1).bars) == "2 5")
	assert(opener:GetAttribute("bar1") == 2 and cui.barsText.text:find("Bar 2, Bar 5"))
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
	cui.autohide:SetValue(2); cui.autohide.scripts.OnMouseUp(cui.autohide)
	assert(trigger(1).autohide == 2 and opener:GetAttribute("autohide") == 2)
	ClickUI(cui.modeHold)
	assert(trigger(1).mode == "hold" and cui.autohide.enabled ~= false, "auto-hide applies to nested rings too, so it stays enabled in hold mode")
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
	assert(not cui.capturing and cui.key.text == "SHIFT-F")
	assert(cfg.propagate == false, "a captured key must not reach the game")
	Tick(); RunTimers()
	assert(cfg.propagate == true, "keys must pass through again after the capture")

	ClickUI(cui.key)
	cui.key:Click("Button5", true)
	assert(trigger(1).key == "BUTTON5" and bindings.BUTTON5, "mouse button not bound")

	ClickUI(cui.key)
	cfg.scripts.OnMouseDown(cfg, "LeftButton")
	assert(trigger(1).key == "BUTTON5" and not cui.capturing)
	assert(OutputContains("left and right mouse buttons cannot be triggers"))

	ClickUI(cui.key)
	cfg.scripts.OnKeyDown(cfg, "ESCAPE")
	assert(trigger(1).key == "BUTTON5" and not cui.capturing and cfg:IsShown() and cfg.propagate == false, "Escape must cancel the capture, not close the window")
	Tick(); RunTimers()

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
-- Custom rings (M4)
-------------------------------------------------------------------------------

local function rings() return ns.Rings() end
local function char() return RadicalRadialDB.chars[ns.charKey] end
local function AssertRingShown(ring)
	for i = 1, 12 do
		local s = ring.slices[i]
		local kind, field = slice(i):GetAttribute("type"), slice(i):GetAttribute("action_field")
		if s then
			assert(kind == s.kind, ("slice %d shows %s, expected %s"):format(i, tostring(kind), s.kind))
			local expected = s.kind == "macro" and s.name or (s.kind == "item" and ("item:" .. s.id) or s.id)
			assert(slice(i):GetAttribute(field) == expected, ("slice %d %s is %s, expected %s"):format(i, field, tostring(slice(i):GetAttribute(field)), tostring(expected)))
			assert(slice(i).icon.shown, "slice " .. i .. " icon hidden")
		else
			assert(kind == "empty", ("slice %d shows %s, expected empty"):format(i, tostring(kind)))
			assert(not slice(i).icon.shown, "empty slice " .. i .. " shows an icon")
		end
	end
end

scenario("custom rings: add, set slices, cycle to it, release fires the spell, item or macro on the ring's unit", function()
	rr("reset")
	assert(#rings() == 0)
	rr("ring add Utility")
	assert(#rings() == 1 and rings()[1].name == "Utility", "ring not added")
	rr("ring add 3"); assert(#rings() == 1 and OutputContains("not a bar number"), "a numeric name must be refused")
	rr("ring add utility"); assert(#rings() == 1 and OutputContains("already a ring called Utility"))
	rr("ring set Utility 5 spell 6603")
	rr("ring set Utility 1 item 6948")
	rr("ring set Utility 7 macro Mount up")
	rr("ring set Utility 17 spell 1"); assert(OutputContains("slots are 1 to 16"))
	rr("ring set Utility 2 spell x"); assert(OutputContains("a slice is spell ID"))
	local custom = rings()[1]
	assert(custom.slices[5].kind == "spell" and custom.slices[5].id == 6603)
	assert(custom.slices[1].kind == "item" and custom.slices[1].id == 6948)
	assert(custom.slices[7].kind == "macro" and custom.slices[7].name == "Mount up")
	assert(custom.slices[2] == nil)
	-- the states exist on every slice, out of the way of the action pages
	assert(slice(5):GetAttribute("labtype-16") == "spell" and slice(5):GetAttribute("labaction-16") == 6603)
	assert(slice(1):GetAttribute("labaction-16") == "item:6948" and slice(7):GetAttribute("labaction-16") == "Mount up")
	assert(slice(2):GetAttribute("labtype-16") == "empty")
	-- on the wheel by name
	rr("bars 1 utility")
	assert(trigger(1).bars[2] == "Utility", "ring name not canonical in the list: " .. tostring(trigger(1).bars[2]))
	assert(opener:GetAttribute("barcount") == 2 and opener:GetAttribute("bar2") == 9, "ring code not on the opener")
	local before = Uses()
	OpenAt(800, 450)
	AssertSlots(1)
	Scroll("MOUSEWHEELDOWN")
	assert(header:GetAttribute("page") == 2 and Label() == "Utility", "label is " .. Label())
	AssertRingShown(custom)
	assert(slice(5).icon.texture == 206603 and slice(1).icon.texture == 306948 and slice(7).icon.texture == 400001, "icons not painted")
	ReleaseAt(800, 550)
	assert(Uses() == before + 1 and LastUse().spell == 6603 and LastUse().unit == nil, "spell slice did not cast")
	assert(opener:GetAttribute("type") == "spell" and opener:GetAttribute("spell") == 6603)
	OpenAt(800, 450); Scroll("MOUSEWHEELDOWN"); ReleaseAt(800, 490)
	assert(LastUse().item == "item:6948", "item slice did not use the item: " .. tostring(LastUse().item))
	OpenAt(800, 450); Scroll("MOUSEWHEELDOWN"); ReleaseAt(900, 450)
	assert(LastUse().macro == "Mount up", "macro slice did not run the macro")
	-- an empty slice closes the ring and fires nothing; a bar release afterwards works as before
	before = Uses()
	OpenAt(800, 450); Scroll("MOUSEWHEELDOWN"); ReleaseAt(800, 350)
	assert(Uses() == before and not ring:IsShown(), "empty slice fired or kept the ring open")
	OpenAt(800, 450); ReleaseAt(800, 550)
	assert(LastSlot() == 5 and LastUse().unit == nil)
	-- a context list can be a ring: the slices aim at the captured unit
	rr("harm Utility")
	Mouseover("enemy")
	before = Uses()
	OpenAt(800, 450)
	assert(Uses() == before + 1 and LastUse().macrotext == "/focus [@mouseover,exists,nodead]", "capture did not run before a ring")
	assert(Label() == "Utility · enemy @focus", "label is " .. Label())
	AssertRingShown(custom)
	ReleaseAt(800, 550)
	assert(LastUse().spell == 6603 and LastUse().unit == "focus", "spell not cast on the focus")
	Mouseover(nil); rr("harm none")
	rr("rings")
	assert(OutputContains("ring 1 Utility (4 + 8): 3 of 12 slices") and OutputContains("spell 6603 (Spell 6603)") and OutputContains("macro Mount up"))
	rr("triggers")
	assert(OutputContains("bars 1 Utility |"))
	rr("ring clear Utility 7")
	assert(rings()[1].slices[7] == nil and slice(7):GetAttribute("labtype-16") == "empty")
end)

scenario("custom rings: a capture press after a macro-slice release still runs the capture macro", function()
	rr("ring set Utility 7 macro Heal me")
	OpenAt(800, 450); Scroll("MOUSEWHEELDOWN"); ReleaseAt(900, 450)
	assert(LastUse().macro == "Heal me" and opener:GetAttribute("macro") == "Heal me")
	rr("harm 3")
	Mouseover("enemy")
	local before = Uses()
	OpenAt(800, 450)
	assert(Uses() == before + 1 and LastUse().macrotext == "/focus [@mouseover,exists,nodead]",
		"the named macro left on the opener hijacked the capture click")
	ReleaseAt(800, 550)
	assert(LastSlot() == 53 and LastUse().unit == "focus")
	Mouseover(nil); rr("harm none"); rr("ring clear Utility 7")
end)

scenario("custom rings: fill from a bar copies its actions, the offensive/helpful filters pick slots, mounts become spells", function()
	rr("ring add Offense")
	rr("ring fill Offense 1")
	local ring = rings()[2]
	assert(ring.slices[1].kind == "spell" and ring.slices[1].id == 1001)
	assert(ring.slices[2].kind == "item" and ring.slices[2].id == 6948, "item slot not copied")
	assert(ring.slices[4].kind == "macro" and ring.slices[4].name == "Mount up", "macro slot not copied by name")
	assert(ring.slices[6].kind == "spell" and ring.slices[6].id == 507, "mount slot not turned into its spell")
	assert(ring.slices[8] == nil, "a flyout has no direct equivalent")
	assert(ring.slices[5] == nil and ring.slices[10] == nil, "empty slots must stay empty")
	assert(OutputContains("filled from Bar 1 (every slot): 9 slices"))
	rr("ring fill Offense 1 harm")
	for i = 1, 12 do
		local s = rings()[2].slices[i]
		assert((s ~= nil) == (C_ActionBar.HasAction(i) and i % 2 == 1), "harm filter wrong at slot " .. i)
	end
	rr("ring fill Offense 2 help")
	for i = 1, 12 do
		local s = rings()[2].slices[i]
		assert((s ~= nil) == (C_ActionBar.HasAction(60 + i) and i % 2 == 0), "help filter wrong at slot " .. i)
	end
	assert(rings()[2].slices[2].kind == "spell" and rings()[2].slices[2].id == 1062, "bar 2 slots not used")
	rr("ring fill Offense 9"); assert(OutputContains("bars are 1 to 8"))
	rr("ring fill Nope 1"); assert(OutputContains("no ring called Nope"))
end)

scenario("custom rings: export/import round trip, rename follows the lists, remove strips them, saved garbage is cleaned", function()
	rr("ring set Utility 2 macro Odd, name:100%")
	rr("ring export Utility")
	local text
	for _, line in ipairs(output) do text = line:match("copy this string: (RR2:.*)$") or text end
	assert(text, "export printed nothing")
	assert(text:find("^RR2:Utility:4%+8:") and text:find("i6948,mOdd%%2C name%%3A100%%25,%-,%-,s6603,"), "unexpected string: " .. text)
	assert(select(2, text:gsub(",", ",")) == 15, "sixteen slices expected in " .. text)
	local decoded = ns.DecodeRing(text)
	assert(decoded.name == "Utility" and decoded.layout == "4+8" and decoded.slices[2].name == "Odd, name:100%" and decoded.slices[5].id == 6603 and decoded.slices[3] == nil)
	-- import as a new ring under another name, then replace the original
	rr("ring import " .. text:gsub("^RR2:Utility:", "RR2:Copy%%20of%%20it:"))
	assert(#rings() == 3 and rings()[3].name == "Copy of it" and rings()[3].slices[5].id == 6603, "import did not add the ring")
	rr("ring import " .. text:gsub("s6603", "s1234"))
	assert(#rings() == 3 and rings()[1].slices[5].id == 1234, "import did not replace the ring of the same name")
	rr("ring import hello"); assert(OutputContains("not a Radical Radial ring string"))
	rr("ring import RR2::8:-"); assert(OutputContains("no usable name"))
	rr("ring import RR2:Bad:4+8:s1,q9"); assert(OutputContains("slice 2 is not readable"))
	rr("ring import RR2:Bad:3+9:s1"); assert(OutputContains("names a layout this version does not have"))
	-- a 0.5.x string (no layout, twelve slices) still imports as a 4 + 8 ring
	rr("ring import RR1:Oldone:s1,-,-,-,i6948,-,-,-,-,-,-,mHeal%20me")
	assert(rings()[4] and rings()[4].name == "Oldone" and rings()[4].layout == "4+8" and rings()[4].slices[5].id == 6948 and rings()[4].slices[12].name == "Heal me", "RR1 import failed")
	rr("ring remove Oldone")
	-- rename keeps every list pointing at the ring
	rr("2 bind BUTTON5"); rr("2 harm Utility 3"); rr("2 bars utility")
	rr("ring rename Utility Tools")
	assert(rings()[1].name == "Tools" and trigger(1).bars[2] == "Tools" and trigger(2).harm[1] == "Tools" and trigger(2).bars[1] == "Tools", "rename did not follow the lists")
	assert(Label() == "Bar 1")
	OpenAt(800, 450); Scroll("MOUSEWHEELDOWN"); assert(Label() == "Tools"); ReleaseAt(800, 450)
	rr("ring rename Tools Offense"); assert(rings()[1].name == "Tools" and OutputContains("already a ring called Offense"))
	-- remove strips it from the lists; a list left empty falls back to Bar 1
	rr("ring remove Tools")
	assert(#rings() == 2 and rings()[1].name == "Offense" and rings()[2].name == "Copy of it")
	assert(#trigger(1).bars == 1 and trigger(1).bars[1] == 1 and #trigger(2).harm == 1 and trigger(2).harm[1] == 3)
	assert(trigger(2).bars[1] == 1, "an emptied list must fall back to Bar 1")
	assert(opener:GetAttribute("barcount") == 1 and opener:GetAttribute("bar2") == nil)
	-- the ring that moved up to index 1 now has state 16 and code 9
	rr("bars 1 Offense")
	assert(opener:GetAttribute("bar2") == 9 and slice(2):GetAttribute("labtype-16") == "spell" and slice(1):GetAttribute("labtype-16") == "empty", "Offense did not move to state 16")
	assert(slice(1):GetAttribute("labtype-17") == "item", "Copy of it did not move to state 17")
	rr("2 remove")
	-- at most MAX_RINGS
	for n = #rings() + 1, ns.MAX_RINGS do rr("ring add R" .. n) end
	assert(#rings() == ns.MAX_RINGS)
	rr("ring add Extra"); assert(#rings() == ns.MAX_RINGS and OutputContains("at most " .. ns.MAX_RINGS .. " rings"))
	-- saved variables: bad rings, slices and references are cleaned on load
	local current = RadicalRadialDB
	RadicalRadialDB = {
		rings = { { name = "", layout = "3+9", slices = { [1] = { kind = "spell", id = "x" }, [2] = { kind = "item", id = 7 }, [13] = { kind = "spell", id = 1 }, [17] = { kind = "spell", id = 1 } } },
			{ name = "7" }, { name = "Dup" }, { name = "dup", slices = { [1] = { kind = "macro", name = "" } } }, "junk" },
		triggers = { { key = "F", bars = { "ring 1", 2, "Missing", "DUP" }, harm = { "Dup 2" } } },
	}
	ns.LoadDB()
	local r = rings()
	assert(#r == 4 and r[1].name == "Ring 1" and r[2].name == "Ring 2" and r[3].name == "Dup" and r[4].name == "dup 2", "ring names not normalized: " .. r[1].name .. "," .. r[2].name .. "," .. r[3].name .. "," .. r[4].name)
	assert(r[1].slices[1] == nil and r[1].slices[2].id == 7 and r[1].slices[13].id == 1 and r[1].slices[17] == nil and r[4].slices[1] == nil, "bad slices kept")
	assert(r[1].layout == "4+8" and r[2].layout == "4+8", "unknown layout not replaced by the default")
	assert(#trigger(1).bars == 3 and trigger(1).bars[1] == "Ring 1" and trigger(1).bars[2] == 2 and trigger(1).bars[3] == "Dup", "list not cleaned: " .. ns.BarList(trigger(1).bars))
	assert(trigger(1).harm[1] == "dup 2", "reference not canonical: " .. tostring(trigger(1).harm[1]))
	ns.ApplyConfig()
	assert(opener:GetAttribute("bar1") == 9 and opener:GetAttribute("bar3") == 11 and opener:GetAttribute("harm1") == 12)
	RadicalRadialDB = current
	ns.LoadDB(); ns.ApplyConfig()
	assert(bindings.BUTTON4 and #rings() == ns.MAX_RINGS)
	for _, name in ipairs({ "R3", "R4", "R5", "R6" }) do rr("ring remove " .. name) end
	assert(#rings() == 2)
end)

scenario("custom rings: spell and item slices tint from the client's range calls against the slice's unit; secret answers are ignored", function()
	local LAB = LibStub("LibActionButton-1.0")
	rr("ring set Offense 5 spell 6603"); rr("ring set Offense 1 item 6948")
	OpenAt(800, 450); Scroll("MOUSEWHEELDOWN")
	spellRange[6603] = false; itemRange["item:6948"] = false
	LAB.RangeTick()
	assert(slice(5).outOfRange == true and slice(5).icon.vertex[1] == 0.8, "spell slice not tinted")
	assert(slice(1).outOfRange == true, "item slice not tinted")
	assert(rangeAsked[6603] == "target" and rangeAsked["item:6948"] == "target", "range not asked against the target")
	spellRange[6603] = true; LAB.RangeTick()
	assert(slice(5).icon.vertex[1] == 1)
	spellRange[6603] = SECRET; LAB.RangeTick()
	assert(slice(5).outOfRange == false, "a secret answer must not tint")
	spellRange[6603] = nil; itemRange["item:6948"] = nil
	ReleaseAt(800, 450)
	-- aimed at the focus, the calls ask about the focus
	rr("harm Offense"); Mouseover("enemy")
	OpenAt(800, 450); LAB.RangeTick()
	assert(rangeAsked[6603] == "focus", "range not asked against the captured unit")
	ReleaseAt(800, 450)
	Mouseover(nil); rr("harm none")
end)

scenario("ring editor: the tab, new ring, drops, pick up, swap, clear, rename, fill, export and import, remove asks first", function()
	rr("reset")
	rr("config"); assert(cfg:IsShown())
	assert(cui.tab == "triggers" and cui.triggersTab.shown and not cui.ringsTab.shown)
	assert(not cui.barsRings[1].shown, "ring boxes shown with no rings")
	ClickUI(cui.tabButtons.rings)
	assert(cui.tab == "rings" and cui.ringsTab.shown and not cui.triggersTab.shown, "tab did not switch")
	assert(cui.ringMissing.shown and not cui.ringPanel.shown, "no-rings state not shown")
	ClickUI(cui.newRing)
	assert(#rings() == 1 and rings()[1].name == "Ring 1" and cui.ring == 1)
	assert(cui.ringPanel.shown and not cui.ringMissing.shown and cui.ringName.text == "Ring 1")
	assert(cui.ringButtons[1].shown and cui.ringButtons[1].text == "Ring 1" and not cui.ringButtons[2].shown)
	-- drop a spell from the cursor onto slot 5
	local s5 = cui.slots[5]
	C_Spell.PickupSpell(6603)
	s5.scripts.OnReceiveDrag(s5)
	assert(rings()[1].slices[5].id == 6603 and cursorInfo == nil, "drop did not take the spell")
	assert(s5.icon.texture == 206603 and s5.icon.shown and s5.slice.id == 6603, "slot not painted")
	assert(s5.bg.atlas == "UI-HUD-ActionBar-IconFrame-Slot" and s5.border.atlas == "UI-HUD-ActionBar-IconFrame", "slot art missing")
	-- a mount drops as its spell; a pet action is refused
	cursorInfo = { "mount", 7 }
	ClickUI(cui.slots[6])
	assert(rings()[1].slices[6].kind == "spell" and rings()[1].slices[6].id == 507 and cursorInfo == nil)
	cursorInfo = { "petaction", 1 }
	ClickUI(cui.slots[8])
	assert(rings()[1].slices[8] == nil and cursorInfo ~= nil and OutputContains("a ring slice can hold a spell, an item, a macro or a mount"))
	ClearCursor()
	-- click a filled slot: it goes to the cursor and the slot empties; click another: it lands there
	ClickUI(s5)
	assert(cursorInfo and cursorInfo[1] == "spell" and cursorInfo[4] == 6603 and rings()[1].slices[5] == nil, "pick up failed")
	ClickUI(cui.slots[1])
	assert(rings()[1].slices[1].id == 6603 and cursorInfo == nil, "move failed")
	-- dropping on a filled slot swaps
	C_Item.PickupItem(6948)
	ClickUI(cui.slots[1])
	assert(rings()[1].slices[1].kind == "item" and cursorInfo and cursorInfo[1] == "spell" and cursorInfo[4] == 6603, "swap failed")
	ClearCursor()
	-- a macro from the macro window, then right-click clears
	PickupMacro(2)
	cui.slots[3].scripts.OnDragStart(cui.slots[3])   -- dragging an empty slot does nothing
	assert(cursorInfo and cursorInfo[1] == "macro")
	cui.slots[3].scripts.OnReceiveDrag(cui.slots[3])
	assert(rings()[1].slices[3].name == "Heal me")
	cui.slots[3]:Click("RightButton", false)
	assert(rings()[1].slices[3] == nil and not cui.slots[3].icon.shown)
	-- tooltips
	cui.slots[1].scripts.OnEnter(cui.slots[1]); assert(tooltip.item == 6948 and tooltip.shown)
	cui.slots[1].scripts.OnLeave(cui.slots[1]); assert(not tooltip.shown)
	cui.slots[6].scripts.OnEnter(cui.slots[6]); assert(tooltip.spell == 507)
	cui.slots[9].scripts.OnEnter(cui.slots[9]); assert(tooltip.text:find("Slot 9"))
	cui.slots[9].scripts.OnLeave(cui.slots[9])
	-- rename through the box
	cui.ringName:SetText("  Utility   belt ")
	cui.ringName.scripts.OnEnterPressed(cui.ringName)
	assert(rings()[1].name == "Utility belt" and cui.ringName.text == "Utility belt" and cui.ringButtons[1].text == "Utility b…")
	cui.ringName:SetText("8"); ClickUI(cui.renameRing)
	assert(rings()[1].name == "Utility belt" and cui.ringName.text == "Utility belt", "a bar number must be refused and the box restored")
	-- the ring appears on the trigger tab's rows and can be ticked
	ClickUI(cui.tabButtons.triggers)
	assert(cui.barsRings[1].shown and cui.barsRings[1].label.text == "Utility…" and not cui.barsRings[2].shown, "ring box label: " .. tostring(cui.barsRings[1].label.text))
	ClickUI(cui.barsRings[1])
	assert(trigger(1).bars[3] == "Utility belt" and cui.barsRings[1].checked and cui.barsText.text:find("Bar 1, Bar 2, Utility belt"))
	ClickUI(cui.harmRings[1])
	assert(trigger(1).harm[1] == "Utility belt" and cui.harmText.text:find("Utility belt"))
	ClickUI(cui.harmRings[1]); ClickUI(cui.barsRings[1])
	assert(#trigger(1).harm == 0 and #trigger(1).bars == 2)
	ClickUI(cui.tabButtons.rings)
	-- fill from a bar with the filter radios
	ClickUI(cui.fillRadios.harm)
	assert(cui.fillFilter == "harm" and cui.fillRadios.harm.checked and not cui.fillRadios.all.checked)
	ClickUI(cui.fillButtons[3])
	assert(rings()[1].slices[1].id == 1049 and rings()[1].slices[2] == nil and rings()[1].slices[3].id == 1051, "fill from Bar 3 (offensive) wrong")
	ClickUI(cui.fillRadios.all)
	-- export fills the box selected; import from the box adds a ring and selects it
	ClickUI(cui.exportRing)
	assert(cui.ringIO.text:find("^RR2:Utility belt:4%+8:s1049,") and cui.ringIO.highlighted and cui.ringIO.focused, "export box wrong: " .. tostring(cui.ringIO.text))
	cui.ringIO:SetText((cui.ringIO.text:gsub("Utility belt", "Second")))
	ClickUI(cui.importRing)
	assert(#rings() == 2 and rings()[2].name == "Second" and cui.ring == 2 and cui.ringIO.text == "", "import from the box failed")
	assert(cui.ringName.text == "Second" and cui.ringButtons[2].shown)
	-- selecting, and removing with confirmation
	ClickUI(cui.ringButtons[1])
	assert(cui.ring == 1 and cui.ringName.text == "Utility belt")
	ClickUI(cui.removeRing)
	assert(lastPopup == "RADICALRADIAL_REMOVE_RING" and lastPopupData == "Utility belt" and #rings() == 2, "remove must ask first")
	StaticPopupDialogs.RADICALRADIAL_REMOVE_RING.OnAccept(nil, lastPopupData)
	assert(#rings() == 1 and rings()[1].name == "Second" and cui.ring == 1 and cui.ringName.text == "Second")
	-- the new-ring button hides at the limit
	for n = 2, ns.MAX_RINGS do ClickUI(cui.newRing) end
	assert(#rings() == ns.MAX_RINGS and not cui.newRing.shown)
	rr("reset")
	assert(#rings() == 0 and cui.ringMissing.shown)
	rr("config"); assert(not cfg:IsShown())
end)

scenario("per character: rings and wheel lists belong to the character, settings and triggers are shared, copies from another character", function()
	local db = RadicalRadialDB
	assert(db.rings == nil and char() and char().rings and char().lists, "character entry missing")
	assert(ns.charKey == "Tester-Forever Beta" and trigger(1).id == 1 and db.nextTriggerId >= 2, "trigger ids")
	rr("ring add Utility"); rr("ring set Utility 1 spell 100"); rr("ring layout Utility 8"); rr("bars 1 Utility")
	assert(rings()[1].name == "Utility" and char().rings[1] == rings()[1], "ring not saved under the character")
	assert(char().lists[1].bars == trigger(1).bars and trigger(1).bars[2] == "Utility", "lists not mirrored")
	-- a second character shares the settings and triggers, starts with the
	-- last character's lists minus the rings it lacks, and has no rings
	rr("scale 1.3"); rr("2 bind BUTTON5"); rr("2 bars 3 Utility")
	playerName = "Alt"
	ns.LoadDB(); ns.ApplyConfig()
	assert(ns.charKey == "Alt-Forever Beta" and #rings() == 0, "the alt must start without rings")
	assert(db.scale == 1.3 and trigger(2).key == "BUTTON5" and bindings.BUTTON5, "settings and triggers must be shared")
	assert(Bars(trigger(1).bars) == "1" and Bars(trigger(2).bars) == "3", "alt lists: " .. Bars(trigger(1).bars) .. " / " .. Bars(trigger(2).bars))
	local tester = db.chars["Tester-Forever Beta"]
	assert(tester.rings[1].name == "Utility" and tester.lists[1].bars[2] == "Utility", "the first character's data must survive")
	-- listing and copying
	rr("rings")
	assert(OutputContains("no custom rings on this character yet") and OutputContains("Tester-Forever Beta has: Utility"), "rings listing")
	rr("ring copy Nobody Utility"); assert(OutputContains("no other character called Nobody has rings"))
	rr("ring copy Tester Utility")
	assert(#rings() == 1 and rings()[1].name == "Utility" and rings()[1].slices[1].id == 100 and rings()[1].layout == "8", "copy failed")
	assert(OutputContains("ring Utility copied from Tester") and rings()[1] ~= tester.rings[1], "the copy must be its own table")
	rr("ring set Utility 2 item 6948")
	assert(tester.rings[1].slices[2] == nil, "editing the copy must not touch the original")
	rr("ring copy tester-foreverbeta Utility")
	assert(OutputContains("ring Utility replaced from Tester") and rings()[1].slices[2] == nil, "a second copy replaces the ring")
	rr("bars 2 Utility")
	assert(Bars(tester.lists[1].bars) == "1 Utility", "the alt's lists must not reach the first character")
	-- the editor: a menu of the other characters' rings, from the ring page and from the empty page
	rr("config"); cui.ShowTab("rings")
	assert(cui.ringPanel.shown and cui.copyRing.shown)
	ClickUI(cui.copyRing)
	assert(lastMenu.children[1].title and lastMenu.children[2].text == "Tester" and lastMenu.children[2].children[1].text == "Utility", "copy menu")
	rr("ring remove Utility"); assert(#rings() == 0 and cui.ringMissing.shown)
	ClickUI(cui.copyRingMissing)
	lastMenu.children[2].children[1].callback()
	assert(#rings() == 1 and rings()[1].name == "Utility" and cui.ring == 1 and cui.ringPanel.shown, "menu copy failed")
	-- reset clears the shared settings and this character only
	rr("reset")
	assert(#rings() == 0 and db.scale == 1 and #db.triggers == 1, "reset")
	assert(db.chars["Tester-Forever Beta"].rings[1].name == "Utility", "reset must keep other characters")
	-- a removed trigger's lists go with it; an id that names no trigger is dropped on load
	rr("2 bind BUTTON5"); local id2 = trigger(2).id
	assert(char().lists[id2] and id2 > 1, "new trigger needs an id and lists")
	rr("2 remove"); assert(char().lists[id2] == nil, "removed trigger's lists must go")
	char().lists[99] = { bars = { 4 } }
	ns.LoadDB(); assert(char().lists[99] == nil, "stale list not dropped")
	-- back on the first character everything is as it was left
	playerName = "Tester"
	ns.LoadDB(); ns.ApplyConfig()
	assert(rings()[1].name == "Utility" and Bars(trigger(1).bars) == "1 Utility", "first character's data changed")
	-- rings saved by 0.5.0 go to the first character that logs in; a player
	-- the client cannot name at ADDON_LOADED is attached at PLAYER_LOGIN
	local current = RadicalRadialDB
	RadicalRadialDB = { rings = { { name = "Old", slices = { { kind = "spell", id = 5 } } } }, triggers = { { key = "BUTTON4", bars = { 1, "Old" } } } }
	playerName = nil
	ns.LoadDB()
	assert(ns.charKey == nil and RadicalRadialDB.rings == nil and rings()[1].name == "Old" and next(RadicalRadialDB.chars) == nil, "early attach")
	playerName = "Tester"
	Fire("PLAYER_LOGIN")
	assert(ns.charKey == "Tester-Forever Beta" and char().rings[1].name == "Old" and Bars(trigger(1).bars) == "1 Old", "late attach")
	RadicalRadialDB = current
	ns.LoadDB(); ns.ApplyConfig()
	rr("ring remove Utility"); rr("bars 1 2")
	assert(#rings() == 0 and Bars(trigger(1).bars) == "1 2" and bindings.BUTTON4)
	rr("config"); assert(not cfg:IsShown())
end)

-------------------------------------------------------------------------------
-- Layouts, nested rings, the macro trigger and click to fire (0.6.0)
-------------------------------------------------------------------------------

scenario("layouts: a trigger's bar layout places the slices and resolves sectors; custom rings carry their own; unknown layouts are refused", function()
	rr("reset")
	assert(trigger(1).layout == "4+8")
	-- single tier of 8: the first eight slots, 45-degree sectors from the dead zone out
	rr("layout 8")
	assert(trigger(1).layout == "8" and opener:GetAttribute("layout") == 8)
	AssertLayout(0, 8)
	local before = Uses()
	OpenAt(800, 450); AssertLayout(0, 8); AssertSlots(1)
	ReleaseAt(800, 490)          -- r = 40: inside the old inner tier, now sector 1 of the only tier
	assert(Uses() == before + 1 and LastSlot() == 1, "layout 8: (0,40) fired " .. tostring(LastSlot()))
	OpenAt(800, 450); ReleaseAt(870, 380)   -- SE
	assert(LastSlot() == 4)
	OpenAt(800, 450); Scroll("MOUSEWHEELDOWN"); AssertLayout(0, 8); AssertSlots(61); ReleaseAt(700, 450)   -- W
	assert(LastSlot() == 67)
	-- the highlight follows the same layout
	OpenAt(800, 450); MoveTo(800, 490); ring.scripts.OnUpdate(ring)
	assert(slice(1).highlightLocked and not slice(5).highlightLocked, "highlight ignores the layout")
	ReleaseAt(800, 450)
	-- 12 flat: 30-degree sectors
	rr("layout 12")
	OpenAt(800, 450); AssertLayout(0, 12)
	ReleaseAt(850, 537)          -- 30 degrees: sector 2
	assert(LastSlot() == 2, "layout 12: expected slot 2, got " .. tostring(LastSlot()))
	OpenAt(800, 450); ReleaseAt(750, 537)   -- -30 degrees: sector 12
	assert(LastSlot() == 12)
	-- 8 + 8: sixteen slices, the inner ring pushed out so eight icons fit; a bar fills the first twelve
	rr("layout 8+8")
	OpenAt(800, 450); AssertLayout(8, 8); AssertSlots(1)
	assert(slice(16).shown and slice(16):GetAttribute("type") == "empty", "slice 16 must be shown but empty on a bar")
	ReleaseAt(800, 490); assert(LastSlot() == 1)
	OpenAt(800, 450); ReleaseAt(800, 550); assert(LastSlot() == 9, "8+8: outer north is slice 9")
	OpenAt(800, 450); ReleaseAt(828, 478); assert(LastSlot() == 2, "8+8: inner NE is slice 2")   -- 45 degrees, r = 40
	-- an unknown layout is refused and the setting stays
	rr("layout 3+9"); assert(trigger(1).layout == "8+8" and OutputContains("layouts are 4+8, 12, 8, 6, 4, 6+6, 8+8"))
	rr("layout 0+12"); assert(trigger(1).layout == "12", "0+12 must read as 12")
	rr("layout 4 + 8"); assert(trigger(1).layout == "4+8")
	AssertLayout(4, 8)
	-- a custom ring's layout wins over the trigger's while it shows
	rr("ring add Wide"); rr("ring layout Wide 12"); rr("ring set Wide 12 spell 5"); rr("bars 1 Wide")
	assert(rings()[1].layout == "12" and header:GetAttribute("layoutofbar9") == 12)
	OpenAt(800, 450); AssertLayout(4, 8)
	Scroll("MOUSEWHEELDOWN"); AssertLayout(0, 12)
	assert(slice(12):GetAttribute("type") == "spell" and slice(12):GetAttribute("spell") == 5)
	ReleaseAt(750, 537)
	assert(LastUse().spell == 5, "slice 12 of the 12 layout did not fire")
	-- back on a bar the trigger's layout returns
	OpenAt(800, 450); AssertLayout(4, 8); ReleaseAt(800, 450)
	-- a smaller layout keeps the slices it no longer shows
	rr("ring layout Wide 6")
	assert(rings()[1].slices[12].id == 5, "slices past the layout must survive")
	rr("rings"); assert(OutputContains("Wide (6): 0 of 6 slices") and OutputContains("(not shown in this layout)"))
	rr("ring set Wide 7 spell 6"); assert(OutputContains("not shown in the 6 layout"))
	OpenAt(800, 450); Scroll("MOUSEWHEELDOWN"); AssertLayout(0, 6)
	assert(not slice(12).shown and slice(7):GetAttribute("subring") == nil)
	ReleaseAt(800, 450)
	rr("ring layout Wide 9"); assert(rings()[1].layout == "6")
	-- the layout travels in the export string
	rr("ring export Wide")
	assert(OutputContains("RR2:Wide:6:"))
	rr("ring layout Wide 4+8")
	-- the options window: the trigger's layout radios
	rr("config")
	assert(cui.layouts["4+8"].checked and not cui.layouts["8"].checked)
	ClickUI(cui.layouts["8"])
	assert(trigger(1).layout == "8" and cui.layouts["8"].checked and not cui.layouts["4+8"].checked)
	rr("layout 4+8"); assert(cui.layouts["4+8"].checked, "slash change must refresh the radios")
	rr("config")
	rr("ring remove Wide"); rr("bars 1 2")
end)

scenario("nested rings: a slice opens another ring in place; the centre goes back, the wheel leaves, rename and remove follow", function()
	rr("reset")
	rr("ring add Potions"); rr("ring set Potions 5 item 6948"); rr("ring set Potions 1 spell 77")
	rr("ring add Menu"); rr("ring set Menu 1 ring Potions"); rr("ring set Menu 5 spell 42")
	rr("ring set Menu 2 ring Menu"); assert(rings()[2].slices[2] == nil and OutputContains("cannot nest itself"))
	rr("ring set Menu 3 ring Nope"); assert(rings()[2].slices[3] == nil and OutputContains("no ring called Nope to nest"))
	rr("ring set Menu 4 ring potions"); assert(rings()[2].slices[4].name == "Potions", "the target's own spelling")
	rr("ring clear Menu 4")
	assert(rings()[2].slices[1].kind == "ring" and rings()[2].slices[1].name == "Potions")
	rr("rings"); assert(OutputContains("ring Potions (nested)"))
	-- on the secure side the slice is an empty state that names the target's bar code
	assert(slice(1):GetAttribute("labtype-17") == "empty" and slice(1):GetAttribute("sub-17") == 9, "nested slice state wrong")
	assert(slice(5):GetAttribute("sub-17") == nil)
	rr("bars 1 Menu")
	local before = Uses()
	OpenAt(800, 450); Scroll("MOUSEWHEELDOWN")
	assert(Label() == "Menu" and slice(1):GetAttribute("subring") == 9 and slice(5):GetAttribute("subring") == nil)
	assert(slice(1).folderIcon.shown and slice(1).folderName.text == "Potions" and not slice(5).folderIcon.shown, "folder art missing")
	-- releasing on the folder opens Potions at the cursor, waiting, and fires nothing
	ReleaseAt(800, 490)
	assert(Uses() == before, "the folder fired")
	assert(ring:IsShown() and header:GetAttribute("open") == true and header:GetAttribute("sub") == 9)
	assert(ring.cx == 800 and ring.cy == 490, "the nested ring must re-centre on the cursor")
	assert(Label() == "Potions « Menu", "label is " .. Label())
	assert(slice(5):GetAttribute("type") == "item" and slice(1):GetAttribute("type") == "spell" and slice(1):GetAttribute("subring") == nil)
	assert(not slice(1).folderIcon.shown, "folder art left on a plain slice")
	assert(ring.autoHide == 3, "a waiting nested ring must arm auto-hide in hold mode")
	assert(not clicker:IsVisible(), "the clicker must stay hidden for a thumb-button trigger")
	assert(opener:GetAttribute("type") == nil)
	-- press and release on a slice of the nested ring fires it
	MoveTo(800, 590); Press("BUTTON4")
	assert(ring:IsShown(), "a press outside the dead zone closed the nested ring")
	Release("BUTTON4")
	assert(Uses() == before + 1 and LastUse().item == "item:6948", "nested slice did not fire: " .. tostring(LastUse() and LastUse().item))
	assert(not ring:IsShown() and header:GetAttribute("sub") == nil)
	-- a press in the centre goes back to the ring it came from; another closes
	OpenAt(800, 450); Scroll("MOUSEWHEELDOWN"); ReleaseAt(800, 490)
	assert(header:GetAttribute("sub") == 9)
	MoveTo(801, 491); Press("BUTTON4")
	assert(ring:IsShown() and header:GetAttribute("sub") == nil and Label() == "Menu" and ring.cx == 801, "dead-zone press did not go back")
	assert(slice(1):GetAttribute("subring") == 9, "the folder must be back")
	Release("BUTTON4")
	assert(ring:IsShown() and Uses() == before + 1, "the release after going back must do nothing")
	Press("BUTTON4")
	assert(not ring:IsShown(), "a second dead-zone press must close the ring")
	Release("BUTTON4")
	-- the wheel leaves the nested ring first, then pages
	OpenAt(800, 450); Scroll("MOUSEWHEELDOWN"); ReleaseAt(800, 490)
	Scroll("MOUSEWHEELDOWN")
	assert(header:GetAttribute("sub") == nil and header:GetAttribute("page") == 2 and Label() == "Menu", "wheel did not leave the nested ring")
	Scroll("MOUSEWHEELDOWN")
	assert(header:GetAttribute("page") == 1 and Label() == "Bar 1")
	Press("ESCAPE"); Release("ESCAPE")
	assert(not ring:IsShown() and header:GetAttribute("sub") == nil)
	-- Escape from a nested ring closes everything
	OpenAt(800, 450); Scroll("MOUSEWHEELDOWN"); ReleaseAt(800, 490)
	Press("ESCAPE"); Release("ESCAPE")
	assert(not ring:IsShown() and header:GetAttribute("open") == false and header:GetAttribute("sub") == nil)
	-- tap mode: tap, press and release on the folder, press and release on the potion
	rr("mode tap")
	OpenAt(800, 450); ReleaseAt(800, 450)
	Scroll("MOUSEWHEELDOWN")
	MoveTo(800, 490); Press("BUTTON4"); Release("BUTTON4")
	assert(ring:IsShown() and header:GetAttribute("sub") == 9 and Uses() == before + 1)
	MoveTo(800, 590); Press("BUTTON4"); Release("BUTTON4")
	assert(Uses() == before + 2 and LastUse().item == "item:6948" and not ring:IsShown())
	rr("mode hold")
	-- rename follows the folder; remove strips it
	rr("ring rename Potions Brews")
	assert(rings()[2].slices[1].name == "Brews")
	rr("ring export Menu")
	assert(OutputContains("RR2:Menu:4+8:rBrews,-,-,-,s42,"), "export must carry the nested ring")
	rr("ring remove Brews")
	assert(#rings() == 1 and rings()[1].name == "Menu" and rings()[1].slices[1] == nil, "remove did not strip the folder")
	-- an import naming a ring that is not here drops that slice and says so
	rr("ring import RR2:Other:8:rNowhere,s3,-,-,-,-,-,-,-,-,-,-,-,-,-,-")
	assert(rings()[2].name == "Other" and rings()[2].slices[1] == nil and rings()[2].slices[2].id == 3 and OutputContains("1 nested ring slice dropped"))
	-- saved variables: dangling and self references go on load
	local current = RadicalRadialDB
	RadicalRadialDB = { triggers = { { key = "BUTTON4", bars = { 1 } } }, chars = { ["Tester-Forever Beta"] = { rings = {
		{ name = "A", slices = { [1] = { kind = "ring", name = "b" }, [2] = { kind = "ring", name = "A" }, [3] = { kind = "ring", name = "Gone" } } },
		{ name = "B", slices = { [1] = { kind = "ring", name = "A" } } },
	} } } }
	ns.LoadDB()
	assert(rings()[1].slices[1].name == "B" and rings()[1].slices[2] == nil and rings()[1].slices[3] == nil and rings()[2].slices[1].name == "A", "folder cleanup on load")
	RadicalRadialDB = current
	ns.LoadDB(); ns.ApplyConfig()
	rr("ring remove Other"); rr("ring remove Menu"); rr("bars 1 2")
	assert(#rings() == 0 and bindings.BUTTON4)
end)

scenario("macro trigger: /click opens the ring waiting, the next click fires, the clicker fires on a mouse click and cancels on a right click", function()
	rr("reset")
	local before = Uses()
	MoveTo(800, 450)
	MacroClick(1)
	assert(ring:IsShown() and header:GetAttribute("open") == true and header:GetAttribute("active") == 1 and header:GetAttribute("via") == "macro", "macro click did not open the ring")
	assert(ring.cx == 800 and ring.cy == 450 and Uses() == before)
	assert(clicker:IsVisible(), "a macro-opened ring must take the mouse")
	assert(ring.autoHide == 3, "a macro-opened ring must arm auto-hide")
	assert(bindings.ESCAPE and bindings.MOUSEWHEELUP, "temporary bindings missing")
	AssertSlots(1)
	-- the wheel still pages (through the clicker, the topmost wheel frame now)
	Scroll("MOUSEWHEELDOWN"); AssertSlots(61); assert(Label() == "Bar 2")
	-- the next /click fires the slice under the cursor, from the macro opener itself
	MoveTo(800, 550); MacroClick(1)
	assert(Uses() == before + 1 and LastSlot() == 65, "macro click did not fire slot 65")
	assert(macroOpener(1):GetAttribute("type") == "action" and macroOpener(1):GetAttribute("action") == 65 and macroOpener(1):GetAttribute("useOnKeyDown") == false)
	assert(not ring:IsShown() and not clicker:IsVisible() and header:GetAttribute("open") == false)
	-- a macro written with the down flag works the same
	MoveTo(800, 450); MacroClick(1, true)
	assert(ring:IsShown() and macroOpener(1):GetAttribute("useOnKeyDown") == true)
	MoveTo(900, 450); MacroClick(1, true)
	assert(Uses() == before + 2 and LastSlot() == 7 and not ring:IsShown())
	-- a click in the centre or past the cancel radius cancels
	MoveTo(800, 450); MacroClick(1); MacroClick(1)
	assert(not ring:IsShown() and Uses() == before + 2, "centre click did not cancel")
	MoveTo(800, 450); MacroClick(1); MoveTo(800, 700); MacroClick(1)
	assert(not ring:IsShown() and Uses() == before + 2, "click past the cancel radius did not cancel")
	-- a left click on the waiting ring fires; a right click cancels
	MoveTo(800, 450); MacroClick(1)
	MoveTo(800, 550); ClickRing("LeftButton")
	assert(Uses() == before + 3 and LastSlot() == 5, "clicker did not fire slot 5")
	assert(clicker:GetAttribute("type") == "action" and clicker:GetAttribute("action") == 5 and not ring:IsShown())
	MoveTo(800, 450); MacroClick(1)
	MoveTo(800, 550); ClickRing("RightButton")
	assert(not ring:IsShown() and Uses() == before + 3, "right click did not cancel")
	-- a hidden clicker takes no clicks: a key-opened ring in hold mode never shows it
	OpenAt(800, 450)
	assert(not clicker:IsVisible())
	assert(not pcall(ClickRing, "LeftButton"), "clicker must not be clickable while hidden")
	ReleaseAt(800, 450)
	-- context: the opening click captures the unit, the ring aims at it
	rr("harm 3"); Mouseover("enemy")
	MoveTo(800, 450); MacroClick(1)
	assert(Uses() == before + 4 and LastUse().macrotext == "/focus [@mouseover,exists,nodead]", "macro click did not capture")
	assert(header:GetAttribute("context") == "harm" and header:GetAttribute("unit") == "focus" and Label() == "Bar 3 · enemy @focus")
	AssertSlots(49)
	MoveTo(800, 550); MacroClick(1)
	assert(LastSlot() == 53 and LastUse().unit == "focus", "captured slice did not fire on the focus")
	Mouseover(nil); rr("harm none")
	-- another trigger's macro closes an open ring without firing
	rr("2 bars 3")
	MoveTo(800, 450); MacroClick(1)
	MoveTo(800, 550); MacroClick(2)
	assert(not ring:IsShown() and Uses() == before + 5, "trigger 2's macro must cancel trigger 1's ring")
	MoveTo(800, 450); MacroClick(2)
	assert(ring:IsShown() and header:GetAttribute("active") == 2 and Label() == "Bar 3")
	MoveTo(800, 550); MacroClick(2)
	assert(LastSlot() == 53)
	rr("2 remove")
	-- a trigger with no bars ignores its macro
	assert(frameByName.RadicalRadialOpener3:GetAttribute("barcount") == 0)
	MacroClick(3)
	assert(not ring:IsShown())
	-- nested rings through the clicker: a click on the folder opens it, a right click goes back, another closes
	rr("ring add Potions"); rr("ring set Potions 5 item 6948")
	rr("ring add Menu"); rr("ring set Menu 1 ring Potions"); rr("bars Menu")
	MoveTo(800, 450); MacroClick(1)
	MoveTo(800, 490); ClickRing("LeftButton")
	assert(ring:IsShown() and header:GetAttribute("sub") == 9 and clicker:IsVisible() and Uses() == before + 6, "clicker did not open the nested ring")
	ClickRing("RightButton")
	assert(ring:IsShown() and header:GetAttribute("sub") == nil and Label() == "Menu", "right click did not go back")
	ClickRing("RightButton")
	assert(not ring:IsShown())
	MoveTo(800, 450); MacroClick(1); MoveTo(800, 490); MacroClick(1)
	assert(header:GetAttribute("sub") == 9)
	MoveTo(800, 590); MacroClick(1)
	assert(Uses() == before + 7 and LastUse().item == "item:6948", "nested slice did not fire from the macro")
	rr("ring remove Menu"); rr("ring remove Potions"); rr("bars 1 2")
end)

scenario("click to fire: a key trigger's waiting ring takes the mouse only when asked; a nested ring in hold mode waits the same way", function()
	rr("reset"); rr("mode tap")
	OpenAt(800, 450); ReleaseAt(800, 450)
	assert(ring:IsShown() and not clicker:IsVisible(), "click to fire is off by default")
	Press("ESCAPE"); Release("ESCAPE")
	rr("click on")
	assert(trigger(1).click == true and opener:GetAttribute("clickfire") == true)
	local before = Uses()
	OpenAt(800, 450); ReleaseAt(800, 450)
	assert(clicker:IsVisible(), "click to fire did not show the clicker")
	MoveTo(800, 550); ClickRing("LeftButton")
	assert(Uses() == before + 1 and LastSlot() == 5 and not ring:IsShown())
	-- a hold-and-release in tap mode never rests, so the clicker never shows
	OpenAt(800, 450)
	assert(not clicker:IsVisible())
	ReleaseAt(900, 450)
	assert(LastSlot() == 7)
	-- hold mode: only a nested ring waits
	rr("mode hold")
	rr("ring add Potions"); rr("ring set Potions 5 item 6948"); rr("ring add Menu"); rr("ring set Menu 1 ring Potions"); rr("bars Menu")
	OpenAt(800, 450)
	assert(not clicker:IsVisible())
	ReleaseAt(800, 490)
	assert(ring:IsShown() and header:GetAttribute("sub") == 9 and clicker:IsVisible(), "a nested ring must take the mouse with click to fire on")
	MoveTo(800, 590); ClickRing("LeftButton")
	assert(Uses() == before + 3 and LastUse().item == "item:6948")
	-- the thumb button still works on a waiting ring (it lands on the clicker, which fires like any button)
	OpenAt(800, 450); ReleaseAt(800, 490)
	MoveTo(800, 590); ClickRing("Button4")
	assert(Uses() == before + 4 and LastUse().item == "item:6948")
	rr("click off")
	OpenAt(800, 450); ReleaseAt(800, 490)
	assert(ring:IsShown() and not clicker:IsVisible())
	Press("ESCAPE"); Release("ESCAPE")
	-- the window's box
	rr("config")
	assert(not cui.click.checked)
	ClickUI(cui.click)
	assert(trigger(1).click == true and opener:GetAttribute("clickfire") == true and cui.click.checked)
	ClickUI(cui.click)
	assert(trigger(1).click == false)
	rr("triggers"); assert(OutputContains("| layout 4+8 | click off | macro /click RadicalRadialMacro1"))
	rr("config")
	rr("ring remove Menu"); rr("ring remove Potions"); rr("bars 1 2")
end)

scenario("macro creation: /rr macro prints the macro, create makes or updates it and puts it on the cursor, the window's button does the same", function()
	rr("macro")
	assert(OutputContains("/click RadicalRadialMacro1"))
	assert(GetMacroIndexByName("Radial 1") == 0)
	rr("macro create")
	local index = GetMacroIndexByName("Radial 1")
	assert(index > 0 and select(3, GetMacroInfo(index)) == "/click RadicalRadialMacro1", "macro not created")
	assert(cursorInfo and cursorInfo[1] == "macro" and cursorInfo[2] == index, "macro not on the cursor")
	assert(OutputContains("macro Radial 1 created") and OutputContains("drop it on an action bar"))
	ClearCursor()
	rr("2 macro create")
	assert(GetMacroIndexByName("Radial 2") > 0 and select(3, GetMacroInfo("Radial 2")) == "/click RadicalRadialMacro2" and #RadicalRadialDB.triggers == 2)
	ClearCursor()
	EditMacro("Radial 1", "Radial 1", "INV_MISC_QUESTIONMARK", "/say broken")
	rr("macro create")
	assert(select(3, GetMacroInfo("Radial 1")) == "/click RadicalRadialMacro1" and OutputContains("macro Radial 1 updated"))
	assert(GetMacroIndexByName("Radial 1") == index, "update must keep the macro's slot")
	ClearCursor()
	-- the window
	rr("config"); assert(cfg:IsShown())
	assert(cui.macroHint.shown and cui.macroHint.text:find("/click RadicalRadialMacro1", 1, true), "macro hint missing: " .. tostring(cui.macroHint.text))
	ClickUI(cui.key)
	assert(cui.hint.shown and not cui.macroHint.shown, "the capture hint must replace the macro line")
	cfg.scripts.OnKeyDown(cfg, "ESCAPE"); Tick(); RunTimers()
	assert(cui.macroHint.shown and not cui.hint.shown)
	ClickUI(cui.macro)
	assert(cursorInfo and cursorInfo[1] == "macro" and cursorInfo[2] == index)
	ClearCursor()
	-- in combat nothing is made
	inCombat = true
	rr("macro create")
	assert(OutputContains("not in combat") and cursorInfo == nil)
	inCombat = false
	-- a full macro list
	macroLimit = #macros
	rr("3 macro create")
	assert(GetMacroIndexByName("Radial 3") == 0 and OutputContains("could not create the macro"))
	macroLimit = 120
	rr("config")
	rr("3 remove"); rr("2 remove")
end)

scenario("ring editor: the layout radios place the slots, an empty slot's right-click menu nests a ring, a nested slot changes or clears", function()
	rr("reset")
	rr("ring add Potions"); rr("ring set Potions 5 item 6948")
	rr("ring add Menu")
	rr("config"); cui.ShowTab("rings")
	ClickUI(cui.ringButtons[2]); assert(cui.ring == 2 and cui.ringName.text == "Menu")
	assert(cui.ringLayouts["4+8"].checked and cui.slots[12].shown and not cui.slots[13].shown)
	ClickUI(cui.ringLayouts["8+8"])
	assert(rings()[2].layout == "8+8" and cui.ringLayouts["8+8"].checked and cui.slots[16].shown, "layout radio did not apply")
	ClickUI(cui.ringLayouts["6"])
	assert(rings()[2].layout == "6" and cui.slots[6].shown and not cui.slots[7].shown)
	assert(cui.slots[1].w == 36, "single tier slots are outer-sized")
	ClickUI(cui.ringLayouts["4+8"])
	assert(cui.slots[1].w == 30 and cui.slots[5].w == 36)
	-- right-click an empty slot: the menu of other rings; the choice nests it
	cui.slots[1]:Click("RightButton", false)
	assert(lastMenu.children[1].title and lastMenu.children[1].text == "Nest a ring in slot 1" and lastMenu.children[2].text == "Potions" and #lastMenu.children == 2, "nest menu wrong")
	lastMenu.children[2].callback()
	assert(rings()[2].slices[1].kind == "ring" and rings()[2].slices[1].name == "Potions")
	assert(cui.slots[1].icon.shown and cui.slots[1].icon.texture == ns.FOLDER_ICON and cui.slots[1].sub.text == "Potions", "folder slot art")
	cui.slots[1].scripts.OnEnter(cui.slots[1]); assert(tooltip.text == "Nested ring: Potions"); cui.slots[1].scripts.OnLeave(cui.slots[1])
	-- clicking a nested slot offers the rings and Clear; nothing goes on the cursor
	ClickUI(cui.slots[1])
	assert(cursorInfo == nil and lastMenu.children[3].text == "Clear", "nested slot click")
	lastMenu.children[3].callback()
	assert(rings()[2].slices[1] == nil and not cui.slots[1].icon.shown and cui.slots[1].sub.text == "")
	-- dragging a nested slot does nothing; right-click clears it
	cui.slots[1]:Click("RightButton", false); lastMenu.children[2].callback()
	cui.slots[1].scripts.OnDragStart(cui.slots[1])
	assert(rings()[2].slices[1] and cursorInfo == nil, "a nested ring has no cursor form")
	cui.slots[1]:Click("RightButton", false)
	assert(rings()[2].slices[1] == nil)
	-- a drop on a nested slot replaces it and puts nothing on the cursor
	cui.slots[1]:Click("RightButton", false); lastMenu.children[2].callback()
	C_Spell.PickupSpell(6603); ClickUI(cui.slots[1])
	assert(rings()[2].slices[1].kind == "spell" and cursorInfo == nil, "drop on a nested slot")
	-- with no other ring the menu only says so
	ClickUI(cui.ringButtons[1]); assert(cui.ring == 1)
	rr("ring remove Menu")
	cui.slots[2]:Click("RightButton", false)
	assert(lastMenu.children[1].text == "No other ring to nest yet" and #lastMenu.children == 1)
	rr("reset"); rr("config"); assert(not cfg:IsShown())
end)

-------------------------------------------------------------------------------
-- Run
-------------------------------------------------------------------------------

local failures = 0
for _, s in ipairs(scenarios) do
	local ok, err = xpcall(s.fn, function(e)
		-- the assertion and the scenario line it came from
		local trace = debug.traceback(tostring(e), 2)
		local where = trace:match("harness%.lua:(%d+): in function <[^>]+>") or trace:match("\n%s*%[string [^%]]+%]:(%d+): in [^\n]*\n%s*%[string")
		return tostring(e) .. (where and (" (scenario line " .. where .. ")") or "") .. (os.getenv("HARNESS_VERBOSE") and ("\n" .. trace) or "")
	end)
	realPrint((ok and "PASS  " or "FAIL  ") .. s.name .. (ok and "" or ("\n      " .. tostring(err))))
	if not ok then failures = failures + 1 end
end
realPrint(("%d scenarios, %d failed"):format(#scenarios, failures))
return failures
