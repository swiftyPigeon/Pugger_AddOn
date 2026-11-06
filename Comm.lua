local ADDON, ns = ...

-- Transport: one public custom channel per realm and faction ("PuggerA1" / "PuggerH1"), joined and
-- hidden from the chat windows, with numbered backups for when one is locked; whispers for
-- answers meant for one player. A send queue keeps to the budget (section 8 of the plan), long
-- messages go in pieces, and every sender has a flood limit. Built on Guild Master Forever's
-- Comm.lua (MIT, see LICENSE.txt).
--
-- Forever (tested 2026-11-06) drops add-on messages on custom channels, and lets an add-on write
-- on a channel only during a click or key press. So:
--   * what the player does (a post, a like, a call: opt.now) goes on the channel at once, as a
--     line of chat text, hidden from the chat windows; everyone in the channel reads it;
--   * the rest (profiles, sync, stones) goes by add-on whisper (prefix PUGGERW: "meant for the
--     channel") to a few players from the channel's member list, who are all add-on users.
--
--   Comm.Send(msg, { to = name (a whisper; else the channel), logged = true (player text),
--                    now = true (sent inside a click: on the channel; else whispered around),
--                    wide = true (with to: a channel message, whispered to that one player),
--                    reach = n (whispered around: to this many players, not Comm.SPREAD),
--                    key = dedupe key, urgent = true, done = fn(sent) })
--   Comm.Handle("P1", function(dist, sender, text, logged) ... end)
--
-- Test copies only (tools/install-test-mop.sh): ns.TEST_NET = "GUILD" or "PARTY" sends what
-- goes on the channel there instead, for clients that refuse add-on messages on custom channels
-- (MoP Classic). nil in a release.

local Comm = {}
ns.Comm = Comm
local Codec = ns.Codec

ns.TEST_NET = nil

Comm.CHANNEL_GAP = 1.0   -- seconds between two messages on the channel
Comm.WHISPER_GAP = 0.25  -- ...and between two whispers
Comm.MAX_QUEUE = 300
Comm.SPREAD = 3          -- players a background message is whispered to
Comm.REACH = 25          -- ...and news everyone should hear (opt.reach): stones, a move
Comm.ROSTER_EVERY = 20   -- seconds between two readings of the channel's member list
Comm.WIDE = ns.PREFIX .. "W" -- whispers meant for the channel

local queue = {}
local lastChannel, lastWhisper = 0, 0
local channelIndex = 0
local joinedName
local msgId = 0
local asm = { CHANNEL = Codec.NewAssembler(), WHISPER = Codec.NewAssembler() }
local handlers = {}
local stats = { sent = 0, fails = 0, recv = 0, flood = 0, bad = 0, echo = 0, dropped = 0, events = 0, ours = 0, secret = 0, elsewhere = 0, said = 0, heardText = 0, spread = 0, blocked = 0, unreachable = 0, byType = {} }
Comm.stats = stats
local function Squash(realm) return (realm:gsub("[%s%-]", ""):lower()) end
local reached, refused = {}, {} -- [squashed realm] = true: a whisper reaches it, or can't (Comm.CanWhisper)
local heard = {} -- [sender] = when we last heard them (so a whisper only goes to someone online)
local countingSince = GetTime()

-- Every client sends its profile at login and every ten minutes (Identity.PROFILE_EVERY), slower
-- on a big feed (Comm.Scale): the players heard within that, and a minute more, are the ones
-- online with the add-on.
Comm.ONLINE_WINDOW = 660
-- On a big feed the regular messages (profiles, digests) slow down in step with the players, so
-- the channel carries about the same: 1 up to SCALE_FROM players, at most SCALE_MAX (1,000
-- players: a profile every 40 minutes). Worked out each minute from the last count.
Comm.SCALE_FROM, Comm.SCALE_MAX = 250, 4
local scale = 1
function Comm.Scale() return scale end
local function Window() return Comm.ONLINE_WINDOW + (scale - 1) * (ns.Identity and ns.Identity.PROFILE_EVERY or 600) end

function Comm.HeardWithin(name, seconds)
	local t = heard[name]
	return t ~= nil and GetTime() - t <= seconds
end

-- Players online with the add-on on this feed, this one included (only those whose profile this
-- client holds: garbage on the channel never makes one); and for how many seconds this client
-- has been listening (under ONLINE_WINDOW, the count is still filling in).
function Comm.Online()
	-- The channel's member list, when the game gives it: exact, and at once.
	local r = Comm.Roster()
	if r and r.count > 0 then return r.count, math.huge, Window() end
	local now, n = GetTime(), 1
	local profiles = ns.rdb and ns.rdb.profiles or {}
	local window = Window()
	for k, t in pairs(heard) do
		if now - t <= window and profiles[k] then n = n + 1 end
	end
	return n, now - countingSince, window
end

local function Dist()
	if ns.TestNet() then return ns.TestNet() end
	return "CHANNEL"
end

-- The test transport, when this is a test copy and the player switched it on.
function ns.TestNet()
	local net = ns.db and ns.db.testNet or ns.TEST_NET
	if not ns.TEST_COPY then return nil end
	if net == "GUILD" or net == "PARTY" then return net end
	return nil
end

function Comm.Handle(kind, fn) handlers[kind] = fn end

local function Enqueue(item)
	if item.key then
		for _, q in ipairs(queue) do
			if q.key == item.key then
				q.msg, q.to, q.logged, q.done = item.msg, item.to, item.logged, item.done or q.done
				return
			end
		end
	end
	if #queue >= Comm.MAX_QUEUE then
		local drop = 1
		for i, q in ipairs(queue) do if not q.urgent then drop = i break end end
		local q = table.remove(queue, drop)
		stats.dropped = stats.dropped + 1
		if q.done then ns.SafeCall("send done", q.done, false) end
	end
	if item.urgent then
		local at = 1
		while queue[at] and queue[at].urgent do at = at + 1 end
		table.insert(queue, at, item)
	else
		queue[#queue + 1] = item
	end
end

local function Pieces(msg)
	if #msg <= 255 then return { msg } end
	msgId = (msgId + 1) % 1296
	return Codec.Chunk(msg, Codec.Base36(msgId))
end

function Comm.Send(msg, opt)
	opt = opt or {}
	if type(msg) ~= "string" or msg == "" then return end
	if opt.to and (type(opt.to) ~= "string" or opt.to == "" or ns.IsMe(opt.to)) then return end
	if opt.to and not Comm.CanWhisper(opt.to) then
		stats.unreachable = stats.unreachable + 1
		return
	end
	if not opt.to and not ns.TestNet() then
		if opt.now then return Comm.Say(msg, opt.done) end
		return Comm.Spread(msg, opt)
	end
	local pieces = Pieces(msg)
	for i, piece in ipairs(pieces) do
		Enqueue({ msg = piece, to = opt.to, wide = opt.wide, logged = opt.logged, key = #pieces == 1 and opt.key or nil,
			urgent = opt.urgent, done = i == #pieces and opt.done or nil })
	end
end

-- On the channel, as chat text, now: only inside a click or key press (the game blocks it
-- otherwise). Long messages go in pieces, all at once.
function Comm.Say(msg, done)
	local ok = channelIndex > 0 and type(SendChatMessage) == "function"
	if ok then
		for _, piece in ipairs(Pieces(msg)) do
			if not pcall(SendChatMessage, piece, "CHANNEL", nil, channelIndex) then ok = false break end
			stats.sent = stats.sent + 1
			stats.said = stats.said + 1
		end
	end
	if not ok then stats.fails = stats.fails + 1 end
	lastChannel = GetTime()
	if done then ns.SafeCall("send done", done, ok) end
	return ok
end

-- To a few players in the channel, by whisper (they hand it on as if heard on the channel).
-- Nobody to send to while the member list isn't loaded yet (just after login): held until it
-- is, HOLD_FOR seconds at most.
Comm.HOLD_FOR, Comm.HOLD_MAX = 120, 20
local held = {}
function Comm.Spread(msg, opt)
	local peers = Comm.Peers(opt.reach or Comm.SPREAD)
	if #peers == 0 and not Comm.Roster() then
		if #held < Comm.HOLD_MAX then held[#held + 1] = { msg = msg, opt = opt, t = GetTime() } end
		return
	end
	stats.spread = stats.spread + #peers
	for i, to in ipairs(peers) do
		Comm.Send(msg, { to = to, wide = true, logged = opt.logged, key = opt.key and (opt.key .. to) or nil,
			urgent = opt.urgent, done = i == 1 and opt.done or nil })
	end
	if #peers == 0 and opt.done then ns.SafeCall("send done", opt.done, false) end
end

function Comm.QueueSize() return #queue end
function Comm.Ready() return ns.TestNet() ~= nil or channelIndex > 0 end
function Comm.ChannelName() return joinedName end
function Comm.ChannelIndex() return channelIndex end
function Comm.SetIndexForTest(i) channelIndex = i end -- (as at a /reload: in the channel, number not yet known)

local function IsSuccess(res) return res == nil or res == true or res == 0 end

local function SendNow(item)
	local dist, target = "WHISPER", ns.TellName(item.to)
	if not item.to then
		dist = Dist()
		target = dist == "CHANNEL" and channelIndex or nil
	end
	local send = item.logged and C_ChatInfo.SendAddonMessageLogged or C_ChatInfo.SendAddonMessage
	local ok, res = pcall(send, item.wide and Comm.WIDE or ns.PREFIX, item.msg, dist, target)
	if ok and IsSuccess(res) then
		stats.sent = stats.sent + 1
		return true
	end
	stats.fails = stats.fails + 1
	stats.lastFail = ("%s %s"):format(dist, tostring(res))
	ns.Log("send failed on %s: %s", dist, tostring(res))
	return false
end

-- One message per call, the first one whose lane is free.
local function Pump()
	if not queue[1] then return end
	local now = GetTime()
	for i, item in ipairs(queue) do
		local lane = item.to and "w" or "c"
		if lane == "c" and Comm.Ready() and now - lastChannel >= Comm.CHANNEL_GAP then
			lastChannel = now
			table.remove(queue, i)
			local sent = SendNow(item)
			if item.done then ns.SafeCall("send done", item.done, sent) end
			return
		elseif lane == "w" and now - lastWhisper >= Comm.WHISPER_GAP then
			lastWhisper = now
			table.remove(queue, i)
			local sent = SendNow(item)
			if item.done then ns.SafeCall("send done", item.done, sent) end
			return
		end
	end
end
Comm.Pump = Pump

---------------------------------------------------------------------------
-- Flood limits per sender (from Guild Master Forever's chat flood guard): a burst, then one
-- message per interval. Over it, the sender is ignored for a minute.
---------------------------------------------------------------------------

Comm.FLOOD = { c = { burst = 12, every = 1.0 }, w = { burst = 60, every = 0.2 } }
local buckets = {}
local ignored = {}

function Comm.Admit(sender, lane, now)
	local until_ = ignored[sender]
	if until_ then
		if now < until_ then return false end
		ignored[sender] = nil
	end
	local rule = Comm.FLOOD[lane]
	local key = lane .. sender
	local b = buckets[key]
	if not b then
		b = { tokens = rule.burst, t = now }
		buckets[key] = b
	end
	b.tokens = math.min(rule.burst, b.tokens + (now - b.t) / rule.every)
	b.t = now
	if b.tokens < 1 then
		ignored[sender] = now + 60
		stats.flood = stats.flood + 1
		ns.Log("flood: %s ignored for a minute", sender)
		return false
	end
	b.tokens = b.tokens - 1
	return true
end

---------------------------------------------------------------------------
-- Receiving
---------------------------------------------------------------------------

local function Dispatch(dist, sender, text, logged)
	local kind = text:sub(1, 2)
	local handler = handlers[kind]
	if not handler or text:sub(3, 3) ~= "~" then
		stats.bad = stats.bad + 1
		return
	end
	stats.byType[kind] = (stats.byType[kind] or 0) + 1
	-- Only a post keeps its "|" (links, Codec.Sanitize checks them); every other message loses
	-- every "|" and control byte before a handler reads it.
	if kind ~= "P1" then text = text:gsub("[|%c]", "") end
	ns.SafeCall("handler " .. kind, handler, dist, sender, text, logged)
end

local function OnAddonMessage(prefix, text, dist, sender, target, zoneChannelID, localID, channelName, logged)
	stats.events = stats.events + 1
	if ns.Secret(prefix, text, sender, dist, localID) then stats.secret = stats.secret + 1 return end
	if dist == "WHISPER" and type(sender) == "string" then
		-- A whisper came from their realm: ours reach it too.
		local r = sender:match("%-([^%-]+)$")
		if r then reached[Squash(r)] = true end
	end
	if prefix == Comm.WIDE and dist == "WHISPER" then
		-- Meant for the channel, whispered to us (Comm.Spread): handled as heard there.
		prefix, dist, localID = ns.PREFIX, "CHANNEL", nil
	end
	if prefix == ns.PREFIX then stats.ours = stats.ours + 1 end
	if prefix ~= ns.PREFIX or type(text) ~= "string" or type(sender) ~= "string" or sender == "" then return end
	if not ns.rdb then return end
	local net = ns.TestNet()
	if dist == "CHANNEL" then
		if net then return end
		-- Our channel only: someone in any other channel we sit in can't reach the handlers.
		if type(localID) == "number" and localID > 0 and localID ~= channelIndex then
			local id = joinedName and GetChannelName(joinedName) or 0
			if id ~= localID then stats.elsewhere = stats.elsewhere + 1 return end
			channelIndex = id
		end
	elseif dist == "WHISPER" then
		-- (a whisper is a whisper)
	elseif not (net and dist == net) then
		return
	end
	local realm = sender:match("%-([^%-]+)$")
	if realm then ns.knownRealms[realm] = true end
	sender = ns.Key(sender)
	if sender == ns.me then
		stats.echo = stats.echo + 1
		return
	end
	local lane = dist == "WHISPER" and "w" or "c"
	local now = GetTime()
	if ns.Safety and ns.Safety.IsBlocked(sender) and dist == "WHISPER" then return end
	if not Comm.Admit(sender, lane, now) then return end
	stats.recv = stats.recv + 1
	heard[sender] = now
	if ns.Identity then ns.Identity.Heard(sender) end
	local wire = dist == "WHISPER" and "WHISPER" or "CHANNEL"
	if text:match("^C%w+:%d+:%d+:") then
		local full = Codec.Feed(asm[wire], sender, text, now)
		if not full then return end
		-- Put together from pieces: logged only if every piece was (each sender sends a post's
		-- pieces all one way, so the last piece says it).
		return Dispatch(wire, sender, full, logged)
	end
	Dispatch(wire, sender, text, logged)
end
Comm.OnAddonMessage = OnAddonMessage

-- A line of chat text on our channel (Comm.Say): the same as an add-on message there, logged
-- (the server keeps chat text).
function Comm.OnChannelText(text, sender, _, channelName, _, _, _, localID, baseName)
	if ns.Secret(text, sender, channelName, localID, baseName) then return end
	if not joinedName or type(text) ~= "string" then return end
	local name = type(baseName) == "string" and baseName ~= "" and baseName
		or type(channelName) == "string" and channelName:gsub("^%d+%.%s*", "") or ""
	if name:lower() ~= joinedName:lower() then return end
	stats.heardText = stats.heardText + 1
	OnAddonMessage(ns.PREFIX, text, "CHANNEL", sender, nil, 0, nil, name, true)
end

---------------------------------------------------------------------------
-- The channel's member list: everyone in it runs the add-on. It counts who is online, and
-- gives the players a background message is whispered to.
---------------------------------------------------------------------------

-- A member's name as the add-on keeps names (Name-Realm), from the realm their GUID gives.
local function MemberKey(name, guid)
	if type(name) ~= "string" or name == "" then return nil end
	if name:find("-", 1, true) then return ns.Key(name) end
	local realm
	if type(guid) == "string" and GetPlayerInfoByGUID then
		local ok, _, _, _, _, _, _, r = pcall(GetPlayerInfoByGUID, guid)
		if ok and type(r) == "string" then realm = r end
	end
	if realm == nil then return nil end
	if realm == "" then realm = ns.realm end
	return ns.Key(name .. "-" .. realm)
end

local roster, rosterAt, askedAt = nil, -1e9, -1e9
Comm.ROSTER_ASK = 60 -- seconds between two asks for the member list

-- The game has the member list only once asked for it (Forever: no count at all until then),
-- as selecting the channel in the Chat Channels window does. Not while that window is open:
-- what the player looks at there stays theirs. Read again a few seconds later.
local function AskRoster(i)
	if not SetSelectedDisplayChannel then return end
	if type(ChannelFrame) == "table" and ChannelFrame.IsShown and ChannelFrame:IsShown() then return end
	askedAt = GetTime()
	pcall(SetSelectedDisplayChannel, i)
	rosterAt = GetTime() - Comm.ROSTER_EVERY + 3
end

local function ReadRoster()
	if not joinedName or not GetNumDisplayChannels or not GetChannelDisplayInfo then return nil end
	local R = C_ChatInfo and C_ChatInfo.GetChannelRosterInfo or GetChannelRosterInfo
	for i = 1, GetNumDisplayChannels() or 0 do
		local name, _, _, _, count = GetChannelDisplayInfo(i)
		if ns.Secret(name, count) then return nil end
		if type(name) == "string" and name:lower() == joinedName:lower() then
			-- (We're in it: 0 or none means not loaded yet.)
			if (tonumber(count) or 0) == 0 then
				AskRoster(i)
				return nil
			end
			if GetTime() - askedAt >= Comm.ROSTER_ASK then AskRoster(i) end
			local list = { count = tonumber(count) or 0 }
			for j = 1, R and list.count or 0 do
				local who, _, _, guid = R(i, j)
				if ns.Secret(who, guid) then break end
				local key = MemberKey(who, guid)
				if key and key ~= ns.me then list[#list + 1] = key end
			end
			return list
		end
	end
	return nil
end

-- { count = members, Name-Realm of the others }, or nil while the game hasn't told.
function Comm.Roster()
	if GetTime() - rosterAt >= Comm.ROSTER_EVERY then
		rosterAt = GetTime()
		local ok, list = pcall(ReadRoster)
		roster = ok and list or nil
		-- The list came: what waited for it goes now (Comm.Spread).
		if roster and held[1] then
			local now, list2 = GetTime(), held
			held = {}
			for _, h in ipairs(list2) do
				if now - h.t <= Comm.HOLD_FOR then Comm.Spread(h.msg, h.opt) end
			end
		end
	end
	return roster
end
function Comm.RosterChanged() rosterAt = -1e9 end

-- Can a whisper reach them? Forever's channels reach players of many realms (seen 2026-11-06),
-- a whisper only ours and the ones connected to it: the game's list of those, and any realm a
-- whisper came to us from. Anyone else gets "no player named" (and that realm is skipped after).
local function Connected()
	local f = C_AutoComplete and C_AutoComplete.GetAutoCompleteRealms or GetAutoCompleteRealms
	if type(f) ~= "function" then return nil end
	local ok, a = pcall(function() return { f() } end)
	if not ok then return nil end
	local list = type(a[1]) == "table" and a[1] or a
	return #list > 0 and list or nil
end
function Comm.CanWhisper(name)
	local realm = ns.RealmOf(name)
	if not realm or realm == ns.realm then return true end
	local want = Squash(realm)
	if refused[want] then return false end
	if reached[want] then return true end
	for _, r in ipairs(Connected() or {}) do
		if type(r) == "string" and Squash(r) == want then return true end
	end
	return false
end

-- "No player named 'Name-Realm' is currently playing": that realm is out of a whisper's reach.
function Comm.OnSystemText(text)
	if ns.Secret(text) or type(text) ~= "string" or type(ERR_CHAT_PLAYER_NOT_FOUND_S) ~= "string" then return end
	local pattern = "^" .. ERR_CHAT_PLAYER_NOT_FOUND_S:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%0"):gsub("%%%%s", "(.+)") .. "$"
	local who = text:match(pattern)
	local realm = who and ns.RealmOf(who)
	if not realm or realm == ns.realm or reached[Squash(realm)] then return end
	refused[Squash(realm)] = true
	ns.Log("whispers can't reach %s", realm)
end

-- Up to n players to whisper a background message to: from the member list (heard players
-- while it's unknown), at random.
function Comm.Peers(n)
	local pool = {}
	local r = Comm.Roster()
	if r and #r > 0 then
		for _, k in ipairs(r) do if Comm.CanWhisper(k) then pool[#pool + 1] = k end end
	else
		local now = GetTime()
		for k, t in pairs(heard) do if now - t <= Window() and Comm.CanWhisper(k) then pool[#pool + 1] = k end end
	end
	local out = {}
	while #pool > 0 and #out < n do
		out[#out + 1] = table.remove(pool, math.random(#pool))
	end
	return out
end

---------------------------------------------------------------------------
-- The channel and its backups. Anyone can own a custom channel and lock it (a password, bans):
-- then the feed moves to the next name, PuggerA2, PuggerA3..., in an order fixed here, so
-- everyone ends up in the same place. The add-on never uses an owner's powers on anyone.
---------------------------------------------------------------------------

local function ChannelFor(n)
	local base = ns.CHANNELS[ns.faction or ""]
	return base and (base .. n) or nil
end
Comm.ChannelFor = ChannelFor

local function HideChannelFromChat(name)
	for i = 1, (NUM_CHAT_WINDOWS or 10) do
		local cf = _G["ChatFrame" .. i]
		if cf and ChatFrame_RemoveChannel then pcall(ChatFrame_RemoveChannel, cf, name) end
	end
end

-- Our hidden channel after the game's own. Joined before them (a slow login, or Forever, where
-- General comes in late), it took /1 and pushed General to /2, Trade to /3: moved past each of
-- the game's channels numbered after it, they get their usual numbers back. The player's own
-- channels and other add-ons' keep theirs. (From Sylvanistas' Comm.KeepLast.)
function Comm.KeepLast()
	if not joinedName or not GetChannelList then return end
	local swap = C_ChatInfo and C_ChatInfo.SwapChatChannelsByChannelIndex
	local infoOf = C_ChatInfo and C_ChatInfo.GetChannelInfoFromIdentifier
	if not swap or not infoOf then return end
	local ours = GetChannelName(joinedName) or 0
	if ours <= 0 then return end
	local list = { GetChannelList() }
	local stride = type(list[3]) == "boolean" and 3 or 2 -- (id, name, disabled) or (id, name)
	local after = {}
	for i = 1, #list, stride do
		local id = tonumber(list[i])
		local ok, info = pcall(infoOf, list[i + 1])
		-- The game's channels (General, Trade...) are zone channels; custom ones are not.
		if id and id > ours and ok and type(info) == "table" and (tonumber(info.zoneChannelID) or 0) > 0 then after[#after + 1] = id end
	end
	if #after == 0 then return end
	table.sort(after)
	local at = ours
	for _, id in ipairs(after) do
		if not pcall(swap, at, id) then break end
		at = id
	end
	channelIndex = GetChannelName(joinedName) or channelIndex
	ns.Log("channel %s moved from #%d to #%d", joinedName, ours, channelIndex)
end

local joinAt = -1e9
function Comm.JoinChannel()
	if ns.TestNet() or not ns.rdb then return end
	local n = math.max(1, math.min(ns.CHANNEL_MAX, tonumber(ns.rdb.channel) or 1))
	local name = ChannelFor(n)
	if not name then return end
	if joinedName and joinedName ~= name and (GetChannelName(joinedName) or 0) > 0 then
		LeaveChannelByName(joinedName)
		ns.Log("left %s for %s", joinedName, name)
	end
	if joinedName ~= name then channelIndex = 0 Comm.RosterChanged() end
	joinedName = name
	local was = channelIndex
	local id = GetChannelName(name) or 0
	if id > 0 then
		-- Already in it (a /reload): say we're here all the same.
		channelIndex = id
		HideChannelFromChat(name)
		Comm.KeepLast()
		if was == 0 then ns.Fire("CHANNEL_READY") end
		return
	end
	if GetTime() - joinAt < 5 then return end
	joinAt = GetTime()
	ns.Log("joining %s", name)
	JoinChannelByName(name)
	ns.After(3, "channel check", function()
		channelIndex = GetChannelName(name) or 0
		ns.Log("%s -> #%d", name, channelIndex)
		HideChannelFromChat(name)
		Comm.KeepLast()
		if channelIndex > 0 then ns.Fire("CHANNEL_READY") end
	end)
end

-- We join once the game's own channels are in (General is /1 for two seconds), so General,
-- Trade and LocalDefense keep their usual numbers; at JOIN_BY seconds whatever happens.
Comm.JOIN_BY = 15
function Comm.JoinSoon(t, seenAt)
	local _, first = GetChannelName(1)
	if type(first) == "string" and first ~= "" then seenAt = seenAt or t end
	if t >= Comm.JOIN_BY or (seenAt and t - seenAt >= 2) then return Comm.JoinChannel() end
	ns.After(1, "join channel", function() Comm.JoinSoon(t + 1, seenAt) end)
end

-- To channel n (a backup): never back down to a lower one this way.
function Comm.MoveTo(n, why)
	n = tonumber(n)
	if not n or n <= (ns.rdb.channel or 1) or n > ns.CHANNEL_MAX then return end
	ns.Log("moving to channel %d (%s)", n, tostring(why))
	-- Told to the old channel's members while we're still in it, so those who missed the notice
	-- follow (the whispers' names are picked now, from its member list).
	if channelIndex > 0 and not ns.TestNet() then Comm.Send("B1~" .. n, { reach = Comm.REACH }) end
	ns.rdb.channel = n
	ns.Print(ns.L.CHANNEL_MOVED:format(ChannelFor(n) or "?"))
	joinAt = -1e9
	Comm.JoinChannel()
end

-- "The feed moved": believed only for the next channel, and only once B1_QUORUM different players
-- said it within ten minutes (one griefer can't walk the realm through every backup). Whoever
-- logs in later finds the old channel locked and moves on by itself.
Comm.B1_QUORUM = 3
local movers = {}
Comm.Handle("B1", function(dist, sender, text)
	local n = Codec.Int(text:match("^B1~(%d+)$"), 2, ns.CHANNEL_MAX)
	if not n or dist ~= "CHANNEL" or n ~= (ns.rdb.channel or 1) + 1 then return end
	local now = ns.Now()
	movers[sender] = now
	local count = 0
	for name, t in pairs(movers) do
		if now - t > 600 then movers[name] = nil else count = count + 1 end
	end
	if count >= Comm.B1_QUORUM then
		wipe(movers)
		Comm.MoveTo(n, "told by " .. count .. " players")
	end
end)

-- CHAT_MSG_CHANNEL_NOTICE(_USER): (notice, player, language, "5. PuggerA1", player2, ..., baseName)
function Comm.OnChannelNotice(notice, player, _, channelName, player2, _, _, _, baseName)
	if type(issecretvalue) == "function" and (issecretvalue(notice) or issecretvalue(player)) then return end
	if type(notice) ~= "string" or not joinedName then return end
	local name
	for _, n in ipairs({ baseName, channelName }) do
		if type(n) == "string" and n:gsub("^%d+%.%s*", ""):lower() == joinedName:lower() then name = joinedName end
	end
	if not name then return end
	if notice == "WRONG_PASSWORD" or notice == "BANNED" then
		Comm.MoveTo((ns.rdb.channel or 1) + 1, notice)
	elseif notice == "PASSWORD_CHANGED" and player and ns.Key(player) ~= ns.me then
		-- Whoever logs in next can't get in: everyone moves now, together.
		Comm.MoveTo((ns.rdb.channel or 1) + 1, "password set by " .. tostring(player))
	elseif notice == "YOU_JOINED" or notice == "YOU_CHANGED" then
		channelIndex = GetChannelName(joinedName) or channelIndex
		HideChannelFromChat(joinedName)
	end
end

function Comm.OnPasswordRequest(channel)
	if joinedName and type(channel) == "string" and channel:lower() == joinedName:lower() then
		Comm.MoveTo((ns.rdb.channel or 1) + 1, "password asked")
	end
end

-- After switching the test transport (/pug testnet): onto the channel or off it.
function Comm.Reset()
	wipe(queue)
	if not ns.TestNet() then Comm.JoinChannel() end
end

ns.On("LOGIN", function()
	if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
		C_ChatInfo.RegisterAddonMessagePrefix(ns.PREFIX)
		C_ChatInfo.RegisterAddonMessagePrefix(Comm.WIDE)
	end
	ns.RegisterEvent("CHAT_MSG_ADDON", function(...) OnAddonMessage(...) end)
	ns.RegisterEvent("CHAT_MSG_CHANNEL", Comm.OnChannelText)
	ns.RegisterEvent("CHAT_MSG_SYSTEM", Comm.OnSystemText)
	pcall(ns.RegisterEvent, "CHANNEL_ROSTER_UPDATE", Comm.RosterChanged)
	-- A send the game refused (outside a click): counted, so /pug status tells.
	ns.RegisterEvent("ADDON_ACTION_BLOCKED", function(addon, what)
		if addon ~= ADDON then return end
		stats.blocked = stats.blocked + 1
		ns.Log("blocked: %s", tostring(what))
	end)
	ns.RegisterEvent("CHAT_MSG_ADDON_LOGGED", function(prefix, text, dist, sender, target, z, l, c)
		OnAddonMessage(prefix, text, dist, sender, target, z, l, c, true)
	end)
	ns.RegisterEvent("CHAT_MSG_CHANNEL_NOTICE", Comm.OnChannelNotice)
	ns.RegisterEvent("CHAT_MSG_CHANNEL_NOTICE_USER", Comm.OnChannelNotice)
	ns.RegisterEvent("CHANNEL_PASSWORD_REQUEST", Comm.OnPasswordRequest)
	-- After the game's own channels (General, Trade), so ours never takes their numbers.
	ns.After(1, "join channel", function() Comm.JoinSoon(1) end)
	if ns.TestNet() then ns.After(4, "test net", function() ns.Fire("CHANNEL_READY") end) end
	C_Timer.NewTicker(0.1, function() ns.SafeCall("send pump", Pump) end)
	-- The member list, read as it loads (Comm.Roster reads the game's at most every ROSTER_EVERY).
	ns.Every(5, "member list", function() if not ns.TestNet() then Comm.Roster() end end)
	ns.Every(60, "channel housekeeping", function()
		local now = GetTime()
		Codec.Gc(asm.CHANNEL, now)
		Codec.Gc(asm.WHISPER, now)
		for k, b in pairs(buckets) do if now - b.t > 300 then buckets[k] = nil end end
		for k, t in pairs(heard) do if now - t > Window() then heard[k] = nil end end
		scale = math.max(1, math.min(Comm.SCALE_MAX, Comm.Online() / Comm.SCALE_FROM))
		if not ns.TestNet() and (channelIndex == 0 or (GetChannelName(joinedName or "") or 0) == 0) then Comm.JoinChannel() end
	end)
end)
