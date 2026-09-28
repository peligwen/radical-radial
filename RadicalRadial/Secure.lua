-------------------------------------------------------------------------------
-- Radical Radial — Secure
--
-- The control layer: the openers (one per trigger, the bindings' targets),
-- the header (owner of the snippets, frame refs and temporary bindings) and
-- the snippets that run in Blizzard's restricted environment. In combat this
-- layer only flips attributes, anchors, visibility and bindings.
--
-- Hold mode, end to end:
--   trigger down  → wrapped OnClick: OpenRing (ring at "$cursor", page 1, wheel
--                   and Escape bindings), swallow the click
--   wheel         → ring _onmousewheel while the cursor is over the ring,
--                   header _onclick through an override binding elsewhere;
--                   both run StepPage: next/previous bar, ApplyPage
--   trigger up    → wrapped OnClick: Resolve the slice under the cursor from
--                   GetMousePosition(), copy its type and its action field
--                   (action slot, spell, item or macro) onto the opener,
--                   CloseRing, and let Blizzard's handler perform the action;
--                   in the dead zone or past the cancel radius, just CloseRing
--
-- Tap mode differs only at the ends: a release in the dead zone leaves the
-- ring open (and arms auto-hide), and a later press in the dead zone or past
-- the cancel radius cancels.
-- Whatever hides the ring (CloseRing, Escape, auto-hide, /rr preview) runs the
-- ring's _onhide snippet, which resets the open state and drops the bindings.
--
-- Context rings: the down snippet classifies the unit under the cursor with
-- macro-conditional-grade checks (PlayerCanAttack / PlayerCanAssist on
-- "mouseover"). If the trigger has bars for that context, the ring opens on
-- them, the opener runs a "/focus [@mouseover,exists,nodead]" (or /target)
-- macro on the very same down click, which is a hardware event, and every
-- slice carries unit="focus" (or "target") until the ring closes.
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

-- Header attribute "Resolve": slice index under the cursor, its distance and
-- the zone ("dead" or "outside" when there is no index). Distances come from
-- the screen-sized frame and the ring's rect, both in UIParent units; the
-- cancel radius is the header's "outer" attribute, a fraction of the radius.
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
if r < $DEAD * R then return nil, r, "dead" end
local outer = self:GetAttribute("outer") or 0
if outer > 0 and r > outer * R then return nil, r, "outside" end
local a = (90 - deg(math.atan2(dy, dx))) % 360
if r < $LIMIT * R then
	return 1 + floor(((a + 180 / $IN) % 360) / (360 / $IN)), r
end
return $IN + 1 + floor(((a + 180 / $OUT) % 360) / (360 / $OUT)), r
]])

-- Header attribute "ApplyPage": switch every slice to the page of the bar on
-- the current wheel page of the active trigger. Bars 2-8 and custom rings
-- (bar codes 9 and up, a LibActionButton state each) have fixed pages, set as
-- "pageofbar" attributes by Config.lua; Bar 1 follows Blizzard's own page
-- selection for the main bar, in the same order ActionBarController uses.
local APPLY_PAGE = Snippet([[
local opener = self:GetFrameRef("opener" .. (self:GetAttribute("active") or 1))
local ctx    = self:GetAttribute("context") or "none"
local prefix = (ctx == "harm" or ctx == "help") and ctx or "bar"
local page   = self:GetAttribute("page") or 1
local bar    = opener:GetAttribute(prefix .. page) or 1
local p      = self:GetAttribute("pageofbar" .. bar)
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
local unit = self:GetAttribute("unit")
for i = 1, $SLICES do
	local slice = self:GetFrameRef("slice" .. i)
	slice:RunAttribute("UpdateState", p)
	slice:SetAttribute("unit", unit)
	slice:CallMethod("UpdateAction")
end
]])

-- Header attribute "StepPage" (arguments: step, source): move the wheel page
-- of the active trigger's list for the current context by step, wrapping.
local STEP_PAGE = [[
local step, via = ...
local opener = self:GetFrameRef("opener" .. (self:GetAttribute("active") or 1))
local ctx    = self:GetAttribute("context") or "none"
local prefix = (ctx == "harm" or ctx == "help") and ctx or "bar"
local n      = opener:GetAttribute(prefix .. "count") or 1
local page   = self:GetAttribute("page") or 1
page = ((page - 1 + step) % n) + 1
self:SetAttribute("page", page)
self:RunAttribute("ApplyPage")
if self:GetAttribute("debug") then print("|cff33ff99RR secure|r page " .. page .. " (wheel via " .. tostring(via) .. ")") end
]]

