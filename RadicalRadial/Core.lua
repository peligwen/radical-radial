-------------------------------------------------------------------------------
-- Radical Radial — Core
--
-- Namespace, constants, defaults, saved variables and the geometry that the
-- presentation layer shares with the secure snippets (which repeat the same
-- formulas with the constants baked in; see Secure.lua).
--
-- Load order (RadicalRadial.toc): Libs → Core → Rings → Ring → Secure →
-- Config → Options → Editor.
-------------------------------------------------------------------------------

local ADDON, ns = ...

ns.VERSION = "0.5.1"

-------------------------------------------------------------------------------
-- Geometry (UIParent units at scale 1)
-------------------------------------------------------------------------------

ns.RADIUS      = 120    -- outer icon ring radius
ns.INNER_R     = 0.40   -- inner icon ring radius as a fraction of RADIUS
ns.DEAD        = 0.15   -- release inside this fraction of RADIUS cancels
ns.OUTER_MIN   = 1.2    -- the cancel radius (db.outer, a fraction of RADIUS) stays in this range;
ns.OUTER_MAX   = 3      -- past it nothing is selected, so a release or a tap there cancels
-- Tier boundary as a fraction of RADIUS. The inner icons end at 0.55 R
-- (0.40 R + 18 px) and the outer icons begin at 0.82 R (R - 22 px); the
-- boundary sits midway through that gap, so the cursor keeps the inner slice
-- for a little way past its icon before the outer tier takes over.
ns.INNER_LIMIT = 0.68
ns.INNER_COUNT = 4
ns.OUTER_COUNT = 8
ns.SLICE_COUNT = ns.INNER_COUNT + ns.OUTER_COUNT   -- 12: one action bar
ns.ICON_INNER  = 36     -- on-screen size of an inner slice
ns.ICON_OUTER  = 44     -- on-screen size of an outer slice
ns.BUTTON_SIZE = 45     -- ActionButtonTemplate's native size; slices are scaled from it
ns.EXTENT      = ns.RADIUS + ns.ICON_OUTER   -- half the side of the square the ring occupies

-- Side of the ring frame at a given scale. The frame is mouse-transparent; its
-- rect only matters to the auto-hide driver, which counts down once the
-- cursor has left it.
function ns.RingSize(scale)
	return 2 * ns.EXTENT * (scale or 1)
end

-------------------------------------------------------------------------------
-- Action pages
--
-- 180 action slots in 15 pages of 12. Bars 2-8 sit on fixed pages. Bar 1 has
-- no fixed page: the ring resolves it at open time (stance, form, vehicle,
-- override) inside a snippet, using the same calls Blizzard's main bar uses.
-- Every slice carries one LibActionButton state per page, so switching bars
-- in combat is a state change, not an attribute rewrite.
-------------------------------------------------------------------------------

ns.PAGE_COUNT  = 15
ns.PAGE_OF_BAR = { [2] = 6, [3] = 5, [4] = 3, [5] = 4, [6] = 13, [7] = 14, [8] = 15 }
ns.BAR_NAMES   = { "Bar 1", "Bar 2", "Bar 3", "Bar 4", "Bar 5", "Bar 6", "Bar 7", "Bar 8" }

function ns.SlotOfPage(page, i)
	return (page - 1) * ns.SLICE_COUNT + i
end

-------------------------------------------------------------------------------
-- Defaults and saved variables
--
-- A trigger is a bound key or mouse button with its own bar list, interaction
-- mode and auto-hide delay. Up to MAX_TRIGGERS triggers share one ring.
--
--   mode "hold": press opens, release fires the slice under the cursor,
--                a release in the dead zone cancels.
--   mode "tap":  a release in the dead zone leaves the ring open; the next
--                release fires, a press in the dead zone cancels, and the
--                ring hides itself autohide seconds after the cursor has
--                left it (0 = never).
--
-- Context rings: when the trigger is pressed over an attackable unit the
-- ring shows the trigger's harm bars instead, over a friendly unit its help
-- bars (each list may be empty, meaning "use the normal bars"). The press
-- itself captures that unit as focus or target (capture = "focus", "target"
-- or "none"), and the context ring's slices act on the captured unit.
--
-- Every list holds bar numbers (1-8) and names of custom rings (Rings.lua)
-- in wheel order.
--
-- What is saved where (RadicalRadialDB, one file for the account):
--
--   scale, outer, debug        account-wide
--   triggers[i]                account-wide: key, mode, capture, autohide,
--                              and a stable id
--   chars["Name-Realm"]        this character's rings, and its own copy of
--                              every trigger's bars/harm/help lists, keyed by
--                              the trigger's id
--
-- Rings hold class spells, so they belong to a character; the lists name
-- rings, so they follow. Which button opens the ring and how it behaves is
-- the same on every character. At runtime the trigger tables carry the
-- current character's lists (ns.AttachCharacter), so the rest of the addon
-- reads and writes t.bars as before; a character seen for the first time
-- starts with the lists the last character saved, minus rings it lacks.
-------------------------------------------------------------------------------

