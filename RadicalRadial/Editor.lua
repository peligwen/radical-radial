-------------------------------------------------------------------------------
-- Radical Radial — Editor
--
-- The "Custom rings" tab of the settings window (Options.lua owns the window
-- and the widget helpers). A ring is edited in its own layout, as the live
-- ring shows it, with the centre slice (the ring's default action) as the
-- slot in the middle: drop a spell, item, macro or mount from the spellbook,
-- bags, macro window, mount journal or an action bar onto a slot; click or
-- drag a filled slot to pick it up again (dropping it on another slot moves
-- it, dropping it on a filled slot swaps); right-click clears. Right-click
-- an empty slot to nest another ring in it (the slot then opens that ring in
-- place); click a nested-ring slot to change which. Every change goes
-- through the setters in Rings.lua, so the slash commands, the string
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
local LAYOUT_PITCH = 62
local FILTERS = { { "all", "everything" }, { "harm", "offensive only" }, { "help", "helpful only" } }

ui.ring = 1             -- selected ring index
ui.fillFilter = "all"

local function Selected()
	return ns.Rings()[ui.ring]
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
local missingText = Text(ui.ringMissing, "No custom rings on this character yet. A custom ring holds spells, items, macros, mounts and other rings directly, without using action bar slots, in a layout of its own. Create one, fill it, then tick it on a trigger's Bars row (or its enemy or friend row) so the wheel reaches it, or nest it in another ring. Rings belong to the character that made them; another character's rings can be copied here.", "GameFontHighlight", WIDTH - 60)
missingText:SetPoint("TOPLEFT", ui.ringMissing, "TOPLEFT", PAD, -8)
local missingButton = Button(ui.ringMissing, "New ring", 120, NewRing)
missingButton:SetPoint("TOPLEFT", ui.ringMissing, "TOPLEFT", PAD, -92)

-------------------------------------------------------------------------------
-- Copy from another character. Every character's rings are in the saved
-- variables (RadicalRadialDB.chars), so the menu lists them all.
-------------------------------------------------------------------------------

local function TakeCopy(other, ring)
	local index = ns.CopyRingFrom(other.key, ring.name)
	if index then
		ui.ring = index
		ns.RefreshConfigUI()
	end
end

-- One submenu per character, one entry per ring (MenuUtil, the client's
-- menu system since 11.0).
local function CopyMenu(_, root)
	local others = ns.OtherCharacters()
	root:CreateTitle(#others > 0 and "Copy a ring from" or "No other character has rings yet")
	for _, other in ipairs(others) do
		local sub = root:CreateButton(other.name)
		for _, ring in ipairs(other.rings) do
			sub:CreateButton(ring.name, function() TakeCopy(other, ring) end)
		end
	end
end

local function CopyButton(parent)
	local b
	b = Button(parent, "Copy from another character…", 200, function()
		if MenuUtil and MenuUtil.CreateContextMenu then
			MenuUtil.CreateContextMenu(b, CopyMenu)
			return
		end
		-- No menu system on this client: say what there is and how to copy it.
		local others = ns.OtherCharacters()
		if #others == 0 then ns.Print("no other character has rings yet") end
		for _, other in ipairs(others) do
			local names = {}
			for i, ring in ipairs(other.rings) do names[i] = ring.name end
			ns.Print("%s has: %s. Copy one with /rr ring copy %s NAME", other.key, table.concat(names, ", "), other.name)
		end
	end)
	return b
end
ui.copyRingMissing = CopyButton(ui.ringMissing)
ui.copyRingMissing:SetPoint("LEFT", missingButton, "RIGHT", 8, 0)

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
	text = "Remove the ring %s? Triggers that cycle through it will skip it, and rings that nest it lose that slice.",
	button1 = YES,
	button2 = NO,
	OnAccept = function(_, name) ns.RemoveRing(name) end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

-- Layout
local layoutLabel = Text(panel, "Layout", "GameFontNormal")
layoutLabel:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD, -36)
ui.ringLayouts = {}
for n, layout in ipairs(ns.LAYOUTS) do
	local r = Radio(panel, layout.text, function()
		local ring = Selected()
		if ring then ns.SetRingLayout(ring.name, layout.key) end
	end)
	r:SetPoint("TOPLEFT", panel, "TOPLEFT", COL + (n - 1) * LAYOUT_PITCH, -36)
	ui.ringLayouts[layout.key] = r
end

-------------------------------------------------------------------------------
-- Slots, laid out like the ring: the inner tier, the outer tier, and the
-- centre slice in the middle
-------------------------------------------------------------------------------

local CENTER_X, CENTER_Y = 132, -196
local EDIT_RADIUS = 100          -- outer tier radius in the editor
local SLOT_OUTER, SLOT_INNER, SLOT_CENTER = 36, 30, 30

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
		ns.PickupSlice(old)          -- swap: the previous content goes on the cursor (a nested ring has no cursor form)
	end
end

local function Pickup(slot)
	local ring = Selected()
	local slice = ring and ring.slices[slot]
	if not slice or slice.kind == "ring" then return end
	ns.PickupSlice(slice)
	ns.ClearRingSlice(ring.name, slot)
end

-- The menu of rings a slot can nest: every other ring, and Clear for a
-- slot that holds one.
local function NestMenu(slot)
	return function(_, root)
		local ring = Selected()
		if not ring then return end
		local others = {}
		for _, other in ipairs(ns.Rings()) do
			if other ~= ring then others[#others + 1] = other end
		end
		root:CreateTitle(#others > 0 and ("Nest a ring in " .. (slot == ns.CENTER and "the centre" or ("slot " .. slot))) or "No other ring to nest yet")
		for _, other in ipairs(others) do
			root:CreateButton(other.name, function() ns.SetRingSlice(ring.name, slot, { kind = "ring", name = other.name }) end)
		end
		if ring.slices[slot] then
			root:CreateButton("Clear", function() ns.ClearRingSlice(ring.name, slot) end)
		end
	end
end

local function Nest(button)
	local ring = Selected()
	if not ring then return end
	if MenuUtil and MenuUtil.CreateContextMenu then
		MenuUtil.CreateContextMenu(button, NestMenu(button.slot))
		return
	end
	local names = {}
	for _, other in ipairs(ns.Rings()) do
		if other ~= ring then names[#names + 1] = other.name end
	end
	if #names == 0 then
		ns.Print("no other ring to nest yet; make one first")
	else
		ns.Print("nest a ring with /rr ring set %s %s ring NAME (rings: %s)", ring.name,
			button.slot == ns.CENTER and "centre" or tostring(button.slot), table.concat(names, ", "))
	end
end

local function SlotTooltip(self)
	if not GameTooltip then return end
	local slice = self.slice
	local centre = self.slot == ns.CENTER
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	if not slice then
		GameTooltip:SetText(centre and "Centre: drop the ring's default action here, or right-click to nest a ring"
			or ("Slot %d: drop a spell, item, macro or mount here, or right-click to nest a ring"):format(self.slot))
	elseif slice.kind == "spell" then
		GameTooltip:SetSpellByID(slice.id)
	elseif slice.kind == "item" then
		GameTooltip:SetItemByID(slice.id)
	elseif slice.kind == "ring" then
		GameTooltip:SetText("Nested ring: " .. slice.name)
		GameTooltip:AddLine("Releasing or clicking here opens that ring in place. Click to change it, right-click to clear.", 1, 1, 1, true)
	else
		GameTooltip:SetText("Macro: " .. slice.name)
	end
	if centre then
		GameTooltip:AddLine("The centre slice fires when the trigger is released without moving, instead of cancelling.", 1, 1, 1, true)
	end
	GameTooltip:Show()
end

ui.slots = {}
for i = 1, ns.SLOT_COUNT do
	local b = CreateFrame("Button", nil, panel)
	b.slot = i
	b:SetSize(SLOT_OUTER, SLOT_OUTER)
	b:SetPoint("CENTER", panel, "TOPLEFT", CENTER_X, CENTER_Y)
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
	b.num = Text(b, i == ns.CENTER and "C" or tostring(i), "GameFontHighlightSmall")
	b.num:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -2, 2)
	b.sub = Text(b, "", "GameFontHighlightSmallOutline")
	b.sub:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", 2, 2)
	b.sub:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -2, 2)
	b.sub:SetJustifyH("CENTER")
	b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
	b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	b:RegisterForDrag("LeftButton")
	b:SetScript("OnClick", function(self, button)
		local ring = Selected()
		local slice = ring and ring.slices[self.slot]
		if button == "RightButton" then
			if slice then
				ns.ClearRingSlice(ring.name, self.slot)
			else
				Nest(self)
			end
		elseif GetCursorInfo() then
			Drop(self.slot)
		elseif slice and slice.kind == "ring" then
			Nest(self)
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

-- Place the slot buttons for a layout, as the live ring places its slices;
-- the centre slot is in the middle whatever the layout.
local function PlaceSlots(inner, outer)
	for i, b in ipairs(ui.slots) do
		if i == ns.CENTER or i <= inner + outer then
			local angle, fraction = ns.SlicePolar(i, inner, outer)
			local size = i == ns.CENTER and SLOT_CENTER or i <= inner and SLOT_INNER or SLOT_OUTER
			b:SetSize(size, size)
			b:ClearAllPoints()
			b:SetPoint("CENTER", panel, "TOPLEFT",
				CENTER_X + math.sin(math.rad(angle)) * EDIT_RADIUS * fraction,
				CENTER_Y + math.cos(math.rad(angle)) * EDIT_RADIUS * fraction)
			b:Show()
		else
			b:Hide()
		end
	end
end

-------------------------------------------------------------------------------
-- Right column: help, fill from a bar, import and export
-------------------------------------------------------------------------------

local RIGHT = 270
local help = Text(panel, "Drop a spell, item, macro or mount from the spellbook, bags, macro window, mount journal or an action bar onto a slot. Click or drag a filled slot to pick it up (drop it on another slot to move or swap), right-click to clear it. Right-click an empty slot to nest another ring in it. The inner tier comes first. The slot in the middle is the centre slice, the ring's default action: releasing the trigger without moving fires it instead of cancelling.", "GameFontHighlightSmall", WIDTH - RIGHT - 40)
help:SetPoint("TOPLEFT", panel, "TOPLEFT", RIGHT, -62)

local fillLabel = Text(panel, "Fill from bar", "GameFontNormal")
fillLabel:SetPoint("TOPLEFT", panel, "TOPLEFT", RIGHT, -164)
ui.fillButtons = {}
for bar = 1, 8 do
	local b = Button(panel, tostring(bar), 26, function()
		local ring = Selected()
		if ring then ns.FillRingFromBar(ring.name, bar, ui.fillFilter) end
	end)
	b:SetPoint("TOPLEFT", panel, "TOPLEFT", RIGHT + 90 + (bar - 1) * 29, -160)
	ui.fillButtons[bar] = b
end
ui.fillRadios = {}
for n, f in ipairs(FILTERS) do
	local r = Radio(panel, f[2], function()
		ui.fillFilter = f[1]
		ns.RefreshConfigUI()
	end)
	r:SetPoint("TOPLEFT", panel, "TOPLEFT", RIGHT + (n - 1) * 108, -188)
	ui.fillRadios[f[1]] = r
end
local fillNote = Text(panel, "Replaces the tier slots with the bar's twelve actions as direct slices and keeps the centre (the client classifies offensive and helpful actions out of combat).", "GameFontHighlightSmall", WIDTH - RIGHT - 40)
fillNote:SetPoint("TOPLEFT", panel, "TOPLEFT", RIGHT, -210)

local ioLabel = Text(panel, "Share", "GameFontNormal")
ioLabel:SetPoint("TOPLEFT", panel, "TOPLEFT", RIGHT, -258)
ui.ringIO = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
ui.ringIO:SetSize(WIDTH - RIGHT - 44, 22)
ui.ringIO:SetPoint("TOPLEFT", panel, "TOPLEFT", RIGHT + 6, -276)
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
ui.exportRing:SetPoint("TOPLEFT", panel, "TOPLEFT", RIGHT, -304)
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
ioNote:SetPoint("TOPLEFT", panel, "TOPLEFT", RIGHT, -332)

local otherLabel = Text(panel, "Other characters", "GameFontNormal")
otherLabel:SetPoint("TOPLEFT", panel, "TOPLEFT", RIGHT, -380)
ui.copyRing = CopyButton(panel)
ui.copyRing:SetPoint("TOPLEFT", panel, "TOPLEFT", RIGHT, -398)

-------------------------------------------------------------------------------
-- Refresh, called from RefreshConfigUI
-------------------------------------------------------------------------------

function ui.RefreshRings()
	local db = ns.db
	if not db then return end
	local rings = ns.Rings()
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
	for key, r in pairs(ui.ringLayouts) do r:SetChecked(key == ring.layout) end
	PlaceSlots(ns.LayoutCounts(ring.layout))
	for i, b in ipairs(ui.slots) do
		local slice = ring.slices[i]
		local icon = slice and ns.SliceIcon(slice)
		b.slice = slice
		b.icon:SetTexture(icon)
		b.icon:SetShown(slice ~= nil)
		b.sub:SetText(slice and slice.kind == "ring" and Trunc(slice.name, 7) or "")
	end
	for key, r in pairs(ui.fillRadios) do r:SetChecked(key == ui.fillFilter) end
end
