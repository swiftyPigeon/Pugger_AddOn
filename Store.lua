local ADDON, ns = ...

-- The posts this client holds, in ns.rdb (one realm and faction): the feed lives in the moment
-- (the user's call: play, don't look back): KEEP_HOURS of posts, KEEP_BUSY_HOURS on a busy feed
-- (Feed.Busy); mentions of the player stay KEEP_MENTIONS_HOURS, their own posts a week. At most
-- PER_AUTHOR per author and MAX_POSTS in all, the oldest dropped first. A delete leaves a small tombstone for TOMB_DAYS, so sync never brings the post
-- back. Posts:
--   posts[id] = { id, a = author, t = time, f = "p"|"r"|nil, par = parent id, pin, x = text,
--                 s = signature, v = "direct"|"ok"|nil (checked), lk = { [liker] = true },
--                 lc = likes count heard, rc = reposts count heard }
--   tombs[id] = { at = when deleted, a = author, s = signature }
-- Demo posts (/pug demo) live in memory only and never leave the client.

local Store = {}
ns.Store = Store
local Codec = ns.Codec

Store.PER_AUTHOR = 200
Store.MAX_POSTS = 5000
Store.TOMB_DAYS = 7
Store.KEEP_HOURS = 6
Store.KEEP_BUSY_HOURS = 2
Store.KEEP_MENTIONS_HOURS = 24
Store.BUCKET = 3600  -- an hour
Store.BUCKETS = 6    -- a digest's hours at most (as many as the client keeps: Store.Hours)

local children = {}  -- [parent id] = { [id] = true }: replies and reposts
local byAuthor = {}  -- [author] = count
local total = 0
Store.demo = {}      -- [id] = post (never saved, never sent)

local function Index(p, add)
	local d = add and 1 or -1
	byAuthor[p.a] = math.max(0, (byAuthor[p.a] or 0) + d)
	total = math.max(0, total + d)
	if p.par then
		local c = children[p.par]
		if add then
			if not c then c = {} children[p.par] = c end
			c[p.id] = true
		elseif c then
			c[p.id] = nil
		end
	end
end

function Store.Rebuild()
	wipe(children)
	wipe(byAuthor)
	total = 0
	for _, p in pairs(ns.rdb.posts) do Index(p, true) end
	for _, p in pairs(Store.demo) do
		if p.par then
			children[p.par] = children[p.par] or {}
			children[p.par][p.id] = true
		end
	end
end

function Store.Get(id) return ns.rdb.posts[id] or Store.demo[id] end
function Store.Total() return total end
function Store.IsTomb(id) return ns.rdb.tombs[id] ~= nil end

-- The hours of posts kept now: fewer on a busy feed.
function Store.Hours()
	return (ns.Feed and ns.Feed.Busy()) and Store.KEEP_BUSY_HOURS or Store.KEEP_HOURS
end

local function Oldest()
	return ns.Now() - Store.Hours() * 3600
end
Store.Oldest = Oldest

-- Would this post be kept here? (Sync asks only for those.)
function Store.Wants(id, t)
	if ns.rdb.posts[id] or ns.rdb.tombs[id] then return false end
	if t and (t < Oldest() or t > ns.Now() + 600) then return false end
	local author = Codec.ParseId(id)
	if author and (byAuthor[author] or 0) >= Store.PER_AUTHOR and author ~= ns.me then return false end
	return true
end

local function DropOldest(author)
	local worst
	for _, p in pairs(ns.rdb.posts) do
		if (not author or p.a == author) and p.a ~= ns.me and (not worst or p.t < worst.t) then worst = p end
	end
	if worst then Store.Remove(worst.id) end
end

-- Adds a post checked by Codec.DecodePost; returns "new", or why it wasn't kept.
function Store.Add(p)
	local posts = ns.rdb.posts
	if posts[p.id] then return "dup" end
	if ns.rdb.tombs[p.id] then return "tomb" end
	if p.t < Oldest() then return "old" end
	if p.t > ns.Now() + 600 then return "future" end
	if p.a ~= ns.me and (byAuthor[p.a] or 0) >= Store.PER_AUTHOR then DropOldest(p.a) end
	if total >= Store.MAX_POSTS then DropOldest(nil) end
	p.lk = p.lk or {}
	posts[p.id] = p
	Index(p, true)
	return "new"
