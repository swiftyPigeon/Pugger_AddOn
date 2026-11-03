local ADDON, ns = ...

-- Posting and reading: posts (P1), deletes (D1), likes (L1), counts (C1), reposts, replies
-- (one level deep: a reply to a reply joins the same thread), follows, mentions and hashtags.
--
-- A post heard on the channel from its author is the author's (the server says who sent it):
-- shown at once. Its signature is still checked, in the background, before this client relays
-- it to anyone (Sync.lua). A post heard from anyone else (sync) shows only once its signature
-- checks against the author's pinned key; while the key is unknown it is kept, greyed
-- "unverified", and checked when the author's profile arrives (Identity.lua).

local Feed = {}
ns.Feed = Feed
local Codec, Store = ns.Codec, ns.Store

Feed.MAX_LETTERS = Codec.MAX_LETTERS
Feed.MENTION_AGE = 3600 -- a mention older than this makes no card

local function Changed() ns.Fire("FEED_CHANGED") end

-- The thread a reply belongs to: replies are one level deep.
function Feed.Root(id)
	local p = Store.Get(id)
	if p and p.f == "p" and p.par then return p.par end
	return id
end

---------------------------------------------------------------------------
-- Writing
---------------------------------------------------------------------------

-- Why a text can't be posted, or nil.
function Feed.Check(text, isRepost)
	if not ns.Safety.CanPost() then return ns.L.NEED_LEVEL:format(ns.Safety.LEVEL_TO_POST) end
	if not ns.Identity.Ready() then return ns.L.KEY_NOT_READY end
	if not ns.Comm.Ready() then return ns.L.NOT_CONNECTED end
	text = Codec.Sanitize(text)
	if text == "" and not isRepost then return ns.L.EMPTY_POST end
	if ns.Letters(Codec.Visible(text)) > Feed.MAX_LETTERS then return ns.L.TOO_LONG:format(Feed.MAX_LETTERS) end
	if #text > Codec.MAX_BYTES then return ns.L.TOO_MANY_LINKS end
	return nil
end

-- opt: { reply = post id, repost = post id }. done(ok, why). Every post carries where its author
-- stood (zone and coordinates): readers can find someone to report or mute, and a name is never
-- just a name.
function Feed.Post(text, opt, done)
	opt = opt or {}
	done = done or function() end
	local why = Feed.Check(text, opt.repost ~= nil)
	if why then return done(false, why) end
	-- A reply to a sample post (/pug demo) stays a sample: shown here, never sent.
	local root = opt.reply and Feed.Root(opt.reply)
	if root and Store.demo[root] then
		local t = ns.Now()
		local p = { id = Codec.PostId(ns.me, t, math.random(1, 1e6)), a = ns.me, t = t, x = Codec.Sanitize(text),
			f = "p", par = root, v = "direct", lk = {}, demo = true }
		Store.demo[p.id] = p
		Store.Rebuild()
		Changed()
		return done(true)
	end
	-- From one spot, a few posts at a time (Safety.SpotRoom); replies are free.
	if not opt.reply then
		local here = Codec.EncodePin(ns.Calls.MyPlace())
		local ok, wait = ns.Safety.SpotRoom(ns.me, here, ns.Now())
		if not ok then
			return done(false, ns.L.SPOT_FULL:format(ns.Safety.SPOT_POSTS, ns.Safety.SPOT_YARDS, math.max(1, math.ceil(wait / 60))))
		end
	end
	ns.Consent.Ask(function()
		local rdb = ns.rdb
		rdb.counter = (rdb.counter or 0) + 1
		local t = ns.Now()
		local p = { id = Codec.PostId(ns.me, t, rdb.counter), a = ns.me, t = t, x = Codec.Sanitize(text) }
		if opt.repost then
			p.f, p.par = "r", opt.repost
		elseif opt.reply then
			p.f, p.par = "p", Feed.Root(opt.reply)
		end
		local mapID, x, y = ns.Calls.MyPlace()
		if mapID then p.pin = Codec.EncodePin(mapID, x, y) end
		ns.Identity.Sign(Codec.PostSigned(p), function(sig)
			if not sig then return done(false, ns.L.KEY_NOT_READY) end
			p.s, p.v, p.sv = sig, "direct", true
			Store.Add(p)
			if p.f ~= "p" then ns.Safety.NoteSpot(ns.me, p.pin, ns.Now()) end
			-- Logged: the server keeps the text, so abuse can be reported to Blizzard.
			ns.Comm.Send(Codec.EncodePost(p), { logged = true })
			Changed()
			done(true)
		end)
	end)
end

function Feed.Repost(id)
	local o = Store.Get(id)
	if not o or o.demo then return end
	if o.f == "r" and o.par then id, o = o.par, Store.Get(o.par) or o end
	for _, c in ipairs(Store.Children(id, "r")) do
		if c.a == ns.me then return ns.Print(ns.L.ALREADY_REPOSTED) end
	end
	Feed.Post("", { repost = id }, function(ok, why) if not ok then ns.Print(why) end end)
end

