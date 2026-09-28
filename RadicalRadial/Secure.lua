-------------------------------------------------------------------------------
-- Radical Radial — Secure
--
-- The control layer: the opener (the trigger's target), the header (owner of
-- the snippets, frame refs and temporary bindings) and the snippets that run
-- in Blizzard's restricted environment. In combat this layer only flips
-- attributes, anchors, visibility and bindings.
--
-- Hold-and-release, end to end:
--   trigger down  → wrapped OnClick: open the ring at "$cursor", install the
--                   wheel and Escape bindings, swallow the click
--   wheel         → header _onclick: next/previous bar, ApplyPage
--   trigger up    → wrapped OnClick: resolve the slice under the cursor from
--                   GetMousePosition(), copy its attributes onto the opener,
--                   close, and let Blizzard's handler perform the action
-------------------------------------------------------------------------------

local ADDON, ns = ...

-------------------------------------------------------------------------------
-- Snippets
-------------------------------------------------------------------------------

local SNIPPET_CONSTANTS = {
	DEAD = ns.DEAD, LIMIT = ns.INNER_LIMIT, IN = ns.INNER_COUNT, OUT = ns.OUTER_COUNT,
	SLICES = ns.SLICE_COUNT, PAGES = ns.PAGE_COUNT,
}
local function Snippet(body)
	return (body:gsub("%$(%u+)", function(key)
		return tostring(assert(SNIPPET_CONSTANTS[key], "unknown snippet constant " .. key))
	end))
end

-- Header attribute "Resolve": slice index under the cursor, or nil in the dead
-- zone. Distances come from the screen-sized frame and the ring's rect, both
-- in UIParent units.
local RESOLVE = Snippet([[
local screen = self:GetFrameRef("screen")
local ring   = self:GetFrameRef("ring")
local fx, fy = screen:GetMousePosition()
local sl, sb, sw, sh = screen:GetRect()
local l, b, w, h = ring:GetRect()
if not (fx and sl and l) then return nil end
local dx = (sl + fx * sw) - (l + w / 2)
local dy = (sb + fy * sh) - (b + h / 2)
local R  = self:GetAttribute("radius")
local r  = math.sqrt(dx * dx + dy * dy)
if r < $DEAD * R then return nil, r end
local a = (90 - deg(math.atan2(dy, dx))) % 360
if r < $LIMIT * R then
	return 1 + floor(((a + 180 / $IN) % 360) / (360 / $IN)), r
end
return $IN + 1 + floor(((a + 180 / $OUT) % 360) / (360 / $OUT)), r
]])

-- Header attribute "ApplyPage": switch every slice to the action page of the
-- bar on the current wheel page. Bar 1 follows Blizzard's own page selection
-- for the main bar, in the same order ActionBarController uses.
local APPLY_PAGE = Snippet([[
local page = self:GetAttribute("page") or 1
local bar  = self:GetAttribute("bar" .. page) or 1
local p    = self:GetAttribute("pageofbar" .. bar)
if not p then
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
	if not p or p < 1 or p > $PAGES then p = 1 end
end
self:SetAttribute("basecurrent", (p - 1) * $SLICES + 1)
for i = 1, $SLICES do
	local slice = self:GetFrameRef("slice" .. i)
	slice:RunAttribute("UpdateState", p)
	slice:CallMethod("UpdateAction")
end
]])

-- Header attribute "Close": hide the ring and drop the temporary bindings.
local CLOSE = [[
self:SetAttribute("open", false)
self:GetFrameRef("ring"):Hide()
self:ClearBindings()
]]

-- Wrapped around the opener's OnClick. `self` is the opener, `control` the
-- header; `button` and `down` come from the click. Returning false tells the
-- wrap machinery to skip Blizzard's click handler entirely; returning nothing
-- lets it run with the attributes we just set.
local PRE_CLICK = [[
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

local idx, r = hdr:RunAttribute("Resolve")
hdr:RunAttribute("Close")

if idx then
	local slice = hdr:GetFrameRef("slice" .. idx)
	self:SetAttribute("type",   slice:GetAttribute("type"))
	self:SetAttribute("action", slice:GetAttribute("action"))
	self:SetAttribute("unit",   slice:GetAttribute("unit"))
	if hdr:GetAttribute("debug") then
		print("|cff33ff99RR secure|r release: slice " .. idx .. " -> slot " .. tostring(slice:GetAttribute("action")) .. " (r=" .. floor(r) .. ")")
	end
	return
end

self:SetAttribute("type", nil)
if hdr:GetAttribute("debug") then
	print("|cff33ff99RR secure|r release: cancelled (r=" .. tostring(r and floor(r)) .. ")")
end
return false
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
-- Frames (created at load, out of combat)
-------------------------------------------------------------------------------

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

-- Wiring
SecureHandlerSetFrameRef(header, "ring", ns.ring)
SecureHandlerSetFrameRef(header, "screen", ns.screen)
SecureHandlerSetFrameRef(header, "opener", opener)
for i, slice in ipairs(ns.slices) do
	SecureHandlerSetFrameRef(header, "slice" .. i, slice)
end
header:SetAttribute("Resolve", RESOLVE)
header:SetAttribute("ApplyPage", APPLY_PAGE)
header:SetAttribute("Close", CLOSE)
header:SetAttribute("_onclick", HEADER_CLICK)
header:SetAttribute("open", false)
header:SetAttribute("page", 1)
SecureHandlerWrapScript(opener, "OnClick", header, PRE_CLICK)

header:SetScript("OnAttributeChanged", function(_, name)
	if name == "page" then ns.UpdateLabel() end
end)

-- Debug taps: show what actually arrives at the secure frames.
opener:HookScript("OnClick", function(_, button, down)
	ns.Debug("opener click: %s %s", tostring(button), down and "down" or "up")
end)
header:HookScript("OnClick", function(_, button, down)
	ns.Debug("header click: %s %s", tostring(button), down and "down" or "up")
end)

ns.opener, ns.header, ns.bindOwner = opener, header, bindOwner
