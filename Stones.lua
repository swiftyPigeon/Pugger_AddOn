local ADDON, ns = ...

-- Every dungeon's meeting stone: the dungeon, the zones its stone stands in (Classic uiMapIDs),
-- the level range the game suggests, and the stone's spot on the zone map (x, y from 0 to 1).
--
-- The spots are left empty until someone stands at each stone and types /pug stone here
-- <dungeon> (Phase 0): a guessed spot would refuse honest calls 30 yards away. A stone with a spot
-- is checked both ways: the prompt comes within NEAR yards of it, and a call made far from it is
-- dropped by everyone. Without a spot, the prompt comes when the player uses the stone (the
-- summoning spell, Calls.lua) and receivers can't check the call's position.
-- Paste what /pug stone export prints here, once checked.
--
-- Until then, players' clients learn the spots from each other, silently (the gossip, below).

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
	-- (One stone in Blackrock Mountain serves all three: `shared`.)
	{ key = "brd",   name = "Blackrock Depths",     zones = { 1427, 1428 }, lo = 52, hi = 60, shared = "brm" },
	{ key = "lbrs",  name = "Lower Blackrock Spire", zones = { 1427, 1428 }, lo = 55, hi = 60, shared = "brm" },
	{ key = "ubrs",  name = "Upper Blackrock Spire", zones = { 1427, 1428 }, lo = 58, hi = 60, shared = "brm" },
	{ key = "dire",  name = "Dire Maul",            zones = { 1444 },       lo = 55, hi = 60 },
	{ key = "scholo", name = "Scholomance",         zones = { 1422 },       lo = 58, hi = 60 },
	{ key = "strat", name = "Stratholme",           zones = { 1423 },       lo = 58, hi = 60 },
}

local byKey = {}
for _, s in ipairs(Stones.LIST) do byKey[s.key] = s end

function Stones.Get(key) return byKey[key] end

-- The shipped table's spot only: the one spot strict enough to drop a call made far from it.
function Stones.TableSpot(s)
	if s.x and s.zones[1] then return s.map or s.zones[1], s.x, s.y end
	return nil
end

-- The stone's spot as best known, for help only (the prompt, the AT THE STONE badge): the
-- shipped table's, then one this player recorded, then one the players agreed on (the gossip).
function Stones.Spot(s)
	local m, x, y = Stones.TableSpot(s)
	if m then return m, x, y end
	local rec = ns.db and ns.db.stones[s.key]
	if rec and rec.map and rec.x then return rec.map, rec.x, rec.y end
	return Stones.Agreed(s.key)
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

-- /pug stone here <key>: this player's spot as that stone's.
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
	Stones.Sighted(map, x, y, s.key, true)
end

