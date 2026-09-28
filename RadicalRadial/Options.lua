-------------------------------------------------------------------------------
-- Radical Radial — Options
--
-- The settings window: /rr (or /rr config), the Options → AddOns entry, or
-- the addon compartment button on the minimap. It edits the saved variables
-- through the setters in Config.lua and Rings.lua, the same ones the slash
-- commands use, so the two never disagree, and ApplyConfig refreshes the
-- window after every change from either side. Two tabs: the triggers (this
-- file) and the custom rings (Editor.lua, which builds into ui.ringsTab).
--
-- Nothing here touches a secure frame. In combat the setters save the change
-- and defer the secure side until combat ends; the footer says so.
-------------------------------------------------------------------------------

local ADDON, ns = ...

local WIDTH, HEIGHT = 620, 730
local PAD = 14
local COL = 130          -- x of the first control in a labelled row
local CHECK_PITCH = 42   -- bar checkboxes 1..8
local RING_PITCH = 76    -- ring checkboxes, named, on the line below the bars

local ui = { selected = 1, capturing = false, refreshing = false }
ns.configUI = ui

-------------------------------------------------------------------------------
-- Widget helpers
-------------------------------------------------------------------------------

local function Text(parent, text, font, width)
	local fs = parent:CreateFontString(nil, "ARTWORK", font or "GameFontHighlight")
	fs:SetText(text)
	if width then
		fs:SetWidth(width)
		fs:SetJustifyH("LEFT")
	end
	return fs
end

local function Button(parent, text, width, onClick)
	local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	b:SetSize(width, 22)
	b:SetText(text)
	b:SetScript("OnClick", onClick)
	return b
end

local function Check(parent, label, onClick, font)
	local c = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
	c:SetSize(24, 24)
	c.label = Text(c, label, font)
	c.label:SetPoint("LEFT", c, "RIGHT", 1, 0)
	c:SetScript("OnClick", onClick)
	return c
end

local function Radio(parent, label, onClick)
	local r = CreateFrame("CheckButton", nil, parent, "UIRadioButtonTemplate")
	r:SetSize(16, 16)
	r.label = Text(r, label)
	r.label:SetPoint("LEFT", r, "RIGHT", 4, 0)
	r:SetScript("OnClick", onClick)
	return r
end

-- A slider shows its value while dragged and commits on release, so a drag is
-- one change (one chat line, one apply) rather than one per step.
local function Slider(parent, label, min, max, step, describe, onCommit)
	local s = CreateFrame("Slider", nil, parent, "UISliderTemplateWithLabels")
	s:SetSize(150, 17)
	s:SetOrientation("HORIZONTAL")
	s:SetMinMaxValues(min, max)
	s:SetValueStep(step)
	s:SetObeyStepOnDrag(true)
	s.Text:SetText(label)
	s.Low:SetText(describe(min))
	s.High:SetText(describe(max))
	s.describe = describe
	s.value = Text(s, "")
	s.value:SetPoint("LEFT", s, "RIGHT", 10, 0)
	s:SetScript("OnValueChanged", function(self, value)
		self.value:SetText(describe(value))
	end)
	s:SetScript("OnMouseUp", function(self)
		if not ui.refreshing then onCommit(self:GetValue()) end
	end)
	return s
end

local function SetEnabled(widget, enabled)
	if enabled then widget:Enable() else widget:Disable() end
	widget:SetAlpha(enabled and 1 or 0.5)
end

local function Contains(list, value)
	for _, v in ipairs(list) do if v == value then return true end end
	return false
end

