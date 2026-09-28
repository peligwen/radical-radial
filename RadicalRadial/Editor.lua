-------------------------------------------------------------------------------
-- Radical Radial — Editor
--
-- The "Custom rings" tab of the settings window (Options.lua owns the window
-- and the widget helpers). A ring is edited as the same 4 + 8 layout the
-- live ring uses: drop a spell, item, macro or mount from the spellbook,
-- bags, macro window, mount journal or an action bar onto a slot; click or
-- drag a filled slot to pick it up again (dropping it on another slot moves
-- it, dropping it on a filled slot swaps); right-click clears. Every change
-- goes through the setters in Rings.lua, so the slash commands, the string
-- import/export and this tab always agree.
--
-- Nothing here touches a secure frame: the setters save, and ApplyConfig
-- refreshes the slices (out of combat, or when combat ends).
-------------------------------------------------------------------------------

local ADDON, ns = ...

local ui = ns.configUI
local W = ui.widgets
local Text, Button, Radio, Trunc = W.Text, W.Button, W.Radio, W.Trunc
local PAD, COL, WIDTH = W.PAD, W.COL, W.WIDTH

local tab = ui.ringsTab
local RING_BUTTON, RING_PITCH = 70, 74
local FILTERS = { { "all", "everything" }, { "harm", "offensive only" }, { "help", "helpful only" } }

ui.ring = 1             -- selected ring index
ui.fillFilter = "all"

local function Selected()
	return ns.db and ns.db.rings[ui.ring]
end

-- "Ring 1", "Ring 2", ... the first name not taken.
local function NextRingName()
	for n = 1, ns.MAX_RINGS + 1 do
		if not ns.FindRing("Ring " .. n) then return "Ring " .. n end
	end
end

local function NewRing()
	local index = ns.AddRing(NextRingName())
	if index then
		ui.ring = index
		ns.RefreshConfigUI()
	end
end

-------------------------------------------------------------------------------
-- Ring selector
-------------------------------------------------------------------------------

local ringLabel = Text(tab, "Ring", "GameFontNormal")
ringLabel:SetPoint("TOPLEFT", tab, "TOPLEFT", PAD, -6)
ui.ringButtons = {}
for k = 1, ns.MAX_RINGS do
	local b = Button(tab, "", RING_BUTTON, function()
		ui.ring = k
		ns.RefreshConfigUI()
	end)
	b:SetPoint("TOPLEFT", tab, "TOPLEFT", 50 + (k - 1) * RING_PITCH, -2)
	ui.ringButtons[k] = b
end
ui.newRing = Button(tab, "+ New ring", 86, NewRing)
ui.newRing:SetPoint("TOPLEFT", tab, "TOPLEFT", 50 + ns.MAX_RINGS * RING_PITCH, -2)

-- No rings yet
ui.ringMissing = CreateFrame("Frame", nil, tab)
ui.ringMissing:SetPoint("TOPLEFT", tab, "TOPLEFT", 0, -34)
ui.ringMissing:SetPoint("BOTTOMRIGHT", tab, "BOTTOMRIGHT", 0, 0)
local missingText = Text(ui.ringMissing, "No custom rings yet. A custom ring holds spells, items, macros and mounts directly, without using action bar slots. Create one, fill it, then tick it on a trigger's Bars row (or its enemy or friend row) so the wheel reaches it.", "GameFontHighlight", WIDTH - 60)
missingText:SetPoint("TOPLEFT", ui.ringMissing, "TOPLEFT", PAD, -8)
local missingButton = Button(ui.ringMissing, "New ring", 120, NewRing)
missingButton:SetPoint("TOPLEFT", ui.ringMissing, "TOPLEFT", PAD, -64)

-------------------------------------------------------------------------------
-- The selected ring
-------------------------------------------------------------------------------

local panel = CreateFrame("Frame", nil, tab)
ui.ringPanel = panel
panel:SetPoint("TOPLEFT", tab, "TOPLEFT", 0, -34)
panel:SetPoint("BOTTOMRIGHT", tab, "BOTTOMRIGHT", 0, 0)

-- Name
local nameLabel = Text(panel, "Name", "GameFontNormal")
nameLabel:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD, -8)
ui.ringName = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
ui.ringName:SetSize(170, 22)
ui.ringName:SetPoint("TOPLEFT", panel, "TOPLEFT", COL + 6, -4)
ui.ringName:SetAutoFocus(false)
ui.ringName:SetMaxLetters(ns.NAME_MAX)
local function CommitName()
	local ring = Selected()
	if not ring then return end
	ui.ringName:ClearFocus()
	ns.RenameRing(ring.name, ui.ringName:GetText())
	ns.RefreshConfigUI()
