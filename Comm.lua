local ADDON, ns = ...

-- Transport: one public custom channel per realm and faction ("PuggerA1" / "PuggerH1"), joined and
-- hidden from the chat windows, with numbered backups for when one is locked; whispers for
-- answers meant for one player. A send queue keeps to the budget (section 8 of the plan), long
-- messages go in pieces, and every sender has a flood limit. Built on Guild Master Forever's
-- Comm.lua (MIT, see LICENSE.txt).
--
--   Comm.Send(msg, { to = name (a whisper; else the channel), logged = true (player text),
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

local queue = {}
local lastChannel, lastWhisper = 0, 0
local channelIndex = 0
local joinedName
local msgId = 0
local asm = { CHANNEL = Codec.NewAssembler(), WHISPER = Codec.NewAssembler() }
local handlers = {}
local stats = { sent = 0, fails = 0, recv = 0, flood = 0, bad = 0, echo = 0, dropped = 0, byType = {} }
Comm.stats = stats
local heard = {} -- [sender] = when we last heard them (so a whisper only goes to someone online)
local countingSince = GetTime()

-- Every client sends its profile at login and every half hour (Identity.PROFILE_EVERY), slower
-- on a big feed (Comm.Scale): the players heard within that, and a minute more, are the ones
-- online with the add-on.
Comm.ONLINE_WINDOW = 1860
-- On a big feed the regular messages (profiles, digests) slow down in step with the players, so
-- the channel carries about the same: 1 up to SCALE_FROM players, at most SCALE_MAX (1,000
-- players: a profile every two hours). Worked out each minute from the last count.
Comm.SCALE_FROM, Comm.SCALE_MAX = 250, 4
local scale = 1
function Comm.Scale() return scale end
local function Window() return Comm.ONLINE_WINDOW + (scale - 1) * 1800 end

function Comm.HeardWithin(name, seconds)
	local t = heard[name]
	return t ~= nil and GetTime() - t <= seconds
end

-- Players online with the add-on on this feed, this one included (only those whose profile this
-- client holds: garbage on the channel never makes one); and for how many seconds this client
-- has been listening (under ONLINE_WINDOW, the count is still filling in).
function Comm.Online()
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

function Comm.Send(msg, opt)
	opt = opt or {}
	if type(msg) ~= "string" or msg == "" then return end
	if opt.to and (type(opt.to) ~= "string" or opt.to == "" or ns.IsMe(opt.to)) then return end
	if #msg <= 255 then
		Enqueue({ msg = msg, to = opt.to, logged = opt.logged, key = opt.key, urgent = opt.urgent, done = opt.done })
		return
	end
	msgId = (msgId + 1) % 1296
	local pieces = Codec.Chunk(msg, Codec.Base36(msgId))
	for i, piece in ipairs(pieces) do
		Enqueue({ msg = piece, to = opt.to, logged = opt.logged, urgent = opt.urgent, done = i == #pieces and opt.done or nil })
	end
end

function Comm.QueueSize() return #queue end
function Comm.Ready() return ns.TestNet() ~= nil or channelIndex > 0 end
function Comm.ChannelName() return joinedName end

local function IsSuccess(res) return res == nil or res == true or res == 0 end

local function SendNow(item)
	local dist, target = "WHISPER", ns.TellName(item.to)
	if not item.to then
		dist = Dist()
		target = dist == "CHANNEL" and channelIndex or nil
	end
	local send = item.logged and C_ChatInfo.SendAddonMessageLogged or C_ChatInfo.SendAddonMessage
	local ok, res = pcall(send, ns.PREFIX, item.msg, dist, target)
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
	if prefix ~= ns.PREFIX or type(text) ~= "string" or type(sender) ~= "string" or sender == "" then return end
	if not ns.rdb then return end
	local net = ns.TestNet()
	if dist == "CHANNEL" then
		if net then return end
		-- Our channel only: someone in any other channel we sit in can't reach the handlers.
		if type(localID) == "number" and localID > 0 and localID ~= channelIndex then
			local id = joinedName and GetChannelName(joinedName) or 0
			if id ~= localID then return end
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
	if joinedName ~= name then channelIndex = 0 end
	joinedName = name
	local id = GetChannelName(name) or 0
	if id > 0 then
		channelIndex = id
		HideChannelFromChat(name)
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
		if channelIndex > 0 then ns.Fire("CHANNEL_READY") end
	end)
end

-- To channel n (a backup): never back down to a lower one this way.
function Comm.MoveTo(n, why)
	n = tonumber(n)
	if not n or n <= (ns.rdb.channel or 1) or n > ns.CHANNEL_MAX then return end
	ns.Log("moving to channel %d (%s)", n, tostring(why))
	-- Said on the old channel while we're still in it, so those who missed the notice follow.
	if channelIndex > 0 and not ns.TestNet() then
		pcall(C_ChatInfo.SendAddonMessage, ns.PREFIX, "B1~" .. n, "CHANNEL", channelIndex)
	end
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
	if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then C_ChatInfo.RegisterAddonMessagePrefix(ns.PREFIX) end
	ns.RegisterEvent("CHAT_MSG_ADDON", function(...) OnAddonMessage(...) end)
	ns.RegisterEvent("CHAT_MSG_ADDON_LOGGED", function(prefix, text, dist, sender, target, z, l, c)
		OnAddonMessage(prefix, text, dist, sender, target, z, l, c, true)
	end)
	ns.RegisterEvent("CHAT_MSG_CHANNEL_NOTICE", Comm.OnChannelNotice)
	ns.RegisterEvent("CHAT_MSG_CHANNEL_NOTICE_USER", Comm.OnChannelNotice)
	ns.RegisterEvent("CHANNEL_PASSWORD_REQUEST", Comm.OnPasswordRequest)
	-- After the game's own channels (General, Trade), so ours never takes their numbers.
	ns.After(4, "join channel", Comm.JoinChannel)
	if ns.TestNet() then ns.After(4, "test net", function() ns.Fire("CHANNEL_READY") end) end
	C_Timer.NewTicker(0.1, function() ns.SafeCall("send pump", Pump) end)
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
