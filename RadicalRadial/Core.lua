-------------------------------------------------------------------------------
-- Radical Radial — Core
--
-- Namespace, constants, defaults, saved variables and the geometry that the
-- presentation layer shares with the secure snippets (which repeat the same
-- formulas with the constants baked in; see Secure.lua).
--
-- Load order (RadicalRadial.toc): Libs → Core → Ring → Secure → Config.
-------------------------------------------------------------------------------

local ADDON, ns = ...

ns.VERSION = "0.4.0"

-------------------------------------------------------------------------------
-- Geometry (UIParent units at scale 1)
-------------------------------------------------------------------------------

ns.RADIUS      = 120    -- outer icon ring radius
ns.INNER_R     = 0.40   -- inner icon ring radius as a fraction of RADIUS
ns.DEAD        = 0.15   -- release inside this fraction of RADIUS cancels
ns.INNER_LIMIT = 0.55   -- tier boundary as a fraction of RADIUS
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
-------------------------------------------------------------------------------

ns.MAX_TRIGGERS = 4
ns.MODES = { hold = true, tap = true }
ns.CAPTURES = { focus = true, target = true, none = true }
ns.CONTEXTS = { "harm", "help" }
ns.TRIGGER_DEFAULTS = { key = "", bars = { 1, 2 }, harm = {}, help = {}, capture = "focus", mode = "hold", autohide = 3 }
ns.DEFAULTS = {
	scale = 1,
	debug = false,
	triggers = { { key = "BUTTON4", bars = { 1, 2 }, harm = {}, help = {}, capture = "focus", mode = "hold", autohide = 3 } },
}

ns.db = nil   -- RadicalRadialDB, available after ADDON_LOADED

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
-- value it cannot use.
function ns.NormalizeTrigger(t)
	CopyDefaults(t, ns.TRIGGER_DEFAULTS)
	t.key = tostring(t.key or ""):upper()
	if t.key == "NONE" then t.key = "" end
	if not ns.MODES[t.mode] then t.mode = "hold" end
	t.autohide = math.max(0, tonumber(t.autohide) or 0)
	if not ns.CAPTURES[t.capture] then t.capture = "focus" end
	t.bars = ns.CleanBars(t.bars)
	if #t.bars == 0 then t.bars[1] = 1 end
	t.harm = ns.CleanBars(t.harm)
	t.help = ns.CleanBars(t.help)
	return t
end

-- Keep only valid bar numbers, in order.
function ns.CleanBars(list)
	local bars = {}
	for _, bar in ipairs(type(list) == "table" and list or {}) do
		bar = tonumber(bar)
		if bar and bar >= 1 and bar <= 8 and bar == math.floor(bar) then bars[#bars + 1] = bar end
	end
	return bars
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
	for i = #db.triggers, ns.MAX_TRIGGERS + 1, -1 do table.remove(db.triggers, i) end
	for _, t in ipairs(db.triggers) do ns.NormalizeTrigger(t) end
	ns.db = db
	return db
end

function ns.ResetDB()
	for key in pairs(RadicalRadialDB) do RadicalRadialDB[key] = nil end
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

-- Cursor offset from the ring centre → slice index (nil in the dead zone), distance.
function ns.Resolve(dx, dy, R)
	local r = math.sqrt(dx * dx + dy * dy)
	if r < ns.DEAD * R then return nil, r end
	local a = (90 - math.deg(math.atan2(dy, dx))) % 360
	if r < ns.INNER_LIMIT * R then
		return 1 + math.floor(((a + 180 / ns.INNER_COUNT) % 360) / (360 / ns.INNER_COUNT)), r
	end
	return ns.INNER_COUNT + 1 + math.floor(((a + 180 / ns.OUTER_COUNT) % 360) / (360 / ns.OUTER_COUNT)), r
end