end
ui.ringName:SetScript("OnEnterPressed", CommitName)
ui.ringName:SetScript("OnEscapePressed", function(self)
	self:ClearFocus()
	ns.RefreshConfigUI()
end)
ui.renameRing = Button(panel, "Rename", 70, CommitName)
ui.renameRing:SetPoint("LEFT", ui.ringName, "RIGHT", 6, 0)
ui.removeRing = Button(panel, "Remove ring", 110, function()
	local ring = Selected()
	if ring then StaticPopup_Show("RADICALRADIAL_REMOVE_RING", ring.name, nil, ring.name) end
end)
ui.removeRing:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -PAD, -4)

StaticPopupDialogs["RADICALRADIAL_REMOVE_RING"] = {
	text = "Remove the ring %s? Triggers that cycle through it will skip it.",
	button1 = YES,
	button2 = NO,
	OnAccept = function(_, name) ns.RemoveRing(name) end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

-------------------------------------------------------------------------------
-- Slots, laid out like the ring: centre, inner tier of 4, outer tier of 8
-------------------------------------------------------------------------------

local CENTER_X, CENTER_Y = 132, -186
local EDIT_RADIUS = 92           -- outer tier radius in the editor
local SLOT_OUTER, SLOT_INNER = 36, 30

-- Blizzard's own slot art where the client has it, the classic file otherwise.
local function SlotArt(tex, atlas, file)
	if tex.SetAtlas and C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(atlas) then
		tex:SetAtlas(atlas)
	elseif file then
		tex:SetTexture(file)
	end
end

local function Drop(slot)
	local ring = Selected()
	if not ring then return end
	local slice, why = ns.SliceFromCursor()
	if not slice then
		if why then ns.Print(why) end
		return
	end
	local old = ring.slices[slot]
	ClearCursor()
	if ns.SetRingSlice(ring.name, slot, slice) and old then
		ns.PickupSlice(old)          -- swap: the previous content goes on the cursor
	end
end

local function Pickup(slot)
	local ring = Selected()
	local slice = ring and ring.slices[slot]
	if not slice then return end
	ns.PickupSlice(slice)
	ns.ClearRingSlice(ring.name, slot)
end

local function SlotTooltip(self)
	if not GameTooltip then return end
	local slice = self.slice
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	if not slice then
		GameTooltip:SetText(("Slot %d: drop a spell, item, macro or mount here"):format(self.slot))
	elseif slice.kind == "spell" then
		GameTooltip:SetSpellByID(slice.id)
	elseif slice.kind == "item" then
		GameTooltip:SetItemByID(slice.id)
	else
		GameTooltip:SetText("Macro: " .. slice.name)
	end
	GameTooltip:Show()
end

ui.slots = {}
for i = 1, ns.SLICE_COUNT do
	local angle, fraction = ns.SlicePolar(i)
	local size = i <= ns.INNER_COUNT and SLOT_INNER or SLOT_OUTER
	local b = CreateFrame("Button", nil, panel)
	b.slot = i
	b:SetSize(size, size)
	b:SetPoint("CENTER", panel, "TOPLEFT",
		CENTER_X + math.sin(math.rad(angle)) * EDIT_RADIUS * fraction,
		CENTER_Y + math.cos(math.rad(angle)) * EDIT_RADIUS * fraction)
	b.bg = b:CreateTexture(nil, "BACKGROUND")
	b.bg:SetAllPoints()
	SlotArt(b.bg, "UI-HUD-ActionBar-IconFrame-Slot", "Interface\\Buttons\\UI-Quickslot2")
	b.icon = b:CreateTexture(nil, "ARTWORK")
	b.icon:SetPoint("TOPLEFT", 2, -2)
	b.icon:SetPoint("BOTTOMRIGHT", -2, 2)
	b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	b.border = b:CreateTexture(nil, "OVERLAY")
	b.border:SetAllPoints()
	SlotArt(b.border, "UI-HUD-ActionBar-IconFrame", nil)
	b.num = Text(b, tostring(i), "GameFontHighlightSmall")
	b.num:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -2, 2)
	b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
	b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	b:RegisterForDrag("LeftButton")
	b:SetScript("OnClick", function(self, button)
		if button == "RightButton" then
			local ring = Selected()
			if ring and ring.slices[self.slot] then ns.ClearRingSlice(ring.name, self.slot) end
		elseif GetCursorInfo() then
			Drop(self.slot)
		else
			Pickup(self.slot)
		end
	end)
	b:SetScript("OnReceiveDrag", function(self) Drop(self.slot) end)
	b:SetScript("OnDragStart", function(self) Pickup(self.slot) end)
	b:SetScript("OnEnter", SlotTooltip)
	b:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
	ui.slots[i] = b
end

local centerDot = panel:CreateTexture(nil, "OVERLAY")
centerDot:SetSize(8, 8)
centerDot:SetPoint("CENTER", panel, "TOPLEFT", CENTER_X, CENTER_Y)
centerDot:SetColorTexture(0.9, 0.2, 0.2, 0.9)

