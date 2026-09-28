-------------------------------------------------------------------------------
-- Radical Radial — Rings
--
-- Custom rings (M4): named rings of up to twelve direct slices, each a spell,
-- an item or a macro, that never touch an action bar. A trigger's wheel lists
-- (bars, harm, help) mix bar numbers and ring names; on the secure side a
-- ring is just another "bar" number (8 + its index) whose page is a
-- LibActionButton state past the fifteen action pages (Config.lua), so the
-- snippets page through rings and bars alike.
--
-- This file owns the data model (validation, lookup, the codec for
-- import/export, reading the cursor and action slots) and the setters the
-- slash commands and the editor share. Nothing here is secure: the setters
-- save and call ApplyConfig, which defers to the end of combat when needed.
-------------------------------------------------------------------------------

local ADDON, ns = ...

ns.MAX_RINGS  = 6          -- one LibActionButton state per ring per slice, and one checkbox per ring per list
ns.MAX_LIST   = 12         -- entries a wheel list can hold (bars and rings together)
ns.RING_KINDS = { spell = true, item = true, macro = true }
ns.NAME_MAX   = 24

local GetSpellTexture = C_Spell and C_Spell.GetSpellTexture or GetSpellTexture
local GetSpellName    = C_Spell and C_Spell.GetSpellName or function(id) return (GetSpellInfo(id)) end
local GetItemIcon     = C_Item and C_Item.GetItemIconByID or GetItemIcon
local GetItemName     = C_Item and C_Item.GetItemNameByID or function(id) return (GetItemInfo(id)) end
local PickupSpell     = C_Spell and C_Spell.PickupSpell or PickupSpell
local PickupItem      = C_Item and C_Item.PickupItem or PickupItem

-------------------------------------------------------------------------------
-- Slices and rings
--
-- slice = { kind = "spell", id = 1234 } | { kind = "item", id = 6948 } | { kind = "macro", name = "..." }
-- ring  = { name = "Utility", slices = { [1] = slice, ..., [12] = slice } }   (holes are empty slices)
-------------------------------------------------------------------------------

-- A validated copy of a slice, or nil.
function ns.ValidSlice(s)
	if type(s) ~= "table" or not ns.RING_KINDS[s.kind] then return nil end
	if s.kind == "macro" then
		if type(s.name) ~= "string" or s.name == "" then return nil end
		return { kind = "macro", name = s.name }
	end
	local id = tonumber(s.id)
	if not id or id < 1 or id ~= math.floor(id) then return nil end
	return { kind = s.kind, id = id }
end

-- Trimmed, single-spaced, at most NAME_MAX characters; nil when nothing is
-- left or the name would read as a bar number in a wheel list.
function ns.CleanRingName(name)
	if type(name) ~= "string" then return nil end
	name = name:gsub("%s+", " "):match("^ ?(.-) ?$")
	if name == "" or tonumber(name) then return nil end
	return name:sub(1, ns.NAME_MAX)
end

-- Case-insensitive lookup by name → index, ring.
function ns.FindRing(name, rings)
	rings = rings or (ns.db and ns.db.rings) or {}
	if type(name) ~= "string" then return nil end
	local key = name:lower()
	for i, ring in ipairs(rings) do
		if ring.name:lower() == key then return i, ring end
	end
	return nil
end

-- Fill in and clamp a ring so the rest of the addon never sees a bad one.
function ns.NormalizeRing(ring, fallback)
	if type(ring) ~= "table" then ring = {} end
	ring.name = ns.CleanRingName(ring.name) or fallback
	local slices = {}
	for i = 1, ns.SLICE_COUNT do
		slices[i] = ns.ValidSlice(type(ring.slices) == "table" and ring.slices[i])
	end
	ring.slices = slices
	return ring
end

function ns.NormalizeRings(rings)
	if type(rings) ~= "table" then rings = {} end
	for i = #rings, 1, -1 do
		if type(rings[i]) ~= "table" then table.remove(rings, i) end
	end
	for i = #rings, ns.MAX_RINGS + 1, -1 do table.remove(rings, i) end
	local seen = {}
	for i, ring in ipairs(rings) do
		ns.NormalizeRing(ring, "Ring " .. i)
		local key = ring.name:lower()
		while seen[key] do
			ring.name = ring.name:sub(1, ns.NAME_MAX - 2) .. " 2"
			key = ring.name:lower()
		end
		seen[key] = true
	end
	return rings
