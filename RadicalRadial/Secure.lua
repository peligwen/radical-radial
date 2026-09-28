-------------------------------------------------------------------------------
-- Radical Radial — Secure
--
-- The control layer: the openers (one per trigger, the bindings' targets),
-- the header (owner of the snippets, frame refs and temporary bindings) and
-- the snippets that run in Blizzard's restricted environment. In combat this
-- layer only flips attributes, anchors, visibility and bindings.
--
-- Hold mode, end to end:
--   trigger down  → wrapped OnClick: Open (ring at "$cursor", page 1, wheel
--                   and Escape bindings), swallow the click
--   wheel         → header _onclick: next/previous bar, ApplyPage
--   trigger up    → wrapped OnClick: Resolve the slice under the cursor from
--                   GetMousePosition(), copy its attributes onto the opener,
--                   Close, and let Blizzard's handler perform the action
--
-- Tap mode differs only at the ends: a release in the dead zone leaves the
-- ring open (and arms auto-hide), and a later press in the dead zone cancels.
-- Whatever hides the ring (Close, Escape, auto-hide, /rr preview) runs the
-- ring's _onhide snippet, which resets the open state and drops the bindings.
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

-- Header attribute "Resolve": slice index under the cursor and its distance,
-- or nil in the dead zone. Distances come from the screen-sized frame and the
-- ring's rect, both in UIParent units.
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
-- bar on the current wheel page of the active trigger. Bar 1 follows
-- Blizzard's own page selection for the main bar, in the same order
-- ActionBarController uses.
local APPLY_PAGE = Snippet([[
local opener = self:GetFrameRef("opener" .. (self:GetAttribute("active") or 1))
local page = self:GetAttribute("page") or 1
local bar  = opener:GetAttribute("bar" .. page) or 1
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

-- Header attribute "Open" (argument: trigger index): show the ring at the
-- cursor on page 1 of that trigger's bars, capture the wheel and Escape, and
-- in tap mode arm auto-hide. Registered after Show so the driver sees the
-- ring's rect at its new position, with the cursor inside it.
local OPEN = [[
local me     = ...
local opener = self:GetFrameRef("opener" .. me)
local ring   = self:GetFrameRef("ring")
self:SetAttribute("active", me)
self:SetAttribute("page", 1)
self:RunAttribute("ApplyPage")
ring:ClearAllPoints()
ring:SetPoint("CENTER", "$cursor")
ring:Show()
self:SetAttribute("open", true)
self:SetBindingClick(true, "MOUSEWHEELUP",   "RadicalRadialHeader", "wheelup")
self:SetBindingClick(true, "MOUSEWHEELDOWN", "RadicalRadialHeader", "wheeldown")
self:SetBindingClick(true, "ESCAPE",         "RadicalRadialHeader", "cancel")
local ttl = opener:GetAttribute("autohide") or 0
if opener:GetAttribute("mode") == "tap" and ttl > 0 then
	ring:RegisterAutoHide(ttl)
end
]]

-- Header attribute "Close": hide the ring; its _onhide does the rest. The
-- state is also reset here so Close is safe when the ring is already hidden.
local CLOSE = [[
self:SetAttribute("open", false)
self:ClearBindings()
self:GetFrameRef("ring"):Hide()
]]

-- Ring _onhide: runs for every hide, secure or not (Close, Escape, auto-hide,
-- /rr preview). `self` is the ring.
local RING_HIDE = [[
local hdr = self:GetFrameRef("header")
hdr:SetAttribute("open", false)
hdr:ClearBindings()
self:UnregisterAutoHide()
]]

-- Wrapped around each opener's OnClick. `self` is the opener, `control` the
-- header; `button` and `down` come from the click. Returning false tells the
-- wrap machinery to skip Blizzard's click handler entirely; returning nothing
-- lets it run with the attributes we just set.
local PRE_CLICK = [[
local hdr   = control
local me    = self:GetAttribute("trigger")
local debug = hdr:GetAttribute("debug")

if down then
	if hdr:GetAttribute("open") then
		if hdr:GetAttribute("active") ~= me then
			-- another trigger's ring is open: cancel it, swallow this press
			hdr:RunAttribute("Close")
			if debug then print("|cff33ff99RR secure|r press: trigger " .. me .. " closed the open ring") end
			return false
		end
		-- tap mode, second press: in the dead zone it cancels; anywhere else
		-- the release that follows fires the slice under the cursor
		if not hdr:RunAttribute("Resolve") then
			hdr:RunAttribute("Close")
			if debug then print("|cff33ff99RR secure|r press: cancelled in the dead zone") end
		end
		return false
	end
	if (self:GetAttribute("barcount") or 0) < 1 then return false end
	hdr:RunAttribute("Open", me)
	if debug then print("|cff33ff99RR secure|r press: trigger " .. me .. " opened the ring at cursor") end
	return false
end

if not hdr:GetAttribute("open") or hdr:GetAttribute("active") ~= me then return false end

local idx, r = hdr:RunAttribute("Resolve")
if idx then
	hdr:RunAttribute("Close")
	local slice = hdr:GetFrameRef("slice" .. idx)
	self:SetAttribute("type",   slice:GetAttribute("type"))
	self:SetAttribute("action", slice:GetAttribute("action"))
	self:SetAttribute("unit",   slice:GetAttribute("unit"))
	if debug then
		print("|cff33ff99RR secure|r release: slice " .. idx .. " -> slot " .. tostring(slice:GetAttribute("action")) .. " (r=" .. floor(r) .. ")")
	end
	return
end

if self:GetAttribute("mode") == "tap" then
	if debug then print("|cff33ff99RR secure|r release: tap, ring stays open") end
	return false
end

hdr:RunAttribute("Close")
self:SetAttribute("type", nil)
if debug then
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
	local opener = self:GetFrameRef("opener" .. (self:GetAttribute("active") or 1))
	local n    = opener:GetAttribute("barcount") or 1
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

-- The header: owns the snippets, the frame refs and the temporary bindings.
local header = CreateFrame("Button", "RadicalRadialHeader", UIParent, "SecureHandlerClickTemplate")
header:RegisterForClicks("AnyDown", "AnyUp")
header:SetSize(1, 1)
header:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", -8, -8)
header:SetAlpha(0)

-- Owner of the persistent trigger bindings, kept separate from the header so
-- the header's ClearBindings() never removes the triggers themselves.
local bindOwner = CreateFrame("Frame", "RadicalRadialBindOwner", UIParent)

-- The openers: one per possible trigger. Both the down and the up click land
-- on the pressed one; the wrapped pre-snippet decides what, if anything,
-- Blizzard's handler does with them.
local openers = {}
for i = 1, ns.MAX_TRIGGERS do
	local opener = CreateFrame("Button", "RadicalRadialOpener" .. i, UIParent, "SecureActionButtonTemplate")
	opener:RegisterForClicks("AnyDown", "AnyUp")
	opener:SetAttribute("useOnKeyDown", false)
	opener:SetAttribute("trigger", i)
	opener:SetAttribute("barcount", 0)
	opener:SetSize(1, 1)
	opener:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", -8, -8)
	opener:SetAlpha(0)
	SecureHandlerSetFrameRef(header, "opener" .. i, opener)
	SecureHandlerWrapScript(opener, "OnClick", header, PRE_CLICK)
	opener:HookScript("OnClick", function(_, button, down)
		ns.Debug("opener %d click: %s %s", i, tostring(button), down and "down" or "up")
	end)
	openers[i] = opener
end

-- Wiring
SecureHandlerSetFrameRef(header, "ring", ns.ring)
SecureHandlerSetFrameRef(header, "screen", ns.screen)
for i, slice in ipairs(ns.slices) do
	SecureHandlerSetFrameRef(header, "slice" .. i, slice)
end
header:SetAttribute("Resolve", RESOLVE)
header:SetAttribute("ApplyPage", APPLY_PAGE)
header:SetAttribute("Open", OPEN)
header:SetAttribute("Close", CLOSE)
header:SetAttribute("_onclick", HEADER_CLICK)
header:SetAttribute("open", false)
header:SetAttribute("active", 1)
header:SetAttribute("page", 1)

SecureHandlerSetFrameRef(ns.ring, "header", header)
ns.ring:SetAttribute("_onhide", RING_HIDE)

header:SetScript("OnAttributeChanged", function(_, name)
	if name == "page" or name == "active" then ns.UpdateLabel() end
end)

header:HookScript("OnClick", function(_, button, down)
	ns.Debug("header click: %s %s", tostring(button), down and "down" or "up")
end)

ns.openers, ns.header, ns.bindOwner = openers, header, bindOwner