-- The list with the value appended, or removed if it is already there: a
-- checkbox row that keeps the order the bars were ticked in.
local function Toggled(list, value)
	local out, found = {}, false
	for _, v in ipairs(list) do
		if v == value then found = true else out[#out + 1] = v end
	end
	if not found then out[#out + 1] = value end
	return out
end

-- Wheel lists hold bar numbers and ring names; show both as words.
local function Join(list)
	local parts = {}
	for i, entry in ipairs(list) do parts[i] = ns.EntryName(entry) end
	return table.concat(parts, ", ")
end

local function Trunc(text, n)
	text = tostring(text)
	if #text <= n then return text end
	return (text:sub(1, n - 1):gsub("%s+$", "")) .. "…"
end

-- Shared with Editor.lua.
ui.widgets = { Text = Text, Button = Button, Check = Check, Radio = Radio, Slider = Slider, SetEnabled = SetEnabled, Trunc = Trunc, PAD = PAD, COL = COL, WIDTH = WIDTH }

-------------------------------------------------------------------------------
-- The window
-------------------------------------------------------------------------------

local frame = CreateFrame("Frame", "RadicalRadialConfig", UIParent, "ButtonFrameTemplate")
ui.frame = frame
frame:SetSize(WIDTH, HEIGHT)
frame:SetPoint("CENTER")
frame:SetFrameStrata("DIALOG")
frame:SetToplevel(true)
frame:SetMovable(true)
frame:SetClampedToScreen(true)
frame:EnableMouse(true)
frame:RegisterForDrag("LeftButton")
frame:SetScript("OnDragStart", frame.StartMoving)
frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
frame:Hide()
if frame.SetTitle then frame:SetTitle("Radical Radial") end
if ButtonFrameTemplate_HidePortrait then ButtonFrameTemplate_HidePortrait(frame) end
if ButtonFrameTemplate_HideButtonBar then ButtonFrameTemplate_HideButtonBar(frame) end
if UISpecialFrames then table.insert(UISpecialFrames, "RadicalRadialConfig") end

local inset = frame.Inset or frame

-- Global rows: the scale and cancel-radius sliders; then debug, preview, reset.
ui.scale = Slider(inset, "Ring scale", 0.5, 2, 0.05,
	function(v) return ("%.2f"):format(v) end,
	function(v) ns.SetScale(v) end)
ui.scale:SetPoint("TOPLEFT", inset, "TOPLEFT", PAD + 6, -34)

ui.outer = Slider(inset, "Cancel radius", ns.OUTER_MIN, ns.OUTER_MAX, 0.1,
	function(v) return ("%.1f x"):format(v) end,
	function(v) ns.SetOuter(v) end)
ui.outer:SetPoint("TOPLEFT", inset, "TOPLEFT", PAD + 246, -34)
local outerNote = Text(inset, "past it, releasing or tapping cancels", "GameFontHighlightSmall")
outerNote:SetPoint("LEFT", ui.outer, "RIGHT", 52, 0)

ui.reset = Button(inset, "Reset to defaults", 130, function() StaticPopup_Show("RADICALRADIAL_RESET") end)
ui.reset:SetPoint("TOPRIGHT", inset, "TOPRIGHT", -PAD, -60)
ui.preview = Button(inset, "Preview ring", 110, function() ns.TogglePreview() end)
ui.preview:SetPoint("RIGHT", ui.reset, "LEFT", -6, 0)

ui.debug = Check(inset, "Debug output in chat", function(self)
	ns.SetDebug(self:GetChecked())
end)
ui.debug:SetPoint("TOPLEFT", inset, "TOPLEFT", PAD, -62)

local rule = inset:CreateTexture(nil, "ARTWORK")
rule:SetColorTexture(1, 1, 1, 0.15)
rule:SetPoint("TOPLEFT", inset, "TOPLEFT", PAD, -96)
rule:SetPoint("TOPRIGHT", inset, "TOPRIGHT", -PAD, -96)
rule:SetHeight(1)

-- Tabs. Each is a frame under the rule; Editor.lua fills the rings one.
ui.tab = "triggers"
ui.tabButtons = {}
local function Tab(name, text, x)
	local b = Button(inset, text, 110, function() ui.ShowTab(name) end)
	b:SetPoint("TOPLEFT", inset, "TOPLEFT", PAD + x, -104)
	ui.tabButtons[name] = b
	local tab = CreateFrame("Frame", nil, inset)
	tab:SetPoint("TOPLEFT", inset, "TOPLEFT", 0, -132)
	tab:SetPoint("BOTTOMRIGHT", inset, "BOTTOMRIGHT", 0, 40)
	tab:Hide()
	return tab
end
ui.triggersTab = Tab("triggers", "Triggers", 0)
ui.ringsTab = Tab("rings", "Custom rings", 114)
local tabHint = Text(inset, "Triggers open the ring; custom rings hold spells, items and macros without using bar slots.", "GameFontHighlightSmall", WIDTH - 260)
tabHint:SetPoint("TOPLEFT", inset, "TOPLEFT", PAD + 232, -107)

function ui.ShowTab(name)
	ui.tab = name
	ui.StopCapture()
	ns.RefreshConfigUI()
end

local tabs = ui.triggersTab

-- Trigger selector
local triggerLabel = Text(tabs, "Trigger", "GameFontNormal")
triggerLabel:SetPoint("TOPLEFT", tabs, "TOPLEFT", PAD, -6)
ui.triggerButtons = {}
for i = 1, ns.MAX_TRIGGERS do
	local b = Button(tabs, "Trigger " .. i, 92, function()
		ui.selected = i
		ui.StopCapture()
		ns.RefreshConfigUI()
	end)
	b:SetPoint("TOPLEFT", tabs, "TOPLEFT", 70 + (i - 1) * 98, -2)
	ui.triggerButtons[i] = b
end

-- A trigger that is not set up yet
ui.missing = CreateFrame("Frame", nil, tabs)
ui.missing:SetPoint("TOPLEFT", tabs, "TOPLEFT", 0, -34)
ui.missing:SetPoint("BOTTOMRIGHT", tabs, "BOTTOMRIGHT", 0, 0)
ui.missingText = Text(ui.missing, "", "GameFontHighlight", WIDTH - 60)
ui.missingText:SetPoint("TOPLEFT", ui.missing, "TOPLEFT", PAD, -8)
ui.addButton = Button(ui.missing, "", 150, function() ns.AddTrigger(ui.selected) end)
ui.addButton:SetPoint("TOPLEFT", ui.missing, "TOPLEFT", PAD, -34)

-- The selected trigger
local panel = CreateFrame("Frame", nil, tabs)
ui.panel = panel
panel:SetPoint("TOPLEFT", tabs, "TOPLEFT", 0, -34)
panel:SetPoint("BOTTOMRIGHT", tabs, "BOTTOMRIGHT", 0, 0)

local function Row(y, label)
	local fs = Text(panel, label, "GameFontNormal")
	fs:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD, y)
	return fs
end

-- Binding
Row(-8, "Binding")
ui.key = Button(panel, "", 170, nil)
ui.key:SetPoint("TOPLEFT", panel, "TOPLEFT", COL, -4)
ui.key:RegisterForClicks("AnyDown", "AnyUp")
ui.clear = Button(panel, "Clear", 60, function()
	ui.StopCapture()
	ns.SetTriggerKey(ui.selected, "")
end)
ui.clear:SetPoint("LEFT", ui.key, "RIGHT", 6, 0)
ui.hint = Text(panel, "Press a key or a mouse button. Esc cancels.", "GameFontHighlightSmall")
ui.hint:SetPoint("LEFT", ui.clear, "RIGHT", 10, 0)
ui.hint:Hide()

-- Mode and auto-hide
Row(-44, "Mode")
ui.modeHold = Radio(panel, "Hold: release fires, centre cancels", function() ns.SetTriggerMode(ui.selected, "hold") end)
ui.modeHold:SetPoint("TOPLEFT", panel, "TOPLEFT", COL, -44)
ui.modeTap = Radio(panel, "Tap: centre keeps the ring open, next release fires", function() ns.SetTriggerMode(ui.selected, "tap") end)
ui.modeTap:SetPoint("TOPLEFT", panel, "TOPLEFT", COL, -64)

ui.autohide = Slider(panel, "Auto-hide (tap mode)", 0, 10, 0.5,
	function(v) return v == 0 and "never" or (tostring(v) .. " s") end,
	function(v) ns.SetTriggerAutohide(ui.selected, v) end)
ui.autohide:SetPoint("TOPLEFT", panel, "TOPLEFT", COL + 4, -110)
ui.autohideNote = Text(panel, "seconds after the cursor leaves the ring", "GameFontHighlightSmall")
ui.autohideNote:SetPoint("TOPLEFT", ui.autohide, "BOTTOMLEFT", -4, -14)

-- Wheel list rows: the eight bars on one line, the custom rings by name on
-- the next (shown for the rings that exist), and the order underneath.
local function BarRow(y, label, key, ctx)
	Row(y, label)
	local function Toggle(entry)
		local t = ns.db and ns.db.triggers[ui.selected]
		if not t then return end
		local ok
		if ctx then
			ok = ns.SetTriggerContext(ui.selected, ctx, Toggled(t[ctx], entry))
		else
			ok = ns.SetTriggerBars(ui.selected, Toggled(t.bars, entry))
		end
		if not ok then ns.RefreshConfigUI() end
	end
	local boxes = {}
	for k = 1, 8 do
		local c = Check(panel, tostring(k), function() Toggle(k) end)
		c:SetPoint("TOPLEFT", panel, "TOPLEFT", COL + (k - 1) * CHECK_PITCH, y + 4)
		boxes[k] = c
	end
	ui[key] = boxes
	local ringBoxes = {}
	for k = 1, ns.MAX_RINGS do
		local c = Check(panel, "", function()
			local ring = ns.db and ns.db.rings[k]
			if ring then Toggle(ring.name) end
		end, "GameFontHighlightSmall")
		c:SetPoint("TOPLEFT", panel, "TOPLEFT", COL + (k - 1) * RING_PITCH, y - 17)
		ringBoxes[k] = c
	end
	ui[key .. "Rings"] = ringBoxes
	ui[key .. "Text"] = Text(panel, "", "GameFontHighlightSmall", WIDTH - COL - 40)
	ui[key .. "Text"]:SetPoint("TOPLEFT", panel, "TOPLEFT", COL + 4, y - 40)
end
BarRow(-156, "Bars", "bars")
BarRow(-222, "Over an enemy", "harm", "harm")
BarRow(-288, "Over a friend", "help", "help")

-- Capture
Row(-354, "Capture the unit as")
ui.capFocus = Radio(panel, "Focus", function() ns.SetTriggerCapture(ui.selected, "focus") end)
ui.capFocus:SetPoint("TOPLEFT", panel, "TOPLEFT", COL, -354)
ui.capTarget = Radio(panel, "Target", function() ns.SetTriggerCapture(ui.selected, "target") end)
ui.capTarget:SetPoint("TOPLEFT", panel, "TOPLEFT", COL + 90, -354)
ui.capNone = Radio(panel, "Nothing", function() ns.SetTriggerCapture(ui.selected, "none") end)
ui.capNone:SetPoint("TOPLEFT", panel, "TOPLEFT", COL + 180, -354)
local capNote = Text(panel, "Pressed over an enemy or a friend, the trigger makes that unit your focus (or target) and the ring's actions go to it.", "GameFontHighlightSmall", WIDTH - COL - 40)
capNote:SetPoint("TOPLEFT", panel, "TOPLEFT", COL + 4, -374)

ui.remove = Button(panel, "", 150, function() ns.RemoveTrigger(ui.selected) end)
ui.remove:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD, -404)

