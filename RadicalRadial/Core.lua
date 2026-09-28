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

ns.VERSION = "0.1.0-m1"

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
-------------------------------------------------------------------------------

ns.DEFAULTS = { trigger = "BUTTON4", bars = { 1, 2 }, scale = 1, debug = false }

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

function ns.LoadDB()
	RadicalRadialDB = RadicalRadialDB or {}
	ns.db = CopyDefaults(RadicalRadialDB, ns.DEFAULTS)
	return ns.db
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
