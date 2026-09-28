-------------------------------------------------------------------------------
-- Radical Radial — Config
--
-- Applying settings to the secure frames (out of combat, deferred otherwise),
-- events, diagnostics and the /rr slash commands.
-------------------------------------------------------------------------------

local ADDON, ns = ...

local header, opener, bindOwner = ns.header, ns.opener, ns.bindOwner
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
		return
	end
	pendingConfig = false

	ClearOverrideBindings(bindOwner)
	if db.trigger and db.trigger ~= "" and db.trigger ~= "none" then
		SetOverrideBindingClick(bindOwner, true, db.trigger, "RadicalRadialOpener", "LeftButton")
	end

	header:SetAttribute("barcount", #db.bars)
	for i, bar in ipairs(db.bars) do header:SetAttribute("bar" .. i, bar) end
	for bar, page in pairs(ns.PAGE_OF_BAR) do header:SetAttribute("pageofbar" .. bar, page) end
	header:SetAttribute("radius", ns.RADIUS * db.scale)
	header:SetAttribute("debug", db.debug and true or false)
	header:SetAttribute("page", 1)
	visual:SetScale(db.scale)

	-- Point the slices at page 1 through the same snippet the ring uses.
	local ok, err = pcall(SecureHandlerExecute, header, [[ self:RunAttribute("ApplyPage") ]])
	if not ok then
		ns.Print("|cffff4444secure snippets are not working on this build:|r %s", tostring(err))
	end
	ns.UpdateLabel()
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
		ns.Print("v%s loaded. Hold %s to open the ring. /rr for commands.", ns.VERSION, tostring(ns.db.trigger))
	elseif event == "PLAYER_REGEN_ENABLED" then
		if pendingConfig then ns.ApplyConfig() end
	end
end)

-------------------------------------------------------------------------------
-- Diagnostics
-------------------------------------------------------------------------------

BINDING_HEADER_RADICALRADIAL = "Radical Radial"
_G["BINDING_NAME_CLICK RadicalRadialOpener:LeftButton"] = "Open radial (hold)"

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

local function Status()
	local db = ns.db
	local version, build, _, toc = GetBuildInfo()
	ns.Print("v%s on client %s (build %s, interface %s, project %s), LibActionButton-1.0 r%s",
		ns.VERSION, tostring(version), tostring(build), tostring(toc), tostring(WOW_PROJECT_ID),
		tostring(LibStub.minors["LibActionButton-1.0"]))
	ns.Print("trigger: %s | bars: %s | scale: %s | debug: %s",
		tostring(db.trigger), table.concat(db.bars, " "), tostring(db.scale), db.debug and "on" or "off")
	if InCombatLockdown() then
		ns.Print("secure snippets: cannot self-test in combat")
	else
		local ok, err = SnippetSelfTest()
		ns.Print("secure snippets: %s", ok and "|cff33ff33OK|r" or ("|cffff4444FAILED|r " .. tostring(err)))
	end
	ns.Print("ring open: %s | page: %s | current base slot: %s",
		tostring(header:GetAttribute("open")), tostring(header:GetAttribute("page")),
		tostring(header:GetAttribute("basecurrent")))
	ns.Print("client paging: %s", PageReport())
end

local function Usage()
	ns.Print("commands:")
	print("  /rr bind KEY        trigger binding, e.g. BUTTON4, SHIFT-BUTTON5, F (none to clear)")
	print("  /rr bars 1 2 3      bars the wheel cycles through, in order (1-8)")
	print("  /rr scale 1.2       ring scale (0.5 to 2)")
	print("  /rr preview         show or hide the ring at screen centre, out of combat")
	print("  /rr debug           toggle chat output for every press, release, page and cancel")
	print("  /rr status          client, binding, snippet self-test and bar paging state")
	print("  /rr reset           restore defaults")
end

-------------------------------------------------------------------------------
-- Slash commands
-------------------------------------------------------------------------------

SLASH_RADICALRADIAL1 = "/rr"
SLASH_RADICALRADIAL2 = "/radicalradial"
SlashCmdList.RADICALRADIAL = function(input)
	local db = ns.db
	local cmd, rest = (input or ""):match("^%s*(%S*)%s*(.-)%s*$")
	cmd = cmd:lower()
	if cmd == "bind" then
		if rest == "" then Usage() return end
		db.trigger = rest:upper()
		ns.Print("trigger set to %s", db.trigger)
		ns.ApplyConfig()
	elseif cmd == "bars" then
		local bars = {}
		for token in rest:gmatch("%d+") do
			local bar = tonumber(token)
			if bar >= 1 and bar <= 8 then bars[#bars + 1] = bar end
		end
		if #bars == 0 then Usage() return end
		db.bars = bars
		ns.Print("wheel cycles: %s", table.concat(bars, " "))
		ns.ApplyConfig()
	elseif cmd == "scale" then
		local scale = tonumber(rest)
		if not scale then Usage() return end
		db.scale = math.max(0.5, math.min(2, scale))
		ns.Print("scale set to %s", tostring(db.scale))
		ns.ApplyConfig()
	elseif cmd == "preview" then
		if InCombatLockdown() then ns.Print("not in combat") return end
		if ring:IsShown() then
			ring:Hide()
		else
			ring:ClearAllPoints()
			ring:SetPoint("CENTER", UIParent, "CENTER")
			ring:Show()
		end
	elseif cmd == "debug" then
		db.debug = not db.debug
		header:SetAttribute("debug", db.debug and true or false)
		ns.Print("debug %s", db.debug and "on" or "off")
	elseif cmd == "status" then
		Status()
	elseif cmd == "reset" then
		ns.ResetDB()
		ns.Print("defaults restored")
		ns.ApplyConfig()
	else
		Usage()
	end
end
