-------------------------------------------------------------------------------
-- Radical Radial — M0 spike
--
-- Hold the trigger (default BUTTON4): a ring showing the current action bar
-- opens around the cursor. Flick toward a slice and release to use it. Scroll
-- while holding to cycle bars. Release in the centre, or press Escape, to
-- cancel.
--
-- This spike exists to prove four things in combat on the Forever beta:
--   1. a mouse-button binding delivers both the down and the up click to a
--      secure action button, and a wrapped OnClick can swallow the down click;
--   2. "$cursor" anchoring and GetMousePosition() give correct geometry;
--   3. wheel paging through override bindings works while the trigger is held;
--   4. secure snippets run on the current build.
-- Run /rr status, turn on /rr debug, then fight something.
--
-- Layout of this file: constants → geometry → secure snippets → secure frames
-- → presentation (icons, highlight) → config → events → slash commands.
-------------------------------------------------------------------------------

local VERSION = "0.0.1-m0"

-------------------------------------------------------------------------------
-- Constants
-------------------------------------------------------------------------------

local RADIUS      = 120    -- outer icon ring radius, UIParent units at scale 1
local INNER_R     = 0.40   -- inner icon ring radius as a fraction of RADIUS
local DEAD        = 0.15   -- release inside this fraction of RADIUS cancels
local INNER_LIMIT = 0.55   -- tier boundary as a fraction of RADIUS
local INNER_COUNT = 4
local OUTER_COUNT = 8
local SLICE_COUNT = INNER_COUNT + OUTER_COUNT   -- 12: one action bar
local ICON_INNER  = 36
local ICON_OUTER  = 44

-- First action slot of each Edit Mode bar. Bar 1 has no fixed base: the ring
-- resolves it at open time (stance, form, vehicle, override) inside a snippet,
-- using the same calls Blizzard's own main bar uses.
local BAR_BASE  = { [2] = 61, [3] = 49, [4] = 25, [5] = 37, [6] = 145, [7] = 157, [8] = 169 }
local BAR_NAMES = { "Bar 1", "Bar 2", "Bar 3", "Bar 4", "Bar 5", "Bar 6", "Bar 7", "Bar 8" }

local DEFAULTS = { trigger = "BUTTON4", bars = { 1, 2 }, scale = 1, debug = false }

local db   -- RadicalRadialDB, available after ADDON_LOADED

local PREFIX = "|cff33ff99Radical Radial|r "
local function Print(fmt, ...)
	if select("#", ...) > 0 then fmt = fmt:format(...) end
	print(PREFIX .. fmt)
end
local function Debug(fmt, ...)
	if db and db.debug then Print(fmt, ...) end
end

-------------------------------------------------------------------------------
-- Geometry (shared by the presentation layer; the snippet below repeats the
-- same formulas with the same constants baked in)
-------------------------------------------------------------------------------

-- Slice i → angle in degrees clockwise from 12 o'clock, radius fraction, icon size.
local function SlicePolar(i)
	if i <= INNER_COUNT then
		return (i - 1) * (360 / INNER_COUNT), INNER_R, ICON_INNER
	end
	return (i - INNER_COUNT - 1) * (360 / OUTER_COUNT), 1, ICON_OUTER
end

-- Cursor offset from the ring centre → slice index (nil in the dead zone), distance.
local function Resolve(dx, dy, R)
	local r = math.sqrt(dx * dx + dy * dy)
	if r < DEAD * R then return nil, r end
	local a = (90 - math.deg(math.atan2(dy, dx))) % 360
	if r < INNER_LIMIT * R then
		return 1 + math.floor(((a + 180 / INNER_COUNT) % 360) / (360 / INNER_COUNT)), r
	end
	return INNER_COUNT + 1 + math.floor(((a + 180 / OUTER_COUNT) % 360) / (360 / OUTER_COUNT)), r
end

