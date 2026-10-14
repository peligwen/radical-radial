-------------------------------------------------------------------------------
-- Radical Radial — Ranks
--
-- Spells on Forever come in ranks, and every rank is a spell id of its own.
-- A ring slice holds a spell by id (Rings.lua) and so does an action slot,
-- so training a new rank leaves both pointing at the old one. When the
-- client reports a newly learned spell (LEARNED_SPELL_IN_SKILL_LINE, or
-- LEARNED_SPELL_IN_TAB on older clients) this file looks for older ranks of
-- it, the same name and a lower rank, on every action slot and in this
-- character's rings, and asks with one popup whether to move them to the
-- new rank. Yes rewrites the ring slices (saved, then ApplyConfig) and puts
-- the new rank into the bar slots through the cursor (PickupSpell,
-- PlaceAction), which the client refuses in combat, so that part waits for
-- combat to end. A spell learned while the popup waits joins it. /rr ranks
-- runs the same search by hand, from the spell the client knows by each
-- name; /rr ranks off stops the asking. Nothing here touches a secure
-- frame.
-------------------------------------------------------------------------------

local ADDON, ns = ...

local GetSpellName = C_Spell and C_Spell.GetSpellName or function(id) return (GetSpellInfo(id)) end
local PickupSpell  = C_Spell and C_Spell.PickupSpell or PickupSpell
local PlaceAction  = PlaceAction or (C_ActionBar and C_ActionBar.PutActionInSlot)
local RequestLoadSpellData = C_Spell and C_Spell.RequestLoadSpellData

ns.POPUP_NEW_RANK = "RADICALRADIAL_NEW_RANK"
-- Seconds between the client's report and the search: time for the spell's
-- data to arrive, and for a trainer's next click to join the same offer.
ns.RANK_DELAY = 0.5

-------------------------------------------------------------------------------
-- Candidates: the spell ids an offer is about, in order, each tagged
-- "learned" (reported by the client, so new for certain) or "lookup" (the
-- spell the client knows by a name, from /rr ranks). They are kept until
-- the popup is answered, so a spell learned while it waits joins the offer
-- and a popup that could not be shown can be asked for again.
-------------------------------------------------------------------------------

local candidates = {}      -- id → "learned" | "lookup"
local order = {}           -- the ids, oldest first
local offerQueued = false  -- a search is on the timer
local waitingSlots = {}    -- bar updates accepted in combat: { slot, oldID, newID }

