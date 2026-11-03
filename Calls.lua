local ADDON, ns = ...

-- Live map calls: short-lived posts tied to a place, in the feed and on everyone's map
-- (section 4 of the plan). Never saved: a call lives in memory until it ends.
--   R  Rare call    a real rare (or tougher) as the caller's target; zone-wide; 15 min or "Dead"
--   C  Camp         "camp here" with a note; zone-wide; an hour, renewed with a click
--   G  Quest / farm group: only players within GROUP_YARDS of the caller in the same zone (and
--      the caller's party) ever see it; asks only from in range; 30 min or until full
--   D  Dungeon group: only at that dungeon's meeting stone; in everyone's Groups tab; asks from
--      any fitting level; until full, or 10 min after the caller left the stone
-- Calls are never relayed (no catch-up): the server says who sent each, so they carry no
-- signature. Location is never automatic: a call holds the spot the caller clicked from.
--
-- Wire (Codec.lua): M1~kind~cid~map~x~y~expires36~a~b~c~class~note (class: the caller's, for
-- their name's colour)
--   R: a = target name, b = classification (e|r|R|w), c = NPC id
--   G: a = quest or spot, b = the roles needed ("THDD": a tank, a healer, two damage; or a
--      count, 1-4, any role), c = "lo-hi"
--   D: a = dungeon key, b = the roles needed (as G), c = "lo-hi"
-- M2~caller~cid~u|d|f|x, J1 (ask, with the role the asker would fill), J2 (answer). The caller
-- sends M1 again when an invite fills a role: everyone's card shows the roles still needed.

local Calls = {}
ns.Calls = Calls
local Codec = ns.Codec

Calls.GROUP_YARDS = 300
Calls.LIFE = { R = 900, C = 3600, G = 1800, D = 3600 }
Calls.LIMIT = { R = 3, C = 4, G = 4, D = 4 } -- calls a player may make of each kind an hour
Calls.ASKS_WAITING = 5
Calls.AWAY_FROM_STONE = 600
Calls.NOTE_MAX = 80
-- Phase 0: SAY or YELL instead of the channel for group calls, if Forever carries add-on
-- messages there (the server's own range then). nil: the channel and the distance check.
Calls.GROUP_DIST = nil

-- The roles each class can fill (Forever's classes and MoP's); any other class: damage.
Calls.CLASS_ROLES = { WARRIOR = "TD", PALADIN = "THD", DRUID = "THD", PRIEST = "HD", SHAMAN = "HD",
	MONK = "THD", DEATHKNIGHT = "TD" }
Calls.ROLE_ORDER = { "T", "H", "D" }

-- Roles as a group call carries them: tanks, then healers, then damage, 4 at most ("THDD").
function Calls.Roles(t, h, d)
	return (("T"):rep(t or 0) .. ("H"):rep(h or 0) .. ("D"):rep(d or 0)):sub(1, 4)
end

-- How many of each role a roles string holds.
function Calls.RoleCounts(roles)
	local n = { T = 0, H = 0, D = 0 }
	for r in tostring(roles or ""):gmatch("[THD]") do n[r] = n[r] + 1 end
	return n
end

-- The roles call c still needs that this player's class can fill, in order (T, H, D).
function Calls.MyRoles(c)
	local can = Calls.CLASS_ROLES[select(2, UnitClass("player")) or ""] or "D"
	local out = {}
	for _, r in ipairs(Calls.ROLE_ORDER) do
		if c.roles and c.roles:find(r, 1, true) and can:find(r, 1, true) then out[#out + 1] = r end
	end
	return out
end

-- A group call's need as the wire carries it: the roles ("THDD", sorted, 1 to open at most) or
-- a count, 1 to open.
local function Need(need, open)
	if type(need) == "string" and need:match("^[THD]+$") then
		local n = Calls.RoleCounts(need)
		return Calls.Roles(n.T, n.H, n.D):sub(1, open)
	end
	return tostring(math.max(1, math.min(open, tonumber(need) or open)))
end

local CLASS = { elite = "e", rare = "r", rareelite = "R", worldboss = "w" }
local CLASS_NAME = { e = "elite", r = "rare", R = "rare elite", w = "world boss" }
Calls.CLASS_NAME = CLASS_NAME

local active = {}  -- [callId] = call
local mine = {}    -- [kind] = my active call's id
local made = {}    -- [kind] = { times } this hour
local cid = 0
local HBD = LibStub and LibStub("HereBeDragons-2.0", true)

local function Changed() ns.Fire("CALLS_CHANGED") end
local function CallId(caller, id) return caller .. "#" .. id end

---------------------------------------------------------------------------
-- Positions and distances
---------------------------------------------------------------------------

function Calls.MyPosition()
	if not C_Map or not C_Map.GetBestMapForUnit then return nil end
	local map = C_Map.GetBestMapForUnit("player")
	if not map then return nil end
	local pos = C_Map.GetPlayerMapPosition and C_Map.GetPlayerMapPosition(map, "player")
	if not pos then return nil end
	local x, y = pos.x, pos.y
	if pos.GetXY then x, y = pos:GetXY() end
	if not x or not y or (x == 0 and y == 0) then return nil end
	return map, x, y
end

-- Where the player is, for a post: the map and position, or the map alone where the game gives
-- no position (x, y nil); nil when not even the map is known.
function Calls.MyPlace()
	local map, x, y = Calls.MyPosition()
	if map then return map, x, y end
	map = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
	return map
end

-- Yards between two spots on zone maps; nil when they can't be compared (another continent,
-- or no map data).
function Calls.Distance(m1, x1, y1, m2, x2, y2)
	if not HBD or not m1 or not m2 then return nil end
	local ax, ay, ai = HBD:GetWorldCoordinatesFromZone(x1, y1, m1)
	local bx, by, bi = HBD:GetWorldCoordinatesFromZone(x2, y2, m2)
	if not ax or not bx or ai ~= bi then return nil end
	return HBD:GetWorldDistance(ai, ax, ay, bx, by)
end

function Calls.DistanceToMe(m, x, y)
	local mm, mx, my = Calls.MyPosition()
	if not mm then return nil end
	return Calls.Distance(mm, mx, my, m, x, y)
end

-- A map in our zone, or one next to it (their rectangles on the continent within 300 yd),
-- from HereBeDragons' world coordinates (Guild Master Forever's Decree.Near).
local function Rect(mapID)
	if not (HBD and HBD.GetWorldCoordinatesFromZone) then return nil end
	local x1, y1, inst = HBD:GetWorldCoordinatesFromZone(0, 0, mapID)
	local x2, y2 = HBD:GetWorldCoordinatesFromZone(1, 1, mapID)
	if not x1 or not x2 then return nil end
	return math.min(x1, x2), math.max(x1, x2), math.min(y1, y2), math.max(y1, y2), inst
end
function Calls.Near(mapID)
	local mine_ = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
	if not mine_ or not mapID then return false end
	if mine_ == mapID then return true end
	local ax1, ax2, ay1, ay2, ai = Rect(mine_)
	local bx1, bx2, by1, by2, bi = Rect(mapID)
	if not ax1 or not bx1 or ai ~= bi then return false end
	local m = 300
	return ax1 - m <= bx2 and bx1 - m <= ax2 and ay1 - m <= by2 and by1 - m <= ay2
end

function Calls.MyZone()
	return C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
end

function Calls.ZoneName(mapID)
	local info = mapID and C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(mapID)
	return info and info.name or ("#" .. tostring(mapID))
end

local function InMyParty(name)
	if not IsInGroup or not IsInGroup() then return false end
	local short = ns.TellName(name)
	return UnitInParty and (UnitInParty(short) or UnitInRaid and UnitInRaid(short)) and true or false
end

local function LevelFits(c)
	local lv = UnitLevel("player") or 0
	return not c.lo or (lv >= c.lo and lv <= c.hi)
end
Calls.LevelFits = LevelFits

---------------------------------------------------------------------------
-- What the player sees
---------------------------------------------------------------------------

-- Is this call one the player should see now?
function Calls.Shown(c)
	if c.ended or ns.Now() >= c.expires then return false end
	if ns.Safety.IsBlocked(c.caller) or ns.Safety.IsMuted(c.caller) then return false end
	local slow = ns.rdb.slow[c.caller]
	if slow and slow > ns.Now() and not c.mine then return false end
	if c.kind == "G" and not c.mine and not c.demo then
		if InMyParty(c.caller) then return true end
		local d = Calls.DistanceToMe(c.map, c.x, c.y)
		return d ~= nil and d <= Calls.GROUP_YARDS
	end
	return true
end

-- "nearby": rares, camps and quest groups in this zone and the ones next to it;
-- "groups": dungeon calls; "realm": dungeon calls for the Realm timeline's small line.
function Calls.List(view)
	local out = {}
	for _, c in pairs(active) do
		if Calls.Shown(c) then
			if view == "nearby" and c.kind ~= "D" and (c.kind == "G" or Calls.Near(c.map)) then out[#out + 1] = c
			elseif (view == "groups" or view == "realm") and c.kind == "D" then out[#out + 1] = c
			elseif view == "all" then out[#out + 1] = c end
		end
	end
	table.sort(out, function(a, b) return a.t > b.t end)
	return out
end

function Calls.Get(id) return active[id] end

function Calls.Votes(c)
	local up, dead = 0, 0
	for _, v in pairs(c.votes) do
		if v == "u" then up = up + 1 elseif v == "d" then dead = dead + 1 end
	end
	return up, dead
end

---------------------------------------------------------------------------
-- Making calls
---------------------------------------------------------------------------

local function Allowed(kind)
	local list = made[kind] or {}
	made[kind] = list
	local now = ns.Now()
	while list[1] and now - list[1] > 3600 do table.remove(list, 1) end
	if #list >= Calls.LIMIT[kind] then return false end
	return true
end

local function Encode(c)
	return table.concat({ "M1", c.kind, Codec.Base36(c.cid), tostring(c.map), tostring(math.floor(c.x * 10000 + 0.5)),
		tostring(math.floor(c.y * 10000 + 0.5)), Codec.Base36(c.expires), Codec.Clean(c.a or ""), Codec.Clean(c.b or ""),
		Codec.Clean(c.c or ""), Codec.Clean(c.cls or ""), Codec.Clean(c.note or "") }, "~")
end

local function Broadcast(c)
	local msg = Encode(c)
	if c.kind == "G" and Calls.GROUP_DIST then
		local ok = pcall(C_ChatInfo.SendAddonMessageLogged, ns.PREFIX, msg, Calls.GROUP_DIST)
		if ok then return end
	end
	ns.Comm.Send(msg, { logged = true, key = "M1" .. c.cid })
end

-- fields: a, b, c, note, lo, hi, stone. Returns the call, or nil and why.
local function Make(kind, map, x, y, fields)
	if not ns.Comm.Ready() then return nil, ns.L.NOT_CONNECTED end
	if not ns.Safety.CanPost() then return nil, ns.L.NEED_LEVEL:format(ns.Safety.LEVEL_TO_POST) end
	if not Allowed(kind) then return nil, ns.L.CALL_LIMIT end
	if mine[kind] and active[mine[kind]] and not active[mine[kind]].ended then Calls.End(mine[kind], "x") end
	cid = (cid + 1) % 46656
	local now = ns.Now()
	local c = {
		kind = kind, cid = cid, caller = ns.me, map = map, x = x, y = y, t = now, expires = now + Calls.LIFE[kind],
		a = fields.a, b = fields.b, c = fields.c, note = ns.Cut(Codec.Clean(fields.note or ""), Calls.NOTE_MAX * 2),
		votes = {}, asks = {}, mine = true, cls = select(2, UnitClass("player")),
	}
	Calls.Read(c)
	c.total = c.need -- (the roles still needed shrink as invites go out; the party fills against this)
	c.id = CallId(ns.me, Codec.Base36(cid))
	active[c.id] = c
	mine[kind] = c.id
	table.insert(made[kind], now)
	if kind == "G" or kind == "D" then c.party0 = GetNumGroupMembers and GetNumGroupMembers() or 0 end
	ns.Consent.Ask(function()
		Broadcast(c)
		Changed()
	end)
	return c
end

-- The target a rare call needs: living, attackable, rare or tougher (Guild Master Forever's
-- Decree.RareTarget).
function Calls.RareTarget()
	if not UnitExists("target") or UnitIsDead("target") or not UnitCanAttack("player", "target") then return nil end
	local class = CLASS[UnitClassification("target") or ""]
	if not class then return nil end
	local guid, name = UnitGUID("target"), UnitName("target")
	if type(guid) ~= "string" or type(name) ~= "string" then return nil end
	local npc = guid:match("^%a+%-%d+%-%d+%-%d+%-%d+%-(%d+)%-")
	return name, class, npc or "0"
end

function Calls.Rare()
	local name, class, npc = Calls.RareTarget()
	if not name then return ns.Print(ns.L.RARE_NEED_TARGET) end
	local map, x, y = Calls.MyPosition()
	if not map then return ns.Print(ns.L.NO_POSITION) end
	-- One call per rare at a time: a second one is a "still up" for the first.
	for id, c in pairs(active) do
		if c.kind == "R" and c.c == npc and c.map == map and Calls.Shown(c) then
			if not c.mine then Calls.Vote(id, "u") end
			return ns.Print(ns.L.RARE_ALREADY:format(c.a, ns.DisplayName(c.caller)))
		end
	end
	local c, why = Make("R", map, x, y, { a = name, b = class, c = npc })
	if not c then return ns.Print(why) end
	c.votes[ns.me] = "u"
end

function Calls.Camp(note)
	local map, x, y = Calls.MyPosition()
	if not map then return ns.Print(ns.L.NO_POSITION) end
	local _, why = Make("C", map, x, y, { note = note })
	if why then ns.Print(why) end
end

-- A quest or farm group, away from a stone. need: the roles ("THDD") or a count, 1-4.
function Calls.Group(what, need, note)
	local map, x, y = Calls.MyPosition()
	if not map then return ns.Print(ns.L.NO_POSITION) end
	need = Need(need or "1", 4)
	local lv = UnitLevel("player") or 1
	local _, why = Make("G", map, x, y, { a = ns.Cut(Codec.Clean(what or ""), 60), b = tostring(need),
		c = ("%d-%d"):format(math.max(1, lv - 4), lv + 4), note = note })
	if why then ns.Print(why) end
end

-- At a meeting stone: the player said yes to the prompt (Popups.lua).
function Calls.Dungeon(key, need, note)
	local s = ns.Stones.Get(key)
	if not s then return end
	local map, x, y = Calls.MyPosition()
	if not map then return ns.Print(ns.L.NO_POSITION) end
	if not Calls.AtStone(s) then return ns.Print(ns.L.NOT_AT_STONE:format(s.name)) end
	need = Need(need, math.max(1, 4 - math.max(0, (GetNumGroupMembers and GetNumGroupMembers() or 0) - 1)))
	local c, why = Make("D", map, x, y, { a = s.key, b = tostring(need), c = ("%d-%d"):format(s.lo, s.hi), note = note })
	if why then return ns.Print(why) end
	-- Learned: that stone's spot, so standing there is enough next time.
	if c and not ns.Stones.Spot(s) then
		ns.db.stones[s.key] = { map = map, x = x, y = y, t = ns.Now(), learned = true }
		ns.Log("stone %s learned at %d %.3f %.3f", s.key, map, x, y)
	end
	if c then
		local own = ns.db.stoneSeen
		local found
		for _, v in ipairs(own) do
			local d = Calls.Distance(v.map, v.x, v.y, map, x, y)
			if d and d <= ns.Stones.CLUSTER then v.key, v.t, found = s.key, ns.Now(), true end
		end
		if not found then own[#own + 1] = { map = map, x = x, y = y, key = s.key, t = ns.Now() } end
	end
end

-- Ends a call of ours (f: full, x: closed), or votes on someone else's (u, d).
function Calls.End(id, how)
	local c = active[id]
	if not c or not c.mine then return end
	c.ended = how
	if mine[c.kind] == id then mine[c.kind] = nil end
	if not c.demo then ns.Comm.Send(("M2~%s~%s~%s"):format(ns.me, Codec.Base36(c.cid), how)) end
	Changed()
end

function Calls.Renew(id)
	local c = active[id]
	if not c or not c.mine or c.kind ~= "C" then return end
	c.expires = ns.Now() + Calls.LIFE.C
	if not c.demo then Broadcast(c) end
	Changed()
end

function Calls.Vote(id, v)
	local c = active[id]
	if not c or c.kind ~= "R" or c.votes[ns.me] == v then return end
	c.votes[ns.me] = v
	if not c.demo then ns.Comm.Send(("M2~%s~%s~%s"):format(c.caller, Codec.Base36(c.cid), v), { key = "M2" .. id }) end
	Calls.Settle(c)
	Changed()
end

-- A rare call closes once more said "Dead" than "Still up" (two at least, or the caller).
function Calls.Settle(c)
	local up, dead = Calls.Votes(c)
	if c.ended or c.kind ~= "R" then return end
	if dead > up and (dead >= 2 or c.votes[c.caller] == "d") then
		c.ended = "d"
		-- A caller whose calls keep dying soon after they were made: hidden for a while.
		if not c.mine and ns.Now() - c.t < 120 then
			local s = ns.rdb.slow
			local k = "n" .. c.caller
			s[k] = (s[k] or 0) + 1
			if s[k] >= 3 then
				s[c.caller], s[k] = ns.Now() + 7200, nil
				ns.Log("rare calls of %s hidden for two hours", c.caller)
			end
		end
	end
end

---------------------------------------------------------------------------
-- Reading calls
---------------------------------------------------------------------------

-- The fields that follow from the wire ones: levels, the dungeon, how many are needed.
function Calls.Read(c)
	if c.kind == "G" or c.kind == "D" then
		local lo, hi = tostring(c.c or ""):match("^(%d+)%-(%d+)$")
		c.lo, c.hi = tonumber(lo), tonumber(hi)
		local roles = tostring(c.b or ""):match("^[THD]+$")
		if roles and #roles <= 4 then
			c.roles, c.need = roles, #roles
		else
			c.roles, c.need = nil, Codec.Int(c.b, 1, 4) or 1
		end
	end
	if c.kind == "D" then c.stone = ns.Stones.Get(c.a) end
end

function Calls.Decode(text)
	local f = Codec.Fields(text, 12)
	if #f ~= 12 or f[1] ~= "M1" or not Calls.LIFE[f[2]] then return nil end
	local id = Codec.UnBase36(f[3])
	local map = Codec.Int(f[4], 1, 100000)
	local x, y = Codec.Int(f[5], 0, 10000), Codec.Int(f[6], 0, 10000)
	local expires = Codec.UnBase36(f[7])
	if not id or not map or not x or not y or not expires then return nil end
	local c = { kind = f[2], cid = id, map = map, x = x / 10000, y = y / 10000, expires = expires,
		a = f[8]:sub(1, 60), b = f[9]:sub(1, 12), c = f[10]:sub(1, 12), note = ns.Cut(f[12], Calls.NOTE_MAX * 2),
		cls = f[11]:match("^%u+$") and f[11]:sub(1, 12) or nil }
	if c.kind == "R" and not CLASS_NAME[c.b] then return nil end
	if c.kind == "D" and not ns.Stones.Get(c.a) then return nil end
	return c
end

ns.Comm.Handle("M1", function(dist, sender, text)
	local c = Calls.Decode(text)
	if not c then return end
	local now = ns.Now()
	local life = Calls.LIFE[c.kind]
	if c.expires <= now or c.expires > now + life + 120 then return end
	c.caller, c.id = sender, CallId(sender, Codec.Base36(c.cid))
	Calls.Read(c)
	local old = active[c.id]
	if old then
		-- Sent again (a renewed camp; a group with a role filled): the new end time and roles,
		-- the votes and asks kept.
		old.expires = c.expires
		if old.b ~= c.b then
			old.b = c.b
			Calls.Read(old)
		end
		return Changed()
	end
	-- Quest / farm groups never reach anyone farther than GROUP_YARDS.
	if c.kind == "G" and not InMyParty(sender) then
		local d = Calls.DistanceToMe(c.map, c.x, c.y)
		if not d or d > Calls.GROUP_YARDS then return end
	end
	-- A dungeon call far from its stone is dropped (when the stone's spot is known).
	if c.kind == "D" then
		if ns.Stones.Strict(c.map) and not ns.Stones.InZone(c.stone, c.map) then return end
		local sm, sx, sy = ns.Stones.TableSpot(c.stone)
		if sm then
			local d = Calls.Distance(sm, sx, sy, c.map, c.x, c.y)
			if d and d > ns.Stones.CALL_NEAR then return end
		end
		-- The call is a vote for its stone's spot (the gossip, Stones.lua).
		ns.Stones.Vote(sender, c.map, c.x, c.y, c.a)
	end
	-- Rares: one call per rare; a second is a vote for the first.
	if c.kind == "R" then
		for _, o in pairs(active) do
			if o.kind == "R" and o.c == c.c and o.map == c.map and not o.ended and o.expires > now then
				o.votes[sender] = "u"
				return Changed()
			end
		end
	end
	c.t, c.votes, c.asks = now, {}, {}
	if c.kind == "R" then c.votes[sender] = "u" end
	active[c.id] = c
	if Calls.Shown(c) and ns.Popups then ns.Popups.Call(c) end
	Changed()
end)

ns.Comm.Handle("M2", function(dist, sender, text)
	local caller, cid36, how = text:match("^M2~(.+)~([0-9a-z]+)~([udfx])$")
	if not caller then return end
	local c = active[CallId(ns.Key(caller), cid36)]
	if not c then return end
	if how == "u" or how == "d" then
		if c.kind ~= "R" then return end
		c.votes[sender] = how
		Calls.Settle(c)
	elseif sender == c.caller then
		c.ended = how
	end
	Changed()
end)

---------------------------------------------------------------------------
-- Ask to join. The asker's add-on whispers the caller; the caller gets a card with Invite and
-- No; nobody is invited without the caller's click.
---------------------------------------------------------------------------

-- Why the player can't ask to join call c, or nil.
function Calls.CantAsk(c)
	if c.mine then return ns.L.YOUR_CALL end
	if c.asked then return ns.L.ASKED end
	if c.roles and #Calls.MyRoles(c) == 0 then return ns.L.NO_ROLE_FITS end
	if c.kind == "G" then
		local d = Calls.DistanceToMe(c.map, c.x, c.y)
		if not d or d > Calls.GROUP_YARDS then return ns.L.TOO_FAR:format(Calls.GROUP_YARDS) end
	end
	if not LevelFits(c) then return ns.L.LEVELS:format(c.lo, c.hi) end
	return nil
end

-- role: the one this player would fill ("T", "H" or "D"), when the call names roles.
function Calls.Ask(id, role)
	local c = active[id]
	if not c or Calls.CantAsk(c) then return end
	if c.roles then
		local fits = false
		for _, r in ipairs(Calls.MyRoles(c)) do if r == role then fits = true end end
		if not fits then return end
	end
	c.asked = true
	c.askedAs = role
	if c.demo then
		c.answer = "ok"
		ns.Print(ns.L.ANSWER_OK:format(ns.DisplayName(c.caller)))
		return Changed()
	end
	local _, class = UnitClass("player")
	local map, x, y = Calls.MyPosition()
	local zone = GetRealZoneText and GetRealZoneText() or ""
	ns.Comm.Send(table.concat({ "J1", Codec.Base36(c.cid), tostring(UnitLevel("player") or 0), class or "",
		tostring(map or 0), tostring(math.floor((x or 0) * 10000)), tostring(math.floor((y or 0) * 10000)), Codec.Clean(zone),
		c.roles and role or "" }, "~"),
		{ to = c.caller, urgent = true })
	Changed()
end

local function Answer(to, cid36, word)
	ns.Comm.Send(("J2~%s~%s"):format(cid36, word), { to = to, urgent = true })
end

local function IsFriendOrGuild(name)
	local short = ns.TellName(name)
	if C_FriendList and C_FriendList.IsFriend then
		local ok, yes = pcall(C_FriendList.IsFriend, UnitGUID and UnitGUID(short) or "")
		if ok and yes then return true end
	end
	if C_FriendList and C_FriendList.GetFriendInfo then
		local ok, info = pcall(C_FriendList.GetFriendInfo, short)
		if ok and info then return true end
	end
	return UnitIsInMyGuild and UnitIsInMyGuild(short) or false
end

ns.Comm.Handle("J1", function(dist, sender, text)
	if dist ~= "WHISPER" then return end
	local f = Codec.Fields(text, 9)
	if #f < 8 then return end
	local c = active[CallId(ns.me, f[2])]
	if not c or not c.mine or c.ended or (c.kind ~= "G" and c.kind ~= "D") then return end
	if ns.Safety.IsBlocked(sender) then return end
	local mode = ns.db.settings.asks
	if mode == "off" or (mode == "friends" and not IsFriendOrGuild(sender)) then return Answer(sender, f[2], "off") end
	if c.asks[sender] then return end
	local waiting = 0
	for _, a in pairs(c.asks) do if a.state == "waiting" then waiting = waiting + 1 end end
	if waiting >= Calls.ASKS_WAITING then return Answer(sender, f[2], "many") end
	local level = Codec.Int(f[3], 1, 200) or 0
	local ask = { name = sender, level = level, class = f[4]:sub(1, 12), zone = f[8]:sub(1, 40), state = "waiting", t = ns.Now() }
	local map, x, y = Codec.Int(f[5], 0, 100000), Codec.Int(f[6], 0, 10000), Codec.Int(f[7], 0, 10000)
	if map and map > 0 and x and y then ask.map, ask.x, ask.y = map, x / 10000, y / 10000 end
	if c.kind == "G" then
		local d = ask.map and Calls.DistanceToMe(ask.map, ask.x, ask.y)
		if not d or d > Calls.GROUP_YARDS then return Answer(sender, f[2], "far") end
		ask.yards = math.floor(d)
	end
	if c.lo and (level < c.lo or level > c.hi) then return Answer(sender, f[2], "no") end
	if c.roles then
		local role = (f[9] or ""):match("^[THD]$")
		if not role or not c.roles:find(role, 1, true) then return Answer(sender, f[2], "role") end
		ask.role = role
	end
	c.asks[sender] = ask
	if ns.Popups then ns.Popups.Ask(c, ask) end
	Changed()
end)

-- The caller's click on Invite or No.
function Calls.Decide(id, name, yes)
	local c = active[id]
	local ask = c and c.asks[name]
	if not ask or ask.state ~= "waiting" then return end
	if not yes then
		ask.state = "no"
		if not c.demo then Answer(name, Codec.Base36(c.cid), "no") end
		return Changed()
	end
	if c.demo then
		ask.state = "invited"
		ns.Print(ns.L.DEMO_INVITE:format(ns.DisplayName(name)))
		return Changed()
	end
	-- Checked again: has the asker wandered off since they asked? (Their spot is the one they
	-- asked from; ours is now.)
	if c.kind == "G" and ask.map then
		local d = Calls.DistanceToMe(ask.map, ask.x, ask.y)
		if not d or d > Calls.GROUP_YARDS then ns.Print(ns.L.ASKER_FAR:format(ns.DisplayName(name), d and math.floor(d) or 0)) end
	end
	ask.state = "invited"
	local target = ns.TellName(name)
	if C_PartyInfo and C_PartyInfo.InviteUnit then C_PartyInfo.InviteUnit(target) elseif InviteUnit then InviteUnit(target) end
	Answer(name, Codec.Base36(c.cid), "ok")
	ns.Log("invited %s to call %s", name, id)
	-- Their role is filled: the call says what it still needs (or, none left, it is full).
	if ask.role and c.roles then
		c.b = c.roles:gsub(ask.role, "", 1)
		if c.b == "" then return Calls.End(id, "f") end
		Calls.Read(c)
		Broadcast(c)
	end
	Changed()
end

ns.Comm.Handle("J2", function(dist, sender, text)
	if dist ~= "WHISPER" then return end
	local cid36, word = text:match("^J2~([0-9a-z]+)~(%a+)$")
	local c = cid36 and active[CallId(sender, cid36)]
	if not c then return end
	c.answer = word
	local line = ns.L["ANSWER_" .. word:upper()]
	if line then ns.Print(line:format(ns.DisplayName(sender))) end
	Changed()
end)

---------------------------------------------------------------------------
-- Housekeeping: ended and expired calls go, a full party closes our call, and a dungeon call
-- closes once its caller has been away from the stone for AWAY_FROM_STONE. And the meeting
-- stone prompt.
---------------------------------------------------------------------------

-- A meeting stone under the mouse: the game's tooltip names it (any client, no table needed).
-- The player counts as at a stone for STONE_SEEN_FOR seconds after, while within STONE_SEEN_YARDS
-- of where they stood.
Calls.STONE_SEEN_FOR = 120
Calls.STONE_SEEN_YARDS = 15
local seen -- { t, map, x, y }

function Calls.NearSeenStone()
	if not seen or GetTime() - seen.t > Calls.STONE_SEEN_FOR then return false end
	local map, x, y = Calls.MyPosition()
	if not map or map ~= seen.map then return false end
	local d = Calls.Distance(map, x, y, seen.map, seen.x, seen.y)
	if d == nil then d = math.max(math.abs(x - seen.x), math.abs(y - seen.y)) * 1000 end
	return d <= Calls.STONE_SEEN_YARDS
end

function Calls.AtStone(s)
	local map, x, y = Calls.MyPosition()
	if not map then return false end
	local sm, sx, sy = ns.Stones.Spot(s)
	if sm then
		local d = Calls.Distance(sm, sx, sy, map, x, y)
		if d and d <= ns.Stones.NEAR * 2 then return true end
	end
	if ns.Stones.Strict(map) and not ns.Stones.InZone(s, map) then return false end
	if Calls.usedStone and GetTime() - (Calls.usedStoneAt or 0) < Calls.STONE_SEEN_FOR then return true end
	return Calls.NearSeenStone()
end

-- The stone the player stands at, if its spot is known.
local function KnownStoneHere()
	local map, x, y = Calls.MyPosition()
	if not map then return nil end
	for _, s in ipairs(ns.Stones.LIST) do
		local sm, sx, sy = ns.Stones.Spot(s)
		if sm and (not s.faction or s.faction == ns.faction) then
			local d = Calls.Distance(sm, sx, sy, map, x, y)
			if d and d <= ns.Stones.NEAR * 2 then return s end
		end
	end
end

-- "Look for group" (the Groups tab, the stone card): at a known stone, that dungeon; at a stone
-- the player hovered over, the dungeons it may be for; elsewhere, how to get there.
function Calls.StartAtStone(anchor)
	local known = KnownStoneHere()
	if known then return ns.Popups.GroupAsk(known) end
	if not (Calls.NearSeenStone() or (Calls.usedStone and GetTime() - (Calls.usedStoneAt or 0) < Calls.STONE_SEEN_FOR)) then
		return ns.Print(ns.L.POINT_AT_STONE)
	end
	local list = ns.Stones.OfZone(Calls.MyZone())
	if #list == 1 then return ns.Popups.GroupAsk(list[1]) end
	local items = { { text = ns.L.PICK_DUNGEON, title = true } }
	for i, s in ipairs(list) do
		if i > 12 then break end
		items[#items + 1] = { text = ("%s  |cff9d9480%d-%d|r"):format(s.name, s.lo, s.hi), go = function() ns.Popups.GroupAsk(s) end }
	end
	Calls.menu = Calls.menu or ns.UI.Menu()
	Calls.menu:Open(anchor or UIParent, items)
end

-- The game's tooltip showed a meeting stone (hovered in the world).
local STONE_NAMES = {}
for name in tostring(ns.L.MEETING_STONE_NAMES):gmatch("[^;]+") do STONE_NAMES[name] = true end
local lastSeenCard = -1e9
function Calls.OnTooltip(tip)
	if not tip or (tip.GetUnit and tip:GetUnit()) then return end
	local line = _G[(tip.GetName and tip:GetName() or "GameTooltip") .. "TextLeft1"]
	local text = line and line.GetText and line:GetText()
	if type(text) ~= "string" or not STONE_NAMES[text] then return end
	local map, x, y = Calls.MyPosition()
	if not map then return end
	seen = { t = GetTime(), map = map, x = x, y = y }
	ns.Stones.Sighted(map, x, y)
	if (mine.D and active[mine.D]) or GetTime() - lastSeenCard < 600 or not ns.Popups then return end
	lastSeenCard = GetTime()
	ns.Popups.StoneSeen()
end

local prompted = {} -- [stone key] = when the prompt was last shown

local function StoneCheck()
	if InCombatLockdown and InCombatLockdown() then return end
	if IsInInstance and IsInInstance() then return end
	local map, x, y = Calls.MyPosition()
	if not map then return end
	for _, s in ipairs(ns.Stones.OfZone(map)) do
		local sm, sx, sy = ns.Stones.Spot(s)
		if sm and not (mine.D and active[mine.D]) and GetTime() - (prompted[s.key] or -1e9) > 600 then
			local d = Calls.Distance(sm, sx, sy, map, x, y)
			if d and d <= ns.Stones.NEAR then
				prompted[s.key] = GetTime()
				if ns.Popups then ns.Popups.StonePrompt({ s }) end
				return
			end
		end
	end
end

-- The player used a meeting stone (its summoning spell): the prompt for that zone's stones.
local SUMMON_SPELLS = { [23598] = true } -- "Meeting Stone Summon" (Phase 0 confirms on Forever)
function Calls.UsedStone(spellID)
	if not SUMMON_SPELLS[spellID] then return end
	local map = Calls.MyZone()
	local list = map and ns.Stones.OfZone(map) or {}
	if #list == 0 then return end
	Calls.usedStone, Calls.usedStoneAt = list[1].key, GetTime()
	if #list == 1 or not ns.Stones.Spot(list[1]) then
		if ns.Popups then ns.Popups.StonePrompt(list) end
	end
end

local function Tick()
	local now = ns.Now()
	local changed = false
	for id, c in pairs(active) do
		if c.ended or now >= c.expires then
			c.endedAt = c.endedAt or now
			if mine[c.kind] == id then mine[c.kind] = nil end
			-- Kept a minute after its end, so the card can say how it ended.
			if now - c.endedAt > 60 then
				active[id] = nil
				changed = true
			end
		end
		if c.mine and not c.ended and (c.kind == "G" or c.kind == "D") then
			local size = GetNumGroupMembers and GetNumGroupMembers() or 0
			if size >= 5 or (size > 0 and size - math.max(1, c.party0 or 1) >= (c.total or c.need or 1)) then
				Calls.End(id, "f")
			end
			if c.kind == "D" and c.stone and not c.ended then
				if Calls.AtStone(c.stone) then c.awayAt = nil
				elseif not c.awayAt then c.awayAt = now
				elseif now - c.awayAt > Calls.AWAY_FROM_STONE then Calls.End(id, "x") end
			end
		end
	end
	if changed then Changed() end
end

function Calls.ResetForTest() wipe(active) wipe(mine) wipe(made) end
function Calls.AddDemo(c) active[c.id] = c Changed() end
function Calls.ClearDemo()
	for id, c in pairs(active) do if c.demo then active[id] = nil end end
	for k, id in pairs(mine) do if not active[id] then mine[k] = nil end end
	Changed()
end

ns.On("LOGIN", function()
	HBD = HBD or (LibStub and LibStub("HereBeDragons-2.0", true))
	C_Timer.NewTicker(5, function() ns.SafeCall("calls tick", Tick) end)
	C_Timer.NewTicker(2, function() ns.SafeCall("stone check", StoneCheck) end)
	if GameTooltip and GameTooltip.HookScript then
		-- After the game's own: reads the tooltip's first line, changes nothing.
		GameTooltip:HookScript("OnShow", function(tip) ns.SafeCall("stone tooltip", Calls.OnTooltip, tip) end)
	end
	ns.RegisterEvent("UNIT_SPELLCAST_SUCCEEDED", function(unit, _, spellID)
		if unit == "player" then Calls.UsedStone(spellID) end
	end)
	ns.RegisterEvent("GROUP_ROSTER_UPDATE", function() ns.SafeCall("calls tick", Tick) end)
end)
