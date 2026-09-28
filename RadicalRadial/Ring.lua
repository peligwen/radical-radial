-------------------------------------------------------------------------------
-- Radical Radial — Ring
--
-- The ring frames and the presentation layer. Slices are LibActionButton-1.0
-- buttons: they paint icons, cooldowns, charges, counts, usable and range
-- tints the same way Bartender4's buttons do, including under Midnight's
-- secret values. Each slice carries one state per action page (1-15) and one
-- per custom ring (16 and up, set from the saved rings by Config.lua); the
-- secure side switches pages by switching states (Secure.lua).
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
ring:Hide()

-- Scaled parent of the slices, and LibActionButton's "header" for them: a
-- secure handler frame that owns their wrap scripts and frame refs.
local visual = CreateFrame("Frame", "RadicalRadialVisual", ring, "SecureHandlerBaseTemplate")
visual:SetPoint("CENTER")
visual:SetSize(2, 2)

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

local slices = {}
for i = 1, ns.SLICE_COUNT do
	local angle, fraction, size = ns.SlicePolar(i)
	local slice = LAB:CreateButton(i, "RadicalRadialSlice" .. i, visual, LAB_CONFIG)

	-- Size by scaling the native 45 px template, so Blizzard's slot art, masks
	-- and highlight keep their proportions. Anchor offsets are in the slice's
	-- own (scaled) units, hence the division.
	local s = size / ns.BUTTON_SIZE
	slice:SetScale(s)
	slice:ClearAllPoints()
	slice:SetPoint("CENTER", visual, "CENTER",
		math.sin(math.rad(angle)) * ns.RADIUS * fraction / s,
		math.cos(math.rad(angle)) * ns.RADIUS * fraction / s)
	slice:EnableMouse(false)
	slice:SetAttribute("LABdisableDragNDrop", true)

	-- One state per action page: state p shows slot (p - 1) * 12 + i.
	for page = 1, ns.PAGE_COUNT do
		slice:SetState(page, "action", ns.SlotOfPage(page, i))
	end

	slices[i] = slice
end

local center = visual:CreateTexture(nil, "OVERLAY")
center:SetSize(10, 10)
center:SetPoint("CENTER")
center:SetColorTexture(0.9, 0.2, 0.2, 0.9)

local label = visual:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
label:SetPoint("TOP", visual, "CENTER", 0, -(ns.RADIUS + ns.ICON_OUTER))
label:SetText("")

ns.screen, ns.ring, ns.visual, ns.slices, ns.label = screen, ring, visual, slices, label

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
	local trigger = ns.db and ns.db.triggers[active]
	local list = trigger and (CONTEXT_TEXT[context] and trigger[context] or trigger.bars)
	local entry = list and list[page] or 1
	label:SetText(ns.EntryName(entry)
		.. (CONTEXT_TEXT[context] or "")
		.. (unit and (" @" .. unit) or ""))
end

-- The selected slice gets the locked highlight and a green centre; past the
-- cancel radius the whole ring dims to say a release there does nothing.
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

-- Cosmetic selection tracking. Uses the same formulas as the release snippet.
ring:SetScript("OnUpdate", function(self)
	local cx, cy = GetCursorPosition()
	local scale = self:GetEffectiveScale()
	local rx, ry = self:GetCenter()
	if not rx then return end
	local db = ns.db
	local idx, _, zone = ns.Resolve(cx / scale - rx, cy / scale - ry, ns.RADIUS * (db and db.scale or 1), db and db.outer)
	ns.Highlight(idx, zone)
end)