local function AddCandidate(id, how)
	id = tonumber(id)
	if not id then return end
	if not candidates[id] then order[#order + 1] = id end
	if candidates[id] ~= "learned" then candidates[id] = how end
end

local function ClearCandidates()
	candidates, order = {}, {}
end

-- The spell an action slot holds, or nil (empty, an item, a macro, or
-- anything the client keeps secret).
local function SlotSpell(slot)
	local kind, id = GetActionInfo(slot)
	if issecretvalue and (issecretvalue(kind) or issecretvalue(id)) then return nil end
	if kind ~= "spell" or type(id) ~= "number" then return nil end
	return id
end

-- The spell the client knows by a name (the highest rank, where the client
-- answers a name at all), or nil.
local function KnownSpellByName(name)
	if C_Spell and C_Spell.GetSpellInfo then
		local ok, info = pcall(C_Spell.GetSpellInfo, name)
		return ok and type(info) == "table" and tonumber(info.spellID) or nil
	elseif type(GetSpellInfo) == "function" then
		local ok, id = pcall(function() return (select(7, GetSpellInfo(name))) end)
		return ok and tonumber(id) or nil
	end
	return nil
end

local function Join(parts)
	local n = #parts
	if n <= 1 then return parts[1] or "" end
	return table.concat(parts, ", ", 1, n - 1) .. " and " .. parts[n]
end

local function Count(n, noun)
	return n .. " " .. noun .. (n == 1 and "" or "s")
end

-------------------------------------------------------------------------------
-- The plan: every bar slot and ring slice holding an older rank of a
-- candidate, as { slot, oldID, newID } for an action slot and { ring, slot,
-- oldID, newID } for a ring slice; the bars first in slot order, then the
-- rings in their order. It is built when the offer is made and again when
-- it is accepted, so whatever changed in between is respected.
-------------------------------------------------------------------------------

-- The candidate each name stands for: the highest rank of those sharing it
-- (the later one when the ranks cannot be read).
local function Newest()
	local byName = {}
	for _, id in ipairs(order) do
		local name = GetSpellName(id)
		if name then
			local current = byName[name]
			local rank, currentRank = ns.SpellRank(id), current and ns.SpellRank(current)
			if not current or not (rank and currentRank and rank < currentRank) then byName[name] = id end
		end
	end
	return byName
end

-- The candidate that supersedes a spell, or nil: the same name and a higher
-- rank where both ranks can be read; where they cannot, only a learned
-- candidate counts (it is new for certain), never a lookup.
local function Replacement(byName, oldID)
	local name = GetSpellName(oldID)
	local newID = name and byName[name]
	if not newID or newID == oldID then return nil end
	local oldRank, newRank = ns.SpellRank(oldID), ns.SpellRank(newID)
	if oldRank and newRank then
		if newRank <= oldRank then return nil end
	elseif candidates[newID] ~= "learned" then
		return nil
	end
	return newID
end

function ns.RankPlan()
	local byName = Newest()
	local plan = {}
	for slot = 1, ns.PAGE_COUNT * ns.SLICE_COUNT do
		local ok, id = pcall(SlotSpell, slot)
		local newID = ok and id and Replacement(byName, id)
		if newID then plan[#plan + 1] = { slot = slot, oldID = id, newID = newID } end
	end
	for _, ring in ipairs(ns.Rings()) do
		for slot = 1, ns.SLOT_COUNT do
			local s = ring.slices[slot]
			local newID = s and s.kind == "spell" and Replacement(byName, s.id)
			if newID then plan[#plan + 1] = { ring = ring, slot = slot, oldID = s.id, newID = newID } end
		end
	end
	return plan
end

-- "Bar 1 (slots 3 and 7), bar page 7 (slot 1) and the ring Heals (slot 5 and the centre)"
function ns.DescribeRankPlan(plan)
	local groups, byKey = {}, {}
	for _, e in ipairs(plan) do
		local key, label, slot, centre
		if e.ring then
			key, label = "ring " .. e.ring.name, "the ring " .. e.ring.name
			slot, centre = e.slot, e.slot == ns.CENTER
		else
			local page, i = ns.PageOfSlot(e.slot)
			key, label, slot = "page " .. page, ns.PageName(page), i
		end
		local g = byKey[key]
		if not g then
			g = { label = label, numbers = {} }
			byKey[key] = g
			groups[#groups + 1] = g
		end
		if centre then g.centre = true else g.numbers[#g.numbers + 1] = tostring(slot) end
	end
	local parts = {}
	for i, g in ipairs(groups) do
		local items = {}
		for _, n in ipairs(g.numbers) do items[#items + 1] = n end
		if g.centre then items[#items + 1] = "the centre" end
		local prefix = #g.numbers == 1 and "slot " or #g.numbers > 1 and "slots " or ""
		parts[i] = g.label .. " (" .. prefix .. Join(items) .. ")"
	end
	return Join(parts)
end

-------------------------------------------------------------------------------
-- The offer: one popup for everything the candidates supersede, and a chat
-- line per new spell saying what holds the older rank, so the record stays
-- after the popup is gone.
-------------------------------------------------------------------------------

StaticPopupDialogs[ns.POPUP_NEW_RANK] = {
	text = "%s",
	button1 = YES,
	button2 = NO,
	OnAccept = function() ns.ApplyRankUpdate() end,
	-- "override" is the popup being shown again with more to offer; the
	-- client does not call this for that with noCancelOnReuse, this is for
	-- a client without it.
	OnCancel = function(_, _, reason) if reason ~= "override" then ns.DismissRankUpdate() end end,
	noCancelOnReuse = true,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

-- Show the popup for the current candidates. False when nothing holds an
-- older rank of any of them.
function ns.OfferRankUpdate()
	local plan = ns.RankPlan()
	if #plan == 0 then return false end
	local ids, seen, learned = {}, {}, true
	for _, e in ipairs(plan) do
		if not seen[e.newID] then
			seen[e.newID] = true
			ids[#ids + 1] = e.newID
		end
		if candidates[e.newID] ~= "learned" then learned = false end
	end
	local labels = {}
	for i, id in ipairs(ids) do
		labels[i] = ns.SpellLabel(id)
		local mine, olds, seenOld = {}, {}, {}
		for _, e in ipairs(plan) do
			if e.newID == id then
				mine[#mine + 1] = e
				local old = ns.SpellSubtext(e.oldID) or "an older rank"
				if not seenOld[old] then
					seenOld[old] = true
					olds[#olds + 1] = old
				end
			end
		end
		ns.Print("%s: %s %s %s", labels[i], ns.DescribeRankPlan(mine), #mine == 1 and "holds" or "hold", Join(olds))
	end
	local places = ns.DescribeRankPlan(plan)
	local holds = #plan == 1 and "holds an older rank" or "hold older ranks"
	local them = #plan == 1 and "it" or "them"
	local message
	if learned then
		message = ("Radical Radial: you learned %s. %s%s %s; update %s to the new %s?"):format(
			Join(labels), places:sub(1, 1):upper(), places:sub(2), holds, them, #ids == 1 and "rank" or "ranks")
	else
		message = ("Radical Radial: %s %s of %s; update %s?"):format(places, holds, Join(labels), them)
	end
	if StaticPopup_Show(ns.POPUP_NEW_RANK, message) then
		ns.Print("answer the popup to update %s (/rr ranks asks again, /rr ranks off stops the asking)", them)
	else
		ns.Print("no popup free to ask with; /rr ranks asks again")
	end
	return true
end

-- The client reported a newly learned spell: remember it and, unless the
-- prompts are off, search once the timer runs (one search for a burst).
function ns.NoteLearnedSpell(id)
	id = tonumber(id)
	if not id then return end
	AddCandidate(id, "learned")
	if RequestLoadSpellData then pcall(RequestLoadSpellData, id) end
	if not ns.db or ns.db.rankPrompt == false or offerQueued then return end
	offerQueued = true
	C_Timer.After(ns.RANK_DELAY, function()
		offerQueued = false
		ns.OfferRankUpdate()
	end)
end

-- /rr ranks: take the spell the client knows by the name of every spell on
-- the bars and in the rings as a candidate, with whatever was learned and
-- not answered, and offer.
function ns.ScanRanks()
	local names, seen = {}, {}
	local function Note(id)
		local name = GetSpellName(id)
		if name and not seen[name] then
			seen[name] = true
			names[#names + 1] = name
		end
	end
	for slot = 1, ns.PAGE_COUNT * ns.SLICE_COUNT do
		local ok, id = pcall(SlotSpell, slot)
		if ok and id then Note(id) end
	end
	for _, ring in ipairs(ns.Rings()) do
		for slot = 1, ns.SLOT_COUNT do
			local s = ring.slices[slot]
			if s and s.kind == "spell" then Note(s.id) end
		end
	end
	for _, name in ipairs(names) do
		local id = KnownSpellByName(name)
		if id then AddCandidate(id, "lookup") end
	end
	if ns.OfferRankUpdate() then return true end
	ns.Print("nothing to update: no bar slot or ring slice holds an older rank of a spell this character knows")
	ClearCandidates()
	return false
end

function ns.SetRankPrompt(on)
	ns.db.rankPrompt = on and true or false
	ns.Print("asking about new spell ranks: %s%s", ns.db.rankPrompt and "on" or "off",
		ns.db.rankPrompt and "" or " (/rr ranks still looks for older ranks when you ask)")
	return true
end

-------------------------------------------------------------------------------
-- Applying the answer
-------------------------------------------------------------------------------

-- Put the new rank into the bar slots that still hold the old one, through
-- the cursor as a drag does: the slot's old content comes back on the
-- cursor, so it is cleared after each. Returns how many were placed. Out of
-- combat only (the client refuses it in combat); the caller keeps the list
-- for the end of combat.
local function PlaceRanks(entries)
	if #entries == 0 then return 0 end
	if not (PickupSpell and PlaceAction) then
		ns.Print("this client cannot place spells on the bars from an addon; drag the new rank from the spellbook yourself")
		return 0
	end
	local placed = 0
	ClearCursor()   -- whatever was held goes back where it came from
	for _, e in ipairs(entries) do
		if SlotSpell(e.slot) == e.oldID then
			PickupSpell(e.newID)
			if GetCursorInfo() == "spell" then
				PlaceAction(e.slot)
				placed = placed + 1
			end
			ClearCursor()
		end
	end
	return placed
end

-- Yes in the popup: the plan as it stands now. Ring slices change at once
-- (ApplyConfig defers the secure side in combat); bar slots change now, or
-- when combat ends.
function ns.ApplyRankUpdate()
	local plan = ns.RankPlan()
	ClearCandidates()
	local slices, slots, ranks, seen = 0, {}, 0, {}
	for _, e in ipairs(plan) do
		if not seen[e.newID] then
			seen[e.newID] = true
			ranks = ranks + 1
		end
		if e.ring then
			e.ring.slices[e.slot] = { kind = "spell", id = e.newID }
			slices = slices + 1
		else
			slots[#slots + 1] = e
		end
	end
	local placed, deferred = 0, 0
	if #slots > 0 then
		if InCombatLockdown() then
			for _, e in ipairs(slots) do waitingSlots[#waitingSlots + 1] = e end
			deferred = #slots
		else
			placed = PlaceRanks(slots)
		end
	end
	local parts = {}
	if slices > 0 then parts[#parts + 1] = Count(slices, "ring slice") end
	if placed > 0 then parts[#parts + 1] = Count(placed, "bar slot") end
	local text = #parts > 0 and ("updated " .. Join(parts) .. " to the new " .. (ranks == 1 and "rank" or "ranks")) or "nothing left to update"
	if deferred > 0 then
		text = text .. ("; %s wait%s for combat to end"):format(Count(deferred, "bar slot"), deferred == 1 and "s" or "")
	end
	ns.Print(text)
	if slices > 0 then ns.ApplyConfig() end
	return slices + placed + deferred > 0
end

-- No in the popup (or Escape): forget the offer. /rr ranks finds the same
-- older ranks again.
function ns.DismissRankUpdate()
	ClearCandidates()
end

-- For /rr status.
function ns.RankReport()
	local n = #order
	return (ns.db.rankPrompt and "on" or "off") .. (n > 0 and (", " .. Count(n, "spell") .. " waiting for an answer") or "")
		.. (#waitingSlots > 0 and (", " .. Count(#waitingSlots, "bar slot") .. " waiting for combat to end") or "")
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
-- The learned-spell event by its current name and by its older one (a
-- client knows one of the two; registering an unknown event is an error).
for _, event in ipairs({ "LEARNED_SPELL_IN_SKILL_LINE", "LEARNED_SPELL_IN_TAB" }) do
	pcall(events.RegisterEvent, events, event)
end
events:SetScript("OnEvent", function(_, event, arg1)
	if event == "PLAYER_REGEN_ENABLED" then
		if #waitingSlots == 0 then return end
		local entries = waitingSlots
		waitingSlots = {}
		local placed = PlaceRanks(entries)
		if placed > 0 then
			ns.Print("updated %s to the new rank now that combat is over", Count(placed, "bar slot"))
		else
			ns.Print("the bar slots waiting for combat to end no longer hold the older rank; nothing updated")
		end
	else
		ns.NoteLearnedSpell(arg1)
	end
end)