end

-- A wheel list: bar numbers 1-8 and names of existing rings, in order, at
-- most MAX_LIST of them. Ring names come back in the ring's own spelling.
function ns.CleanBars(list, rings)
	local out = {}
	for _, entry in ipairs(type(list) == "table" and list or {}) do
		local bar = tonumber(entry)
		if bar then
			if bar >= 1 and bar <= 8 and bar == math.floor(bar) then out[#out + 1] = bar end
		elseif type(entry) == "string" then
			local _, ring = ns.FindRing(entry, rings)
			if ring then out[#out + 1] = ring.name end
		end
		if #out >= ns.MAX_LIST then break end
	end
	return out
end

-- What the secure side is told for a list entry: the bar number, or 8 + the
-- ring's index. Nil for a ring that no longer exists.
function ns.BarCode(entry)
	if type(entry) == "number" then return entry end
	local index = ns.FindRing(entry)
	return index and (8 + index) or nil
end

-- "Bar 3" or the ring's name, for labels and listings.
function ns.EntryName(entry)
	if type(entry) == "number" then return ns.BAR_NAMES[entry] or ("Bar " .. tostring(entry)) end
	return tostring(entry)
end

-------------------------------------------------------------------------------
-- Describing slices (insecure API, for the editor and the listings)
-------------------------------------------------------------------------------

function ns.SliceIcon(slice)
	if not slice then return nil end
	if slice.kind == "spell" then return GetSpellTexture(slice.id) end
	if slice.kind == "item" then return GetItemIcon(slice.id) end
	return (select(2, GetMacroInfo(slice.name)))
end

function ns.SliceName(slice)
	if not slice then return "empty" end
	if slice.kind == "spell" then return GetSpellName(slice.id) or ("spell " .. slice.id) end
	if slice.kind == "item" then return GetItemName(slice.id) or ("item " .. slice.id) end
	return slice.name
end

function ns.DescribeSlice(slice)
	if not slice then return "empty" end
	if slice.kind == "macro" then return "macro " .. slice.name end
	return ("%s %d (%s)"):format(slice.kind, slice.id, ns.SliceName(slice))
end

-------------------------------------------------------------------------------
-- The cursor and the action bars as sources of slices
-------------------------------------------------------------------------------

local NOT_A_SLICE = "a ring slice can hold a spell, an item, a macro or a mount"

-- The slice for whatever is on the cursor: slice, or nil and a reason (nil
-- reason: the cursor is empty).
function ns.SliceFromCursor()
	local kind, a, b, c = GetCursorInfo()
	if not kind then return nil, nil end
	if kind == "spell" then
		return ns.ValidSlice({ kind = "spell", id = c }), NOT_A_SLICE     -- a is the spellbook slot; c is the spell id
	elseif kind == "item" then
		return ns.ValidSlice({ kind = "item", id = a }), NOT_A_SLICE
	elseif kind == "macro" then
		local name = GetMacroInfo(a)
		if not name then return nil, "that macro no longer exists" end
		return { kind = "macro", name = name }
	elseif kind == "mount" and C_MountJournal and C_MountJournal.GetMountInfoByID then
		local _, spellID = C_MountJournal.GetMountInfoByID(a)
		return ns.ValidSlice({ kind = "spell", id = spellID }), NOT_A_SLICE
	end
	return nil, NOT_A_SLICE
end

-- Put a slice on the cursor, as dragging it out of a spellbook or bag would.
function ns.PickupSlice(slice)
	if not slice then return end
	if slice.kind == "spell" and PickupSpell then
		PickupSpell(slice.id)
	elseif slice.kind == "item" and PickupItem then
		PickupItem(slice.id)
	elseif slice.kind == "macro" then
		PickupMacro(slice.name)
	end
end

-- The direct equivalent of what an action slot holds, or nil (empty slot,
-- flyout, pet action, equipment set...).
function ns.SliceFromAction(slot)
	local kind, id = GetActionInfo(slot)
	if kind == "spell" then
		return ns.ValidSlice({ kind = "spell", id = id })
	elseif kind == "item" then
		return ns.ValidSlice({ kind = "item", id = id })
	elseif kind == "macro" then
		local name = GetMacroInfo(id)
		return name and { kind = "macro", name = name } or nil
	elseif (kind == "summonmount" or kind == "mount") and C_MountJournal and C_MountJournal.GetMountInfoByID then
		local _, spellID = C_MountJournal.GetMountInfoByID(id)
		return ns.ValidSlice({ kind = "spell", id = spellID })
	end
	return nil
end

-- First action slot of a bar: page 1 for Bar 1 (what the bar shows out of
-- any stance), the fixed page for the others.
function ns.BarBaseSlot(bar)
	local page = bar == 1 and 1 or ns.PAGE_OF_BAR[bar]
	return page and ns.SlotOfPage(page, 1) or nil
end

-------------------------------------------------------------------------------
-- Import and export
--
-- RR1:<name>:<slice>,<slice>,...   twelve slices: s<spell id>, i<item id>,
-- m<macro name>, or - for empty. Names escape % , and : as %XX.
-------------------------------------------------------------------------------

local function Escape(text)
	return (text:gsub("[%%,:]", function(c) return ("%%%02X"):format(c:byte()) end))
end

local function Unescape(text)
	return (text:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end))
end

function ns.EncodeRing(ring)
	local fields = {}
	for i = 1, ns.SLICE_COUNT do
		local s = ring.slices[i]
		if not s then fields[i] = "-"
		elseif s.kind == "spell" then fields[i] = "s" .. s.id
		elseif s.kind == "item" then fields[i] = "i" .. s.id
		else fields[i] = "m" .. Escape(s.name) end
	end
	return "RR1:" .. Escape(ring.name) .. ":" .. table.concat(fields, ",")
end

-- A ring table from a string, or nil and a reason.
function ns.DecodeRing(text)
	if type(text) ~= "string" then return nil, "nothing to import" end
	text = text:match("^%s*(.-)%s*$")
	local name, body = text:match("^RR1:([^:]*):(.*)$")
	if not name then return nil, "not a Radical Radial ring string (they start with RR1:)" end
	name = ns.CleanRingName(Unescape(name))
	if not name then return nil, "the ring string has no usable name" end
	local ring = { name = name, slices = {} }
	local i = 0
	for field in (body .. ","):gmatch("([^,]*),") do
		i = i + 1
		if i > ns.SLICE_COUNT then break end
		local tag, value = field:sub(1, 1), field:sub(2)
		if tag == "s" then ring.slices[i] = ns.ValidSlice({ kind = "spell", id = tonumber(value) })
		elseif tag == "i" then ring.slices[i] = ns.ValidSlice({ kind = "item", id = tonumber(value) })
		elseif tag == "m" then ring.slices[i] = ns.ValidSlice({ kind = "macro", name = Unescape(value) })
		elseif field ~= "-" and field ~= "" then return nil, ("slice %d is not readable: %s"):format(i, field) end
	end
	return ring
end

-------------------------------------------------------------------------------
-- Setters, shared by the slash commands and the editor. Each one validates,
-- updates the saved variables, says what changed and applies.
-------------------------------------------------------------------------------

local function Ring(name)
	local index, ring = ns.FindRing(name)
	if not ring then ns.Print("no ring called %s (/rr rings lists them)", tostring(name)) end
	return index, ring
end

-- Every place a wheel list refers to a ring.
local function ForEachListEntry(fn)
	for _, t in ipairs(ns.db.triggers) do
		for _, key in ipairs({ "bars", "harm", "help" }) do
			local list = t[key]
			for i = #list, 1, -1 do
				local replacement = fn(list[i])
				if replacement == false then table.remove(list, i) elseif replacement ~= nil then list[i] = replacement end
			end
		end
	end
end

function ns.AddRing(name)
	name = ns.CleanRingName(name)
	if not name then
		ns.Print("a ring needs a name that is not a bar number")
		return nil
	end
	local _, existing = ns.FindRing(name)
	if existing then
		ns.Print("there is already a ring called %s", existing.name)
		return nil
	end
	if #ns.db.rings >= ns.MAX_RINGS then
		ns.Print("at most %d rings; remove one first", ns.MAX_RINGS)
		return nil
	end
	local ring = ns.NormalizeRing({ name = name }, name)
	table.insert(ns.db.rings, ring)
	ns.Print("ring %s added; drag spells, items or macros onto it in /rr, or /rr ring fill %s BAR", name, name)
	ns.ApplyConfig()
	return #ns.db.rings
end

function ns.RemoveRing(name)
	local index, ring = Ring(name)
	if not ring then return false end
	table.remove(ns.db.rings, index)
	ForEachListEntry(function(entry) if entry == ring.name then return false end end)
	for _, t in ipairs(ns.db.triggers) do
		if #t.bars == 0 then t.bars[1] = 1 end
	end
	ns.Print("ring %s removed", ring.name)
	ns.ApplyConfig()
	return true
end

function ns.RenameRing(name, newName)
	local _, ring = Ring(name)
	if not ring then return false end
	newName = ns.CleanRingName(newName)
	if not newName then
		ns.Print("a ring needs a name that is not a bar number")
		return false
	end
	local otherIndex, other = ns.FindRing(newName)
	if other and other ~= ring then
		ns.Print("there is already a ring called %s", other.name)
		return false
	end
	local old = ring.name
	ring.name = newName
	ForEachListEntry(function(entry) if entry == old then return newName end end)
	if old ~= newName then ns.Print("ring %s renamed to %s", old, newName) end
	ns.ApplyConfig()
	return true
end

function ns.SetRingSlice(name, slot, slice)
	local _, ring = Ring(name)
	if not ring then return false end
	slot = tonumber(slot)
	if not slot or slot < 1 or slot > ns.SLICE_COUNT or slot ~= math.floor(slot) then
		ns.Print("slots are 1 to %d (1-4 inner, 5-12 outer, clockwise from the top)", ns.SLICE_COUNT)
		return false
	end
	slice = ns.ValidSlice(slice)
	if not slice then
		ns.Print("a slice is spell ID, item ID or macro NAME")
		return false
	end
	ring.slices[slot] = slice
	ns.Print("ring %s slot %d: %s", ring.name, slot, ns.DescribeSlice(slice))
	ns.ApplyConfig()
	return true
end

function ns.ClearRingSlice(name, slot)
	local _, ring = Ring(name)
	if not ring then return false end
	slot = tonumber(slot)
	if not slot or not ring.slices[slot] then return false end
	ring.slices[slot] = nil
	ns.Print("ring %s slot %d cleared", ring.name, slot)
	ns.ApplyConfig()
	return true
end

-- Replace a ring's content with the direct equivalents of a bar's slots:
-- all of them, or only the harmful ("harm") or helpful ("help") ones, as the
-- client classifies them out of combat.
function ns.FillRingFromBar(name, bar, filter)
	local _, ring = Ring(name)
	if not ring then return false end
	bar = tonumber(bar)
	local base = bar and ns.BarBaseSlot(bar)
	if not base then
		ns.Print("bars are 1 to 8")
		return false
	end
	filter = filter or "all"
	local classify = filter == "harm" and C_ActionBar and C_ActionBar.IsHarmfulAction
		or filter == "help" and C_ActionBar and C_ActionBar.IsHelpfulAction
	if filter ~= "all" and not classify then
		ns.Print("this client cannot classify actions; filling with every slot instead")
		classify = nil
	end
	local count = 0
	for i = 1, ns.SLICE_COUNT do
		local slot = base + i - 1
		local slice = ns.SliceFromAction(slot)
		if slice and classify and not classify(slot) then slice = nil end
		ring.slices[i] = slice
		if slice then count = count + 1 end
	end
	ns.Print("ring %s filled from Bar %d (%s): %d slices", ring.name, bar,
		filter == "harm" and "offensive actions" or filter == "help" and "helpful actions" or "every slot", count)
	ns.ApplyConfig()
	return true
end

function ns.ExportRing(name)
	local _, ring = Ring(name)
	if not ring then return nil end
	return ns.EncodeRing(ring)
end

-- Create the ring in the string, or replace the ring of the same name.
function ns.ImportRing(text)
	local ring, err = ns.DecodeRing(text)
	if not ring then
		ns.Print("import failed: %s", err)
		return nil
	end
	local index, existing = ns.FindRing(ring.name)
	if existing then
		existing.slices = ring.slices
		ns.Print("ring %s replaced from the string", existing.name)
	else
		if #ns.db.rings >= ns.MAX_RINGS then
			ns.Print("at most %d rings; remove one first", ns.MAX_RINGS)
			return nil
		end
		table.insert(ns.db.rings, ring)
		index = #ns.db.rings
		ns.Print("ring %s imported", ring.name)
	end
	ns.ApplyConfig()
	return index
end

function ns.DescribeRing(ring)
	local filled = 0
	for i = 1, ns.SLICE_COUNT do if ring.slices[i] then filled = filled + 1 end end
	return ("%s: %d of %d slices"):format(ring.name, filled, ns.SLICE_COUNT)
end
