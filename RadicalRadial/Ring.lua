-------------------------------------------------------------------------------
-- Radical Radial — Ring
--
-- The ring frames and the presentation layer. Slices are LibActionButton-1.0
-- buttons: they paint icons, cooldowns, charges, counts, usable and range
-- tints the same way Bartender4's buttons do, including under Midnight's
-- secret values. Each slice carries one state per action page (1-15) and one
-- per custom ring (16 and up, set from the saved rings by Config.lua); the
-- secure side switches pages by switching states, and places the slices for
-- the page's layout (Secure.lua). There are MAX_SLICES slices on the tiers;
-- a layout shows the first inner + outer of them. One more sits in the
-- centre: a custom ring's default action, or the action the ring last
-- fired, shown only when the page has one (a bar never does), and fired by
-- a release that never left the dead zone.
--
-- A slice that opens a nested ring is an empty LibActionButton state with a
-- "subring" attribute (the nested ring's bar code); the presentation paints
-- a folder icon and the ring's name over it.
--
-- The clicker is a secure button the size of the ring that takes the mouse
-- only while the ring waits for a click (a ring opened by the macro, or a
-- trigger with "click to fire"): a left click fires the slice under the
-- cursor, a right click cancels. It stays hidden otherwise, so a thumb
-- button's release still reaches its binding.
--
-- Ordinary code here only touches textures, text, highlights and alpha,
-- which are allowed on protected frames in combat.
-------------------------------------------------------------------------------

local ADDON, ns = ...

local LAB = LibStub("LibActionButton-1.0")

-------------------------------------------------------------------------------
-- Frames
-------------------------------------------------------------------------------

-- Reference frame the size of the screen. Snippets read the cursor through it.
local screen = CreateFrame("Frame", "RadicalRadialScreen", UIParent, "SecureFrameTemplate")
screen:SetAllPoints(UIParent)
screen:SetFrameStrata("BACKGROUND")
screen:EnableMouse(false)
screen:Show()

-- The ring. Anchored to the cursor by the open snippet and sized to the
-- square it occupies (auto-hide counts down once the cursor leaves that
-- rect). Kept at scale 1 so its rect is in the same units as the screen
-- frame; the scaled visuals live in a child. Its _onhide snippet (Secure.lua)
-- resets the open state however the ring gets hidden, and its _onmousewheel
-- pages the bars: the ring takes the wheel itself while the cursor is over
-- it, so a chat or scroll frame underneath never eats a notch. Clicks still
-- pass through (EnableMouse stays off; the wheel flag is separate).
local ring = CreateFrame("Frame", "RadicalRadialRing", UIParent,
	"SecureHandlerShowHideTemplate,SecureHandlerMouseWheelTemplate")
ring:SetSize(ns.RingSize(1), ns.RingSize(1))
ring:SetPoint("CENTER")
ring:SetFrameStrata("FULLSCREEN_DIALOG")
ring:EnableMouse(false)
ring:EnableMouseWheel(true)
-- Near a screen edge the client keeps the ring's square on screen, so the
-- ring opens shifted inward from the cursor. Direction is then measured
-- from where the ring actually is (its rect), and the point the cursor was
-- at when the ring opened counts as a dead zone until the first click away
-- from it (Secure.lua), so a release without moving still cancels.
ring:SetClampedToScreen(true)
ring:Hide()

-- Scaled parent of the slices, and LibActionButton's "header" for them: a
-- secure handler frame that owns their wrap scripts and frame refs. The
-- page snippet anchors the slices to it.
local visual = CreateFrame("Frame", "RadicalRadialVisual", ring, "SecureHandlerBaseTemplate")
visual:SetPoint("CENTER")
visual:SetSize(2, 2)

-- The clicker: shown by the secure side while the ring waits for a click.
-- A child of the ring, so it hides with it; its own wheel handler pages
-- like the ring's, since it is the topmost wheel-enabled frame then.
local clicker = CreateFrame("Button", "RadicalRadialClicker", ring,
	"SecureActionButtonTemplate,SecureHandlerMouseWheelTemplate")
clicker:SetAllPoints(ring)
clicker:RegisterForClicks("AnyUp")
clicker:EnableMouse(true)
clicker:EnableMouseWheel(true)
clicker:SetAttribute("useOnKeyDown", false)
clicker:Hide()

-------------------------------------------------------------------------------
-- Slices
-------------------------------------------------------------------------------

local LAB_CONFIG = {
	outOfRangeColoring = "button",
	tooltip = "disabled",          -- slices never take the mouse
	showGrid = true,               -- empty slots keep their slot art, so the ring shape stays readable
	hideElements = { macro = true, hotkey = true, equipped = false, border = false, borderIfEmpty = false },
	keyBoundTarget = false,
	actionButtonUI = false,
}

-- The folder icon and name over a nested-ring slice, driven by its
-- "subring" attribute (set by the page snippet, in combat too).
local function UpdateFolder(slice, code)
	local target = code and ns.RingOfCode(code)
	slice.folderIcon:SetShown(target ~= nil)
	slice.folderName:SetShown(target ~= nil)
	if target then slice.folderName:SetText(target.name) end
end

local slices = {}
for i = 1, ns.SLOT_COUNT do
	local slice = LAB:CreateButton(i, "RadicalRadialSlice" .. i, visual, LAB_CONFIG)
	slice:EnableMouse(false)
	slice:SetAttribute("LABdisableDragNDrop", true)

	-- One state per action page: state p shows slot (p - 1) * 12 + i. A bar
	-- has twelve slots, so slices past that (the centre included) are empty
	-- on every page.
	for page = 1, ns.PAGE_COUNT do
		if i <= ns.SLICE_COUNT then
			slice:SetState(page, "action", ns.SlotOfPage(page, i))
		else
			slice:SetState(page, "empty")
		end
	end

	slice.folderIcon = slice:CreateTexture(nil, "OVERLAY")
	slice.folderIcon:SetPoint("TOPLEFT", 3, -3)
	slice.folderIcon:SetPoint("BOTTOMRIGHT", -3, 3)
	slice.folderIcon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	slice.folderIcon:SetTexture(ns.FOLDER_ICON)
	slice.folderIcon:Hide()
	slice.folderName = slice:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmallOutline")
	slice.folderName:SetPoint("BOTTOMLEFT", 2, 3)
	slice.folderName:SetPoint("BOTTOMRIGHT", -2, 3)
	slice.folderName:SetJustifyH("CENTER")
	slice.folderName:Hide()
	-- The library clears the template's handler and never sets its own.
	slice:SetScript("OnAttributeChanged", function(self, name, value)
		if name == "subring" then UpdateFolder(self, value) end
	end)

	slices[i] = slice
end

-- Place the slices for a layout (out of combat; the page snippet does the
-- same in combat, with the same formulas). Slices past the layout are hidden.
-- The centre slice sits in the middle at every layout; the page snippet
-- shows it when the page has one, so here it starts hidden.
function ns.PlaceSlices(inner, outer)
	for i, slice in ipairs(slices) do
		if i == ns.CENTER then
			local s = ns.ICON_CENTER / ns.BUTTON_SIZE
			slice:SetScale(s)
			slice:ClearAllPoints()
			slice:SetPoint("CENTER", visual, "CENTER", 0, 0)
			slice:Hide()
		elseif i <= inner + outer then
			local angle, fraction, size = ns.SlicePolar(i, inner, outer)
			-- Size by scaling the native 45 px template, so Blizzard's slot art,
			-- masks and highlight keep their proportions. Anchor offsets are in
			-- the slice's own (scaled) units, hence the division.
			local s = size / ns.BUTTON_SIZE
			slice:SetScale(s)
			slice:ClearAllPoints()
			slice:SetPoint("CENTER", visual, "CENTER",
				math.sin(math.rad(angle)) * ns.RADIUS * fraction / s,
				math.cos(math.rad(angle)) * ns.RADIUS * fraction / s)
			slice:Show()
		else
			slice:Hide()
		end
	end
end
ns.PlaceSlices(ns.INNER_COUNT, ns.OUTER_COUNT)

local center = visual:CreateTexture(nil, "OVERLAY")
center:SetSize(10, 10)
center:SetPoint("CENTER")
center:SetColorTexture(0.9, 0.2, 0.2, 0.9)

-- The label sits in the margin between the bottom icon and the edge of the
-- ring's square, so it stays on screen with the square.
local label = visual:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
label:SetPoint("TOP", visual, "CENTER", 0, -(ns.RADIUS + ns.ICON_OUTER / 2 + 1))
label:SetText("")

ns.screen, ns.ring, ns.visual, ns.clicker, ns.slices, ns.label = screen, ring, visual, clicker, slices, label

-------------------------------------------------------------------------------
-- Range
--
-- LibActionButton r160 still polls IsActionInRange for its red tint, and the
-- 12.x client no longer answers that call usefully for addons, so no slice
-- ever went red. Blizzard's own buttons ask the client to watch a slot
-- (C_ActionBar.EnableActionRangeCheck) and receive ACTION_RANGE_CHECK_UPDATE
-- when its state changes. Feed those answers to the library through each
-- slice's IsInRange, and its range loop paints the tint as before. The client
-- checks against the current target, so a ring aimed at the focus still
-- tints for the target.
--
-- Direct spell and item slices (custom rings) ask C_Spell.IsSpellInRange and
-- C_Item.IsItemInRange against the unit the slice aims at. An answer the
-- client keeps secret in combat is treated as unknown, since the library
-- compares the value.
-------------------------------------------------------------------------------

local IsSpellInRange = C_Spell and C_Spell.IsSpellInRange
local IsItemInRange  = C_Item and C_Item.IsItemInRange

local function Plain(value)
	if issecretvalue and issecretvalue(value) then return nil end
	if value == true or value == 1 then return true end
	if value == false or value == 0 then return false end
	return nil
end

local function DirectRange(self)
	local kind = self._state_type
	local unit = self:GetAttribute("unit") or "target"
	if kind == "spell" and IsSpellInRange then
		return Plain(IsSpellInRange(self._state_action, unit))
	elseif kind == "item" and IsItemInRange then
		return Plain(IsItemInRange(self._state_action, unit))
	end
	return nil
end

if C_ActionBar and C_ActionBar.EnableActionRangeCheck then
	local inRange = {}   -- slot -> true/false; nil while unknown or when the action has no range
	local watched = {}   -- slots this addon asked the client to check

	local watcher = CreateFrame("Frame")
	watcher:RegisterEvent("ACTION_RANGE_CHECK_UPDATE")
	watcher:SetScript("OnEvent", function(_, _, slot, isInRange, checksRange)
		if checksRange then
			inRange[slot] = isInRange and true or false
		else
			inRange[slot] = nil
		end
	end)

	-- The flag is per slot and shared with Blizzard's bars, which clear it for
	-- slots they stop showing, so it is asserted again every time the ring
	-- opens rather than once.
	ring:HookScript("OnShow", function() watched = {} end)

	local function IsInRange(self)
		if self._state_type ~= "action" then return DirectRange(self) end
		local slot = self._state_action
		if not watched[slot] then
			watched[slot] = true
			C_ActionBar.EnableActionRangeCheck(slot, true)
		end
		return inRange[slot]
	end
	for _, slice in ipairs(slices) do
		slice.IsInRange = IsInRange
	end
else
	for _, slice in ipairs(slices) do
		slice.IsInRange = DirectRange
	end
end

-------------------------------------------------------------------------------
-- Presentation
-------------------------------------------------------------------------------

local CONTEXT_TEXT = { harm = " · enemy", help = " · friend" }

function ns.UpdateLabel()
	local header = ns.header
	local active = header and header:GetAttribute("active") or 1
	local page = header and header:GetAttribute("page") or 1
	local context = header and header:GetAttribute("context") or "none"
	local unit = header and header:GetAttribute("unit")
	local sub = header and ns.RingOfCode(header:GetAttribute("sub"))
	local trigger = ns.db and ns.db.triggers[active]
	local list = trigger and (CONTEXT_TEXT[context] and trigger[context] or trigger.bars)
	local entry = list and list[page] or 1
	local name = sub and (sub.name .. " « " .. ns.EntryName(entry)) or ns.EntryName(entry)
	label:SetText(name
		.. (CONTEXT_TEXT[context] or "")
		.. (unit and (" @" .. unit) or ""))
end

-- The selected slice gets the locked highlight and a green centre dot; past
-- the cancel radius the whole ring dims to say a release there does nothing.
-- The dot sits under the centre slice, so it shows only while that slice is
-- hidden (a page without a centre).
local selected, dimmed
function ns.Highlight(idx, zone)
	local outside = zone == "outside"
	if outside ~= dimmed then
		dimmed = outside
		visual:SetAlpha(outside and 0.45 or 1)
	end
	if idx == selected then return end
	selected = idx
	for i, slice in ipairs(slices) do
		if i == idx then slice:LockHighlight() else slice:UnlockHighlight() end
	end
	if idx then
		center:SetColorTexture(0.2, 0.9, 0.3, 0.9)
	else
		center:SetColorTexture(0.9, 0.2, 0.2, 0.9)
	end
end

-- The show/hide template owns the OnShow and OnHide handlers, so hook them.
ring:HookScript("OnShow", function()
	selected = false
	ns.UpdateLabel()
	ns.Highlight(nil)
end)

ring:HookScript("OnHide", function()
	ns.Highlight(nil)
end)

-- Would a release (or a click) in the dead zone pick the centre slice right
-- now? The page must show one (the page snippet shows the centre slice
-- exactly then), and in tap mode the opening tap must be over: while the
-- trigger is still held after opening, a release in the centre leaves the
-- ring waiting instead. The same test the secure side makes (Secure.lua).
function ns.CentreArmed()
	if not slices[ns.CENTER]:IsShown() then return false end
	local header = ns.header
	local trigger = header and ns.db and ns.db.triggers[header:GetAttribute("active") or 1]
	if trigger and trigger.mode == "tap" and header:GetAttribute("via") == "key"
		and not header:GetAttribute("sub") and not header:GetAttribute("waiting") then
		return false
	end
	return true
end

-- Cosmetic selection tracking. Uses the same formulas as the release snippet,
-- with the layout the page snippet last applied, and the same opening-point
-- dead zone (the header's "pressx"/"pressy", which the secure side clears on
-- the first click away from it, so both sides always agree).
ring:SetScript("OnUpdate", function(self)
	local cx, cy = GetCursorPosition()
	local scale = self:GetEffectiveScale()
	local rx, ry = self:GetCenter()
	if not rx then return end
	local db = ns.db
	local header = ns.header
	local R = ns.RADIUS * (db and db.scale or 1)
	cx, cy = cx / scale, cy / scale
	local idx, zone
	local px = header and header:GetAttribute("pressx")
	local ex, ey = px and (cx - px), px and (cy - header:GetAttribute("pressy"))
	if px and math.sqrt(ex * ex + ey * ey) < ns.DEAD * R then
		zone = "dead"
	else
		idx, _, zone = ns.Resolve(cx - rx, cy - ry, R, db and db.outer,
			header and header:GetAttribute("incount"), header and header:GetAttribute("outcount"))
	end
	if not idx and zone == "dead" and ns.CentreArmed() then idx = ns.CENTER end
	ns.Highlight(idx, zone)
end)
