-- Offline harness for RadicalRadial.lua.
--
-- Fakes just enough of the WoW API and of the restricted environment to load
-- the addon, run its snippets, and walk through press / wheel / release /
-- cancel scenarios with assertions. It checks syntax and logic, not the
-- client's real behaviour (binding delivery, combat lockdown, secrets): those
-- are the in-game checklist in README.md.
--
-- Run with tools/check.py (needs the lupa Python package) or any Lua 5.1+.

math.atan2 = math.atan2 or function(y, x) return math.atan(y, x) end
unpack = unpack or table.unpack

local SCREEN_W, SCREEN_H = 1600, 900
local cursor = { x = 800, y = 450 }
local inCombat = false
local useActionLog = {}
local bindings = {}          -- key -> { owner, frame, button }
local frameByName = {}
local allFrames = {}
local fontStrings = {}
local output = {}

local realPrint = print
function print(...)
	local parts = {}
	for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
	output[#output + 1] = table.concat(parts, " ")
	if os.getenv("HARNESS_VERBOSE") then realPrint(...) end
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
function Frame:SetFrameStrata() end
function Frame:SetAlpha() end
function Frame:EnableMouse(v) self.mouse = v end
function Frame:Show()
	local was = self.shown
	self.shown = true
	if not was and self.scripts.OnShow then self.scripts.OnShow(self) end
end
function Frame:Hide() self.shown = false end
function Frame:IsShown() return self.shown end
function Frame:RegisterForClicks(...) self.clicks = { ... } end
function Frame:RegisterEvent() end
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
function Frame:CreateFontString()
	local r = NewRegion("fontstring")
	fontStrings[#fontStrings + 1] = r
	return r
end
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

-------------------------------------------------------------------------------
-- Restricted environment emulation
-------------------------------------------------------------------------------

local barState = { page = 1, bonus = false, bonusIndex = 7, vehicle = false, override = false, temp = false }

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
	}
	for k, v in pairs(args or {}) do env[k] = v end
	setmetatable(env, { __index = function(_, k)
		error("snippet used a name that is not in the restricted environment: " .. tostring(k), 2)
	end })
	return env
end

local function RunSnippet(body, self, control, args)
	local chunk, err = load(body, "snippet", "t", RestrictedEnv(self, control, args))
	assert(chunk, err)
	return chunk()
end

function Frame:RunAttribute(name, ...)
	local body = self.attributes[name]
	assert(body, "RunAttribute: no snippet named " .. tostring(name))
	return RunSnippet(body, self, self)
end

-- SecureActionButton_OnClick, reduced to what the spike relies on.
local function SecureActionButtonClick(frame, button, down)
	local useOnKeyDown = frame:GetAttribute("useOnKeyDown")
	local clickAction = (down and useOnKeyDown) or (not down and not useOnKeyDown)
	if clickAction and frame:GetAttribute("type") == "action" then
		table.insert(useActionLog, frame:GetAttribute("action"))
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
WOW_PROJECT_ID = 1
SlashCmdList = {}
C_ActionBar = {
	HasAction = function(slot) return slot >= 1 and slot <= 180 and slot % 5 ~= 0 end,
	GetActionTexture = function(slot) return 100000 + slot end,
	GetActionCooldown = function(slot) return { startTime = 0, duration = 0, isActive = false, modRate = 1 } end,
}

-------------------------------------------------------------------------------
-- Load the addon
-------------------------------------------------------------------------------

local chunk, err = loadfile("RadicalRadial.lua")
assert(chunk, err)
chunk("RadicalRadial")


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
local function SliceSlots()
	local t = {}
	for i = 1, 12 do t[i] = slice(i):GetAttribute("action") end
	return t
end
local function AssertSlots(base)
	for i = 1, 12 do
		local got = slice(i):GetAttribute("action")
		assert(got == base + i - 1, ("slice %d has slot %s, expected %d"):format(i, tostring(got), base + i - 1))
	end
end
local function Label()
	for _, r in ipairs(fontStrings) do if r.text ~= "" then return r.text end end
	return ""
end
local function OutputContains(needle)
	for _, line in ipairs(output) do if line:find(needle, 1, true) then return true end end
	return false
end

local function OpenAt(x, y) MoveTo(x, y); Press("BUTTON4") end
local function ReleaseAt(x, y) MoveTo(x, y); Release("BUTTON4") end

-------------------------------------------------------------------------------
-- Scenarios
-------------------------------------------------------------------------------

local scenarios = {}
local function scenario(name, fn) scenarios[#scenarios + 1] = { name = name, fn = fn } end

scenario("load: binding, slices on Bar 1, label", function()
	Fire("ADDON_LOADED", "RadicalRadial")
	Fire("PLAYER_LOGIN")
	assert(bindings.BUTTON4, "BUTTON4 not bound")
	assert(bindings.BUTTON4.frame == opener and bindings.BUTTON4.button == "LeftButton")
	assert(header:GetAttribute("barcount") == 2)
	assert(header:GetAttribute("radius") == 120)
	AssertSlots(1)
	assert(Label() == "Bar 1", "label is " .. Label())
	assert(not ring:IsShown())
	assert(slice(5).icon.shown == false, "empty slot 5 should hide its icon")
	assert(slice(1).icon.shown == true)
	assert(slice(1).icon.texture == 100001)
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

scenario("wheel cycles bars and wraps", function()
	Wheel("MOUSEWHEELDOWN")
	assert(header:GetAttribute("page") == 2)
	AssertSlots(61)
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
	assert(Uses() == 1 and LastUse() == 65, "expected slot 65, got " .. tostring(LastUse()))
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
		assert(LastUse() == c[3], ("offset (%d,%d): expected slot %d, got %s"):format(c[1], c[2], c[3], tostring(LastUse())))
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

scenario("Bar 1 follows bonus bar, vehicle and override pages", function()
	barState.bonus = true
	OpenAt(800, 450); AssertSlots(73); ReleaseAt(800, 450)
	barState.bonus = false
	barState.vehicle = true
	OpenAt(800, 450); AssertSlots(133); ReleaseAt(800, 450)
	barState.vehicle = false
	barState.override = true
	OpenAt(800, 450); AssertSlots(157); ReleaseAt(800, 450)
	barState.override = false
	barState.page = 3
	OpenAt(800, 450); AssertSlots(25); ReleaseAt(800, 450)
	barState.page = 1
	-- Bar 2 in the cycle is fixed regardless of stance
	barState.bonus = true
	OpenAt(800, 450); Wheel("MOUSEWHEELDOWN"); AssertSlots(61); ReleaseAt(800, 450)
	barState.bonus = false
end)

scenario("presentation highlight follows the cursor", function()
	OpenAt(800, 450)
	MoveTo(800, 550)
	ring.scripts.OnUpdate(ring)
	for i = 1, 12 do
		assert(slice(i).highlight.shown == (i == 5), "highlight wrong on slice " .. i)
	end
	MoveTo(801, 451)
	ring.scripts.OnUpdate(ring)
	for i = 1, 12 do assert(not slice(i).highlight.shown) end
	ReleaseAt(801, 451)
end)

scenario("cooldown and slot-change events update shown slices only", function()
	slice(1).cooldown.cooldown = nil
	Fire("ACTIONBAR_UPDATE_COOLDOWN")
	assert(slice(1).cooldown.cooldown == nil, "updated cooldowns while hidden")
	OpenAt(800, 450)
	slice(1).cooldown.cooldown = nil
	Fire("ACTIONBAR_UPDATE_COOLDOWN")
	assert(slice(1).cooldown.cooldown ~= nil, "cooldown not applied while shown")
	Fire("ACTIONBAR_SLOT_CHANGED", 3)
	ReleaseAt(800, 450)
end)

scenario("slash commands: bars, scale, status, preview, debug, bind, reset", function()
	local rr = SlashCmdList.RADICALRADIAL
	rr("bars 1 2 3")
	assert(header:GetAttribute("barcount") == 3)
	OpenAt(800, 450); Wheel("MOUSEWHEELDOWN"); Wheel("MOUSEWHEELDOWN"); AssertSlots(49); ReleaseAt(800, 450)

	rr("scale 1.4")
	assert(header:GetAttribute("radius") == 168, "radius " .. tostring(header:GetAttribute("radius")))
	OpenAt(800, 450); ReleaseAt(800, 500)   -- r = 50: inner at scale 1.4, outer at scale 1
	assert(LastUse() == 1, "scaled geometry: expected slot 1, got " .. tostring(LastUse()))
	rr("scale 9")
	assert(RadicalRadialDB.scale == 2, "scale not clamped")
	rr("scale 1")

	rr("status")
	assert(OutputContains("secure snippets: |cff33ff33OK|r"), "status did not report snippets OK")
	assert(OutputContains("visual errors: none"))

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

scenario("config changes in combat wait for combat to end", function()
	local before = header:GetAttribute("radius")
	inCombat = true
	SlashCmdList.RADICALRADIAL("scale 1.2")
	assert(RadicalRadialDB.scale == 1.2)
	assert(header:GetAttribute("radius") == before, "applied config in combat")
	inCombat = false
	Fire("PLAYER_REGEN_ENABLED")
	assert(header:GetAttribute("radius") == 144, "pending config not applied")
	SlashCmdList.RADICALRADIAL("scale 1")
end)

scenario("snippets never touch a name outside the restricted environment", function()
	-- RestrictedEnv errors on any unknown global, so a full press/wheel/release
	-- pass with debug on exercises every branch of every snippet.
	SlashCmdList.RADICALRADIAL("debug")
	OpenAt(800, 450); Wheel("MOUSEWHEELDOWN"); Wheel("MOUSEWHEELUP"); ReleaseAt(800, 550)
	OpenAt(800, 450); ReleaseAt(800, 450)
	OpenAt(800, 450); Press("ESCAPE"); Release("ESCAPE"); ReleaseAt(800, 450)
	SlashCmdList.RADICALRADIAL("debug")
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