-- Ring _onmousewheel: the wheel while the cursor is over the ring. The ring
-- is the topmost wheel-enabled frame there, so the event never reaches a chat
-- or scroll frame underneath, and each notch arrives exactly once, as a delta.
local RING_WHEEL = [[
local hdr = self:GetFrameRef("header")
if not hdr:GetAttribute("open") then return end
hdr:RunAttribute("StepPage", (delta > 0) and -1 or 1, "ring")
]]

-- Header attribute "OpenRing" (arguments: trigger index, context): show the ring
-- at the cursor on page 1 of that trigger's bars for the context, capture the
-- wheel and Escape, and in tap mode arm auto-hide. Registered after Show so
-- the driver sees the ring's rect at its new position, with the cursor
-- inside it.
local OPEN = [[
local me, ctx = ...
local opener = self:GetFrameRef("opener" .. me)
local ring   = self:GetFrameRef("ring")
local unit   = opener:GetAttribute("capture")
if ctx == "none" or unit == "none" then unit = nil end
self:SetAttribute("active", me)
self:SetAttribute("context", ctx)
self:SetAttribute("unit", unit)
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

-- Header attribute "CloseRing": hide the ring; its _onhide does the rest. The
-- state is also reset here so Close is safe when the ring is already hidden.
local CLOSE = [[
self:SetAttribute("open", false)
self:ClearBindings()
self:GetFrameRef("ring"):Hide()
]]

-- Ring _onhide: runs for every hide, secure or not (CloseRing, Escape, auto-hide,
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
			hdr:RunAttribute("CloseRing")
			if debug then print("|cff33ff99RR secure|r press: trigger " .. me .. " closed the open ring") end
			return false
		end
		-- tap mode, second press: in the dead zone or past the cancel radius
		-- it cancels; anywhere else the release that follows fires the slice
		-- under the cursor
		local idx, _, zone = hdr:RunAttribute("Resolve")
		if not idx then
			hdr:RunAttribute("CloseRing")
			if debug then print("|cff33ff99RR secure|r press: cancelled " .. (zone == "outside" and "past the cancel radius" or "in the dead zone")) end
		end
		return false
	end
	if (self:GetAttribute("barcount") or 0) < 1 then return false end

	-- context: what is under the cursor, and does this trigger have a ring for it?
	local ctx = "none"
	if UnitExists("mouseover") and not UnitIsDead("mouseover") then
		if PlayerCanAttack("mouseover") then
			ctx = "harm"
		elseif PlayerCanAssist("mouseover") then
			ctx = "help"
		end
	end
	if ctx ~= "none" and (self:GetAttribute(ctx .. "count") or 0) < 1 then ctx = "none" end

	hdr:RunAttribute("OpenRing", me, ctx)
	if debug then print("|cff33ff99RR secure|r press: trigger " .. me .. " opened the " .. ctx .. " ring at cursor") end

	local capture = self:GetAttribute("capture") or "none"
	if ctx ~= "none" and capture ~= "none" then
		-- Capture on press: this down click is a hardware event, so let
		-- Blizzard's handler run a macro on it. The release resets useOnKeyDown.
		-- The handler drops the whole click when the button's "unit" names a
		-- unit that does not exist, and "unit" still holds what the last
		-- release aimed at ("target" after a target-capture ring), so clear
		-- it first: with no current target, the capture never ran. "macro"
		-- goes too: the handler runs a named macro before it looks at
		-- macrotext, and a macro slice's release leaves one behind.
		self:SetAttribute("unit", nil)
		self:SetAttribute("macro", nil)
		self:SetAttribute("useOnKeyDown", true)
		self:SetAttribute("type", "macro")
		self:SetAttribute("macrotext", "/" .. capture .. " [@mouseover,exists,nodead]")
		if debug then print("|cff33ff99RR secure|r press: capturing mouseover as " .. capture) end
		return
	end
	return false
end

-- release: fire on the up click whatever the down click did
self:SetAttribute("useOnKeyDown", false)

if not hdr:GetAttribute("open") or hdr:GetAttribute("active") ~= me then return false end

local idx, r, zone = hdr:RunAttribute("Resolve")
if idx then
	hdr:RunAttribute("CloseRing")
	-- The slice's type and the attribute that type reads (LibActionButton's
	-- UpdateState names it in action_field: "action", "spell", "item" or
	-- "macro") become the opener's. macrotext is cleared so a macro slice
	-- never falls back to the capture macro, and an empty slice leaves a
	-- type Blizzard's handler ignores.
	local slice = hdr:GetFrameRef("slice" .. idx)
	local kind  = slice:GetAttribute("type") or "empty"
	local field = slice:GetAttribute("action_field") or "action"
	local value = slice:GetAttribute(field)
	self:SetAttribute("type", kind)
	self:SetAttribute("macrotext", nil)
	self:SetAttribute(field, value)
	self:SetAttribute("unit", slice:GetAttribute("unit"))
	if debug then
		print("|cff33ff99RR secure|r release: slice " .. idx .. " -> " .. (kind == "action" and "slot" or kind) .. " " .. tostring(value) .. " (r=" .. floor(r) .. ")")
	end
	return
end

if zone == "dead" and self:GetAttribute("mode") == "tap" then
	if debug then print("|cff33ff99RR secure|r release: tap, ring stays open") end
	return false
end

-- the dead zone in hold mode, or past the cancel radius in either mode
hdr:RunAttribute("CloseRing")
self:SetAttribute("type", nil)
self:SetAttribute("unit", nil)
if debug then
	print("|cff33ff99RR secure|r release: cancelled " .. (zone == "outside" and "past the cancel radius" or "in the dead zone")
		.. " (r=" .. tostring(r and floor(r)) .. ")")
end
return false
]]

