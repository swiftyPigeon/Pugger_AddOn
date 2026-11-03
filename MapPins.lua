local ADDON, ns = ...

-- The calls on the world map and the minimap, placed with HereBeDragons-Pins (as Guild Master
-- Forever's Decree.lua and Board.lua), each with a tooltip: what, where, how old, who called.
-- A button at the world map's bottom left opens the switches (also /pug map).

local MapPins = {}
ns.MapPins = MapPins

local ICONS = {
	R = "Interface\\TargetingFrame\\UI-TargetingFrame-Skull",
	C = "Interface\\Icons\\Spell_Fire_Fire",
	G = "Interface\\Icons\\INV_Misc_GroupNeedMore",
	D = "Interface\\Icons\\INV_Misc_Rune_01",
}
local SWITCH = { R = "showRares", C = "showCamps", G = "showGroups", D = "showGroups" }

local Pins
local pool, used = {}, {} -- frames: { world, mini } per call id
local SHOW = HBD_PINS_WORLDMAP_SHOW_CONTINENT or 2

local function Tooltip(self)
	local c = self.call and ns.Calls.Get(self.call)
	if not c then return end
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip:AddLine(ns.UI.CallTitle(c), 1, 0.82, 0)
	GameTooltip:AddLine(ns.UI.CallWhere(c), 0.9, 0.9, 0.9)
	GameTooltip:AddLine(("%s · %s"):format(ns.DisplayName(c.caller), ns.Ago(c.t)), 0.7, 0.7, 0.7)
	if c.note and c.note ~= "" then GameTooltip:AddLine(c.note, 1, 1, 1, true) end
	GameTooltip:Show()
end

local function NewPin(size)
	local f = CreateFrame("Button", nil, UIParent)
	f:SetSize(size, size)
	f.tex = f:CreateTexture(nil, "OVERLAY")
	f.tex:SetAllPoints()
	f:SetScript("OnEnter", Tooltip)
	f:SetScript("OnLeave", function() GameTooltip:Hide() end)
	f:SetScript("OnClick", function(self) if self.call then ns.UI.ShowCall(self.call) end end)
	return f
end

local function Take()
	local p = table.remove(pool)
	if p then return p end
	return { world = NewPin(18), mini = NewPin(14) }
end

function MapPins.Refresh()
	if not Pins then return end
	Pins:RemoveAllWorldMapIcons(MapPins)
	Pins:RemoveAllMinimapIcons(MapPins)
	for id, p in pairs(used) do
		p.world:Hide()
		p.mini:Hide()
		pool[#pool + 1] = p
		used[id] = nil
	end
	local s = ns.db.settings
	for _, c in ipairs(ns.Calls.List("all")) do
		if s[SWITCH[c.kind]] then
			local p = Take()
			used[c.id] = p
			for _, f in ipairs({ p.world, p.mini }) do
				f.call = c.id
				f.tex:SetTexture(ICONS[c.kind])
				f:Show()
			end
			pcall(Pins.AddWorldMapIconMap, Pins, MapPins, p.world, c.map, c.x, c.y, SHOW)
			pcall(Pins.AddMinimapIconMap, Pins, MapPins, p.mini, c.map, c.x, c.y, true, true)
		end
	end
end

---------------------------------------------------------------------------
-- The switches: a button on the world map, and /pug map.
---------------------------------------------------------------------------

local menu
function MapPins.ToggleMenu(anchor)
	if not menu then
		menu = ns.UI.Menu()
	end
	local s = ns.db.settings
	local function Switch(key) return function() s[key] = not s[key] MapPins.Refresh() end end
	menu:Open(anchor or UIParent, {
		{ text = ns.L.MAP_TITLE, title = true },
		{ text = ns.L.MAP_RARES, check = s.showRares, go = Switch("showRares") },
		{ text = ns.L.MAP_CAMPS, check = s.showCamps, go = Switch("showCamps") },
		{ text = ns.L.MAP_GROUPS, check = s.showGroups, go = Switch("showGroups") },
		{ text = ns.L.MAP_RARE_POPUPS, check = s.rarePopups, go = Switch("rarePopups") },
		{ text = ns.L.MAP_GROUP_POPUPS, check = s.groupPopups, go = Switch("groupPopups") },
		{ text = ns.L.MAP_LEVEL_ONLY, check = s.groupLevelOnly, go = Switch("groupLevelOnly") },
	})
end

MapPins.BUTTON_X = 44 -- from the map's left edge: clear of the corner other add-ons use

local toggle
local function MapButton()
	if toggle or type(WorldMapFrame) ~= "table" then return end
	local parent = type(WorldMapFrame.ScrollContainer) == "table" and WorldMapFrame.ScrollContainer or WorldMapFrame
	toggle = CreateFrame("Button", "Pugger_MapButton", parent)
	-- Round, in the minimap buttons' gold ring; a little in from the bottom-left corner, where
	-- other add-ons (Guild Master Forever's among them) put their map button.
	toggle:SetSize(31, 31)
	toggle:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", MapPins.BUTTON_X, 6)
	toggle:SetFrameLevel((parent:GetFrameLevel() or 1) + 20)
	local t = toggle:CreateTexture(nil, "BACKGROUND")
	t:SetSize(20, 20)
	t:SetPoint("CENTER", 0, 1)
	t:SetTexture(ns.ICON)
	if t.SetMask then pcall(t.SetMask, t, "Interface\\CharacterFrame\\TempPortraitAlphaMask") end
	local ring = toggle:CreateTexture(nil, "OVERLAY")
	ring:SetSize(53, 53)
	ring:SetPoint("TOPLEFT")
	ring:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
	toggle:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
	toggle:SetScript("OnClick", function(self) MapPins.ToggleMenu(self) end)
	toggle:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine("Pugger", 0.89, 0.71, 0.36)
		GameTooltip:AddLine(ns.L.MAP_BUTTON_TIP, 1, 1, 1, true)
		GameTooltip:Show()
	end)
	toggle:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

ns.On("LOGIN", function()
	Pins = LibStub and LibStub("HereBeDragons-Pins-2.0", true)
	if Pins and not Pins.AddWorldMapIconMap then Pins = nil end
	if not Pins then ns.Log("map library unavailable: no pins") end
	ns.SafeCall("map button", MapButton)
	if not toggle then
		ns.RegisterEvent("ADDON_LOADED", function(name)
			if name == "Blizzard_WorldMap" then ns.SafeCall("map button", MapButton) end
		end)
	end
	local pending = false
	-- Quest groups show only within range: looked at again as the player moves.
	C_Timer.NewTicker(10, function() ns.SafeCall("map refresh", MapPins.Refresh) end)
	ns.On("CALLS_CHANGED", function()
		if pending then return end
		pending = true
		ns.After(0.5, "map refresh", function() pending = false MapPins.Refresh() end)
	end)
end)
