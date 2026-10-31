local ADDON, ns = ...

-- Every dungeon's meeting stone: the dungeon, the zones its stone stands in (Classic uiMapIDs),
-- the level range the game suggests, and the stone's spot on the zone map (x, y from 0 to 1).
--
-- The spots are left empty until someone stands at each stone and types /fax stone here
-- <dungeon> (Phase 0): a guessed spot would refuse honest calls 30 yards away. A stone with a spot
-- is checked both ways: the prompt comes within NEAR yards of it, and a call made far from it is
-- dropped by everyone. Without a spot, the prompt comes when the player uses the stone (the
-- summoning spell, Calls.lua) and receivers can't check the call's position.
-- Paste what /fax stone export prints here, once checked.

local Stones = {}
ns.Stones = Stones

Stones.NEAR = 20       -- yards: "at the stone"
Stones.CALL_NEAR = 60  -- yards: a call this far from its stone is still believed

-- key, name, zones, lo, hi, x, y (x, y nil: not recorded yet)
Stones.LIST = {
	{ key = "rfc",   name = "Ragefire Chasm",       zones = { 1454 },       lo = 13, hi = 18, faction = "Horde" },
	{ key = "wc",    name = "Wailing Caverns",      zones = { 1413 },       lo = 17, hi = 24 },
	{ key = "dm",    name = "The Deadmines",        zones = { 1436 },       lo = 17, hi = 26 },
	{ key = "sfk",   name = "Shadowfang Keep",      zones = { 1421 },       lo = 22, hi = 30 },
	{ key = "bfd",   name = "Blackfathom Deeps",    zones = { 1440 },       lo = 24, hi = 32 },
	{ key = "stocks", name = "The Stockade",        zones = { 1453 },       lo = 24, hi = 32, faction = "Alliance" },
	{ key = "gnomer", name = "Gnomeregan",          zones = { 1426 },       lo = 29, hi = 38 },
	{ key = "rfk",   name = "Razorfen Kraul",       zones = { 1413 },       lo = 29, hi = 38 },
	{ key = "sm",    name = "Scarlet Monastery",    zones = { 1420 },       lo = 34, hi = 45 },
	{ key = "rfd",   name = "Razorfen Downs",       zones = { 1413, 1441 }, lo = 37, hi = 46 },
	{ key = "ulda",  name = "Uldaman",              zones = { 1418 },       lo = 41, hi = 51 },
	{ key = "zf",    name = "Zul'Farrak",           zones = { 1446 },       lo = 44, hi = 54 },
	{ key = "mara",  name = "Maraudon",             zones = { 1443 },       lo = 46, hi = 55 },
	{ key = "st",    name = "Sunken Temple",        zones = { 1435 },       lo = 50, hi = 60 },
	{ key = "brd",   name = "Blackrock Depths",     zones = { 1427, 1428 }, lo = 52, hi = 60 },
	{ key = "lbrs",  name = "Lower Blackrock Spire", zones = { 1427, 1428 }, lo = 55, hi = 60 },
	{ key = "ubrs",  name = "Upper Blackrock Spire", zones = { 1427, 1428 }, lo = 58, hi = 60 },
	{ key = "dire",  name = "Dire Maul",            zones = { 1444 },       lo = 55, hi = 60 },
	{ key = "scholo", name = "Scholomance",         zones = { 1422 },       lo = 58, hi = 60 },
	{ key = "strat", name = "Stratholme",           zones = { 1423 },       lo = 58, hi = 60 },
}

local byKey = {}
for _, s in ipairs(Stones.LIST) do byKey[s.key] = s end

function Stones.Get(key) return byKey[key] end

-- The stone's spot: one this player recorded wins over the table's.
function Stones.Spot(s)
	local rec = ns.db and ns.db.stones[s.key]
	if rec and rec.map and rec.x then return rec.map, rec.x, rec.y end
	if s.x and s.zones[1] then return s.map or s.zones[1], s.x, s.y end
	return nil
end

function Stones.InZone(s, mapID)
	for _, z in ipairs(s.zones) do if z == mapID then return true end end
	return false
end

-- Does this client number its zones as Forever does (the Classic uiMapIDs above)? Only then
-- can a stone's zone be checked; a client that numbers them otherwise (MoP Classic, retail-style
-- IDs) can't, and the zone check is left out.
function Stones.Strict(mapID)
	return type(mapID) == "number" and mapID >= 1411 and mapID <= 1460
end

-- The stones a player at mapID may mean, for this player's faction: that zone's on Forever;
-- every dungeon elsewhere, those that fit the player's level first.
function Stones.OfZone(mapID)
	local out = {}
	local strict = Stones.Strict(mapID)
	for _, s in ipairs(Stones.LIST) do
		if (not strict or Stones.InZone(s, mapID)) and (not s.faction or s.faction == ns.faction) then out[#out + 1] = s end
	end
	if not strict then
		local lv = UnitLevel("player") or 0
		local function Gap(s) return lv < s.lo and s.lo - lv or (lv > s.hi and lv - s.hi or 0) end
		table.sort(out, function(a, b)
			if Gap(a) ~= Gap(b) then return Gap(a) < Gap(b) end
			return a.lo < b.lo
		end)
	end
	return out
end

-- /fax stone here <key>: this player's spot as that stone's.
function Stones.Record(key)
	local s = byKey[tostring(key or ""):lower()]
	if not s then
		local keys = {}
		for _, x in ipairs(Stones.LIST) do keys[#keys + 1] = x.key end
		return ns.Print(ns.L.STONE_KEYS:format(table.concat(keys, ", ")))
	end
	local map, x, y = ns.Calls.MyPosition()
	if not map then return ns.Print(ns.L.NO_POSITION) end
	if not Stones.InZone(s, map) then ns.Print(ns.L.STONE_OTHER_ZONE:format(s.name)) end
	ns.db.stones[s.key] = { map = map, x = x, y = y, t = ns.Now() }
	ns.Print(ns.L.STONE_RECORDED:format(s.name, map, x * 100, y * 100))
end

-- /fax stone export: the recorded spots as lines for the table above.
function Stones.Export()
	local lines = {}
	for _, s in ipairs(Stones.LIST) do
		local rec = ns.db.stones[s.key]
		if rec then lines[#lines + 1] = ("%s: map = %d, x = %.4f, y = %.4f"):format(s.key, rec.map, rec.x, rec.y) end
	end
	if #lines == 0 then return ns.Print(ns.L.STONE_NONE) end
	ns.Diagnostics.ShowCopy(ns.L.STONE_EXPORT_TITLE, table.concat(lines, "\n"))
end