-------------------------------------------------------------------------------
-- Right column: help, fill from a bar, import and export
-------------------------------------------------------------------------------

local RIGHT = 270
local help = Text(panel, "Drop a spell, item, macro or mount from the spellbook, bags, macro window, mount journal or an action bar onto a slot. Click or drag a filled slot to pick it up (drop it on another slot to move or swap), right-click to clear it. Slots 1-4 are the inner tier.", "GameFontHighlightSmall", WIDTH - RIGHT - 40)
help:SetPoint("TOPLEFT", panel, "TOPLEFT", RIGHT, -40)

local fillLabel = Text(panel, "Fill from bar", "GameFontNormal")
fillLabel:SetPoint("TOPLEFT", panel, "TOPLEFT", RIGHT, -118)
ui.fillButtons = {}
for bar = 1, 8 do
	local b = Button(panel, tostring(bar), 26, function()
		local ring = Selected()
		if ring then ns.FillRingFromBar(ring.name, bar, ui.fillFilter) end
	end)
	b:SetPoint("TOPLEFT", panel, "TOPLEFT", RIGHT + 90 + (bar - 1) * 29, -114)
	ui.fillButtons[bar] = b
end
ui.fillRadios = {}
for n, f in ipairs(FILTERS) do
	local r = Radio(panel, f[2], function()
		ui.fillFilter = f[1]
		ns.RefreshConfigUI()
	end)
	r:SetPoint("TOPLEFT", panel, "TOPLEFT", RIGHT + (n - 1) * 108, -142)
	ui.fillRadios[f[1]] = r
end
local fillNote = Text(panel, "Replaces the ring with the bar's actions as direct slices (the client classifies offensive and helpful actions out of combat).", "GameFontHighlightSmall", WIDTH - RIGHT - 40)
fillNote:SetPoint("TOPLEFT", panel, "TOPLEFT", RIGHT, -164)

local ioLabel = Text(panel, "Share", "GameFontNormal")
ioLabel:SetPoint("TOPLEFT", panel, "TOPLEFT", RIGHT, -212)
ui.ringIO = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
ui.ringIO:SetSize(WIDTH - RIGHT - 44, 22)
ui.ringIO:SetPoint("TOPLEFT", panel, "TOPLEFT", RIGHT + 6, -230)
ui.ringIO:SetAutoFocus(false)
ui.ringIO:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
ui.ringIO:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
ui.exportRing = Button(panel, "Export", 80, function()
	local ring = Selected()
	local text = ring and ns.ExportRing(ring.name)
	if not text then return end
	ui.ringIO:SetText(text)
	ui.ringIO:SetFocus()
	ui.ringIO:HighlightText()
end)
ui.exportRing:SetPoint("TOPLEFT", panel, "TOPLEFT", RIGHT, -258)
ui.importRing = Button(panel, "Import", 80, function()
	local index = ns.ImportRing(ui.ringIO:GetText())
	if index then
		ui.ring = index
		ui.ringIO:SetText("")
		ns.RefreshConfigUI()
	end
end)
ui.importRing:SetPoint("LEFT", ui.exportRing, "RIGHT", 6, 0)
local ioNote = Text(panel, "Export puts a string for this ring in the box (Ctrl-C copies it); paste one and Import to add the ring, or replace the one with the same name.", "GameFontHighlightSmall", WIDTH - RIGHT - 40)
ioNote:SetPoint("TOPLEFT", panel, "TOPLEFT", RIGHT, -286)

-------------------------------------------------------------------------------
-- Refresh, called from RefreshConfigUI
-------------------------------------------------------------------------------

function ui.RefreshRings()
	local db = ns.db
	if not db then return end
	local rings = db.rings
	if ui.ring > #rings then ui.ring = #rings end
	if ui.ring < 1 then ui.ring = 1 end

	for k, b in ipairs(ui.ringButtons) do
		local ring = rings[k]
		b:SetShown(ring ~= nil)
		if ring then
			b:SetText(Trunc(ring.name, 10))
			if k == ui.ring then b:LockHighlight() else b:UnlockHighlight() end
		end
	end
	ui.newRing:SetShown(#rings < ns.MAX_RINGS)

	local ring = rings[ui.ring]
	if not ring then
		panel:Hide()
		ui.ringMissing:Show()
		return
	end
	ui.ringMissing:Hide()
	panel:Show()

	if not ui.ringName:HasFocus() then ui.ringName:SetText(ring.name) end
	for i, b in ipairs(ui.slots) do
		local slice = ring.slices[i]
		local icon = slice and ns.SliceIcon(slice)
		b.slice = slice
		b.icon:SetTexture(icon)
		b.icon:SetShown(slice ~= nil)
	end
	for key, r in pairs(ui.fillRadios) do r:SetChecked(key == ui.fillFilter) end
end