-- Header _onclick: receives the override-bound wheel and Escape "clicks".
-- The wheel binding is the fallback for a cursor outside the ring's rect; a
-- bound key clicks on its press and again on its release, so only the press
-- counts.
local HEADER_CLICK = [[
if not down then return end
if not self:GetAttribute("open") then return end
if button == "cancel" then
	self:RunAttribute("CloseRing")
	if self:GetAttribute("debug") then print("|cff33ff99RR secure|r cancelled with Escape") end
elseif button == "wheelup" or button == "wheeldown" then
	self:RunAttribute("StepPage", (button == "wheeldown") and 1 or -1, "binding")
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
	opener:HookScript("OnClick", function(self, button, down)
		if not (ns.db and ns.db.debug) then return end
		-- After a capturing press, say what the macro left behind.
		if down and self:GetAttribute("useOnKeyDown") == true then   -- only a capturing press turns this on
			ns.Debug("opener %d click: %s down | after capture: target %s, focus %s",
				i, tostring(button), ns.UnitReport("target"), ns.UnitReport("focus"))
		else
			ns.Debug("opener %d click: %s %s", i, tostring(button), down and "down" or "up")
		end
	end)
	openers[i] = opener
end

-- Wiring
SecureHandlerSetFrameRef(header, "ring", ns.ring)
SecureHandlerSetFrameRef(header, "screen", ns.screen)
for i, slice in ipairs(ns.slices) do
	SecureHandlerSetFrameRef(header, "slice" .. i, slice)
end
-- Attribute names are case-insensitive in the client, so a snippet must never
-- share a name with a state flag: "Open" and "open" are the same attribute,
-- and 0.3.0 shipped with the flag overwriting the snippet.
header:SetAttribute("Resolve", RESOLVE)
header:SetAttribute("ApplyPage", APPLY_PAGE)
header:SetAttribute("StepPage", STEP_PAGE)
header:SetAttribute("OpenRing", OPEN)
header:SetAttribute("CloseRing", CLOSE)
header:SetAttribute("_onclick", HEADER_CLICK)
header:SetAttribute("open", false)
header:SetAttribute("active", 1)
header:SetAttribute("context", "none")
header:SetAttribute("page", 1)

SecureHandlerSetFrameRef(ns.ring, "header", header)
ns.ring:SetAttribute("_onhide", RING_HIDE)
ns.ring:SetAttribute("_onmousewheel", RING_WHEEL)
ns.ring:HookScript("OnMouseWheel", function(_, delta)
	ns.Debug("ring wheel: %s", tostring(delta))
end)

header:SetScript("OnAttributeChanged", function(_, name)
	if name == "page" or name == "active" or name == "context" then ns.UpdateLabel() end
end)

header:HookScript("OnClick", function(_, button, down)
	ns.Debug("header click: %s %s", tostring(button), down and "down" or "up")
end)

ns.openers, ns.header, ns.bindOwner = openers, header, bindOwner