ns.MAX_TRIGGERS = 4
ns.MODES = { hold = true, tap = true }
ns.CAPTURES = { focus = true, target = true, none = true }
ns.CONTEXTS = { "harm", "help" }
ns.TRIGGER_DEFAULTS = { key = "", bars = { 1, 2 }, harm = {}, help = {}, capture = "focus", mode = "hold", autohide = 3 }
ns.DEFAULTS = {
	scale = 1,
	outer = 1.6,
	debug = false,
	nextTriggerId = 1,
	chars = {},
	triggers = { { key = "BUTTON4", bars = { 1, 2 }, harm = {}, help = {}, capture = "focus", mode = "hold", autohide = 3 } },
}

ns.db = nil        -- RadicalRadialDB, available after ADDON_LOADED
ns.char = nil      -- this character's entry in db.chars (rings, lists)
ns.charKey = nil   -- "Name-Realm", nil until the client can name the player

local function CopyDefaults(target, defaults)
	for key, value in pairs(defaults) do
		if target[key] == nil then
			if type(value) == "table" then
				target[key] = CopyDefaults({}, value)
			else
				target[key] = value
			end
		end
	end
	return target
end

-- Fill in missing fields and clamp the rest so the secure side never sees a
-- value it cannot use. `rings` is the ring list the wheel lists may name
-- (the saved one by default; ns.CleanBars lives in Rings.lua).
function ns.NormalizeTrigger(t, rings)
	CopyDefaults(t, ns.TRIGGER_DEFAULTS)
	t.key = tostring(t.key or ""):upper()
	if t.key == "NONE" then t.key = "" end
	if not ns.MODES[t.mode] then t.mode = "hold" end
	t.autohide = math.max(0, tonumber(t.autohide) or 0)
	if not ns.CAPTURES[t.capture] then t.capture = "focus" end
	t.bars = ns.CleanBars(t.bars, rings)
	if #t.bars == 0 then t.bars[1] = 1 end
	t.harm = ns.CleanBars(t.harm, rings)
	t.help = ns.CleanBars(t.help, rings)
	-- The lists are this character's: keep its saved copy pointing at them.
	if ns.char and t.id and type(ns.char.lists) == "table" then
		ns.char.lists[t.id] = { bars = t.bars, harm = t.harm, help = t.help }
	end
	return t
end

-- A stable id for a trigger, so a character's lists survive triggers being
-- added or removed on another character.
function ns.AssignTriggerId(db, t)
	db.nextTriggerId = math.max(1, math.floor(tonumber(db.nextTriggerId) or 1))
	t.id = db.nextTriggerId
	db.nextTriggerId = db.nextTriggerId + 1
	return t.id
end

-- "Name-Realm", or nil while the client cannot name the player yet.
function ns.CharKey()
	local name = UnitName and UnitName("player")
	if not name or name == "" or name == "Unknown" or name == UNKNOWNOBJECT then return nil end
	local realm = GetRealmName and GetRealmName() or ""
	return name .. "-" .. (realm or "")
end

local function CopyList(list)
	local out = {}
	for i, v in ipairs(type(list) == "table" and list or {}) do out[i] = v end
	return out
end

