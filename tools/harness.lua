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

local Frame = {}
Frame.__index = Frame

local function NewFrame(kind, name, parent, template)
	local f = setmetatable({
		kind = kind, name = name, parent = parent, template = template or "",
		attributes = {}, scripts = {}, hooks = {}, framerefs = {},
		shown = true, w = 0, h = 0, cx = SCREEN_W / 2, cy = SCREEN_H / 2, scale = 1,
		clicks = {}, mouse = true, protected = (template or ""):find("Secure") ~= nil,
	}, Frame)
	if name then frameByName[name] = f; _G[name] = f end
	allFrames[#allFrames + 1] = f
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
function Frame:RegisterForDrag() end
function Frame:SetChecked(v) self.checked = v end
function Frame:LockHighlight() self.highlightLocked = true end
function Frame:UnlockHighlight() self.highlightLocked = false end
function Frame:Show()
	local was = self.shown
	self.shown = true
	if not was then
		if self.attributes._onshow then self:RunAttribute("_onshow") end
		if self.scripts.OnShow then self.scripts.OnShow(self) end
	end
end
function Frame:Hide()
	local was = self.shown
	self.shown = false
	if was then
		if self.attributes._onhide then self:RunAttribute("_onhide") end
		if self.scripts.OnHide then self.scripts.OnHide(self) end
	end
end
function Frame:IsShown() return self.shown end
function Frame:RegisterForClicks(...) self.clicks = { ... } end
function Frame:RegisterEvent() end
function Frame:UnregisterEvent() end
function Frame:SetScript(name, fn) self.scripts[name] = fn end
function Frame:GetScript(name) return self.scripts[name] end
function Frame:HookScript(name, fn)
	self.hooks[name] = self.hooks[name] or {}
	table.insert(self.hooks[name], fn)
end
function Frame:SetAttribute(name, value)
	self.attributes[name] = value
	if self.scripts.OnAttributeChanged then self.scripts.OnAttributeChanged(self, name, value) end
end
function Frame:GetAttribute(name) return self.attributes[name] end
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
function Frame:RegisterAutoHide(duration) self.autoHide = duration end
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

local function RunSnippet(body, self, control, args, ...)
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
	local body = self.attributes[name]
	assert(body, "RunAttribute: no snippet named " .. tostring(name))
	return RunSnippet(body, self, currentControl or self, nil, ...)
end

-- SecureActionButton_OnClick, reduced to what the addon relies on.
local function SecureActionButtonClick(frame, button, down)
	local useOnKeyDown = frame:GetAttribute("useOnKeyDown")
	local clickAction = (down and useOnKeyDown) or (not down and not useOnKeyDown)
	if not clickAction then return end
	local kind = frame:GetAttribute("type")
	if kind == "action" then
		table.insert(useActionLog, { action = frame:GetAttribute("action"), unit = frame:GetAttribute("unit"), button = button })
	elseif kind == "macro" then
		table.insert(useActionLog, { macrotext = frame:GetAttribute("macrotext"), button = button })
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
		end
	end
	-- HookScript hooks run after the script handler returns, whatever it did.
	for _, hook in ipairs(self.hooks.OnClick or {}) do hook(self, button, down) end
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
function GetCursorPosition() return cursor.x, cursor.y end
function GetBuildInfo() return "1.60.1", "70009", "Sep 24 2026", 16001 end
function securecallfunction(fn, ...) return fn(...) end
function geterrorhandler() return error end
WOW_PROJECT_ID = 1
WOW_PROJECT_MAINLINE = 1
SlashCmdList = {}
C_ActionBar = {
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
	RunSnippet(self.attributes.UpdateState, self, self.header, nil, self:GetAttribute("state"))
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
		else
			self.icon:Hide()
		end
	end
end

function LABButton:UpdateConfig(config) self.config = config end

local function InstallFakeLAB(path)
	local source = ReadFile(path)
	local minor = tonumber(source:match('local MINOR_VERSION = (%d+)'))
	local updateState = source:match('SetAttribute%("UpdateState", %[%[(.-)%]%]%)')
	assert(minor and updateState, "could not extract the UpdateState snippet from " .. path)

	local lib = LibStub:NewLibrary("LibActionButton-1.0", minor)
	lib.callbacks = { RegisterCallback = function() end, UnregisterCallback = function() end, Fire = function() end }
	lib.updateStateSnippet = updateState

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

local eventsFrame
for _, f in ipairs(allFrames) do if f.scripts.OnEvent then eventsFrame = f end end
assert(eventsFrame, "addon created no event frame")

local header = frameByName.RadicalRadialHeader
local ring   = frameByName.RadicalRadialRing
local opener = frameByName.RadicalRadialOpener
local function slice(i) return frameByName["RadicalRadialSlice" .. i] end

local function Fire(event, ...) eventsFrame.scripts.OnEvent(eventsFrame, event, ...) end
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
	assert(header:GetAttribute("barcount") == 2)
	assert(header:GetAttribute("radius") == 120)
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
	assert(header:GetAttribute("barcount") == 3)
	OpenAt(800, 450); Wheel("MOUSEWHEELDOWN"); Wheel("MOUSEWHEELDOWN"); AssertSlots(49); ReleaseAt(800, 450)

	rr("scale 1.4")
	assert(header:GetAttribute("radius") == 168, "radius " .. tostring(header:GetAttribute("radius")))
	assert(frameByName.RadicalRadialVisual.scale == 1.4)
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
	assert(OutputContains("opener click: LeftButton down"), "debug hook output missing")
	assert(OutputContains("RR secure|r press: ring opened at cursor"))
	assert(OutputContains("RR secure|r release: slice 5"))
	rr("debug"); assert(RadicalRadialDB.debug == false)

	rr("bind SHIFT-BUTTON5")
	assert(bindings["SHIFT-BUTTON5"] and not bindings.BUTTON4, "rebind failed")
	rr("bind none")
	assert(not bindings["SHIFT-BUTTON5"], "bind none did not clear")
	rr("reset")
	assert(RadicalRadialDB.trigger == "BUTTON4" and RadicalRadialDB.scale == 1 and #RadicalRadialDB.bars == 2)
	assert(bindings.BUTTON4 and header:GetAttribute("radius") == 120)
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
	rr("debug")
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