end

function Store.Remove(id)
	local p = ns.rdb.posts[id]
	if not p then return end
	ns.rdb.posts[id] = nil
	Index(p, false)
end

function Store.Tomb(id, at, author, sig)
	ns.rdb.tombs[id] = { at = at, a = author, s = sig }
	Store.Remove(id)
end

-- Old posts and tombstones go; called at login and every ten minutes.
function Store.Prune()
	local oldest, now = Oldest(), ns.Now()
	local mentions = now - Store.KEEP_MENTIONS_HOURS * 3600
	for id, p in pairs(ns.rdb.posts) do
		-- The player's own posts stay a week, mentions of them a day: few, and theirs.
		local keep = oldest
		if p.a == ns.me then keep = now - 7 * 86400
		elseif ns.Feed and ns.Feed.MentionsMe(p) then keep = mentions end
		if p.t < keep then Store.Remove(id) end
	end
	for id, tb in pairs(ns.rdb.tombs) do
		if now - (tb.at or 0) > Store.TOMB_DAYS * 86400 then ns.rdb.tombs[id] = nil end
	end
end

---------------------------------------------------------------------------
-- Counts
---------------------------------------------------------------------------

function Store.Likes(p)
	return math.max(p.lc or 0, ns.Count(p.lk))
end

function Store.Children(id, flag)
	local out = {}
	for cid in pairs(children[id] or {}) do
		local c = Store.Get(cid)
		if c and (not flag or c.f == flag) then out[#out + 1] = c end
	end
	table.sort(out, function(a, b) return a.t < b.t or (a.t == b.t and a.id < b.id) end)
	return out
end

function Store.Reposts(p)
	return math.max(p.rc or 0, #Store.Children(p.id, "r"))
end
function Store.Replies(p)
	return #Store.Children(p.id, "p")
end

---------------------------------------------------------------------------
-- Digests for sync (Sync.lua): 12 buckets of an hour back from now; each the count of posts
-- in it and a hash of their ids, order free (a sum of hashes).
---------------------------------------------------------------------------

function Store.BucketOf(t) return math.floor(t / Store.BUCKET) end

function Store.Digest()
	local now = Store.BucketOf(ns.Now())
	local c, h = {}, {}
	local n = math.min(Store.BUCKETS, Store.Hours()) -- (only the hours this client keeps)
	for i = 0, n - 1 do c[i], h[i] = 0, 0 end
	for id, p in pairs(ns.rdb.posts) do
		local i = now - Store.BucketOf(p.t)
		if i >= 0 and i < n then
			c[i] = c[i] + 1
			h[i] = (h[i] + Codec.Hash(id)) % 4294967296
		end
	end
	local list = {}
	for i = 0, n - 1 do list[#list + 1] = { c = c[i], h = h[i] % 1679616 } end -- 36^4
	return now, list
end

function Store.InBucket(b)
	local out = {}
	for _, p in pairs(ns.rdb.posts) do
		if Store.BucketOf(p.t) == b then out[#out + 1] = p end
	end
	table.sort(out, function(x, y) return x.t > y.t end)
	return out
end

function Store.TombsInBucket(b)
	local out = {}
	for id, tb in pairs(ns.rdb.tombs) do
		local _, t = Codec.ParseId(id)
		if t and Store.BucketOf(t) == b then out[id] = tb end
	end
	return out
end

---------------------------------------------------------------------------
-- Timelines
---------------------------------------------------------------------------

-- Posts for which keep(p) is true, newest first, at most max.
function Store.List(keep, max)
	local out = {}
	local function Take(p) if keep(p) then out[#out + 1] = p end end
	for _, p in pairs(ns.rdb.posts) do Take(p) end
	for _, p in pairs(Store.demo) do Take(p) end
	table.sort(out, function(a, b) return a.t > b.t or (a.t == b.t and a.id > b.id) end)
	if max and #out > max then for i = #out, max + 1, -1 do out[i] = nil end end
	return out
end

ns.On("LOGIN", function()
	Store.Prune()
	Store.Rebuild()
	ns.Every(600, "store prune", function() Store.Prune() end)
end)
ns.On("FACTION", function() Store.Prune() Store.Rebuild() end)
