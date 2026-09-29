-------------------------------------------------------------------------------
-- Radical Radial — Unit frames
--
-- A mouse-button binding only fires while the cursor is over the world or
-- over a frame that ignores the mouse. A unit frame takes every mouse button,
-- including the ones it registers no click for, so over a unit frame the
-- trigger never reached the opener; a keyboard trigger did, because keys go
-- through the bindings whatever is under the cursor. This file hands the
-- trigger to unit frames the way click-cast addons take their clicks: each
-- frame's OnClick is wrapped, out of combat, with a snippet the header runs,
-- and the frame carries two attributes per trigger that make Blizzard's own
-- unit-button handler click the trigger's macro opener under a virtual
-- button name ("RadicalRadial1"), on the same hardware event, in combat.
--
-- From there the click is the single click a "/click RadicalRadialMacro1"
-- macro delivers (Secure.lua): the first opens the ring at the cursor,
-- waiting, and captures the frame's unit (the frame's unit is the mouseover,
-- so the same capture macro serves); the ring takes the mouse, so the next
-- click on a slice fires it, a right click cancels, and the ring hides
-- itself after the trigger's auto-hide delay once the cursor has left it.
-- A click on another unit frame while the ring waits goes the same way: a
-- slice under it fires, the centre or anywhere past the cancel radius
-- cancels. A frame only reports a click that starts and ends on it, so a
-- press that leaves the frame before its release is no click at all: that
-- is why the ring waits rather than follows a press-move-release, in either
-- mode. A frame registered for both halves of a click reports the click
-- twice; the first half acts and the second is dropped, so press-only,
-- release-only and both-halves frames behave alike.
--
-- Frames: Blizzard's player, pet, target, focus, party, boss and arena frames
-- by name (re-registered for AnyUp, since Blizzard registers only the left
-- and right buttons on them and a frame reports no click for a button it
-- has not registered), the compact party and raid frames through a hook on
-- CompactUnitFrame_SetUpFrame (they register AnyUp themselves), and any
-- frame another addon lists in the ClickCastFrames table (the oUF, ElvUI
-- and Clique convention; those keep their own click registration). Wrapping
-- never changes what a frame's other buttons do.
-------------------------------------------------------------------------------

local ADDON, ns = ...

local header, macroOpeners = ns.header, ns.macroOpeners

-------------------------------------------------------------------------------
-- The snippet: wrapped around each unit frame's OnClick. `self` is the frame,
-- `control` the header. Returning false swallows the click, a string renames
-- the button for Blizzard's handler, nothing lets the click through as it is.
-------------------------------------------------------------------------------

local UNIT_CLICK = ([[
local hdr = control

-- Which trigger has this button as its key? The exact chord first, then the
-- bare button, the way the client falls back for bindings.
local mods = (IsAltKeyDown() and "alt-" or "") .. (IsControlKeyDown() and "ctrl-" or "") .. (IsShiftKeyDown() and "shift-" or "")
local me
for pass = 1, 2 do
	local want = (pass == 1) and mods or ""
	for i = 1, $TRIGGERS do
		local o = hdr:GetFrameRef("opener" .. i)
		if o and o:GetAttribute("mousebutton") == button and (o:GetAttribute("mousemods") or "") == want then
			me = i
			break
		end
	end
	if me then break end
end
if not me then return end   -- not a trigger: the frame handles the click as usual

-- Both halves of one click: the first acts, the second is dropped.
if down then
	self:SetAttribute("radicalradial-pressed", true)
elseif self:GetAttribute("radicalradial-pressed") then
	self:SetAttribute("radicalradial-pressed", nil)
	return false
end
if hdr:GetAttribute("debug") then
	print("|cff33ff99RR secure|r unit frame: trigger " .. me .. " " .. (down and "pressed" or "released") .. ", handed to the macro opener")
end
-- Blizzard's handler clicks the macro opener for this button name (the
-- frame's *type- and *clickbutton- attributes, set below).
return "RadicalRadial" .. me
]]):gsub("%$TRIGGERS", tostring(ns.MAX_TRIGGERS))

-------------------------------------------------------------------------------
-- Wiring (out of combat; frames met in combat wait for it to end)
-------------------------------------------------------------------------------

local wired   = setmetatable({}, { __mode = "k" })   -- frame -> "blizzard" | "compact" | "addon"
local pending = {}                                   -- frame -> kind, seen in combat
local reclick = {}                                   -- Blizzard frames re-initialised in combat
local counts  = { blizzard = 0, compact = 0, addon = 0 }

-- Nameplates are compact unit frames too, but they never take the mouse.
local function IsNamePlate(frame)
	for _ = 1, 3 do
		if not frame then return false end
		local name = frame.GetName and frame:GetName()
		if name and name:find("^NamePlate") then return true end
		frame = frame.GetParent and frame:GetParent()
	end
	return false
end

local function IsUnitButton(frame)
	return type(frame) == "table" and type(frame.RegisterForClicks) == "function"
		and type(frame.SetAttribute) == "function" and not IsNamePlate(frame)
end