-- Point the runtime at this character's rings and lists, creating its entry
-- on the first login. Runs from LoadDB, and again at PLAYER_LOGIN if the
-- character could not be named at ADDON_LOADED.
function ns.AttachCharacter(db)
	local key = ns.CharKey()
	local char = key and db.chars[key]
	if not char then
		-- Keep whatever an unnamed early attach built, otherwise start fresh.
		char = (ns.char and not ns.charKey) and ns.char or {}
		if key then db.chars[key] = char end
	end
	ns.char, ns.charKey = char, key

	-- Rings made before 0.5.1 were shared by every character; they go to
	-- the first character that logs in with 0.5.1.
	if char.rings == nil and type(db.rings) == "table" then
		char.rings, db.rings = db.rings, nil
	end
	char.rings = ns.NormalizeRings(char.rings)

	-- Lists: this character's copy per trigger id, seeded from the trigger's
	-- own lists (the last character's) the first time. Ids that no longer
	-- name a trigger are dropped.
	if type(char.lists) ~= "table" then char.lists = {} end
	local live = {}
	for _, t in ipairs(db.triggers) do
		live[t.id] = true
		local mine = char.lists[t.id]
		if type(mine) == "table" then
			t.bars, t.harm, t.help = CopyList(mine.bars), CopyList(mine.harm), CopyList(mine.help)
		end
	end
	for id in pairs(char.lists) do
		if not live[id] then char.lists[id] = nil end
	end
	for _, t in ipairs(db.triggers) do ns.NormalizeTrigger(t, char.rings) end
	return char
end

-- This character's custom rings (empty until the saved variables are loaded).
function ns.Rings()
	return ns.char and ns.char.rings or {}
end

function ns.LoadDB()
	RadicalRadialDB = RadicalRadialDB or {}
	local db = RadicalRadialDB
	-- M0/M1 saved one trigger as db.trigger and db.bars.
	if db.triggers == nil and (db.trigger ~= nil or db.bars ~= nil) then
		db.triggers = { { key = db.trigger, bars = db.bars } }
		db.trigger, db.bars = nil, nil
	end
	CopyDefaults(db, ns.DEFAULTS)
	db.outer = ns.ClampOuter(db.outer)
	if type(db.chars) ~= "table" then db.chars = {} end
	for i = #db.triggers, 1, -1 do
		if type(db.triggers[i]) ~= "table" then table.remove(db.triggers, i) end
	end
	for i = #db.triggers, ns.MAX_TRIGGERS + 1, -1 do table.remove(db.triggers, i) end
	local ids = {}
	for _, t in ipairs(db.triggers) do
		local id = tonumber(t.id)
		if not id or id < 1 or id ~= math.floor(id) or ids[id] then id = ns.AssignTriggerId(db, t) end
		t.id = id
		ids[id] = true
		if id >= (tonumber(db.nextTriggerId) or 1) then db.nextTriggerId = id + 1 end
	end
	ns.db = db
	ns.AttachCharacter(db)
	return db
end

function ns.ClampOuter(value)
	value = tonumber(value) or ns.DEFAULTS.outer
	return math.max(ns.OUTER_MIN, math.min(ns.OUTER_MAX, value))
end

-- Back to the defaults for the shared settings and this character. Other
-- characters keep their rings and lists.
function ns.ResetDB()
	local db = RadicalRadialDB
	local chars = db.chars
	for key in pairs(db) do db[key] = nil end
	if type(chars) == "table" then
		if ns.charKey then chars[ns.charKey] = nil end
		db.chars = chars
	end
	ns.char, ns.charKey = nil, nil
	return ns.LoadDB()
end

-------------------------------------------------------------------------------
-- Output
-------------------------------------------------------------------------------

local PREFIX = "|cff33ff99Radical Radial|r "

function ns.Print(fmt, ...)
	if select("#", ...) > 0 then fmt = fmt:format(...) end
	print(PREFIX .. fmt)
end

function ns.Debug(fmt, ...)
	if ns.db and ns.db.debug then ns.Print(fmt, ...) end
end

-- For debug output: what a unit token points at, using only checks that
-- stay plain booleans in combat.
function ns.UnitReport(unit)
	if not UnitExists(unit) then return "none" end
	if UnitExists("mouseover") and UnitIsUnit(unit, "mouseover") then return "the mouseover" end
	return "set"
end

-------------------------------------------------------------------------------
-- Geometry helpers
-------------------------------------------------------------------------------

-- Slice i → angle in degrees clockwise from 12 o'clock, radius fraction, icon size.
function ns.SlicePolar(i)
	if i <= ns.INNER_COUNT then
		return (i - 1) * (360 / ns.INNER_COUNT), ns.INNER_R, ns.ICON_INNER
	end
	return (i - ns.INNER_COUNT - 1) * (360 / ns.OUTER_COUNT), 1, ns.ICON_OUTER
end

-- Cursor offset from the ring centre → slice index, distance, zone. The index
-- is nil in the dead zone (zone "dead") and past the cancel radius (zone
-- "outside"); `outer` is that radius as a fraction of R, nil for unbounded.
function ns.Resolve(dx, dy, R, outer)
	local r = math.sqrt(dx * dx + dy * dy)
	if r < ns.DEAD * R then return nil, r, "dead" end
	if outer and r > outer * R then return nil, r, "outside" end
	local a = (90 - math.deg(math.atan2(dy, dx))) % 360
	if r < ns.INNER_LIMIT * R then
		return 1 + math.floor(((a + 180 / ns.INNER_COUNT) % 360) / (360 / ns.INNER_COUNT)), r
	end
	return ns.INNER_COUNT + 1 + math.floor(((a + 180 / ns.OUTER_COUNT) % 360) / (360 / ns.OUTER_COUNT)), r
end