-- /pug stone export: the spots this player recorded, then the ones the players agreed on, as
-- lines for the table above.
function Stones.Export()
	local lines = {}
	for _, s in ipairs(Stones.LIST) do
		local rec = ns.db.stones[s.key]
		if rec then
			lines[#lines + 1] = ("%s: map = %d, x = %.4f, y = %.4f  -- recorded here"):format(s.key, rec.map, rec.x, rec.y)
		else
			local m, x, y, votes = Stones.Agreed(s.key)
			if m then lines[#lines + 1] = ("%s: map = %d, x = %.4f, y = %.4f  -- agreed by %d players"):format(s.key, m, x, y, votes) end
		end
	end
	if #lines == 0 then return ns.Print(ns.L.STONE_NONE) end
	ns.Diagnostics.ShowCopy(ns.L.STONE_EXPORT_TITLE, table.concat(lines, "\n"))
end

---------------------------------------------------------------------------
-- The gossip: the players' clients learn the stones' spots from each other, silently.
--
-- Sightings: a client's own, first-hand records (ns.db.stoneSeen): a stone its player hovered over
-- (the game's tooltip names it), recorded with /pug stone here, or started a dungeon group at.
-- Reports: hovering over a stone no spot is agreed for yet sends ONE report on the channel
-- (S1~map~x~y~key), once per stone ever. Clients holding a first-hand sighting near it answer
-- (S2, same fields) after a random 2-10 s, until ANSWERS answers were heard: a report costs at most
-- three messages. A dungeon call is a report too (its caller stands at the stone and names it).
-- Votes: every report, answer and call is one vote from its sender for a cluster of spots within
-- CLUSTER yards; the player's own sighting is one vote too. VOTES votes from different players
-- make the spot agreed. Only first-hand sightings answer, never a spot learned from others, so a
-- liar's spot is never echoed: a fake spot needs VOTES real players who stood where no stone is.
-- Which dungeon: the keys named by votes (calls, /pug stone here); else, on Forever, the zone's
-- only stone (Blackrock Mountain's one stone counts once). Agreed spots only help (the prompt,
-- the badge); they never drop a call (Stones.TableSpot does that).
---------------------------------------------------------------------------

Stones.CLUSTER = 30     -- yards: reports this close are about the same stone
Stones.VOTES = 3        -- different players for a spot to be agreed (the player's own sighting counts)
Stones.ANSWERS = 2      -- answers to one report, then the others stay quiet
Stones.MAX_CLUSTERS = 200
Stones.MAX_SEEN = 80
Stones.PER_HOUR = 12    -- reports and answers counted from one sender in an hour

local function Yards(m1, x1, y1, m2, x2, y2)
	if m1 ~= m2 then return nil end
	local d = ns.Calls and ns.Calls.Distance(m1, x1, y1, m2, x2, y2)
	if d == nil then d = math.max(math.abs(x1 - x2), math.abs(y1 - y2)) * 1000 end
	return d
end

local function Near(a, map, x, y, yards)
	local d = Yards(a.map, a.x, a.y, map, x, y)
	return d ~= nil and d <= (yards or Stones.CLUSTER)
end

-- The player's own sighting near a spot, if any.
local function OwnNear(map, x, y)
	for _, s in ipairs(ns.db.stoneSeen) do
		if Near(s, map, x, y) then return s end
	end
	for key, rec in pairs(ns.db.stones) do
		if rec.map and Near(rec, map, x, y) then return { map = rec.map, x = rec.x, y = rec.y, key = key } end
	end
end

-- A stone the player saw (key: the dungeon, when known). report: send it to the others.
function Stones.Sighted(map, x, y, key, report)
	local seen = ns.db.stoneSeen
	local s = OwnNear(map, x, y)
	if s and s.t then
		s.t = ns.Now()
		if key then s.key = key end
	else
		s = { map = map, x = x, y = y, key = key, t = ns.Now() }
		seen[#seen + 1] = s
		while #seen > Stones.MAX_SEEN do table.remove(seen, 1) end
	end
	-- Reported once per stone, ever, and not where a spot is already known.
	local id = ("%d:%d:%d"):format(map, math.floor(x * 50), math.floor(y * 50))
	if not report then
		-- Quiet only when OTHER players already agreed on it: our sighting is news to them otherwise.
		if Stones.KnownNear(map, x, y, true) then return end
		if ns.db.stoneReported[id] then return end
	end
	ns.db.stoneReported[id] = ns.Now()
	ns.Comm.Send(("S1~%d~%d~%d~%s"):format(map, math.floor(x * 10000 + 0.5), math.floor(y * 10000 + 0.5), key or ""))
end

-- Is a spot known near here: the table's, or one the players agreed on (byOthers: without
-- counting the player's own sighting)?
function Stones.KnownNear(map, x, y, byOthers)
	for _, s in ipairs(Stones.LIST) do
		local m, sx, sy = Stones.TableSpot(s)
		if m and Yards(m, sx, sy, map, x, y) and Yards(m, sx, sy, map, x, y) <= Stones.CLUSTER then return true end
	end
	for _, c in ipairs(ns.db.stoneVotes) do
		if Near(c, map, x, y) then
			local v = byOthers and ns.Count(c.voters) - (c.voters[ns.me] and 1 or 0) or Stones.Votes(c)
			if v >= Stones.VOTES then return true end
		end
	end
	return false
end

-- A cluster's votes: the different players behind it, the player's own sighting included.
function Stones.Votes(c)
	local n = ns.Count(c.voters)
	if not c.voters[ns.me] and OwnNear(c.map, c.x, c.y) then n = n + 1 end
	return n
end

local heard = {} -- [sender] = { times } this hour
local function Admit(sender)
	local list = heard[sender] or {}
	heard[sender] = list
	local now = ns.Now()
	while list[1] and now - list[1] > 3600 do table.remove(list, 1) end
	if #list >= Stones.PER_HOUR then return false end
	list[#list + 1] = now
	return true
end

-- One player's vote for a spot (key: the dungeon they named, or nil).
function Stones.Vote(sender, map, x, y, key)
	local votes = ns.db.stoneVotes
	local cluster
	for _, c in ipairs(votes) do
		if Near(c, map, x, y) then cluster = c break end
	end
	if not cluster then
		if #votes >= Stones.MAX_CLUSTERS then
			-- Full: the one with the fewest votes goes (a flood of fake spots never pushes out an agreed one).
			local worst, wi
			for i, c in ipairs(votes) do
				local v = ns.Count(c.voters)
				if not worst or v < worst then worst, wi = v, i end
			end
			table.remove(votes, wi)
		end
		cluster = { map = map, x = x, y = y, voters = {}, keys = {}, t = ns.Now() }
		votes[#votes + 1] = cluster
	end
	if not cluster.voters[sender] and ns.Count(cluster.voters) < 20 then cluster.voters[sender] = ns.Now() end
	if key and byKey[key] then
		cluster.keys[key] = cluster.keys[key] or {}
		cluster.keys[key][sender] = true
	end
	return cluster
end

-- Which dungeons a cluster's stone is for: the keys its votes named, most first; else, on
-- Forever, the zone's only stone (Blackrock Mountain's one stone: all three).
local function KeysOf(c)
	local best, n = nil, 0
	for key, who in pairs(c.keys or {}) do
		local k = ns.Count(who)
		if k > n then best, n = key, k end
	end
	local own = OwnNear(c.map, c.x, c.y)
	if not best and own and own.key then best = own.key end
	if best then
		local s = byKey[best]
		local out = {}
		for _, x in ipairs(Stones.LIST) do
			if x.key == best or (s.shared and x.shared == s.shared) then out[x.key] = true end
		end
		return out
	end
	if not Stones.Strict(c.map) then return {} end
	local groups, list = {}, {}
	for _, s in ipairs(Stones.LIST) do
		if Stones.InZone(s, c.map) then
			local g = s.shared or s.key
			if not groups[g] then groups[g] = {} list[#list + 1] = g end
			groups[g][#groups[g] + 1] = s.key
		end
	end
	if #list ~= 1 then return {} end
	local out = {}
	for _, key in ipairs(groups[list[1]]) do out[key] = true end
	return out
end

-- The spot the players agreed on for a dungeon: map, x, y and how many voted; nil without one.
function Stones.Agreed(key)
	if not ns.db then return nil end
	local best, bestVotes
	for _, c in ipairs(ns.db.stoneVotes) do
		local v = Stones.Votes(c)
		if v >= Stones.VOTES and KeysOf(c)[key] and (not best or v > bestVotes) then best, bestVotes = c, v end
	end
	if best then return best.map, best.x, best.y, bestVotes end
end

-- For /pug status: spots in the table, recorded here, agreed by the players.
function Stones.Counts()
	local table_, recorded, agreed = 0, ns.Count(ns.db.stones), 0
	for _, s in ipairs(Stones.LIST) do
		if Stones.TableSpot(s) then table_ = table_ + 1 end
		if Stones.Agreed(s.key) then agreed = agreed + 1 end
	end
	return table_, recorded, agreed
end

local function Read(text, kind)
	local map, x, y, key = text:match("^" .. kind .. "~(%d+)~(%d+)~(%d+)~(%l*)$")
	map, x, y = ns.Codec.Int(map, 1, 100000), ns.Codec.Int(x, 0, 10000), ns.Codec.Int(y, 0, 10000)
	if not map or not x or not y then return nil end
	if key == "" or not byKey[key] then key = nil end
	return map, x / 10000, y / 10000, key
end

local answers = {} -- [report id] = { heard = n, pending = true }

ns.Comm.Handle("S1", function(dist, sender, text)
	if dist ~= "CHANNEL" or not Admit(sender) then return end
	local map, x, y, key = Read(text, "S1")
	if not map then return end
	Stones.Vote(sender, map, x, y, key)
	-- A first-hand sighting of our own near it: an answer, unless enough came first.
	local own = OwnNear(map, x, y)
	if not own then return end
	local id = sender .. ("#%d:%d:%d"):format(map, math.floor(x * 50), math.floor(y * 50))
	local a = { heard = 0 }
	answers[id] = a
	ns.After(2 + math.random() * 8, "stone answer", function()
		if a.heard >= Stones.ANSWERS then return end
		ns.Comm.Send(("S2~%d~%d~%d~%s~%s"):format(own.map, math.floor(own.x * 10000 + 0.5), math.floor(own.y * 10000 + 0.5),
			own.key or "", sender))
	end)
end)

ns.Comm.Handle("S2", function(dist, sender, text)
	if dist ~= "CHANNEL" or not Admit(sender) then return end
	local body, to = text:match("^(S2~%d+~%d+~%d+~%l*)~(.+)$")
	if not body then return end
	local map, x, y, key = Read(body, "S2")
	if not map then return end
	Stones.Vote(sender, map, x, y, key)
	-- One more answer to that report: ours may stay quiet.
	local a = answers[to .. ("#%d:%d:%d"):format(map, math.floor(x * 50), math.floor(y * 50))]
	if not a then
		for id, b in pairs(answers) do
			local who, m, bx, by = id:match("^(.+)#(%d+):(%d+):(%d+)$")
			if who == to and tonumber(m) == map and Yards(map, bx / 50, by / 50, map, x, y) and Yards(map, bx / 50, by / 50, map, x, y) <= Stones.CLUSTER then a = b break end
		end
	end
	if a then a.heard = a.heard + 1 end
end)

ns.On("LOADED", function()
	ns.db.stoneSeen = ns.db.stoneSeen or {}
	ns.db.stoneVotes = ns.db.stoneVotes or {}
	ns.db.stoneReported = ns.db.stoneReported or {}
end)