-- Footer
ui.status = Text(inset, "", "GameFontHighlightSmall", WIDTH - 40)
ui.status:SetPoint("BOTTOMLEFT", inset, "BOTTOMLEFT", PAD, 22)
local footer = Text(inset, "/rr help lists the slash commands. Escape closes this window.", "GameFontDisableSmall", WIDTH - 40)
footer:SetPoint("BOTTOMLEFT", inset, "BOTTOMLEFT", PAD, 8)

-------------------------------------------------------------------------------
-- Key capture
-------------------------------------------------------------------------------

local META = {
	LSHIFT = true, RSHIFT = true, LCTRL = true, RCTRL = true, LALT = true, RALT = true, LMETA = true, RMETA = true,
}
local MOUSE = {
	LeftButton = "BUTTON1", RightButton = "BUTTON2", MiddleButton = "BUTTON3", Button4 = "BUTTON4", Button5 = "BUTTON5",
}

local function ConvertInput(input)
	if type(GetConvertedKeyOrButton) == "function" then return GetConvertedKeyOrButton(input) end
	return MOUSE[input] or input:gsub("^Button(%d+)$", "BUTTON%1")
end

local function Chord(key)
	if type(CreateKeyChordStringUsingMetaKeyState) == "function" then
		return CreateKeyChordStringUsingMetaKeyState(key)
	end
	local chord = {}
	if IsAltKeyDown() then chord[#chord + 1] = "ALT" end
	if IsControlKeyDown() then chord[#chord + 1] = "CTRL" end
	if IsShiftKeyDown() then chord[#chord + 1] = "SHIFT" end
	chord[#chord + 1] = key
	return table.concat(chord, "-")
end

function ui.StopCapture()
	if not ui.capturing then return end
	ui.capturing = false
	frame:EnableKeyboard(false)
end

function ui.StartCapture()
	if not (ns.db and ns.db.triggers[ui.selected]) then return end
	if InCombatLockdown() then
		ns.Print("not in combat")
		return
	end
	ui.capturing = true
	frame:EnableKeyboard(true)   -- only while capturing, so Escape closes the window otherwise
	ns.RefreshConfigUI()
end

-- A key or mouse button pressed while capturing.
local function Captured(input)
	local key = ConvertInput(input)
	if META[key] then return end            -- wait for the key the modifier goes with
	if key == "ESCAPE" then
		ui.StopCapture()
		ns.RefreshConfigUI()
		return
	end
	ui.StopCapture()
	if key == "BUTTON1" or key == "BUTTON2" then
		ns.Print("the left and right mouse buttons cannot be triggers")
		ns.RefreshConfigUI()
		return
	end
	ns.SetTriggerKey(ui.selected, Chord(key))
end

ui.key:SetScript("OnClick", function(_, button, down)
	if ui.capturing then
		if down then Captured(button) end
	elseif button == "LeftButton" and not down then
		ui.StartCapture()
	end
end)
frame:SetScript("OnKeyDown", function(_, key)
	if ui.capturing then Captured(key) end
end)
frame:SetScript("OnMouseDown", function(_, button)
	if ui.capturing then Captured(button) end
end)

-------------------------------------------------------------------------------
-- Refresh from the saved variables
-------------------------------------------------------------------------------

function ns.RefreshConfigUI()
	local db = ns.db
	if not db or not frame:IsShown() then return end
	ui.refreshing = true

	ui.scale:SetValue(db.scale)
	ui.scale.value:SetText(ui.scale.describe(db.scale))
	ui.outer:SetValue(db.outer)
	ui.outer.value:SetText(ui.outer.describe(db.outer))
	ui.debug:SetChecked(db.debug and true or false)

	for name, b in pairs(ui.tabButtons) do
		if name == ui.tab then b:LockHighlight() else b:UnlockHighlight() end
	end
	ui.triggersTab:SetShown(ui.tab == "triggers")
	ui.ringsTab:SetShown(ui.tab == "rings")

	for i, b in ipairs(ui.triggerButtons) do
		b:SetText((db.triggers[i] and "" or "+ ") .. "Trigger " .. i)
		if i == ui.selected then b:LockHighlight() else b:UnlockHighlight() end
	end

	local t = db.triggers[ui.selected]
	if not t then
		ui.panel:Hide()
		ui.missing:Show()
		ui.missingText:SetText(("Trigger %d is not set up. Add it to bind a second key or mouse button with its own bars and mode."):format(ui.selected))
		ui.addButton:SetText(("Add trigger %d"):format(ui.selected))
	else
		ui.missing:Hide()
		ui.panel:Show()
		if ui.capturing then
			ui.key:SetText("Press a key or button")
		else
			ui.key:SetText(t.key ~= "" and t.key or "Click to bind")
		end
		ui.hint:SetShown(ui.capturing)

		ui.modeHold:SetChecked(t.mode == "hold")
		ui.modeTap:SetChecked(t.mode == "tap")
		ui.autohide:SetValue(math.min(t.autohide, 10))
		ui.autohide.value:SetText(ui.autohide.describe(t.autohide))
		SetEnabled(ui.autohide, t.mode == "tap")
		ui.autohideNote:SetAlpha(t.mode == "tap" and 1 or 0.5)

		for k = 1, 8 do
			ui.bars[k]:SetChecked(Contains(t.bars, k))
			ui.harm[k]:SetChecked(Contains(t.harm, k))
			ui.help[k]:SetChecked(Contains(t.help, k))
		end
		for k = 1, ns.MAX_RINGS do
			local ring = db.rings[k]
			for _, key in ipairs({ "bars", "harm", "help" }) do
				local box = ui[key .. "Rings"][k]
				box:SetShown(ring ~= nil)
				if ring then
					box.label:SetText(Trunc(ring.name, 9))
					box:SetChecked(Contains(t[key], ring.name))
				end
			end
		end
		ui.barsText:SetText("Wheel order: " .. Join(t.bars) .. " (tick in the order you want them)")
		ui.harmText:SetText(#t.harm > 0 and ("Over an enemy the ring shows: " .. Join(t.harm))
			or "None: over an enemy the normal bars open and nothing is captured")
		ui.helpText:SetText(#t.help > 0 and ("Over a friend the ring shows: " .. Join(t.help))
			or "None: over a friend the normal bars open and nothing is captured")

		ui.capFocus:SetChecked(t.capture == "focus")
		ui.capTarget:SetChecked(t.capture == "target")
		ui.capNone:SetChecked(t.capture == "none")

		ui.remove:SetShown(ui.selected ~= 1)
		ui.remove:SetText(("Remove trigger %d"):format(ui.selected))
	end

	if ui.RefreshRings then ui.RefreshRings() end

	local combat = InCombatLockdown()
	ui.preview:SetEnabled(not combat)
	if combat then
		ui.status:SetText("|cffff8800In combat:|r changes are saved now and take effect when combat ends.")
	elseif ns.ConfigPending() then
		ui.status:SetText("Changes are waiting for combat to end.")
	else
		ui.status:SetText("Changes take effect immediately.")
	end
	ui.refreshing = false
end

frame:SetScript("OnShow", function() ns.RefreshConfigUI() end)
frame:SetScript("OnHide", function() ui.StopCapture() end)
frame:RegisterEvent("PLAYER_REGEN_DISABLED")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:SetScript("OnEvent", function() ns.RefreshConfigUI() end)

-------------------------------------------------------------------------------
-- Entry points
-------------------------------------------------------------------------------

function ns.OpenConfig() frame:Show() end
function ns.CloseConfig() frame:Hide() end
function ns.ToggleConfig()
	if frame:IsShown() then frame:Hide() else frame:Show() end
end

-- ## AddonCompartmentFunc in the TOC: the addon list button on the minimap.
function RadicalRadial_OnAddonCompartmentClick()
	ns.ToggleConfig()
end

StaticPopupDialogs["RADICALRADIAL_RESET"] = {
	text = "Reset all Radical Radial settings to their defaults?",
	button1 = YES,
	button2 = NO,
	OnAccept = function() ns.ResetAll() end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

-- Options → AddOns → Radical Radial: a short page with a button to this window.
if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
	local canvas = CreateFrame("Frame")
	local title = Text(canvas, "Radical Radial", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", canvas, "TOPLEFT", 16, -16)
	local desc = Text(canvas, "Mouse-first radial action menu. Hold a thumb button, flick toward an action, release. The settings live in their own window so they can stay open while you try the ring.", "GameFontHighlight", 560)
	desc:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
	local open = Button(canvas, "Open settings window", 200, function()
		if SettingsPanel and HideUIPanel then HideUIPanel(SettingsPanel) end
		ns.OpenConfig()
	end)
	open:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -16)
	local hint = Text(canvas, "Also /rr in chat, or the addon compartment button on the minimap.", "GameFontHighlightSmall", 560)
	hint:SetPoint("TOPLEFT", open, "BOTTOMLEFT", 0, -8)
	local category = Settings.RegisterCanvasLayoutCategory(canvas, "Radical Radial")
	Settings.RegisterAddOnCategory(category)
	ns.settingsCategory = category
end
