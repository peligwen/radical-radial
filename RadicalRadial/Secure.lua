-------------------------------------------------------------------------------
-- Radical Radial — Secure
--
-- The control layer: the openers (one per trigger, the bindings' targets),
-- the macro openers (one per trigger, for "/click RadicalRadialMacro<i>" on
-- an action bar), the clicker (Ring.lua; fires on a mouse click while the
-- ring waits), the header (owner of the snippets, frame refs and temporary
-- bindings) and the snippets that run in Blizzard's restricted environment.
-- In combat this layer only flips attributes, anchors, visibility and
-- bindings.
--
-- Hold mode, end to end:
--   trigger down  → wrapped OnClick: OpenRing (ring at "$cursor", page 1, wheel
--                   and Escape bindings), swallow the click
--   wheel         → ring _onmousewheel while the cursor is over the ring,
--                   header _onclick through an override binding elsewhere;
--                   both run StepPage: next/previous bar, ApplyPage
--   trigger up    → wrapped OnClick: Resolve the slice under the cursor from
--                   GetMousePosition(); Fire copies its type and its action
--                   field (action slot, spell, item or macro) onto the opener,
--                   CloseRing, and Blizzard's handler performs the action;
--                   in the dead zone the slice is the centre one when the page
--                   has it (a custom ring's default action), else it is a
--                   cancel, as is anywhere past the cancel radius: just CloseRing
--
-- Tap mode differs only at the ends: a release in the dead zone leaves the
-- ring waiting (Rest: auto-hide armed, the clicker shown if the trigger
-- wants it), a later press past the cancel radius cancels, and so does one
-- in the dead zone unless the page has a centre slice, which the release
-- then fires (the ring has been waiting, so a press has happened since the
-- opening tap: the header's "waiting" flag tells the two releases apart).
-- Every other gesture on a waiting ring (a macro click, a left click on the
-- clicker, a press-and-release on a nested ring) picks the centre slice in
-- the dead zone the same way, ahead of going back or cancelling.
--
-- A nested ring: a slice whose "subring" attribute names another ring's bar
-- code. A release (or click) on it runs OpenSub: the ring re-centres on the
-- cursor showing that ring, and waits like a tap-mode ring. A press in the
-- dead zone then goes back to the ring it came from (LeaveSub); the wheel
-- leaves it too and pages the list.
--
-- The macro opener gets one click per press of the macro (a /click is a
-- single up click; "useOnKeyDown" is set to match whichever phase arrives so
-- Blizzard's handler acts on it): the first click opens the ring, the next
-- fires the slice under the cursor. The clicker does the same for a left
-- mouse click on a waiting ring; a right click cancels.
--
-- Whatever hides the ring (CloseRing, Escape, auto-hide, /rr preview) runs the
-- ring's _onhide snippet, which resets the open state and drops the bindings.
--
-- Context rings: the opening snippet classifies the unit under the cursor
-- with macro-conditional-grade checks (PlayerCanAttack / PlayerCanAssist on
-- "mouseover"). If the trigger has bars for that context, the ring opens on
-- them, the opener runs a "/focus [@mouseover,exists,nodead]" (or /target)
-- macro on the very same click, which is a hardware event, and every slice
-- carries unit="focus" (or "target") until the ring closes.
-------------------------------------------------------------------------------

local ADDON, ns = ...

-------------------------------------------------------------------------------
-- Snippets
-------------------------------------------------------------------------------

local SNIPPET_CONSTANTS = {
	DEAD = ns.DEAD, LIMIT = ns.INNER_LIMIT, SLOTS = ns.SLICE_COUNT, MAXSLICES = ns.MAX_SLICES, PAGES = ns.PAGE_COUNT,
	CENTER = ns.CENTER, RADIUS = ns.RADIUS, INNERR = ns.INNER_R, INNERK = ns.INNER_K,
	ICONIN = ns.ICON_INNER, ICONOUT = ns.ICON_OUTER, ICONCTR = ns.ICON_CENTER, BTN = ns.BUTTON_SIZE,
}
local function Snippet(body)
	return (body:gsub("%$(%u+)", function(key)
		return tostring(assert(SNIPPET_CONSTANTS[key], "unknown snippet constant " .. key))
	end))
end

-- Header attribute "MarkPress": remember where the cursor is as the ring is
-- placed on it. The client keeps the ring on screen, so near an edge the
-- ring lands shifted inward and the cursor starts off-centre, inside a
-- sector; until the first click away from this point, Resolve treats it as
-- the dead zone, so a release (or a second press) without moving cancels
-- rather than fires. Off an edge the point is the ring's centre anyway.
local MARK_PRESS = [[
local screen = self:GetFrameRef("screen")
local fx, fy = screen:GetMousePosition()
local sl, sb, sw, sh = screen:GetRect()
if fx and sl then
	self:SetAttribute("pressx", sl + fx * sw)
	self:SetAttribute("pressy", sb + fy * sh)
else
	self:SetAttribute("pressx", nil)
	self:SetAttribute("pressy", nil)
end
]]

-- Header attribute "Resolve": slice index under the cursor, its distance and
-- the zone ("dead" or "outside" when there is no index). Distances come from
-- the screen-sized frame and the ring's rect, both in UIParent units; the
-- cancel radius is the header's "outer" attribute, a fraction of the radius;
-- the tier sizes are "incount" and "outcount", set by ApplyPage for the
-- layout on show. With no inner tier, everything past the dead zone is the
-- outer tier. The opening point (MarkPress) is a dead zone too, until the
-- cursor is found away from it.
local RESOLVE = Snippet([[
local screen = self:GetFrameRef("screen")
local ring   = self:GetFrameRef("ring")
local fx, fy = screen:GetMousePosition()
local sl, sb, sw, sh = screen:GetRect()
local l, b, w, h = ring:GetRect()
if not (fx and sl and l) then return nil end
local cx, cy = sl + fx * sw, sb + fy * sh
local dx = cx - (l + w / 2)
local dy = cy - (b + h / 2)
local R  = self:GetAttribute("radius")
local r  = math.sqrt(dx * dx + dy * dy)
if r < $DEAD * R then return nil, r, "dead" end
local px = self:GetAttribute("pressx")
if px then
	local ex, ey = cx - px, cy - self:GetAttribute("pressy")
	if math.sqrt(ex * ex + ey * ey) < $DEAD * R then return nil, r, "dead" end
	self:SetAttribute("pressx", nil)
	self:SetAttribute("pressy", nil)
end
local outer = self:GetAttribute("outer") or 0
if outer > 0 and r > outer * R then return nil, r, "outside" end
local a = (90 - deg(math.atan2(dy, dx))) % 360
local inn, out = self:GetAttribute("incount") or 0, self:GetAttribute("outcount") or 1
if inn > 0 and r < $LIMIT * R then
	return 1 + floor(((a + 180 / inn) % 360) / (360 / inn)), r
end
return inn + 1 + floor(((a + 180 / out) % 360) / (360 / out)), r
]])

-- Header attribute "ApplyPage": switch every slice to the page of the bar on
-- the current wheel page of the active trigger (or of the nested ring in
-- "sub"), and place the slices for that entry's layout. Bars 2-8 and custom
-- rings (bar codes 9 and up, a LibActionButton state each) have fixed pages,
-- set as "pageofbar" attributes by Config.lua; Bar 1 follows Blizzard's own
-- page selection for the main bar, in the same order ActionBarController
-- uses. The layout is the ring's own ("layoutofbar") or the trigger's for a
-- bar, as inner * 100 + outer; the formulas are ns.SlicePolar's (Core.lua).
-- The centre slice follows the page like the others and is shown, in the
-- middle, only when it has something (an action, or a nested ring).
local APPLY_PAGE = Snippet([[
local opener = self:GetFrameRef("opener" .. (self:GetAttribute("active") or 1))
local ctx    = self:GetAttribute("context") or "none"
local prefix = (ctx == "harm" or ctx == "help") and ctx or "bar"
local page   = self:GetAttribute("page") or 1
local bar    = self:GetAttribute("sub") or opener:GetAttribute(prefix .. page) or 1
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
self:SetAttribute("basecurrent", (p - 1) * $SLOTS + 1)
local code = self:GetAttribute("layoutofbar" .. bar) or opener:GetAttribute("layout") or 408
local inn, out = floor(code / 100), code % 100
self:SetAttribute("incount", inn)
self:SetAttribute("outcount", out)
local fr = math.max($INNERR, $INNERK * inn)
local visual = self:GetFrameRef("visual")
local unit = self:GetAttribute("unit")
for i = 1, $MAXSLICES do
	-- every slice follows the page, shown or not, so none keeps a stale action
	local slice = self:GetFrameRef("slice" .. i)
	slice:RunAttribute("UpdateState", p)
	slice:SetAttribute("unit", unit)
	slice:CallMethod("UpdateAction")
	if i <= inn + out then
		local angle, fraction, size
		if i <= inn then
			angle, fraction, size = (i - 1) * (360 / inn), fr, $ICONIN
		else
			angle, fraction, size = (i - inn - 1) * (360 / out), 1, $ICONOUT
		end
		local s = size / $BTN
		slice:SetScale(s)
		slice:ClearAllPoints()
		slice:SetPoint("CENTER", visual, "CENTER",
			math.sin(math.rad(angle)) * $RADIUS * fraction / s,
			math.cos(math.rad(angle)) * $RADIUS * fraction / s)
		slice:SetAttribute("subring", slice:GetAttribute("sub-" .. p))
		slice:Show()
	else
		slice:SetAttribute("subring", nil)
		slice:Hide()
	end
end
local centre = self:GetFrameRef("slice$CENTER")
centre:RunAttribute("UpdateState", p)
centre:SetAttribute("unit", unit)
centre:CallMethod("UpdateAction")
local csub = centre:GetAttribute("sub-" .. p)
centre:SetAttribute("subring", csub)
if csub or (centre:GetAttribute("type") or "empty") ~= "empty" then
	local s = $ICONCTR / $BTN
	centre:SetScale(s)
	centre:ClearAllPoints()
	centre:SetPoint("CENTER", visual, "CENTER", 0, 0)
	centre:Show()
else
	centre:Hide()
end
]])

-- Header attribute "HasCentre": does the page showing have a centre slice,
-- an action or a nested ring in the ring's centre slot? (ApplyPage shows the
-- centre slice exactly then.)
local HAS_CENTRE = Snippet([[
local centre = self:GetFrameRef("slice$CENTER")
return centre:GetAttribute("subring") ~= nil or (centre:GetAttribute("type") or "empty") ~= "empty"
]])

-- Header attribute "StepPage" (arguments: step, source): move the wheel page
-- of the active trigger's list for the current context by step, wrapping.
-- From a nested ring the wheel first goes back to the ring it came from.
local STEP_PAGE = [[
local step, via = ...
local opener = self:GetFrameRef("opener" .. (self:GetAttribute("active") or 1))
local ctx    = self:GetAttribute("context") or "none"
local prefix = (ctx == "harm" or ctx == "help") and ctx or "bar"
local debug  = self:GetAttribute("debug")
if self:GetAttribute("sub") then
	self:SetAttribute("sub", nil)
	self:RunAttribute("ApplyPage")
	if debug then print("|cff33ff99RR secure|r left the nested ring (wheel via " .. tostring(via) .. ")") end
	return
end
local n      = opener:GetAttribute(prefix .. "count") or 1
local page   = self:GetAttribute("page") or 1
page = ((page - 1 + step) % n) + 1
self:SetAttribute("page", page)
self:RunAttribute("ApplyPage")
if debug then print("|cff33ff99RR secure|r page " .. page .. " (wheel via " .. tostring(via) .. ")") end
]]

-- Ring (and clicker) _onmousewheel: the wheel while the cursor is over the
-- ring. The ring is the topmost wheel-enabled frame there, so the event
-- never reaches a chat or scroll frame underneath, and each notch arrives
-- exactly once, as a delta.
local RING_WHEEL = [[
local hdr = self:GetFrameRef("header")
if not hdr:GetAttribute("open") then return end
hdr:RunAttribute("StepPage", (delta > 0) and -1 or 1, "ring")
]]

-- Header attribute "Rest": the ring stays open with no button held (a tap,
-- a nested ring, the macro). Arm auto-hide, and give the ring the mouse
-- when a click is meant to fire it. Registered after Show so the driver
-- sees the ring's rect at its new position, with the cursor inside it.
-- "waiting" records the state for the release that follows a later press
-- (the centre slice, above) and for the presentation's highlight.
local REST = [[
local opener = self:GetFrameRef("opener" .. (self:GetAttribute("active") or 1))
local ring   = self:GetFrameRef("ring")
local ttl    = opener:GetAttribute("autohide") or 0
self:SetAttribute("waiting", true)
if ttl > 0 then ring:RegisterAutoHide(ttl) end
if self:GetAttribute("via") == "macro" or opener:GetAttribute("clickfire") then
	self:GetFrameRef("clicker"):Show()
end
]]

-- Header attribute "OpenRing" (arguments: trigger index, context, how it was
-- opened: "key" or "macro"): show the ring at the cursor on page 1 of that
-- trigger's bars for the context and capture the wheel and Escape. A macro
-- ring waits from the start (Rest). In tap mode auto-hide is armed here,
-- while the trigger is still held: the ring only takes the mouse once the
-- opening release has left it waiting, so that release still reaches the
-- trigger's binding.
local OPEN = [[
local me, ctx, via = ...
local opener = self:GetFrameRef("opener" .. me)
local ring   = self:GetFrameRef("ring")
local unit   = opener:GetAttribute("capture")
if ctx == "none" or unit == "none" then unit = nil end
self:SetAttribute("active", me)
self:SetAttribute("context", ctx)
self:SetAttribute("unit", unit)
self:SetAttribute("via", via or "key")
self:SetAttribute("sub", nil)
self:SetAttribute("waiting", false)
self:SetAttribute("page", 1)
self:RunAttribute("ApplyPage")
self:GetFrameRef("clicker"):Hide()
ring:ClearAllPoints()
ring:SetPoint("CENTER", "$cursor")
ring:Show()
self:RunAttribute("MarkPress")
self:SetAttribute("open", true)
self:SetBindingClick(true, "MOUSEWHEELUP",   "RadicalRadialHeader", "wheelup")
self:SetBindingClick(true, "MOUSEWHEELDOWN", "RadicalRadialHeader", "wheeldown")
self:SetBindingClick(true, "ESCAPE",         "RadicalRadialHeader", "cancel")
if via == "macro" then
	self:RunAttribute("Rest")
else
	local ttl = opener:GetAttribute("autohide") or 0
	if opener:GetAttribute("mode") == "tap" and ttl > 0 then
		ring:RegisterAutoHide(ttl)
	end
end
]]

-- Header attribute "OpenSub" (argument: the nested ring's bar code): show
-- that ring at the cursor, waiting, in place of the current page.
local OPEN_SUB = [[
local code = ...
local ring = self:GetFrameRef("ring")
self:SetAttribute("sub", code)
self:RunAttribute("ApplyPage")
ring:ClearAllPoints()
ring:SetPoint("CENTER", "$cursor")
self:RunAttribute("MarkPress")
self:RunAttribute("Rest")
]]

-- Header attribute "LeaveSub": back from a nested ring to the page it came
-- from, at the cursor, still waiting.
local LEAVE_SUB = [[
local ring = self:GetFrameRef("ring")
self:SetAttribute("sub", nil)
self:RunAttribute("ApplyPage")
ring:ClearAllPoints()
ring:SetPoint("CENTER", "$cursor")
self:RunAttribute("MarkPress")
self:RunAttribute("Rest")
]]

-- Header attribute "CloseRing": hide the ring; its _onhide does the rest. The
-- state is also reset here so Close is safe when the ring is already hidden.
local CLOSE = [[
self:SetAttribute("open", false)
self:SetAttribute("sub", nil)
self:SetAttribute("waiting", false)
self:SetAttribute("pressx", nil)
self:SetAttribute("pressy", nil)
self:ClearBindings()
self:GetFrameRef("ring"):Hide()
]]

-- Ring _onhide: runs for every hide, secure or not (CloseRing, Escape, auto-hide,
-- /rr preview). `self` is the ring.
local RING_HIDE = [[
local hdr = self:GetFrameRef("header")
hdr:SetAttribute("open", false)
hdr:SetAttribute("sub", nil)
hdr:SetAttribute("waiting", false)
hdr:SetAttribute("pressx", nil)
hdr:SetAttribute("pressy", nil)
hdr:ClearBindings()
self:UnregisterAutoHide()
]]

-- Header attribute "Fire" (arguments: the frame ref of the button that was
-- clicked, slice index): make that button perform the slice. The slice's
-- type and the attribute that type reads (LibActionButton's UpdateState
-- names it in action_field: "action", "spell", "item" or "macro") become the
-- button's. macrotext is cleared so a macro slice never falls back to the
-- capture macro, and an empty slice leaves a type Blizzard's handler
-- ignores. Returns the kind and value for the debug line.
local FIRE = [[
local ref, idx = ...
local target = self:GetFrameRef(ref)
local slice  = self:GetFrameRef("slice" .. idx)
local kind   = slice:GetAttribute("type") or "empty"
local field  = slice:GetAttribute("action_field") or "action"
local value  = slice:GetAttribute(field)
target:SetAttribute("type", kind)
target:SetAttribute("macrotext", nil)
target:SetAttribute(field, value)
target:SetAttribute("unit", slice:GetAttribute("unit"))
return kind, value
]]

-- Header attribute "Pick" (arguments: the clicked button's frame ref, the
-- source for the debug line): what a firing click on a waiting or held ring
-- does with the slice under the cursor. Returns "fire" when the button
-- should perform its action (Fire ran and the ring closed), else nil after
-- opening a nested ring, going back from one, or cancelling. In the dead
-- zone the centre slice is picked when the page has one; else a dead-zone
-- click in a nested ring goes back; in tap mode, on the opening release,
-- the caller handles the dead zone itself.
local PICK = Snippet([[
local ref, via = ...
local debug = self:GetAttribute("debug")
local idx, r, zone = self:RunAttribute("Resolve")
if not idx and zone == "dead" and self:RunAttribute("HasCentre") then idx = $CENTER end
if idx then
	local what = idx == $CENTER and "the centre" or ("slice " .. idx)
	local sub = self:GetFrameRef("slice" .. idx):GetAttribute("subring")
	if sub then
		self:RunAttribute("OpenSub", sub)
		if debug then print("|cff33ff99RR secure|r " .. via .. ": " .. what .. " opens nested ring code " .. sub) end
		return nil
	end
	self:RunAttribute("CloseRing")
	local kind, value = self:RunAttribute("Fire", ref, idx)
	if debug then
		print("|cff33ff99RR secure|r " .. via .. ": " .. what .. " -> " .. (kind == "action" and "slot" or kind) .. " " .. tostring(value) .. " (r=" .. floor(r) .. ")")
	end
	return "fire"
end
if zone == "dead" and self:GetAttribute("sub") then
	self:RunAttribute("LeaveSub")
	if debug then print("|cff33ff99RR secure|r " .. via .. ": back from the nested ring") end
	return nil
end
self:RunAttribute("CloseRing")
if debug then
	print("|cff33ff99RR secure|r " .. via .. ": cancelled " .. (zone == "outside" and "past the cancel radius" or "in the dead zone")
		.. " (r=" .. tostring(r and floor(r)) .. ")")
end
return nil
]])

-- Wrapped around each opener's OnClick. `self` is the opener, `control` the
-- header; `button` and `down` come from the click. Returning false tells the
-- wrap machinery to skip Blizzard's click handler entirely; returning nothing
-- lets it run with the attributes we just set.
local PRE_CLICK = [[
local hdr   = control
local me    = self:GetAttribute("trigger")
local debug = hdr:GetAttribute("debug")

if down then
	self:SetAttribute("swallowup", nil)
	if hdr:GetAttribute("open") then
		if hdr:GetAttribute("active") ~= me then
			-- another trigger's ring is open: cancel it, swallow this press
			hdr:RunAttribute("CloseRing")
			if debug then print("|cff33ff99RR secure|r press: trigger " .. me .. " closed the open ring") end
			return false
		end
		-- the ring is waiting (tap mode, or a nested ring): a press in the
		-- dead zone lets the release fire the centre slice when the page has
		-- one, else goes back from a nested ring or cancels; one past the
		-- cancel radius cancels; anywhere else the release that follows fires
		-- the slice under the cursor
		local idx, _, zone = hdr:RunAttribute("Resolve")
		if not idx then
			if zone == "dead" and hdr:RunAttribute("HasCentre") then
				if debug then print("|cff33ff99RR secure|r press: in the centre, the release fires the centre slice") end
			elseif zone == "dead" and hdr:GetAttribute("sub") then
				hdr:RunAttribute("LeaveSub")
				self:SetAttribute("swallowup", true)
				if debug then print("|cff33ff99RR secure|r press: back from the nested ring") end
			else
				hdr:RunAttribute("CloseRing")
				if debug then print("|cff33ff99RR secure|r press: cancelled " .. (zone == "outside" and "past the cancel radius" or "in the dead zone")) end
			end
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

	hdr:RunAttribute("OpenRing", me, ctx, "key")
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

if self:GetAttribute("swallowup") then
	self:SetAttribute("swallowup", nil)
	return false
end
if not hdr:GetAttribute("open") or hdr:GetAttribute("active") ~= me then return false end

if self:GetAttribute("mode") == "tap" and not hdr:GetAttribute("sub") then
	-- the opening tap: a release in the dead zone leaves the ring waiting.
	-- Once it waits, a press has happened since, and a release in the dead
	-- zone picks the centre slice when the page has one (Pick); with no
	-- centre it leaves the ring waiting as before. The rest is Pick's
	local idx, _, zone = hdr:RunAttribute("Resolve")
	if not idx and zone == "dead" and not (hdr:GetAttribute("waiting") and hdr:RunAttribute("HasCentre")) then
		hdr:RunAttribute("Rest")
		if debug then print("|cff33ff99RR secure|r release: tap, ring stays open") end
		return false
	end
end

if hdr:RunAttribute("Pick", "opener" .. me, "release") == "fire" then
	return
end
self:SetAttribute("type", nil)
self:SetAttribute("unit", nil)
return false
]]

-- Wrapped around each macro opener's OnClick: one click per press of the
-- macro on an action bar. `self` is the macro opener; the trigger's settings
-- are on its key opener.
local MACRO_CLICK = [[
local hdr    = control
local me     = self:GetAttribute("trigger")
local opener = hdr:GetFrameRef("opener" .. me)
local debug  = hdr:GetAttribute("debug")

-- a /click is one click, up (the usual) or down; act on whichever this is
self:SetAttribute("useOnKeyDown", down and true or false)

if hdr:GetAttribute("open") then
	if hdr:GetAttribute("active") ~= me then
		hdr:RunAttribute("CloseRing")
		if debug then print("|cff33ff99RR secure|r macro: trigger " .. me .. " closed the open ring") end
		return false
	end
	if hdr:RunAttribute("Pick", "macro" .. me, "macro") == "fire" then
		return
	end
	self:SetAttribute("type", nil)
	self:SetAttribute("unit", nil)
	return false
end
if (opener:GetAttribute("barcount") or 0) < 1 then return false end

local ctx = "none"
if UnitExists("mouseover") and not UnitIsDead("mouseover") then
	if PlayerCanAttack("mouseover") then
		ctx = "harm"
	elseif PlayerCanAssist("mouseover") then
		ctx = "help"
	end
end
if ctx ~= "none" and (opener:GetAttribute(ctx .. "count") or 0) < 1 then ctx = "none" end

hdr:RunAttribute("OpenRing", me, ctx, "macro")
if debug then print("|cff33ff99RR secure|r macro: trigger " .. me .. " opened the " .. ctx .. " ring at cursor") end

local capture = opener:GetAttribute("capture") or "none"
if ctx ~= "none" and capture ~= "none" then
	-- capture on the opening click, as the key opener does on its press
	self:SetAttribute("unit", nil)
	self:SetAttribute("macro", nil)
	self:SetAttribute("type", "macro")
	self:SetAttribute("macrotext", "/" .. capture .. " [@mouseover,exists,nodead]")
	if debug then print("|cff33ff99RR secure|r macro: capturing mouseover as " .. capture) end
	return
end
return false
]]

-- Wrapped around the clicker's OnClick: a mouse click on a waiting ring. A
-- right click cancels (or goes back from a nested ring); any other button
-- fires the slice under the cursor. Only up clicks are registered.
local CLICKER_CLICK = [[
local hdr   = control
local debug = hdr:GetAttribute("debug")
if down or not hdr:GetAttribute("open") then return false end
if button == "RightButton" then
	if hdr:GetAttribute("sub") then
		hdr:RunAttribute("LeaveSub")
		if debug then print("|cff33ff99RR secure|r click: right, back from the nested ring") end
	else
		hdr:RunAttribute("CloseRing")
		if debug then print("|cff33ff99RR secure|r click: right, cancelled") end
	end
	return false
end
if hdr:RunAttribute("Pick", "clicker", "click") == "fire" then
	return
end
self:SetAttribute("type", nil)
self:SetAttribute("unit", nil)
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
-- Blizzard's handler does with them. The macro openers take the single
-- click a "/click RadicalRadialMacro<i>" macro delivers.
local openers, macroOpeners = {}, {}
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

	local macro = CreateFrame("Button", "RadicalRadialMacro" .. i, UIParent, "SecureActionButtonTemplate")
	macro:RegisterForClicks("AnyDown", "AnyUp")
	macro:SetAttribute("useOnKeyDown", false)
	macro:SetAttribute("trigger", i)
	macro:SetSize(1, 1)
	macro:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", -8, -8)
	macro:SetAlpha(0)
	SecureHandlerSetFrameRef(header, "macro" .. i, macro)
	SecureHandlerWrapScript(macro, "OnClick", header, MACRO_CLICK)
	macro:HookScript("OnClick", function(_, button, down)
		ns.Debug("macro opener %d click: %s %s", i, tostring(button), down and "down" or "up")
	end)
	macroOpeners[i] = macro
end

-- Wiring
SecureHandlerSetFrameRef(header, "ring", ns.ring)
SecureHandlerSetFrameRef(header, "screen", ns.screen)
SecureHandlerSetFrameRef(header, "visual", ns.visual)
SecureHandlerSetFrameRef(header, "clicker", ns.clicker)
for i, slice in ipairs(ns.slices) do
	SecureHandlerSetFrameRef(header, "slice" .. i, slice)
end
-- Attribute names are case-insensitive in the client, so a snippet must never
-- share a name with a state flag: "Open" and "open" are the same attribute,
-- and 0.3.0 shipped with the flag overwriting the snippet.
header:SetAttribute("Resolve", RESOLVE)
header:SetAttribute("MarkPress", MARK_PRESS)
header:SetAttribute("ApplyPage", APPLY_PAGE)
header:SetAttribute("StepPage", STEP_PAGE)
header:SetAttribute("OpenRing", OPEN)
header:SetAttribute("OpenSub", OPEN_SUB)
header:SetAttribute("LeaveSub", LEAVE_SUB)
header:SetAttribute("Rest", REST)
header:SetAttribute("CloseRing", CLOSE)
header:SetAttribute("Fire", FIRE)
header:SetAttribute("Pick", PICK)
header:SetAttribute("HasCentre", HAS_CENTRE)
header:SetAttribute("_onclick", HEADER_CLICK)
header:SetAttribute("open", false)
header:SetAttribute("active", 1)
header:SetAttribute("context", "none")
header:SetAttribute("page", 1)
header:SetAttribute("waiting", false)

SecureHandlerSetFrameRef(ns.ring, "header", header)
ns.ring:SetAttribute("_onhide", RING_HIDE)
ns.ring:SetAttribute("_onmousewheel", RING_WHEEL)
ns.ring:HookScript("OnMouseWheel", function(_, delta)
	ns.Debug("ring wheel: %s", tostring(delta))
end)

SecureHandlerSetFrameRef(ns.clicker, "header", header)
ns.clicker:SetAttribute("_onmousewheel", RING_WHEEL)
SecureHandlerWrapScript(ns.clicker, "OnClick", header, CLICKER_CLICK)
ns.clicker:HookScript("OnClick", function(_, button, down)
	ns.Debug("clicker click: %s %s", tostring(button), down and "down" or "up")
end)

header:SetScript("OnAttributeChanged", function(_, name)
	if name == "page" or name == "active" or name == "context" or name == "sub" then ns.UpdateLabel() end
end)

header:HookScript("OnClick", function(_, button, down)
	ns.Debug("header click: %s %s", tostring(button), down and "down" or "up")
end)

ns.openers, ns.macroOpeners, ns.header, ns.bindOwner = openers, macroOpeners, header, bindOwner
