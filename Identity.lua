local ADDON, ns = ...

-- Signed posts (section 6 of the plan). Sync relays posts, so a relayed post only *says* who
-- wrote it. Each character's add-on makes an Ed25519 key pair on first use (the secret half
-- stays in its saved file); the public key travels in the profile (R1), and a profile heard
-- directly from its owner (the server says who sent it) pins their key: first seen, trusted
-- after. Every post and delete is signed; a relayed post shows only once its signature checks
-- against the author's pinned key, and stays greyed "unverified" while the key is unknown.
--
-- Ed25519 in plain Lua takes tens of milliseconds per signature: every signing and check runs
-- in slices (Ed.Run), one at a time, and checks are cached.

local Identity = {}
ns.Identity = Identity
local Ed = ns.Ed25519
local Codec = ns.Codec

Identity.PROFILE_EVERY = 600 -- seconds between two profiles sent unasked (slower on a big feed)
Identity.BIO_MAX = 80

local seed, pk, pkB64

-- 32 bytes nobody can guess: SHA-512 of everything that changes between two players and two
-- moments, the game's random numbers included.
local function NewSeed()
	local parts = {}
	for i = 1, 64 do parts[i] = string.char(math.random(0, 255)) end
	parts[#parts + 1] = tostring(GetTime()) .. tostring(time()) .. tostring(debugprofilestop and debugprofilestop() or 0)
	parts[#parts + 1] = tostring(ns.me) .. tostring(UnitGUID and UnitGUID("player") or "") .. tostring({})
	return Ed.SHA512(table.concat(parts)):sub(1, 32)
end

function Identity.Ready() return pk ~= nil end
function Identity.PublicKey() return pkB64 end

---------------------------------------------------------------------------
-- The work queue: one job in Ed.Run at a time, the player's own signing first.
---------------------------------------------------------------------------

local work, running = {}, false
local function Next()
	if running then return end
	local job = table.remove(work, 1)
	if not job then return end
	running = true
	local started = Ed.Run(job.fn, function(ok, res)
		running = false
		if job.done then ns.SafeCall("identity done", job.done, ok and res) end
		Next()
	end)
	if not started then
		running = false
		table.insert(work, 1, job)
		ns.After(1, "identity retry", Next)
	end
end
local function Queue(fn, done, first)
	if first then table.insert(work, 1, { fn = fn, done = done }) else work[#work + 1] = { fn = fn, done = done } end
	Next()
end
function Identity.Busy() return #work + (running and 1 or 0) end

-- Signs msg at once (about 40 ms on Forever): inside a click, where the channel can be written
-- before the click is over. nil if the key isn't ready.
function Identity.SignNow(msg)
	if not seed or not pk then return nil end
	return Ed.ToB64(Ed.Sign(seed, msg, pk))
end

-- Signs msg with the player's key; done(sigB64) (nil if the key isn't ready).
function Identity.Sign(msg, done)
	if not seed or not pk then return done(nil) end
	local s, p = seed, pk
	Queue(function() return Ed.ToB64(Ed.Sign(s, msg, p)) end, done, true)
end

-- Checks sigB64 of msg against the keys given (the current one first); done(true|false).
local checked = {} -- [sig .. key] = result
function Identity.Verify(keys, msg, sigB64, done)
	local sig = Ed.FromB64(sigB64)
	if not sig or #sig ~= 64 then return done(false) end
	local list = {}
	for _, k in ipairs(keys) do
		local cached = checked[sigB64 .. k]
		if cached == true then return done(true) end
		if cached == nil then list[#list + 1] = k end
	end
	if #list == 0 then return done(false) end
	Queue(function()
		for _, k in ipairs(list) do
			local key = Ed.FromB64(k)
			local ok = key and #key == 32 and Ed.Verify(key, msg, sig) or false
			checked[sigB64 .. k] = ok
			if ok then return true end
		end
		return false
	end, function(ok) done(ok == true) end)
end

---------------------------------------------------------------------------
-- Profiles: name, class, level and guild from the game, a short bio, the public key.
---------------------------------------------------------------------------

-- The keys a post by `author` may be signed with: the pinned one, then older ones.
function Identity.KeysOf(author)
	local pr = ns.rdb.profiles[author]
	if not pr or not pr.pk then return nil end
	local keys = { pr.pk }
	for _, k in ipairs(pr.oldKeys or {}) do keys[#keys + 1] = k end
	return keys
end

function Identity.MyProfile()
	local _, class = UnitClass("player")
	local guild = GetGuildInfo and GetGuildInfo("player") or ""
	return {
		pk = pkB64, level = UnitLevel("player") or 0, class = class or "", guild = Codec.Clean(guild),
		showFollows = ns.db.settings.showFollows, bio = ns.cdb.bio or "", t = ns.Now(),
	}
end

local function ProfileMessage(pr, sig)
	return table.concat({ "R1", pr.pk, tostring(pr.level), pr.class, pr.guild, pr.showFollows and "1" or "0",
		Codec.Base36(pr.t), sig, Codec.Clean(pr.bio) }, "~")
end

-- now: inside a click, on the channel for everyone (else whispered to a few: Comm.Spread).
local lastProfile, lastSaid = 0, -1e9
function Identity.SendProfile(force, now)
	if not pkB64 or not ns.Comm.Ready() then return end
	if not force and ns.Now() - lastProfile < 60 then return end
	lastProfile = ns.Now()
	local pr = Identity.MyProfile()
	-- Kept the way others see it (the Me tab reads this).
	local mine = ns.rdb.profiles[ns.me] or {}
	ns.rdb.profiles[ns.me] = mine
	for k, v in pairs(pr) do mine[k] = v end
	mine.direct = true
	if now then
		local sig = Identity.SignNow(Codec.ProfileSigned(ns.me, pr))
		if not sig then return end
		lastSaid = ns.Now()
		return ns.Comm.Send(ProfileMessage(pr, sig), { logged = true, now = true })
	end
	Identity.Sign(Codec.ProfileSigned(ns.me, pr), function(sig)
		if not sig then return end
		ns.Comm.Send(ProfileMessage(pr, sig), { key = "R1", logged = true })
	end)
end

-- Inside the click of a post: our profile on the channel first, when it hasn't been there for
-- PROFILE_EVERY. Every reader needs our key to check the post, and a whisper can't reach them all.
function Identity.SayProfileIfDue()
	if ns.Now() - lastSaid < Identity.PROFILE_EVERY then return end
	Identity.SendProfile(true, true)
end

-- A profile we lack, asked of its owner by whisper (R0), only once we heard them online in the
-- last ASK_WITHIN seconds (a whisper to someone offline makes the game print an error), and at
-- most once per ASK_AGAIN. Authors of posts waiting for their key are noted until then.
Identity.ASK_WITHIN = 600
Identity.ASK_AGAIN = 600
local waiting, asked = {}, {}
local soon = {} -- [name] = an ask on its way (Identity.Heard)

function Identity.Want(name)
	if not name or name == ns.me or (ns.rdb.profiles[name] and ns.rdb.profiles[name].pk) then return end
	waiting[name] = true
	Identity.Heard(name)
end

local function Lacking(name)
	local pr = ns.rdb.profiles[name]
	return not (pr and pr.pk)
end

local function Ask(name)
	if not ns.Comm.HeardWithin(name, Identity.ASK_WITHIN) then return end
	if GetTime() - (asked[name] or -1e9) < Identity.ASK_AGAIN then return end
	asked[name] = GetTime()
	ns.Comm.Send("R0~", { to = name })
end

-- On a small feed, anyone heard whose profile we lack is asked for it, so they count as online
-- within seconds (Comm.Online counts only players with a profile), not at their next profile.
-- A busy feed looks alive anyway: no whisper to each of hundreds. A few seconds later: the
-- message we just heard may be that profile.
Identity.ASK_UNDER = 25
function Identity.Heard(name)
	if not name or name == ns.me then return end
	if waiting[name] then return Ask(name) end
	if not Lacking(name) or soon[name] or ns.Comm.Online() >= Identity.ASK_UNDER then return end
	soon[name] = true
	ns.After(3, "profile ask", function()
		soon[name] = nil
		if Lacking(name) then Ask(name) end
	end)
end

local answered = {}
ns.Comm.Handle("R0", function(dist, sender)
	if dist ~= "WHISPER" or not pkB64 then return end
	if GetTime() - (answered[sender] or -1e9) < 60 then return end
	answered[sender] = GetTime()
	local pr = Identity.MyProfile()
	Identity.Sign(Codec.ProfileSigned(ns.me, pr), function(sig)
		if not sig then return end
		ns.Comm.Send(ProfileMessage(pr, sig), { to = sender, logged = true })
	end)
end)

function Identity.SetBio(text)
	ns.cdb.bio = ns.Cut(Codec.Clean(text), Identity.BIO_MAX * 3)
	Identity.SendProfile(true, true) -- (saved with a click)
	ns.Fire("FEED_CHANGED")
end

-- A profile, only ever from its owner (the server says who sent it).
ns.Comm.Handle("R1", function(dist, sender, text)
	local f = Codec.Fields(text, 9)
	if #f ~= 9 then return end
	local key = Ed.FromB64(f[2])
	if not key or #key ~= 32 then return end
	local level = Codec.Int(f[3], 1, 200)
	local t = Codec.UnBase36(f[7])
	if not level or not t then return end
	local profiles = ns.rdb.profiles
	local pr = profiles[sender]
	if not pr then
		pr = {}
		profiles[sender] = pr
	end
	if pr.pk and pr.pk ~= f[2] then
		-- A new key (their saved files were lost): heard from them directly, so it is theirs;
		-- their old posts still check against the old one.
		pr.oldKeys = pr.oldKeys or {}
		table.insert(pr.oldKeys, 1, pr.pk)
		while #pr.oldKeys > 3 do table.remove(pr.oldKeys) end
		pr.newKeyAt = ns.Now()
		ns.Log("profile %s: new key", sender)
	end
	local fresh = not pr.pk
	waiting[sender] = nil
	pr.pk = f[2]
	pr.level, pr.class, pr.guild = level, Codec.Clean(f[4]):sub(1, 12), Codec.Clean(f[5]):sub(1, 72)
	pr.showFollows = f[6] == "1"
	pr.bio = ns.Cut(Codec.Clean(f[9]), Identity.BIO_MAX * 3)
	pr.t, pr.heard, pr.direct = t, ns.Now(), true
	if fresh then
		-- Their posts that waited for this key can be checked now.
		if ns.Feed then ns.Feed.KeyArrived(sender) end
	end
	ns.Fire("FEED_CHANGED")
end)

ns.On("LOGIN", function()
	local c = ns.cdb
	if type(c.seed) == "string" then seed = Ed.FromB64(c.seed) end
	if not seed or #seed ~= 32 then
		seed = NewSeed()
		c.seed = Ed.ToB64(seed)
		c.pk = nil
		ns.Log("new signing key")
	end
	local saved = type(c.pk) == "string" and Ed.FromB64(c.pk)
	if saved and #saved == 32 then
		pk, pkB64 = saved, c.pk
	else
		local s = seed
		Queue(function() return Ed.PublicKey(s) end, function(res)
			if type(res) ~= "string" then return end
			pk, pkB64 = res, Ed.ToB64(res)
			c.pk = pkB64
			Identity.SendProfile(true)
		end, true)
	end
end)

ns.On("CHANNEL_READY", function()
	ns.After(2 + math.random() * 6, "profile", function() Identity.SendProfile(true) end)
end)
ns.On("LOGIN", function()
	ns.Every(60, "profile ticker", function()
		if ns.Now() - lastProfile >= Identity.PROFILE_EVERY * ns.Comm.Scale() then Identity.SendProfile(true) end
	end)
end)