function Feed.Delete(id)
	local p = Store.Get(id)
	if not p or p.a ~= ns.me then return end
	if p.demo then
		Store.demo[id] = nil
		Store.Rebuild()
		return Changed()
	end
	local at = ns.Now()
	Store.Tomb(id, at, ns.me)
	Changed()
	ns.Identity.Sign(Codec.DeleteSigned(id, at), function(sig)
		if not sig then return end
		ns.rdb.tombs[id].s = sig
		ns.Comm.Send(Codec.EncodeDelete(id, at, sig))
	end)
end

function Feed.Like(id, on)
	local p = Store.Get(id)
	if not p then return end
	if on == nil then on = not p.lk[ns.me] end
	p.lk[ns.me] = on or nil
	ns.rdb.myLikes[id] = on and ns.Now() or nil
	Changed()
	if not p.demo then ns.Comm.Send(("L1~%s~%s"):format(id, on and "1" or "0"), { key = "L1" .. id }) end
end

function Feed.Follow(name, on)
	if not name or name == ns.me then return end
	ns.rdb.follows[name] = on and ns.Now() or nil
	Changed()
end
function Feed.IsFollowing(name) return ns.rdb.follows[name] ~= nil end

---------------------------------------------------------------------------
-- Mentions
---------------------------------------------------------------------------

-- The words a mention of the player may use: their name without spaces, and its first word.
local function MyNames()
	local short = ns.ShortName(ns.me or ""):lower()
	return { [short:gsub("%s", "")] = true, [short:match("^(%S+)") or short] = true }
end

function Feed.MentionsMe(p)
	if not p.x or p.a == ns.me then return false end
	local mine = MyNames()
	for _, m in ipairs(Codec.Mentions(p.x)) do
		if mine[m] then return true end
	end
	return false
end

local function MaybeNotify(p)
	if ns.Now() - p.t > Feed.MENTION_AGE or not Feed.MentionsMe(p) or ns.Safety.Hidden(p) then return end
	local s = ns.db.settings
	if s.mentionsFollowedOnly and not Feed.IsFollowing(p.a) then return end
	ns.rdb.unreadMentions = (ns.rdb.unreadMentions or 0) + 1
	if s.mentionPopups and ns.Popups then ns.Popups.Mention(p) end
end

---------------------------------------------------------------------------
-- Receiving
---------------------------------------------------------------------------

local function Checked(p, ok)
	local held = ns.rdb.posts[p.id]
	if not held then return end
	if ok then
		held.sv = true
		if held.v ~= "direct" then
			held.v = "ok"
			MaybeNotify(held)
		end
	elseif held.v ~= "direct" then
		-- A relayed post whose signature fails: forged or broken, never shown.
		ns.Log("post %s refused: bad signature", p.id)
		Store.Remove(p.id)
	else
		held.sv = false
	end
	Changed()
end

local function Check(p)
	local keys = ns.Identity.KeysOf(p.a)
	if not keys then
		ns.Identity.Want(p.a)
		return false
	end
	ns.Identity.Verify(keys, Codec.PostSigned(p), p.s, function(ok) Checked(p, ok) end)
	return true
end

local waitingDeletes = {} -- [post id] = a relayed delete waiting for its author's key

-- The author's profile (and so their key) arrived: their waiting posts and deletes are checked now.
function Feed.KeyArrived(author)
	for _, p in pairs(ns.rdb.posts) do
		if p.a == author and p.sv == nil then Check(p) end
	end
	for id, d in pairs(waitingDeletes) do
		if d.a == author then
			waitingDeletes[id] = nil
			ns.Identity.Verify(ns.Identity.KeysOf(author), Codec.DeleteSigned(d.id, d.at), d.s, function(ok)
				if not ok then return end
				Store.Tomb(d.id, d.at, d.a, d.s)
				Changed()
			end)
		end
	end
end

-- dist, sender as Comm hands them; direct: heard live from its author.
function Feed.Take(p, sender, dist)
	local direct = sender == p.a and dist == "CHANNEL"
	if direct then
		if not ns.Safety.AdmitPost(sender, ns.Now()) then return "flood" end
		local pr = ns.rdb.profiles[sender]
		if pr and pr.level and pr.level < ns.Safety.LEVEL_TO_POST then return "level" end
		if p.f ~= "p" then
			if not ns.Safety.SpotRoom(sender, p.pin, ns.Now()) then return "spot" end
			ns.Safety.NoteSpot(sender, p.pin, ns.Now())
		end
		-- A live post is new: one stamped far from now is refused.
		if math.abs(p.t - ns.Now()) > 900 then return "clock" end
	end
	local res = Store.Add(p)
	if res ~= "new" then return res end
	if direct then
		p.v = "direct"
		MaybeNotify(p)
	end
	Check(p)
	Changed()
	return res
end

ns.Comm.Handle("P1", function(dist, sender, text)
	local p, why = Codec.DecodePost(text)
	if not p then
		ns.Log("bad post from %s: %s", sender, tostring(why))
		return
	end
	Feed.Take(p, sender, dist)
end)

