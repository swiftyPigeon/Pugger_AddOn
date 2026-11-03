local ADDON, ns = ...

-- Catch-up without a server (section 5 of the plan).
-- 1. At login, and every DIGEST_EVERY after (slower on a big feed: Comm.Scale), a client sends
--    ONE digest (H2) on the channel: for each hour of the last twelve, how many posts it holds and a hash of their ids. A
--    client that heard a digest just like its own in that time stays quiet: most clients that
--    are in step never send one.
-- 2. A client that holds more of a bucket than the digest's sender waits a random 2-10 s; the
--    first to answer says so on the channel (O2) and the others stay quiet. It whispers the
--    short ids of its posts in that bucket (I2).
-- 3. The sender asks for the ones it lacks and would keep (Q1), newest first, and tells the
--    answerer of posts it holds a tombstone for (D1). The answerer whispers those posts with
--    their counts (C1), only ones whose signature it checked.
-- A login takes at most CATCHUP_MAX posts at once; the rest comes with the next digests.

local Sync = {}
ns.Sync = Sync
local Codec, Store = ns.Codec, ns.Store

Sync.DIGEST_EVERY = 900
Sync.WAIT_MIN, Sync.WAIT_MAX = 2, 10
Sync.ASK_MAX = 38          -- ids in one Q1
Sync.CATCHUP_MAX = 50      -- posts asked for in the first minutes after login
Sync.OFFER_AGAIN = 1800    -- the same answer to the same player and bucket, at most this often
local stats = { digests = 0, heard = 0, offers = 0, asked = 0, sent = 0, got = 0 }
Sync.stats = stats

local lastDigest = 0
local heardSame = 0        -- when a digest just like ours was last heard
local pending = {}         -- [asker .. "#" .. bucket] = true while our answer waits
local offered = {}         -- [asker .. "#" .. bucket] = when we last answered
local askedLogin = 0
local loginAt = 0

local function DigestText()
	local now, list = Store.Digest()
	local parts = {}
	for i, e in ipairs(list) do parts[i] = Codec.Base36(e.c) .. "." .. Codec.Base36(e.h) end
	return now, table.concat(parts, ",")
end

function Sync.SendDigest(force)
	if not ns.Comm.Ready() then return end
	local now = ns.Now()
	if not force and now - heardSame < Sync.DIGEST_EVERY * ns.Comm.Scale() then return end
	local bucket, body = DigestText()
	lastDigest = now
	stats.digests = stats.digests + 1
	ns.Comm.Send(("H2~%s~%s"):format(Codec.Base36(bucket), body), { key = "H2" })
end

