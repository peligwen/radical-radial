-------------------------------------------------------------------------------
-- Radical Radial — Config
--
-- Applying settings to the secure frames (out of combat, deferred otherwise),
-- events, diagnostics, the setters shared by the slash commands and the
-- options window (Options.lua), and the /rr slash commands.
-------------------------------------------------------------------------------

local ADDON, ns = ...

local header, openers, bindOwner = ns.header, ns.openers, ns.bindOwner
local ring, visual, slices = ns.ring, ns.visual, ns.slices

-------------------------------------------------------------------------------
-- Applying configuration
-------------------------------------------------------------------------------

local pendingConfig = false

local function SnippetSelfTest()
	header:SetAttribute("selftest", nil)
	local ok, err = pcall(SecureHandlerExecute, header, [[ self:SetAttribute("selftest", 42) ]])
	if not ok then return false, tostring(err) end
	if header:GetAttribute("selftest") ~= 42 then return false, "snippet ran but did not set the attribute" end
	return true
end

function ns.ApplyConfig()
	local db = ns.db
	if InCombatLockdown() then
		pendingConfig = true
		ns.Print("in combat; settings will apply when combat ends")
		if ns.RefreshConfigUI then ns.RefreshConfigUI() end
		return
	end
	pendingConfig = false

	-- Custom rings: one LibActionButton state per ring on every slice, past
	-- the fifteen action pages, and a "bar" code (8 + index) with a fixed page
	-- and its layout, so the page snippet treats a ring like a bar. A nested
	-- ring is an empty state plus the target's bar code in "sub-<state>",
	-- which the page snippet copies to the slice's "subring".
	local rings = ns.ResolveFolders(ns.Rings())
	for k = 1, ns.MAX_RINGS do
		local custom = rings[k]
		local state = ns.PAGE_COUNT + k
		header:SetAttribute("pageofbar" .. (8 + k), state)
		header:SetAttribute("layoutofbar" .. (8 + k), custom and ns.LayoutCode(custom.layout) or nil)
		for i, slice in ipairs(slices) do
			local s = custom and custom.slices[i]
			local sub
			if s and s.kind == "ring" then
				local index = ns.FindRing(s.name, rings)
				sub = index and (8 + index) or nil
				slice:SetState(state, "empty")
			elseif s then
				slice:SetState(state, s.kind, s.kind == "macro" and s.name or s.id)
			else
				slice:SetState(state, "empty")
			end
			slice:SetAttribute("sub-" .. state, sub)
		end
	end

	-- A wheel list reaches the secure side as bar codes: 1-8 for bars, 8 +
	-- the ring's index for custom rings.
	local function SetList(opener, prefix, list)
		local n = 0
		for _, entry in ipairs(list) do
			local code = ns.BarCode(entry)
			if code then
				n = n + 1
				opener:SetAttribute(prefix .. n, code)
			end
		end
		opener:SetAttribute(prefix .. "count", n)
		for k = n + 1, ns.MAX_LIST do opener:SetAttribute(prefix .. k, nil) end
	end

	ClearOverrideBindings(bindOwner)
	for i, opener in ipairs(openers) do
		local t = db.triggers[i]
		if t then
			ns.NormalizeTrigger(t, rings)
			if t.key ~= "" then
				SetOverrideBindingClick(bindOwner, true, t.key, opener:GetName(), "LeftButton")
			end
			SetList(opener, "bar", t.bars)
			for _, ctx in ipairs(ns.CONTEXTS) do SetList(opener, ctx, t[ctx]) end
			opener:SetAttribute("capture", t.capture)
			opener:SetAttribute("mode", t.mode)
			opener:SetAttribute("autohide", t.autohide)
			opener:SetAttribute("layout", ns.LayoutCode(t.layout))
			opener:SetAttribute("clickfire", t.click and true or false)
		else
			opener:SetAttribute("barcount", 0)
			opener:SetAttribute("harmcount", 0)
			opener:SetAttribute("helpcount", 0)
		end
	end

	for bar, page in pairs(ns.PAGE_OF_BAR) do header:SetAttribute("pageofbar" .. bar, page) end
	header:SetAttribute("radius", ns.RADIUS * db.scale)
	header:SetAttribute("outer", db.outer)
	header:SetAttribute("debug", db.debug and true or false)
	header:SetAttribute("active", 1)
	header:SetAttribute("context", "none")
	header:SetAttribute("unit", nil)
	header:SetAttribute("sub", nil)
	header:SetAttribute("page", 1)
	visual:SetScale(db.scale)
	ring:SetSize(ns.RingSize(db.scale), ns.RingSize(db.scale))

	-- Point the slices at trigger 1, page 1 (and place them for its layout)
	-- through the same snippet the ring uses.
	local ok, err = pcall(SecureHandlerExecute, header, [[ self:RunAttribute("ApplyPage") ]])
	if not ok then
		ns.Print("|cffff4444secure snippets are not working on this build:|r %s", tostring(err))
	end
	ns.UpdateLabel()
	if ns.RefreshConfigUI then ns.RefreshConfigUI() end
