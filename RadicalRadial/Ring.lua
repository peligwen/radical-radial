-------------------------------------------------------------------------------
-- Radical Radial — Ring
--
-- The ring frames and the presentation layer. Slices are LibActionButton-1.0
-- buttons: they paint icons, cooldowns, charges, counts, usable and range
-- tints the same way Bartender4's buttons do, including under Midnight's
-- secret values. Each slice carries one state per action page (1-15); the
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
-- resets the open state however the ring gets hidden.
local ring = CreateFrame("Frame", "RadicalRadialRing", UIParent, "SecureHandlerShowHideTemplate")
ring:SetSize(ns.RingSize(1), ns.RingSize(1))
ring:SetPoint("CENTER")
ring:SetFrameStrata("FULLSCREEN_DIALOG")
ring:EnableMouse(false)
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
-- Presentation
-------------------------------------------------------------------------------

function ns.UpdateLabel()
	local header = ns.header
	local active = header and header:GetAttribute("active") or 1
	local page = header and header:GetAttribute("page") or 1
	local trigger = ns.db and ns.db.triggers[active]
	local bar = trigger and trigger.bars[page] or 1
	label:SetText(ns.BAR_NAMES[bar] or ("Bar " .. tostring(bar)))
end

local selected
function ns.Highlight(idx)
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
	local idx = ns.Resolve(cx / scale - rx, cy / scale - ry, ns.RADIUS * (ns.db and ns.db.scale or 1))
	ns.Highlight(idx)
end)