-------------------------------------------------------------------------------
-- Secure snippets (run in Blizzard's restricted environment)
-------------------------------------------------------------------------------

local SNIPPET_CONSTANTS = { DEAD = DEAD, LIMIT = INNER_LIMIT, IN = INNER_COUNT, OUT = OUTER_COUNT }
local function Snippet(body)
	return (body:gsub("%$(%u+)", function(key)
		return tostring(assert(SNIPPET_CONSTANTS[key], "unknown snippet constant " .. key))
	end))
end

-- Wrapped around the opener's OnClick. `self` is the opener, `control` the
-- header, and `button`, `down` come from the click. Returning false tells the
-- wrap machinery to skip Blizzard's click handler entirely; returning nothing
-- lets it run with the attributes we just set.
local PRE_CLICK = Snippet([[
local hdr = control
if down then
	if hdr:GetAttribute("open") then return false end
	local ring = hdr:GetFrameRef("ring")
	hdr:SetAttribute("page", 1)
	hdr:RunAttribute("ApplyPage")
	ring:ClearAllPoints()
	ring:SetPoint("CENTER", "$cursor")
	ring:Show()
	hdr:SetAttribute("open", true)
	hdr:SetBindingClick(true, "MOUSEWHEELUP",   "RadicalRadialHeader", "wheelup")
	hdr:SetBindingClick(true, "MOUSEWHEELDOWN", "RadicalRadialHeader", "wheeldown")
	hdr:SetBindingClick(true, "ESCAPE",         "RadicalRadialHeader", "cancel")
	if hdr:GetAttribute("debug") then print("|cff33ff99RR secure|r press: ring opened at cursor") end
	return false
end

if not hdr:GetAttribute("open") then return false end

local screen = hdr:GetFrameRef("screen")
local ring   = hdr:GetFrameRef("ring")
local idx, r
local fx, fy = screen:GetMousePosition()
local sl, sb, sw, sh = screen:GetRect()
local l, b, w, h = ring:GetRect()
if fx and sl and l then
	local dx = (sl + fx * sw) - (l + w / 2)
	local dy = (sb + fy * sh) - (b + h / 2)
	local R = hdr:GetAttribute("radius")
	r = math.sqrt(dx * dx + dy * dy)
	if r >= $DEAD * R then
		local a = (90 - deg(math.atan2(dy, dx))) % 360
		if r < $LIMIT * R then
			idx = 1 + floor(((a + 180 / $IN) % 360) / (360 / $IN))
		else
			idx = $IN + 1 + floor(((a + 180 / $OUT) % 360) / (360 / $OUT))
		end
	end
end

hdr:RunAttribute("Close")

if idx then
	local slot = hdr:GetFrameRef("slice" .. idx):GetAttribute("action")
	self:SetAttribute("action", slot)
	self:SetAttribute("type", "action")
	if hdr:GetAttribute("debug") then
		print("|cff33ff99RR secure|r release: slice " .. idx .. " -> slot " .. tostring(slot) .. " (r=" .. floor(r) .. ")")
	end
	return
end

self:SetAttribute("type", nil)
if hdr:GetAttribute("debug") then
	print("|cff33ff99RR secure|r release: cancelled (r=" .. tostring(r and floor(r)) .. ")")
end
return false
]])

-- Header attribute "ApplyPage": point the 12 slices at the bar for the current
-- page. Bar 1 follows Blizzard's own page selection for the main bar.
local APPLY_PAGE = [[
local page = self:GetAttribute("page") or 1
local bar  = self:GetAttribute("bar" .. page) or 1
local base = self:GetAttribute("base" .. bar)
if not base then
	local p
	if HasVehicleActionBar() then
		p = GetVehicleBarIndex()
	elseif HasOverrideActionBar() then
		p = GetOverrideBarIndex()
	elseif HasTempShapeshiftActionBar() then
		p = GetTempShapeshiftBarIndex()
	elseif HasBonusActionBar() and GetActionBarPage() == 1 then
		p = GetBonusBarIndex()
	else
		p = GetActionBarPage()
	end
	base = (p - 1) * 12 + 1
end
self:SetAttribute("basecurrent", base)
for i = 1, 12 do
	self:GetFrameRef("slice" .. i):SetAttribute("action", base + i - 1)
end
]]

-- Header attribute "Close": hide the ring and drop the temporary bindings.
local CLOSE = [[
self:SetAttribute("open", false)
self:GetFrameRef("ring"):Hide()
self:ClearBindings()
]]

-- Header _onclick: receives the override-bound wheel and Escape "clicks".
local HEADER_CLICK = [[
if not down then return end
if not self:GetAttribute("open") then return end
if button == "cancel" then
	self:RunAttribute("Close")
	if self:GetAttribute("debug") then print("|cff33ff99RR secure|r cancelled with Escape") end
elseif button == "wheelup" or button == "wheeldown" then
	local n    = self:GetAttribute("barcount") or 1
	local page = self:GetAttribute("page") or 1
	local step = (button == "wheeldown") and 1 or -1
	page = ((page - 1 + step) % n) + 1
	self:SetAttribute("page", page)
	self:RunAttribute("ApplyPage")
	if self:GetAttribute("debug") then print("|cff33ff99RR secure|r page " .. page) end
end
]]

-------------------------------------------------------------------------------
-- Secure frames (all created at load, out of combat)
-------------------------------------------------------------------------------

-- Reference frame the size of the screen. Snippets read the cursor through it.
local screen = CreateFrame("Frame", "RadicalRadialScreen", UIParent, "SecureFrameTemplate")
screen:SetAllPoints(UIParent)
screen:SetFrameStrata("BACKGROUND")
screen:EnableMouse(false)
screen:Show()

-- The ring. Anchored to the cursor by the press snippet. Kept at scale 1 so its
-- rect is in the same units as the screen frame; the scaled visuals live in a
-- child.
local ring = CreateFrame("Frame", "RadicalRadialRing", UIParent, "SecureFrameTemplate")
ring:SetSize(2, 2)
ring:SetPoint("CENTER")
ring:SetFrameStrata("FULLSCREEN_DIALOG")
ring:EnableMouse(false)
ring:Hide()

local visual = CreateFrame("Frame", nil, ring)
visual:SetPoint("CENTER")
visual:SetSize(2, 2)

-- The trigger's target. Both the down and the up click land here; the wrapped
-- pre-snippet decides what, if anything, Blizzard's handler does with them.
local opener = CreateFrame("Button", "RadicalRadialOpener", UIParent, "SecureActionButtonTemplate")
opener:RegisterForClicks("AnyDown", "AnyUp")
opener:SetAttribute("useOnKeyDown", false)
opener:SetSize(1, 1)
opener:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", -8, -8)
opener:SetAlpha(0)

-- The header: owns the snippets, the frame refs and the temporary bindings.
local header = CreateFrame("Button", "RadicalRadialHeader", UIParent, "SecureHandlerClickTemplate")
header:RegisterForClicks("AnyDown", "AnyUp")
header:SetSize(1, 1)
header:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", -8, -8)
header:SetAlpha(0)

-- Owner of the persistent trigger binding, kept separate from the header so
-- the header's ClearBindings() never removes the trigger itself.
local bindOwner = CreateFrame("Frame", "RadicalRadialBindOwner", UIParent)

-- Slices: secure action buttons whose attributes are the ring's content.
local slices = {}
for i = 1, SLICE_COUNT do
	local angle, radiusFraction, size = SlicePolar(i)
	local slice = CreateFrame("Button", "RadicalRadialSlice" .. i, visual, "SecureActionButtonTemplate")
	slice:SetSize(size, size)
	slice:SetPoint("CENTER", visual, "CENTER",
		math.sin(math.rad(angle)) * RADIUS * radiusFraction,
		math.cos(math.rad(angle)) * RADIUS * radiusFraction)
	slice:EnableMouse(false)
	slice:SetAttribute("type", "action")
	slice:SetAttribute("action", i)

	slice.back = slice:CreateTexture(nil, "BACKGROUND")
	slice.back:SetPoint("TOPLEFT", -3, 3)
	slice.back:SetPoint("BOTTOMRIGHT", 3, -3)
	slice.back:SetColorTexture(0, 0, 0, 0.6)

	slice.icon = slice:CreateTexture(nil, "ARTWORK")
	slice.icon:SetAllPoints()
	slice.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

	slice.cooldown = CreateFrame("Cooldown", nil, slice, "CooldownFrameTemplate")
	slice.cooldown:SetAllPoints()

	slice.highlight = slice:CreateTexture(nil, "OVERLAY")
	slice.highlight:SetPoint("TOPLEFT", -3, 3)
	slice.highlight:SetPoint("BOTTOMRIGHT", 3, -3)
	slice.highlight:SetColorTexture(1, 0.82, 0, 0.35)
	slice.highlight:Hide()

	slices[i] = slice
end

local center = visual:CreateTexture(nil, "OVERLAY")
center:SetSize(10, 10)
center:SetPoint("CENTER")
center:SetColorTexture(0.9, 0.2, 0.2, 0.9)

local label = visual:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
label:SetPoint("TOP", visual, "CENTER", 0, -(RADIUS + ICON_OUTER))
label:SetText("")

-- Wiring
SecureHandlerSetFrameRef(header, "ring", ring)
SecureHandlerSetFrameRef(header, "screen", screen)
SecureHandlerSetFrameRef(header, "opener", opener)
for i, slice in ipairs(slices) do
	SecureHandlerSetFrameRef(header, "slice" .. i, slice)
end
header:SetAttribute("ApplyPage", APPLY_PAGE)
header:SetAttribute("Close", CLOSE)
header:SetAttribute("_onclick", HEADER_CLICK)
header:SetAttribute("open", false)
header:SetAttribute("page", 1)
SecureHandlerWrapScript(opener, "OnClick", header, PRE_CLICK)

-------------------------------------------------------------------------------
-- Presentation layer (ordinary code; only touches textures, text, cooldowns
-- and alpha, which are allowed on protected frames in combat)
-------------------------------------------------------------------------------

local GetActionTexture  = C_ActionBar.GetActionTexture or GetActionTexture
local HasAction         = C_ActionBar.HasAction or HasAction
local GetActionCooldown = C_ActionBar.GetActionCooldown

local visualErrors = {}      -- first message per error site, for /rr status
local function Guard(site, fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok and not visualErrors[site] then
		visualErrors[site] = tostring(err)
		Debug("visual error at %s: %s", site, tostring(err))
	end
	return ok
end

local function ApplyCooldown(slice, slot)
	local info = GetActionCooldown(slot)
	if type(info) == "table" then
		-- Fields may be secret in combat: hand them to the widget, never compare.
		slice.cooldown:SetCooldown(info.startTime, info.duration, info.modRate)
	elseif type(info) == "number" then
		local start, duration, enable, modRate = GetActionCooldown(slot)
		slice.cooldown:SetCooldown(start, duration, modRate)
	end
end

local function UpdateSlice(slice)
	local slot = slice:GetAttribute("action")
	if slot and HasAction(slot) then
		slice.icon:SetTexture(GetActionTexture(slot))
		slice.icon:Show()
		Guard("cooldown", ApplyCooldown, slice, slot)
	else
		slice.icon:Hide()
		slice.cooldown:Clear()
	end
end

local function UpdateAllSlices()
	for _, slice in ipairs(slices) do UpdateSlice(slice) end
end

local function UpdateLabel()
	local page = header:GetAttribute("page") or 1
	local bar = db and db.bars[page] or 1
	label:SetText(BAR_NAMES[bar] or ("Bar " .. tostring(bar)))
end

local selected
local function Highlight(idx)
	if idx == selected then return end
	selected = idx
	for i, slice in ipairs(slices) do
		if i == idx then
			slice.highlight:Show()
			slice.icon:SetVertexColor(1, 1, 1)
		else
			slice.highlight:Hide()
			slice.icon:SetVertexColor(0.75, 0.75, 0.75)
		end
	end
	if idx then
		center:SetColorTexture(0.2, 0.9, 0.3, 0.9)
	else
		center:SetColorTexture(0.9, 0.2, 0.2, 0.9)
	end
end

for _, slice in ipairs(slices) do
	slice:SetScript("OnAttributeChanged", function(self, name)
		if name == "action" then UpdateSlice(self) end
	end)
end

header:SetScript("OnAttributeChanged", function(_, name)
	if name == "page" then UpdateLabel() end
end)

ring:SetScript("OnShow", function()
	selected = false
	UpdateAllSlices()
	UpdateLabel()
	Highlight(nil)
end)

ring:SetScript("OnUpdate", function(self)
	local cx, cy = GetCursorPosition()
	local scale = self:GetEffectiveScale()
	local rx, ry = self:GetCenter()
	if not rx then return end
	local idx = Resolve(cx / scale - rx, cy / scale - ry, RADIUS * (db and db.scale or 1))
	Highlight(idx)
end)

-- Debug taps: show what actually arrives at the secure frames.
opener:HookScript("OnClick", function(_, button, down)
	Debug("opener click: %s %s", tostring(button), down and "down" or "up")
end)
header:HookScript("OnClick", function(_, button, down)
	Debug("header click: %s %s", tostring(button), down and "down" or "up")
end)

-------------------------------------------------------------------------------
-- Configuration
-------------------------------------------------------------------------------

local pendingConfig = false

local function SnippetSelfTest()
	header:SetAttribute("selftest", nil)
	local ok, err = pcall(SecureHandlerExecute, header, [[ self:SetAttribute("selftest", 42) ]])
	if not ok then return false, tostring(err) end
	if header:GetAttribute("selftest") ~= 42 then return false, "snippet ran but did not set the attribute" end
	return true
end

local function ApplyConfig()
	if InCombatLockdown() then
		pendingConfig = true
		Print("in combat; settings will apply when combat ends")
		return
	end
	pendingConfig = false

	ClearOverrideBindings(bindOwner)
	if db.trigger and db.trigger ~= "" and db.trigger ~= "none" then
		SetOverrideBindingClick(bindOwner, true, db.trigger, "RadicalRadialOpener", "LeftButton")
	end

	header:SetAttribute("barcount", #db.bars)
	for i, bar in ipairs(db.bars) do header:SetAttribute("bar" .. i, bar) end
	for bar, base in pairs(BAR_BASE) do header:SetAttribute("base" .. bar, base) end
	header:SetAttribute("radius", RADIUS * db.scale)
	header:SetAttribute("debug", db.debug and true or false)
	header:SetAttribute("page", 1)
	visual:SetScale(db.scale)

	-- Point the slices at page 1 through the same snippet the ring uses.
	local ok, err = pcall(SecureHandlerExecute, header, [[ self:RunAttribute("ApplyPage") ]])
	if not ok then
		Print("|cffff4444secure snippets are not working on this build:|r %s", tostring(err))
	end
	UpdateAllSlices()
	UpdateLabel()
end

local function LoadDB()
	RadicalRadialDB = RadicalRadialDB or {}
	db = RadicalRadialDB
	for key, value in pairs(DEFAULTS) do
		if db[key] == nil then
			if type(value) == "table" then
				db[key] = {}
				for k, v in pairs(value) do db[key][k] = v end
			else
				db[key] = value
			end
		end
	end
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
events:RegisterEvent("ACTIONBAR_UPDATE_COOLDOWN")
events:RegisterEvent("SPELL_UPDATE_COOLDOWN")
events:RegisterEvent("PLAYER_ENTERING_WORLD")

events:SetScript("OnEvent", function(_, event, arg1)
	if event == "ADDON_LOADED" then
		if arg1 == "RadicalRadial" then LoadDB() end
	elseif event == "PLAYER_LOGIN" then
		if not db then LoadDB() end
		ApplyConfig()
		Print("v%s loaded. Hold %s to open the ring. /rr for commands.", VERSION, tostring(db.trigger))
	elseif event == "PLAYER_REGEN_ENABLED" then
		if pendingConfig then ApplyConfig() end
	elseif event == "ACTIONBAR_SLOT_CHANGED" then
		if ring:IsShown() then
			for _, slice in ipairs(slices) do
				if arg1 == 0 or slice:GetAttribute("action") == arg1 then UpdateSlice(slice) end
			end
		end
	elseif event == "ACTIONBAR_UPDATE_COOLDOWN" or event == "SPELL_UPDATE_COOLDOWN" then
		if ring:IsShown() then
			for _, slice in ipairs(slices) do
				local slot = slice:GetAttribute("action")
				if slot and slice.icon:IsShown() then Guard("cooldown", ApplyCooldown, slice, slot) end
			end
		end
	elseif event == "PLAYER_ENTERING_WORLD" then
		if ring:IsShown() then UpdateAllSlices() end
	end
end)

-------------------------------------------------------------------------------
-- Slash commands
-------------------------------------------------------------------------------

BINDING_HEADER_RADICALRADIAL = "Radical Radial"
_G["BINDING_NAME_CLICK RadicalRadialOpener:LeftButton"] = "Open radial (hold)"

local function Status()
	local version, build, _, toc = GetBuildInfo()
	Print("v%s on client %s (build %s, interface %s, project %s)",
		VERSION, tostring(version), tostring(build), tostring(toc), tostring(WOW_PROJECT_ID))
	Print("trigger: %s | bars: %s | scale: %s | debug: %s",
		tostring(db.trigger), table.concat(db.bars, " "), tostring(db.scale), db.debug and "on" or "off")
	if InCombatLockdown() then
		Print("secure snippets: cannot self-test in combat")
	else
		local ok, err = SnippetSelfTest()
		Print("secure snippets: %s", ok and "|cff33ff33OK|r" or ("|cffff4444FAILED|r " .. tostring(err)))
	end
	Print("ring open: %s | page: %s | current base slot: %s",
		tostring(header:GetAttribute("open")), tostring(header:GetAttribute("page")),
		tostring(header:GetAttribute("basecurrent")))
	local n = 0
	for site, err in pairs(visualErrors) do
		n = n + 1
		Print("visual error at %s: %s", site, err)
	end
	if n == 0 then Print("visual errors: none") end
end

local function Usage()
	Print("commands:")
	print("  /rr bind KEY        trigger binding, e.g. BUTTON4, SHIFT-BUTTON5, F (none to clear)")
	print("  /rr bars 1 2 3      bars the wheel cycles through, in order (1-8)")
	print("  /rr scale 1.2       ring scale (0.5 to 2)")
	print("  /rr preview         show or hide the ring at screen centre, out of combat")
	print("  /rr debug           toggle chat output for every press, release, page and cancel")
	print("  /rr status          client, binding, snippet self-test and visual errors")
	print("  /rr reset           restore defaults")
end

SLASH_RADICALRADIAL1 = "/rr"
SLASH_RADICALRADIAL2 = "/radicalradial"
SlashCmdList.RADICALRADIAL = function(input)
	local cmd, rest = (input or ""):match("^%s*(%S*)%s*(.-)%s*$")
	cmd = cmd:lower()
	if cmd == "bind" then
		if rest == "" then Usage() return end
		db.trigger = rest:upper()
		Print("trigger set to %s", db.trigger)
		ApplyConfig()
	elseif cmd == "bars" then
		local bars = {}
		for token in rest:gmatch("%d+") do
			local bar = tonumber(token)
			if bar >= 1 and bar <= 8 then bars[#bars + 1] = bar end
		end
		if #bars == 0 then Usage() return end
		db.bars = bars
		Print("wheel cycles: %s", table.concat(bars, " "))
		ApplyConfig()
	elseif cmd == "scale" then
		local scale = tonumber(rest)
		if not scale then Usage() return end
		db.scale = math.max(0.5, math.min(2, scale))
		Print("scale set to %s", tostring(db.scale))
		ApplyConfig()
	elseif cmd == "preview" then
		if InCombatLockdown() then Print("not in combat") return end
		if ring:IsShown() then
			ring:Hide()
		else
			ring:ClearAllPoints()
			ring:SetPoint("CENTER", UIParent, "CENTER")
			ring:Show()
		end
	elseif cmd == "debug" then
		db.debug = not db.debug
		header:SetAttribute("debug", db.debug and true or false)
		Print("debug %s", db.debug and "on" or "off")
	elseif cmd == "status" then
		Status()
	elseif cmd == "reset" then
		for key in pairs(db) do db[key] = nil end
		LoadDB()
		Print("defaults restored")
		ApplyConfig()
	else
		Usage()
	end
end