ns.Comm.Handle("D1", function(dist, sender, text)
	local d = Codec.DecodeDelete(text)
	if not d or ns.rdb.tombs[d.id] then return end
	if sender == d.a then
		Store.Tomb(d.id, d.at, d.a, d.s)
		return Changed()
	end
	local keys = ns.Identity.KeysOf(d.a)
	if not keys then
		-- Kept until the author's key comes (Feed.KeyArrived), if we hold the post.
		if ns.rdb.posts[d.id] then
			waitingDeletes[d.id] = d
			ns.Identity.Want(d.a)
		end
		return
	end
	ns.Identity.Verify(keys, Codec.DeleteSigned(d.id, d.at), d.s, function(ok)
		if not ok then return end
		Store.Tomb(d.id, d.at, d.a, d.s)
		Changed()
	end)
end)

ns.Comm.Handle("L1", function(dist, sender, text)
	local id, on = text:match("^L1~(.+)~([01])$")
	if not id or dist ~= "CHANNEL" or ns.Safety.IsBlocked(sender) then return end
	local p = ns.rdb.posts[id]
	if not p then return end
	p.lk[sender] = on == "1" or nil
	Changed()
end)

ns.Comm.Handle("C1", function(dist, sender, text)
	local list = Codec.DecodeCounts(text)
	if not list then return end
	for _, c in ipairs(list) do
		local p = ns.rdb.posts[c.id]
		if p then
			p.lc = math.max(p.lc or 0, c.l)
			p.rc = math.max(p.rc or 0, c.r)
		end
	end
	Changed()
end)

---------------------------------------------------------------------------
-- Timelines
---------------------------------------------------------------------------

local function Visible(p) return not ns.Safety.Hidden(p) end

-- A busy feed: more posts in the last hour than anyone reads. Then the faction's tab shows the
-- people the player follows (always), their own posts and mentions of them, and fills what room
-- is left with posts written near them (their zone and the ones next to it); the rest is left
-- out, unless the player asks for all (Feed.showAll, until /reload).
Feed.BUSY_PER_HOUR = 120
Feed.showAll = false
Feed.leftOut = 0
-- (Counted again when the posts held change or every half minute: Store asks on every post.)
local busy, busyN, busyTotal, busyAt = false, 0, -1, -1e9
function Feed.Busy()
	local now = ns.Now()
	if ns.Store.Total() ~= busyTotal or now - busyAt >= 30 then
		local since, n = now - 3600, 0
		for _, p in pairs(ns.rdb.posts) do if p.t >= since and p.f ~= "p" then n = n + 1 end end
		busy, busyN, busyTotal, busyAt = n >= Feed.BUSY_PER_HOUR, n, ns.Store.Total(), now
	end
	return busy, busyN
end

-- Written near the player: the post's zone is theirs or one next to it.
function Feed.Nearby(p)
	local m = p.pin and Codec.DecodePin(p.pin)
	return m ~= nil and ns.Calls.Near(m)
end

local function Focused(max)
	local f = ns.rdb.follows
	local function Mine(p) return f[p.a] or p.a == ns.me or Feed.MentionsMe(p) end
	local first = Store.List(function(p) return p.f ~= "p" and Visible(p) and Mine(p) end, max)
	local near = Store.List(function(p) return p.f ~= "p" and Visible(p) and not Mine(p) and Feed.Nearby(p) end, max - #first)
	local all = 0
	for _, p in pairs(ns.rdb.posts) do if p.f ~= "p" and Visible(p) then all = all + 1 end end
	Feed.leftOut = math.max(0, all - #first - #near)
	for _, p in ipairs(near) do first[#first + 1] = p end
	table.sort(first, function(a, b) return a.t > b.t or (a.t == b.t and a.id > b.id) end)
	return first
end

-- Posts for a tab: "realm", "following", "mentions", "me"; or { tag = "onyxia" },
-- { thread = id }, { author = name }.
function Feed.Timeline(view, max)
	max = max or 100
	if view == "realm" then
		Feed.leftOut = 0
		if not Feed.showAll and Feed.Busy() then return Focused(max) end
		return Store.List(function(p) return p.f ~= "p" and Visible(p) end, max)
	elseif view == "following" then
		local f = ns.rdb.follows
		return Store.List(function(p) return (f[p.a] or p.a == ns.me) and p.f ~= "p" and Visible(p) end, max)
	elseif view == "mentions" then
		return Store.List(function(p) return Feed.MentionsMe(p) and Visible(p) end, max)
	elseif view == "me" then
		return Store.List(function(p) return p.a == ns.me end, max)
	elseif type(view) == "table" and view.tag then
		return Store.List(function(p)
			if not p.x or not Visible(p) then return false end
			for _, t in ipairs(Codec.Tags(p.x)) do if t == view.tag then return true end end
			return false
		end, max)
	elseif type(view) == "table" and view.author then
		return Store.List(function(p) return p.a == view.author and Visible(p) end, max)
	elseif type(view) == "table" and view.thread then
		local root = Store.Get(view.thread)
		local out = {}
		if root then out[1] = root end
		for _, c in ipairs(Store.Children(view.thread, "p")) do
			if Visible(c) then out[#out + 1] = c end
		end
		return out
	end
	return {}
end
