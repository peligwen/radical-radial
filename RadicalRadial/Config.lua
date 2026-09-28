-------------------------------------------------------------------------------
-- Radical Radial — Config
--
-- Applying settings to the secure frames (out of combat, deferred otherwise),
-- events, diagnostics, the setters shared by the slash commands and the
-- options window (Options.lua), and the /rr slash commands.
-------------------------------------------------------------------------------

local ADDON, ns = ...

local header, openers, bindOwner = ns.header, ns.openers, ns.bindOwner
local ring, visual = ns.ring, ns.visual

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

	ClearOverrideBindings(bindOwner)
	for i, opener in ipairs(openers) do
		local t = db.triggers[i]
		if t then
			ns.NormalizeTrigger(t)
			if t.key ~= "" then
				SetOverrideBindingClick(bindOwner, true, t.key, opener:GetName(), "LeftButton")
			end
			opener:SetAttribute("barcount", #t.bars)
			for k = 1, 8 do opener:SetAttribute("bar" .. k, t.bars[k]) end
			for _, ctx in ipairs(ns.CONTEXTS) do
				opener:SetAttribute(ctx .. "count", #t[ctx])
				for k = 1, 8 do opener:SetAttribute(ctx .. k, t[ctx][k]) end
			end
			opener:SetAttribute("capture", t.capture)
			opener:SetAttribute("mode", t.mode)
			opener:SetAttribute("autohide", t.autohide)
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
	header:SetAttribute("page", 1)
	visual:SetScale(db.scale)
	ring:SetSize(ns.RingSize(db.scale), ns.RingSize(db.scale))

	-- Point the slices at trigger 1, page 1 through the same snippet the ring uses.
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
		if not ns.db then ns.LoadDB() end
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
	return #list > 0 and table.concat(list, " ") or "none"
end
local BarList = ns.BarList

local function DescribeTrigger(i, t)
	return ("trigger %d: %s | bars %s | harm %s | help %s | capture %s | mode %s | autohide %ss"):format(
		i, t.key ~= "" and t.key or "unbound", BarList(t.bars), BarList(t.harm), BarList(t.help),
		t.capture, t.mode, tostring(t.autohide))
end

local function ListTriggers()
	for i, t in ipairs(ns.db.triggers) do ns.Print(DescribeTrigger(i, t)) end
end

local function Status()
	local db = ns.db
	local version, build, _, toc = GetBuildInfo()
	ns.Print("v%s on client %s (build %s, interface %s, project %s), LibActionButton-1.0 r%s",
		ns.VERSION, tostring(version), tostring(build), tostring(toc), tostring(WOW_PROJECT_ID),
		tostring(LibStub.minors["LibActionButton-1.0"]))
	ns.Print("scale: %s | cancel radius: %s x ring radius | debug: %s", tostring(db.scale), tostring(db.outer), db.debug and "on" or "off")
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
	print("  /rr bars 1 2 3      bars the wheel cycles through, in order (1-8)")
	print("  /rr harm 3          bars shown instead when pressed over an enemy (none to clear)")
	print("  /rr help 4          bars shown instead when pressed over a friend (none to clear)")
	print("  /rr capture focus   what the press captures the unit under the cursor as: focus, target or none")
	print("  /rr mode hold|tap   hold: release fires, centre cancels. tap: centre keeps the ring open, next release fires")
	print("  /rr autohide 3      tap mode: seconds after the cursor leaves the ring before it closes (0 = never)")
	print("  /rr 2 remove        remove trigger 2 (trigger 1 stays; unbind it with /rr bind none)")
	print("  /rr triggers        list triggers")
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
		db.triggers[i] = ns.NormalizeTrigger({ key = "" })
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
	table.remove(ns.db.triggers, index)
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
	local function Bars() return ns.CleanBars({ strsplit(" ", rest) }) end

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
	elseif cmd == "remove" then
		ns.RemoveTrigger(index)
	elseif cmd == "triggers" then
		ListTriggers()
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