local function ParseDigest(text)
	local b36, body = text:match("^H2~([0-9a-z]+)~(.*)$")
	local bucket = Codec.UnBase36(b36)
	if not bucket or not body then return nil end
	local list = {}
	for c, h in body:gmatch("([0-9a-z]+)%.([0-9a-z]+)") do
		list[#list + 1] = { c = Codec.UnBase36(c) or 0, h = Codec.UnBase36(h) or 0 }
		if #list >= Store.BUCKETS then break end
	end
	return bucket, list
end

-- Our answer to `asker` for bucket b: the short ids of what we hold and may relay there.
local function Offer(asker, b)
	local key = asker .. "#" .. b
	pending[key] = nil
	offered[key] = ns.Now()
	local ids = {}
	for _, p in ipairs(Store.InBucket(b)) do
		if p.sv or p.a == ns.me then ids[#ids + 1] = Codec.ShortId(p.id) end
	end
	if #ids == 0 then return end
	stats.offers = stats.offers + 1
	ns.Comm.Send(("O2~%s~%s"):format(asker, Codec.Base36(b)))
	ns.Comm.Send(("I2~%s~%s"):format(Codec.Base36(b), table.concat(ids, ",")), { to = asker })
end

ns.Comm.Handle("H2", function(dist, sender, text)
	if dist ~= "CHANNEL" then return end
	local bucket, theirs = ParseDigest(text)
	if not bucket then return end
	stats.heard = stats.heard + 1
	local myBucket, mine = Store.Digest()
	if bucket ~= myBucket then return end -- (another hour on its clock: nothing to compare)
	-- Only the hours both keep are compared (a busy feed's client keeps fewer).
	local same = true
	for i = 1, math.min(#mine, #theirs) do
		local e, t = mine[i], theirs[i]
		if t.c ~= e.c or t.h ~= e.h then
			same = false
			local b = myBucket - (i - 1)
			local key = sender .. "#" .. b
			if t and e.c >= t.c and e.c > 0 and not pending[key] and ns.Now() - (offered[key] or 0) > Sync.OFFER_AGAIN then
				pending[key] = true
				ns.After(Sync.WAIT_MIN + math.random() * (Sync.WAIT_MAX - Sync.WAIT_MIN), "sync offer", function()
					if pending[key] then Offer(sender, b) end
				end)
			end
		end
	end
	if same then
		heardSame = ns.Now()
	elseif ns.Now() - lastDigest > 120 then
		-- They hold something we don't: our own digest lets them answer us.
		ns.After(3 + math.random() * 10, "sync digest", function() Sync.SendDigest(true) end)
	end
end)

-- Someone else answers that player for that bucket: ours stays unsent.
ns.Comm.Handle("O2", function(dist, sender, text)
	local asker, b36 = text:match("^O2~(.+)~([0-9a-z]+)$")
	local b = Codec.UnBase36(b36)
	if not asker or not b then return end
	local key = asker .. "#" .. b
	if pending[key] then pending[key] = nil end
	offered[key] = ns.Now()
end)

-- An answer to our digest: the short ids someone holds in a bucket.
ns.Comm.Handle("I2", function(dist, sender, text)
	if dist ~= "WHISPER" then return end
	local b36, body = text:match("^I2~([0-9a-z]+)~(.*)$")
	local b = Codec.UnBase36(b36)
	if not b then return end
	local have, tombs = {}, {}
	for _, p in ipairs(Store.InBucket(b)) do have[Codec.ShortId(p.id)] = true end
	for id, tb in pairs(Store.TombsInBucket(b)) do
		if tb.s then tombs[Codec.ShortId(id)] = id end
	end
	local want = {}
	local room = ns.Now() - loginAt < 300 and (Sync.CATCHUP_MAX - askedLogin) or Sync.ASK_MAX
	for s in body:gmatch("[0-9a-z]+") do
		if #s == 5 then
			if tombs[s] then
				local id = tombs[s]
				local tb = ns.rdb.tombs[id]
				ns.Comm.Send(Codec.EncodeDelete(id, tb.at, tb.s), { to = sender })
			elseif not have[s] and #want < math.min(room, Sync.ASK_MAX) then
				want[#want + 1] = s
			end
		end
	end
	if #want == 0 then return end
	askedLogin = askedLogin + #want
	stats.asked = stats.asked + #want
	ns.Comm.Send("Q1~" .. table.concat(want, ","), { to = sender })
end)

-- "Send me these": the posts asked for, and their counts.
local lastQ = {}
ns.Comm.Handle("Q1", function(dist, sender, text)
	if dist ~= "WHISPER" then return end
	if GetTime() - (lastQ[sender] or -100) < 2 then return end
	lastQ[sender] = GetTime()
	local wanted = {}
	local n = 0
	for s in text:sub(4):gmatch("[0-9a-z]+") do
		if #s == 5 and n < Sync.ASK_MAX then wanted[s], n = true, n + 1 end
	end
	if n == 0 then return end
	local counts = {}
	local cutoff = Store.Oldest()
	for id, p in pairs(ns.rdb.posts) do
		if p.t >= cutoff and wanted[Codec.ShortId(id)] and (p.sv or p.a == ns.me) then
			ns.Comm.Send(Codec.EncodePost(p), { to = sender })
			stats.sent = stats.sent + 1
			local l, r = Store.Likes(p), Store.Reposts(p)
			if l + r > 0 then counts[#counts + 1] = { id = id, l = l, r = r } end
		end
	end
	if #counts > 0 then ns.Comm.Send(Codec.EncodeCounts(counts), { to = sender }) end
end)

ns.On("LOGIN", function()
	loginAt = ns.Now()
	ns.Every(60, "sync digest", function()
		if ns.Now() - lastDigest >= Sync.DIGEST_EVERY * ns.Comm.Scale() then Sync.SendDigest(false) end
	end)
end)
ns.On("CHANNEL_READY", function()
	-- At login always: this client is the one behind.
	ns.After(15 + math.random() * 25, "sync first digest", function() Sync.SendDigest(true) end)
end)