local function Wire(frame, kind)
	if wired[frame] then return true end
	if InCombatLockdown() then
		pending[frame] = kind
		return false
	end
	pending[frame] = nil
	for i = 1, ns.MAX_TRIGGERS do
		-- "*": with or without modifiers, since the trigger's chord is held.
		frame:SetAttribute("*type-RadicalRadial" .. i, "click")
		frame:SetAttribute("*clickbutton-RadicalRadial" .. i, macroOpeners[i])
	end
	SecureHandlerWrapScript(frame, "OnClick", header, UNIT_CLICK)
	if kind == "blizzard" then frame:RegisterForClicks("AnyUp") end
	wired[frame] = kind
	counts[kind] = counts[kind] + 1
	ns.Debug("unit frame wired: %s (%s)", tostring(frame:GetName() or "unnamed"), kind)
	return true
end

-- Blizzard's frames, by name and by key on the party frame (12.x names its
-- party members by key only).
local BLIZZARD = {
	"PlayerFrame", "PetFrame", "TargetFrame", "TargetFrameToT", "FocusFrame", "FocusFrameToT",
	"PartyMemberFrame1", "PartyMemberFrame2", "PartyMemberFrame3", "PartyMemberFrame4",
	"PartyMemberFrame1PetFrame", "PartyMemberFrame2PetFrame", "PartyMemberFrame3PetFrame", "PartyMemberFrame4PetFrame",
}
for i = 1, 8 do BLIZZARD[#BLIZZARD + 1] = "Boss" .. i .. "TargetFrame" end
for i = 1, 5 do
	BLIZZARD[#BLIZZARD + 1] = "ArenaEnemyMatchFrame" .. i
	BLIZZARD[#BLIZZARD + 1] = "ArenaEnemyMatchFrame" .. i .. "PetFrame"
end

local function BlizzardFrames(out)
	for _, name in ipairs(BLIZZARD) do
		if IsUnitButton(_G[name]) then out[#out + 1] = _G[name] end
	end
	local party = _G.PartyFrame
	if type(party) == "table" then
		for i = 1, 4 do
			local member = party["MemberFrame" .. i]
			if IsUnitButton(member) then
				out[#out + 1] = member
				if IsUnitButton(member.PetFrame) then out[#out + 1] = member.PetFrame end
			end
		end
	end
	return out
end

-- Compact frames that already exist; new ones arrive through the hook below.
local function CompactFrames(out)
	local function add(name)
		if IsUnitButton(_G[name]) then out[#out + 1] = _G[name] end
	end
	for i = 1, 5 do add("CompactPartyFrameMember" .. i); add("CompactArenaFrameMember" .. i) end
	for i = 1, 80 do add("CompactRaidFrame" .. i) end
	for g = 1, 8 do for i = 1, 5 do add("CompactRaidGroup" .. g .. "Member" .. i) end end
	return out
end

local function AddonFrames(out)
	local list = _G.ClickCastFrames
	if type(list) ~= "table" then return out end
	for frame, enabled in pairs(list) do
		if enabled and IsUnitButton(frame) then out[#out + 1] = frame end
	end
	return out
end

-- Wire every unit frame that can be found. Cheap and idempotent: it runs
-- with every ApplyConfig, on the events below, and when combat ends.
function ns.WireUnitFrames()
	for _, frame in ipairs(BlizzardFrames({})) do Wire(frame, "blizzard") end
	for _, frame in ipairs(CompactFrames({})) do Wire(frame, "compact") end
	for _, frame in ipairs(AddonFrames({})) do Wire(frame, "addon") end
	if not InCombatLockdown() then
		for frame, kind in pairs(pending) do Wire(frame, kind) end
		for frame in pairs(reclick) do
			reclick[frame] = nil
			frame:RegisterForClicks("AnyUp")
		end
	end
end

-- For /rr status: how many frames take the trigger, and how many wait for combat to end.
function ns.UnitFrameReport()
	local waiting = 0
	for _ in pairs(pending) do waiting = waiting + 1 end
	for _ in pairs(reclick) do waiting = waiting + 1 end
	return counts.blizzard, counts.compact, counts.addon, waiting
end

-- Frames other addons register, now and later. The table is the convention
-- itself; if a click-cast addon replaces it with its own, the polls above
-- still read whatever the global holds.
if type(ClickCastFrames) ~= "table" then ClickCastFrames = {} end
if getmetatable(ClickCastFrames) == nil then
	setmetatable(ClickCastFrames, { __newindex = function(list, frame, enabled)
		rawset(list, frame, enabled)
		if enabled and IsUnitButton(frame) then Wire(frame, "addon") end
	end })
end

-- Compact frames are made on demand (a raid forms); nameplates are filtered out.
if type(CompactUnitFrame_SetUpFrame) == "function" then
	hooksecurefunc("CompactUnitFrame_SetUpFrame", function(frame)
		if IsUnitButton(frame) then Wire(frame, "compact") end
	end)
end

-- Blizzard re-registers the left and right buttons whenever it initialises
-- one of its unit frames again (a party frame set up for a new member).
if type(UnitFrame_Initialize) == "function" then
	hooksecurefunc("UnitFrame_Initialize", function(frame)
		if wired[frame] ~= "blizzard" then return end
		if InCombatLockdown() then reclick[frame] = true else frame:RegisterForClicks("AnyUp") end
	end)
end

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("GROUP_ROSTER_UPDATE")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:SetScript("OnEvent", function()
	if ns.db then ns.WireUnitFrames() end
end)