end

-- True while a change made in combat waits for combat to end.
function ns.ConfigPending()
	return pendingConfig
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_REGEN_ENABLED")

events:SetScript("OnEvent", function(_, event, arg1)
	if event == "ADDON_LOADED" then
		if arg1 == ADDON then ns.LoadDB() end
	elseif event == "PLAYER_LOGIN" then
		if not ns.db then ns.LoadDB() elseif not ns.charKey then ns.AttachCharacter(ns.db) end
		ns.ApplyConfig()
		local first = ns.db.triggers[1]
		ns.Print("v%s loaded. Hold %s to open the ring. /rr for settings.", ns.VERSION,
			(first and first.key ~= "") and first.key or "an unbound trigger (/rr to bind one)")
	elseif event == "PLAYER_REGEN_ENABLED" then
		if pendingConfig then ns.ApplyConfig() end
	end
end)

-------------------------------------------------------------------------------
-- Diagnostics
-------------------------------------------------------------------------------

BINDING_HEADER_RADICALRADIAL = "Radical Radial"
for i = 1, ns.MAX_TRIGGERS do
	_G["BINDING_NAME_CLICK RadicalRadialOpener" .. i .. ":LeftButton"] = "Open radial (trigger " .. i .. ")"
end

-- Bar-paging state as the client reports it, for checking stance and vehicle
-- pages on Forever against what the ring shows.
local PAGE_API = {
	"GetActionBarPage", "HasBonusActionBar", "GetBonusBarIndex", "HasVehicleActionBar", "GetVehicleBarIndex",
	"HasOverrideActionBar", "GetOverrideBarIndex", "HasTempShapeshiftActionBar", "GetTempShapeshiftBarIndex",
}
local function PageReport()
	local parts = {}
	for _, name in ipairs(PAGE_API) do
		local fn = (C_ActionBar and C_ActionBar[name]) or _G[name]
		if fn then
			local ok, value = pcall(fn)
			parts[#parts + 1] = name:gsub("ActionBar", ""):gsub("Index", "") .. "=" .. tostring(ok and value or "?")
		end
	end
	return table.concat(parts, " ")
end

function ns.BarList(list)
	if #list == 0 then return "none" end
	local parts = {}
	for i, entry in ipairs(list) do parts[i] = tostring(entry) end
	return table.concat(parts, " ")
end
local BarList = ns.BarList

local function DescribeTrigger(i, t)
	return ("trigger %d: %s | bars %s | harm %s | help %s | capture %s | mode %s | autohide %ss | layout %s | click %s | macro %s"):format(
		i, t.key ~= "" and t.key or "unbound", BarList(t.bars), BarList(t.harm), BarList(t.help),
		t.capture, t.mode, tostring(t.autohide), t.layout, t.click and "on" or "off", ns.MacroText(i))
end

local function ListTriggers()
	for i, t in ipairs(ns.db.triggers) do ns.Print(DescribeTrigger(i, t)) end
end

local function ListRings()
	local rings = ns.Rings()
	if #rings == 0 then
		ns.Print("no custom rings on this character yet: /rr ring add NAME, or the Custom rings tab of /rr")
	end
	for i, ring in ipairs(rings) do
		ns.Print("ring %d %s", i, ns.DescribeRing(ring))
		local shown = ns.RingSliceCount(ring)
		for slot = 1, ns.MAX_SLICES do
			if ring.slices[slot] then
				print(("  %2d  %s%s"):format(slot, ns.DescribeSlice(ring.slices[slot]), slot > shown and " (not shown in this layout)" or ""))
			end
		end
	end
	for _, other in ipairs(ns.OtherCharacters()) do
		local names = {}
		for i, ring in ipairs(other.rings) do names[i] = ring.name end
		ns.Print("%s has: %s (/rr ring copy %s NAME copies one here)", other.key, table.concat(names, ", "), other.name)
	end
end

local function Status()
	local db = ns.db
	local version, build, _, toc = GetBuildInfo()
	ns.Print("v%s on client %s (build %s, interface %s, project %s), LibActionButton-1.0 r%s",
		ns.VERSION, tostring(version), tostring(build), tostring(toc), tostring(WOW_PROJECT_ID),
		tostring(LibStub.minors["LibActionButton-1.0"]))
	ns.Print("scale: %s | cancel radius: %s x ring radius | debug: %s | character: %s | custom rings here: %d",
		tostring(db.scale), tostring(db.outer), db.debug and "on" or "off", tostring(ns.charKey), #ns.Rings())
	ListTriggers()
	if InCombatLockdown() then
		ns.Print("secure snippets: cannot self-test in combat")
	else
		local ok, err = SnippetSelfTest()
		ns.Print("secure snippets: %s", ok and "|cff33ff33OK|r" or ("|cffff4444FAILED|r " .. tostring(err)))
	end
	ns.Print("ring open: %s | active trigger: %s | context: %s | unit: %s | page: %s | current base slot: %s",
		tostring(header:GetAttribute("open")), tostring(header:GetAttribute("active")),
		tostring(header:GetAttribute("context")), tostring(header:GetAttribute("unit")),
		tostring(header:GetAttribute("page")), tostring(header:GetAttribute("basecurrent")))
	ns.Print("client paging: %s", PageReport())
end

local function Usage()
	ns.Print("/rr opens the settings window. Commands (prefix with a trigger number for triggers 2-%d, e.g. /rr 2 bind BUTTON5):", ns.MAX_TRIGGERS)
	print("  /rr config          open or close the settings window")
	print("  /rr bind KEY        trigger binding, e.g. BUTTON4, SHIFT-BUTTON5, F (none to clear)")
	print("  /rr bars 1 2 3      bars (1-8) and custom rings (by name) the wheel cycles through, in order")
	print("  /rr harm 3          bars or rings shown instead when pressed over an enemy (none to clear)")
	print("  /rr help 4          bars or rings shown instead when pressed over a friend (none to clear)")
	print("  /rr capture focus   what the press captures the unit under the cursor as: focus, target or none")
	print("  /rr mode hold|tap   hold: release fires, centre cancels. tap: centre keeps the ring open, next release fires")
	print("  /rr autohide 3      seconds after the cursor leaves a waiting ring (tap, nested ring, macro) before it closes (0 = never)")
	print("  /rr layout 4+8      layout for bars on this trigger: 4+8, 12, 8, 6, 4, 6+6 or 8+8 (inner + outer slices)")
	print("  /rr click on|off    a waiting ring takes the mouse: left click fires, right click cancels")
	print("  /rr macro [create]  the macro that opens this trigger's ring from an action bar; create makes it and puts it on the cursor")
	print("  /rr 2 remove        remove trigger 2 (trigger 1 stays; unbind it with /rr bind none)")
	print("  /rr triggers        list triggers")
	print("  /rr rings           list this character's custom rings and their slices, and other characters' rings")
	print("  /rr ring add NAME   new custom ring (then /rr bars 1 NAME puts it on the wheel)")
	print("  /rr ring copy CHARACTER NAME   copy a ring from another character (its name, or Name-Realm)")
	print("  /rr ring remove NAME | rename NAME NEWNAME | layout NAME 4+8")
	print("  /rr ring set NAME SLOT spell ID | item ID | macro MACRONAME | ring RINGNAME   (slots 1-16; ring nests that ring)")
	print("  /rr ring clear NAME SLOT")
	print("  /rr ring fill NAME BAR [harm|help]   copy a bar's actions, optionally only the offensive or helpful ones")
	print("  /rr ring export NAME | import STRING")
	print("  (ring names may contain spaces; put a new name in quotes if it could be read as something else)")
	print("  /rr scale 1.2       ring scale (0.5 to 2)")
	print("  /rr outer 1.6       cancel radius as a multiple of the ring radius (1.2 to 3): past it a release or a tap cancels")
	print("  /rr preview         show or hide the ring at screen centre, out of combat")
	print("  /rr debug           toggle chat output for every press, release, page and cancel")
	print("  /rr status          client, triggers, snippet self-test and bar paging state")
	print("  /rr reset           restore defaults")
end

-------------------------------------------------------------------------------
-- Setters, shared by the slash commands and the options window. Each one
-- validates, updates the saved variables, says what changed and applies
-- (deferred to the end of combat when needed).
-------------------------------------------------------------------------------

-- The addressed trigger, created (with unbound predecessors) on demand.
function ns.EnsureTrigger(index)
	local db = ns.db
	for i = #db.triggers + 1, index do
		local t = { key = "" }
		ns.AssignTriggerId(db, t)
		db.triggers[i] = ns.NormalizeTrigger(t)
	end
	return db.triggers[index]
end

-- What the key does without the addon. The override binding wins while the
-- addon is loaded, which is worth a line in chat.
local function BoundActionName(key)
	if key == "" or type(GetBindingAction) ~= "function" then return nil end
	local action = GetBindingAction(key)
	if not action or action == "" or action:find("RadicalRadialOpener", 1, true) then return nil end
	return _G["BINDING_NAME_" .. action] or action
end

function ns.SetTriggerKey(index, key)
	key = tostring(key or ""):upper()
	if key == "NONE" then key = "" end
	if key:match("BUTTON[12]$") then
		ns.Print("the left and right mouse buttons cannot be triggers")
		return false
	end
	local t = ns.EnsureTrigger(index)
	t.key = key
	ns.NormalizeTrigger(t)
	for i, other in ipairs(ns.db.triggers) do
		if i ~= index and t.key ~= "" and other.key == t.key then
			other.key = ""
			ns.Print("trigger %d gives up %s", i, t.key)
		end
	end
	ns.Print("trigger %d bound to %s", index, t.key ~= "" and t.key or "nothing")
	local was = BoundActionName(t.key)
	if was then
		ns.Print("%s was bound to %s; the trigger takes it over while the addon is loaded", t.key, was)
	end
	ns.ApplyConfig()
	return true
end

function ns.SetTriggerBars(index, list)
	local bars = ns.CleanBars(list)
	if #bars == 0 then
		ns.Print("a trigger needs at least one bar")
		return false
	end
	local t = ns.EnsureTrigger(index)
	t.bars = bars
	ns.Print("trigger %d cycles: %s", index, table.concat(bars, " "))
	ns.ApplyConfig()
	return true
end

function ns.SetTriggerContext(index, ctx, list)
	local t = ns.EnsureTrigger(index)
	t[ctx] = ns.CleanBars(list)
	ns.Print("trigger %d %s ring: %s", index, ctx == "harm" and "enemy" or "friend", BarList(t[ctx]))
	ns.ApplyConfig()
	return true
end

function ns.SetTriggerCapture(index, capture)
	if not ns.CAPTURES[capture] then return false end
	local t = ns.EnsureTrigger(index)
	t.capture = capture
	ns.Print("trigger %d captures the unit under the cursor as %s", index, capture)
	ns.ApplyConfig()
	return true
end

function ns.SetTriggerMode(index, mode)
	if not ns.MODES[mode] then return false end
	local t = ns.EnsureTrigger(index)
	t.mode = mode
	ns.Print("trigger %d mode: %s", index, mode)
	ns.ApplyConfig()
	return true
end

function ns.SetTriggerAutohide(index, seconds)
	seconds = tonumber(seconds)
	if not seconds then return false end
	local t = ns.EnsureTrigger(index)
	t.autohide = math.max(0, seconds)
	ns.Print("trigger %d auto-hide: %ss", index, tostring(t.autohide))
	ns.ApplyConfig()
	return true
end

function ns.SetTriggerLayout(index, layout)
	local key = ns.CleanLayout(layout)
	if not key then
		local keys = {}
		for i, l in ipairs(ns.LAYOUTS) do keys[i] = l.key end
		ns.Print("layouts are %s (inner + outer slices)", table.concat(keys, ", "))
		return false
	end
	local t = ns.EnsureTrigger(index)
	t.layout = key
	ns.Print("trigger %d shows bars as %s", index, ns.Layout(key).text)
	ns.ApplyConfig()
	return true
end

function ns.SetTriggerClick(index, on)
	local t = ns.EnsureTrigger(index)
	t.click = on and true or false
	ns.Print("trigger %d click to fire: %s", index, t.click and "on (a waiting ring takes the mouse: left click fires, right click cancels)" or "off")
	ns.ApplyConfig()
	return true
end

-------------------------------------------------------------------------------
-- The macro that opens a trigger's ring from an action bar. "/click" on the
-- trigger's macro opener delivers one click per press (Secure.lua): the
-- first opens the ring where the cursor is, the next fires the slice under
-- it, and a click on the waiting ring fires too.
-------------------------------------------------------------------------------

function ns.MacroText(index)
	return "/click RadicalRadialMacro" .. index
end

function ns.MacroName(index)
	return "Radial " .. index
end

-- Make (or update) the macro and put it on the cursor to drop on a bar.
function ns.CreateTriggerMacro(index)
	if InCombatLockdown() then
		ns.Print("not in combat")
		return false
	end
	if type(CreateMacro) ~= "function" or type(EditMacro) ~= "function" then
		ns.Print("this client cannot make macros; make one yourself with: %s", ns.MacroText(index))
		return false
	end
	ns.EnsureTrigger(index)
	local name, body = ns.MacroName(index), ns.MacroText(index)
	local existing = GetMacroIndexByName(name)
	if existing and existing > 0 then
		EditMacro(existing, name, "INV_MISC_QUESTIONMARK", body)
		ns.Print("macro %s updated", name)
	elseif not CreateMacro(name, "INV_MISC_QUESTIONMARK", body, false) then
		ns.Print("could not create the macro (the macro window may be full); make one yourself with: %s", body)
		return false
	else
		ns.Print("macro %s created", name)
	end
	PickupMacro(name)
	ns.Print("%s is on the cursor: drop it on an action bar. Pressing it opens trigger %d's ring at the cursor; pressing it again, or clicking the ring, fires", name, index)
	ns.ApplyConfig()
	return true
end

function ns.AddTrigger(index)
	if ns.db.triggers[index] then return false end
	ns.EnsureTrigger(index)
	ns.Print("trigger %d added; bind it to a key", index)
	ns.ApplyConfig()
	return true
end

function ns.RemoveTrigger(index)
	if index == 1 or not ns.db.triggers[index] then
		ns.Print("trigger %d cannot be removed", index)
		return false
	end
	local removed = table.remove(ns.db.triggers, index)
	if ns.char and removed.id then ns.char.lists[removed.id] = nil end
	ns.Print("trigger %d removed", index)
	ns.ApplyConfig()
	return true
end

function ns.SetScale(scale)
	scale = tonumber(scale)
	if not scale then return false end
	ns.db.scale = math.max(0.5, math.min(2, scale))
	ns.Print("scale set to %s", tostring(ns.db.scale))
	ns.ApplyConfig()
	return true
end

function ns.SetOuter(value)
	value = tonumber(value)
	if not value then return false end
	ns.db.outer = ns.ClampOuter(value)
	ns.Print("cancel radius set to %s x the ring radius", tostring(ns.db.outer))
	ns.ApplyConfig()
	return true
end

function ns.SetDebug(on)
	ns.db.debug = on and true or false
	ns.Print("debug %s", ns.db.debug and "on" or "off")
	ns.ApplyConfig()
end

function ns.TogglePreview()
	if InCombatLockdown() then
		ns.Print("not in combat")
		return false
	end
	if ring:IsShown() then
		ring:Hide()
	else
		ring:ClearAllPoints()
		ring:SetPoint("CENTER", UIParent, "CENTER")
		ring:Show()
	end
	return true
end

function ns.ResetAll()
	ns.ResetDB()
	ns.Print("defaults restored")
	ns.ApplyConfig()
end

-------------------------------------------------------------------------------
-- Slash commands
-------------------------------------------------------------------------------

SLASH_RADICALRADIAL1 = "/rr"
SLASH_RADICALRADIAL2 = "/radicalradial"
SlashCmdList.RADICALRADIAL = function(input)
	local tokens = {}
	for token in (input or ""):gmatch("%S+") do tokens[#tokens + 1] = token end

	-- Optional leading trigger number: "/rr 2 bars 3 4"
	local index, first = 1, 1
	local n = tonumber(tokens[1])
	if n and n >= 1 and n <= ns.MAX_TRIGGERS and n == math.floor(n) and tokens[2] then
		index, first = n, 2
	end
	local cmd = (tokens[first] or ""):lower()
	local rest = table.concat(tokens, " ", first + 1)

	-- Ring names may contain spaces. A name in quotes is taken as written;
	-- otherwise the longest run of tokens from `from` that names an existing
	-- ring is the name ("Utility belt 5 spell 6603" finds Utility belt), else
	-- the first token, or the whole rest when nothing follows the name.
	-- Returns the name and the index of the token after it.
	local function Unquote(text)
		if #text >= 2 and text:sub(1, 1) == '"' and text:sub(-1) == '"' then return text:sub(2, -2) end
		return text
	end
	local function TakeRingName(from, wholeRest)
		local text = tokens[from]
		if not text then return nil, from end
		if text:sub(1, 1) == '"' then
			for j = from, #tokens do
				if tokens[j]:sub(-1) == '"' and (j > from or #text > 1) then
					return Unquote(table.concat(tokens, " ", from, j)), j + 1
				end
			end
		end
		for j = #tokens, from + 1, -1 do
			local candidate = table.concat(tokens, " ", from, j)
			if ns.FindRing(candidate) then return candidate, j + 1 end
		end
		if wholeRest then return table.concat(tokens, " ", from), #tokens + 1 end
		return text, from + 1
	end

	-- Wheel list arguments: bar numbers and ring names, in order.
	local function Bars()
		local list, i = {}, first + 1
		while tokens[i] do
			local bar = tonumber(tokens[i])
			if bar then
				list[#list + 1] = bar
				i = i + 1
			else
				local name, nextToken = TakeRingName(i)
				list[#list + 1] = name
				i = nextToken
			end
		end
		return ns.CleanBars(list)
	end

	local function RingCommand()
		local sub = (tokens[first + 1] or ""):lower()
		local from = first + 2
		if not tokens[from] then return nil end
		if sub == "add" then
			return ns.AddRing(Unquote(table.concat(tokens, " ", from)))
		elseif sub == "import" then
			return ns.ImportRing(table.concat(tokens, " ", from)) ~= nil
		elseif sub == "copy" then
			if not tokens[from + 1] then return nil end
			local other = ns.FindCharacter(tokens[from])
			return other ~= nil and ns.CopyRingFrom(other.key, Unquote(table.concat(tokens, " ", from + 1))) ~= nil
		end
		local name, nextToken = TakeRingName(from, sub == "remove" or sub == "export")
		local a, b = tokens[nextToken], tokens[nextToken + 1]
		if sub == "remove" then
			return ns.RemoveRing(name)
		elseif sub == "rename" and a then
			return ns.RenameRing(name, Unquote(table.concat(tokens, " ", nextToken)))
		elseif sub == "set" and a and b and tokens[nextToken + 2] then
			local kind = b:lower()
			local value = Unquote(table.concat(tokens, " ", nextToken + 2))
			local slice
			if kind == "macro" or kind == "ring" then slice = { kind = kind, name = value } else slice = { kind = kind, id = tonumber(value) } end
			return ns.SetRingSlice(name, a, slice)
		elseif sub == "layout" and a then
			return ns.SetRingLayout(name, a)
		elseif sub == "clear" and a then
			return ns.ClearRingSlice(name, a)
		elseif sub == "fill" and a then
			return ns.FillRingFromBar(name, a, b and b:lower() or "all")
		elseif sub == "export" then
			local text = ns.ExportRing(name)
			if text then ns.Print("copy this string: %s", text) end
			return text ~= nil
		end
		return nil
	end

	if cmd == "" or cmd == "config" or cmd == "options" then
		if ns.ToggleConfig then ns.ToggleConfig() else Usage() end
	elseif cmd == "bind" then
		if rest == "" then Usage() return end
		ns.SetTriggerKey(index, rest)
	elseif cmd == "bars" then
		local bars = Bars()
		if #bars == 0 then Usage() return end
		ns.SetTriggerBars(index, bars)
	elseif cmd == "harm" or cmd == "help" then
		local bars = Bars()
		if #bars == 0 and rest:lower() ~= "none" then Usage() return end
		ns.SetTriggerContext(index, cmd, bars)
	elseif cmd == "capture" then
		if not ns.SetTriggerCapture(index, rest:lower()) then Usage() end
	elseif cmd == "mode" then
		if not ns.SetTriggerMode(index, rest:lower()) then Usage() end
	elseif cmd == "autohide" then
		if not ns.SetTriggerAutohide(index, rest) then Usage() end
	elseif cmd == "layout" then
		if not ns.SetTriggerLayout(index, rest) then Usage() end
	elseif cmd == "click" then
		local on = rest:lower()
		if on == "on" or on == "off" then ns.SetTriggerClick(index, on == "on") else Usage() end
	elseif cmd == "macro" then
		if rest:lower() == "create" then
			ns.CreateTriggerMacro(index)
		else
			ns.Print("trigger %d opens from an action bar with the macro: %s (/rr %d macro create makes it and puts it on the cursor)", index, ns.MacroText(index), index)
		end
	elseif cmd == "remove" then
		ns.RemoveTrigger(index)
	elseif cmd == "triggers" then
		ListTriggers()
	elseif cmd == "rings" then
		ListRings()
	elseif cmd == "ring" then
		if RingCommand() == nil then Usage() end
	elseif cmd == "scale" then
		if not ns.SetScale(rest) then Usage() end
	elseif cmd == "outer" then
		if not ns.SetOuter(rest) then Usage() end
	elseif cmd == "preview" then
		ns.TogglePreview()
	elseif cmd == "debug" then
		ns.SetDebug(not ns.db.debug)
	elseif cmd == "status" then
		Status()
	elseif cmd == "reset" then
		ns.ResetAll()
	else
		Usage()
	end
end
