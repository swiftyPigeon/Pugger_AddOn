local ADDON, ns = ...

-- /pug demo: sample posts, profiles and calls around the player, so the window, the tabs, the
-- map pins and the cards can be seen alone. They live in memory only (Store.demo, demo calls):
-- never saved, never sent, gone at /reload or with /pug demo off. Asking to join a sample
-- call answers itself; Invite on a sample ask invites nobody.

local Demo = {}
ns.Demo = Demo

Demo.profiles = {}

local PEOPLE = {
	{ "Kaelis", "MAGE", 24, "Water for anyone at Sentinel Hill." },
	{ "Brannoc", "WARRIOR", 26, "Tanking Deadmines most nights." },
	{ "Selwyn", "PRIEST", 30, "" },
	{ "Vessa", "ROGUE", 19, "" },
	{ "Orvak", "WARRIOR", 21, "" },
	{ "Mirela", "DRUID", 23, "Herbs and wool, ask away." },
	{ "Fizzwick", "WARLOCK", 31, "" },
}

local function Name(short) return short .. "-" .. (ns.realm or "Demo") end

local function Post(who, ago, text, extra)
	local t = ns.Now() - ago
	local id = ns.Codec.PostId(Name(who), t, 1)
	local p = { id = id, a = Name(who), t = t, x = text, v = "direct", lk = {}, demo = true }
	for k, v in pairs(extra or {}) do p[k] = v end
	ns.Store.demo[id] = p
	return p
end

function Demo.On()
	Demo.Off(true)
	for _, d in ipairs(PEOPLE) do
		Demo.profiles[Name(d[1])] = { class = d[2], level = d[3], bio = d[4], pk = "demo", guild = "Ironoak" }
	end
	local map, x, y = ns.Calls.MyPosition()
	local me = ns.ShortName(ns.me or "you")
	local first = me:match("^(%S+)") or me
	local p1 = Post("Kaelis", 60, "Dinged 24. Water for anyone at the inn, just ask.",
		{ pin = map and ns.Codec.EncodePin(map, x, y) or nil, lc = 12 })
	Post("Brannoc", 360, "Three runs and it finally dropped: |cff0070dd|Hitem:10399::::::::24:::::|h[Blackened Defias Armor]|h|r #Deadmines", { lc = 41, rc = 4 })
	Post("Selwyn", 720, "Duskwood road is quiet this week. Fewer gankers. #Duskwood", { lc = 23 })
	Post("Vessa", 1200, "Selling Linen Cloth by the bank.", { demoUnverified = true })
	Post("Orvak", 480, "@" .. first .. " thanks for the heals on Hogger! #Elwynn", { lc = 6 })
	Post("Mirela", 2460, "@" .. first .. " wool camp at the farm, join in.", { lc = 3 })
	Post("Fizzwick", 900, "Gnomeregan tonight at 9, watch Groups. #Gnomeregan", { lc = 18, rc = 3 })
	Post("Selwyn", 30, "Grats! Save me a water.", { f = "p", par = p1.id })
	Post("Brannoc", 20, "Same here, on my way.", { f = "p", par = p1.id })
	ns.Store.Rebuild()
	ns.rdb.unreadMentions = 2

	-- Calls around the player (or in Westfall, without a position).
	map, x, y = map or 1436, x or 0.54, y or 0.32
	local now = ns.Now()
	local function Call(kind, caller, ago, fields)
		local c = { kind = kind, cid = math.random(1, 40000), caller = Name(caller), map = map, x = x, y = y, t = now - ago,
			expires = now + ns.Calls.LIFE[kind], votes = {}, asks = {}, demo = true, note = "" }
		for k, v in pairs(fields) do c[k] = v end
		c.id = c.caller .. "#demo" .. kind .. ago
		c.cls = Demo.profiles[c.caller] and Demo.profiles[c.caller].class
		ns.Calls.Read(c)
		ns.Calls.AddDemo(c)
		return c
	end
	local rare = Call("R", "Kaelis", 120, { a = "Foe Reaper 4000", b = "R", c = "573", x = x + 0.02, y = y - 0.02 })
	rare.votes[Name("Kaelis")], rare.votes[Name("Selwyn")] = "u", "u"
	Call("C", "Mirela", 2100, { note = "Wool and linen, join in", x = x - 0.015, y = y + 0.01 })
	Call("G", "Orvak", 240, { a = "The Defias Brotherhood", b = "1", c = "18-26", x = x + 0.004, y = y + 0.003 })
	local stones = ns.Stones.OfZone(map)
	local s = stones[1] or ns.Stones.Get("dm")
	Call("D", "Brannoc", 180, { a = s.key, b = "2", c = ("%d-%d"):format(s.lo, s.hi), x = x + 0.01, y = y + 0.01 })
	local g = ns.Stones.Get("gnomer")
	Call("D", "Fizzwick", 540, { a = g.key, b = "1", c = ("%d-%d"):format(g.lo, g.hi), map = g.zones[1], x = 0.25, y = 0.40 })
	-- One of the player's own, with someone asking: the Invite card.
	local mineCall = Call("G", me, 60, { a = "Hogger", b = "2", c = "8-14", mine = true })
	mineCall.caller = ns.me
	mineCall.asks[Name("Vessa")] = { name = Name("Vessa"), level = 19, class = "ROGUE", zone = "", yards = 120, state = "waiting", t = now }
	ns.Fire("FEED_CHANGED")
	ns.Fire("CALLS_CHANGED")
	ns.UI.Toggle(true)
	ns.Popups.Card({ key = "demo", title = "Pugger demo", body = ns.L.DEMO_ON, life = 15, sound = false })
	ns.Popups.Ask(mineCall, mineCall.asks[Name("Vessa")])
	ns.Popups.Call(rare)
	ns.Popups.StonePrompt({ s })
end

function Demo.Off(quiet)
	wipe(ns.Store.demo)
	wipe(Demo.profiles)
	ns.Calls.ClearDemo()
	ns.Store.Rebuild()
	ns.Fire("FEED_CHANGED")
	ns.Fire("CALLS_CHANGED")
	if not quiet then ns.Print(ns.L.DEMO_OFF) end
end
