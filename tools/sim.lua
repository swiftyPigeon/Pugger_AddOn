-- Pugger's offline test bench: several clients, each a whole copy of the add-on in its own
-- globals, against a fake WoW API joined by a fake channel, whispers and guild. Time is
-- simulated; Ed25519 runs for real. Every add-on message is checked against the game's limits
-- (255 bytes, a 16-character prefix).
-- Usage (from the repo): luajit tools/sim.lua
-- Adapted from the idea of Guild Master Forever's tools/loadtest.lua (MIT, see LICENSE.txt).

local ROOT = (arg and arg[0] or "tools/sim.lua"):gsub("tools/sim%.lua$", "")
if ROOT == "" then ROOT = "./" end
local bitlib = require("bit")

---------------------------------------------------------------------------
-- Time and timers
---------------------------------------------------------------------------

local NOW = 0          -- seconds since the start
-- Inside a player's click or key press (Call): only then may an add-on write on a channel, as
-- Forever has it. Timers and events run outside one.
local HW = false
local BASE = 1793400000 -- server time at the start
local tasks = {}
local seq = 0
local function Schedule(delay, fn, client)
	seq = seq + 1
	tasks[#tasks + 1] = { at = NOW + math.max(0, delay or 0), fn = fn, seq = seq, client = client }
end
local current -- the client whose code is running

local function RunUntil(t)
	while true do
		local best, bi
		for i, task in ipairs(tasks) do
			if task.at <= t and (not best or task.at < best.at or (task.at == best.at and task.seq < best.seq)) then best, bi = task, i end
		end
		if not best then break end
		table.remove(tasks, bi)
		NOW = math.max(NOW, best.at)
		local prev, hw = current, HW
		current, HW = best.client, false
		local ok, err = pcall(best.fn)
		current, HW = prev, hw
		if not ok then print("TIMER ERROR", best.client and best.client.name, err) end
	end
	NOW = t
end
local function Advance(seconds) RunUntil(NOW + seconds) end

---------------------------------------------------------------------------
-- The world
---------------------------------------------------------------------------

local clients = {}      -- by name
local channels = {}     -- [name] = { [client] = true }
local locked = {}       -- [channel] = true: new joins refused
local sent = { total = 0, maxLen = 0, byDist = {} }
local badText = {}      -- chat text the game would refuse (too long, a bare "|")
local invites = {}

local function Fire(client, event, ...)
	local args = { ... }
	local prev, hw = current, HW
	current, HW = client, false
	for _, f in ipairs(client.frames) do
		if f._events[event] and f._scripts.OnEvent then
			local ok, err = pcall(f._scripts.OnEvent, f, event, unpack(args))
			if not ok then print("EVENT ERROR", client.name, event, err) end
		end
	end
	current, HW = prev, hw
end

-- Forever (2026-11-06): add-on messages on a custom channel are accepted and dropped.
local CHANNEL_ADDON_DROPPED = true

local function Deliver(from, prefix, msg, dist, target, logged)
	assert(type(prefix) == "string" and #prefix <= 16, "prefix too long")
	assert(type(msg) == "string", "message not a string")
	if #msg > 255 then error(("message of %d bytes from %s: %s"):format(#msg, from.name, msg:sub(1, 60))) end
	sent.total = sent.total + 1
	sent.byDist[dist] = (sent.byDist[dist] or 0) + 1
	sent.kinds = sent.kinds or {}
	local kind = msg:match("^(%u%d)~")
	if kind then sent.kinds[kind] = (sent.kinds[kind] or 0) + 1 end
	if #msg > sent.maxLen then sent.maxLen = #msg end
	local event = logged and "CHAT_MSG_ADDON_LOGGED" or "CHAT_MSG_ADDON"
	local sender = from.full
	local function To(c, localID, chName)
		if c == from or not c.online then return end
		Schedule(0.05, function() Fire(c, event, prefix, msg, dist, sender, c.full, 0, localID or 0, chName or "") end, c)
	end
	if dist == "CHANNEL" then
		local name
		for n, idx in pairs(from.chans) do if idx == target then name = n end end
		if not name then return false end
		if CHANNEL_ADDON_DROPPED then return 0 end
		for c in pairs(channels[name] or {}) do To(c, c.chans[name], name) end
	elseif dist == "WHISPER" then
		for _, c in pairs(clients) do
			if c.online and (c.full == target or (c.short == target and c.realm == from.realm)) then
				-- (Forever: a whisper reaches our realm only, the channel more.)
				if c.realm ~= from.realm then
					sent.lostWhispers = (sent.lostWhispers or 0) + 1
					Schedule(0.05, function() Fire(from, "CHAT_MSG_SYSTEM", ("No player named '%s' is currently playing."):format(target)) end, from)
				else
					To(c)
				end
			end
		end
	elseif dist == "GUILD" then
		for _, c in pairs(clients) do if c.guild and c.guild == from.guild then To(c) end end
	elseif dist == "SAY" or dist == "YELL" then
		return 1 -- (not allowed, as MoP and perhaps Forever answer)
	end
	return 0
end

---------------------------------------------------------------------------
-- Stub frames
---------------------------------------------------------------------------

local Frame = {}
local function NewFrame(client, kind, name)
	local f = { _events = {}, _scripts = {}, _shown = true, _text = "", _w = 100, _h = 20, _kind = kind, _client = client }
	setmetatable(f, Frame)
	if client then client.frames[#client.frames + 1] = f end
	if name and client then client.env[name] = f end
	return f
end
Frame.__index = function(f, k)
	local m = rawget(Frame, k)
	if m then return m end
	return function() return nil end
end
function Frame:RegisterEvent(e) self._events[e] = true end
function Frame:UnregisterEvent(e) self._events[e] = nil end
function Frame:RegisterAllEvents() end
function Frame:UnregisterAllEvents() self._events = {} end
function Frame:SetScript(what, fn) self._scripts[what] = fn end
function Frame:GetScript(what) return self._scripts[what] end
function Frame:HookScript(what, fn)
	local old = self._scripts[what]
	self._scripts[what] = old and function(...) old(...) fn(...) end or fn
end
function Frame:GetParent() return self._parent end
function Frame:Show() if not self._shown then self._shown = true if self._scripts.OnShow then self._scripts.OnShow(self) end end end
function Frame:Hide() if self._shown then self._shown = false if self._scripts.OnHide then self._scripts.OnHide(self) end end end
function Frame:IsShown() return self._shown end
function Frame:IsVisible() return self._shown end
function Frame:SetText(t) self._text = t or "" end
function Frame:GetText() return self._text end
function Frame:Insert(t) self._text = self._text .. t end
function Frame:HasFocus() return self._focus == true end
function Frame:SetFocus() self._focus = true end
function Frame:ClearFocus() self._focus = false end
function Frame:SetWidth(w) self._w = w end
function Frame:SetHeight(h) self._h = h end
function Frame:SetSize(w, h) self._w, self._h = w, h end
function Frame:GetWidth() return self._w end
function Frame:GetHeight() return self._h end
function Frame:GetStringWidth() return #tostring(self._text) * 5 end
function Frame:GetStringHeight() return 12 end
function Frame:GetVerticalScroll() return 0 end
function Frame:GetFrameLevel() return 1 end
function Frame:GetEffectiveScale() return 1 end
function Frame:GetCenter() return 0, 0 end
function Frame:IsMouseOver() return false end
function Frame:GetPoint() return "TOPRIGHT", nil, "TOPRIGHT", 0, 0 end
function Frame:CreateFontString() return NewFrame(nil, "FontString") end
function Frame:CreateTexture() return NewFrame(nil, "Texture") end
function Frame:GetNormalTexture() return NewFrame(nil, "Texture") end
function Frame:Click() if self._scripts.OnClick then self._scripts.OnClick(self, "LeftButton") end end
function Frame:SetEnabled(on) self._enabled = on end
function Frame:IsEnabled() return self._enabled ~= false end

---------------------------------------------------------------------------
-- A client
---------------------------------------------------------------------------

local function Stub(name)
	local t = {}
	return setmetatable(t, {
		__index = function(_, k) local s = Stub(name .. "." .. tostring(k)) rawset(t, k, s) return s end,
		__call = function() return nil end,
	})
end

local FILES = {}
for line in io.lines(ROOT .. "Pugger.toc") do
	line = line:gsub("\r", "")
	if line ~= "" and not line:find("^#") and not line:find("^libs") then FILES[#FILES + 1] = line end
end

-- Fake HereBeDragons: every map is a 1000 x 1000 yard square, side by side on one continent.
local function FakeHBD()
	local HBD = {}
	function HBD:GetWorldCoordinatesFromZone(x, y, map) return (map % 100) * 1000 + x * 1000, y * 1000, 0 end
	function HBD:GetWorldDistance(_, ax, ay, bx, by) return math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2) end
	return HBD
end

local function NewClient(o)
	local c = {
		name = o.name, short = o.name, realm = o.realm or "Forever", faction = o.faction or "Alliance",
		level = o.level or 30, class = o.class or "MAGE", guild = o.guild, frames = {}, chans = {}, online = false,
		map = o.map or 1436, x = o.x or 0.5, y = o.y or 0.5, target = nil, party = {},
	}
	c.full = c.name .. "-" .. c.realm
	local env = {}
	c.env = env
	for _, k in ipairs({ "pairs", "ipairs", "next", "type", "tostring", "tonumber", "select", "unpack", "pcall", "error",
		"assert", "setmetatable", "getmetatable", "rawget", "rawset", "math", "string", "table", "coroutine", "print" }) do
		env[k] = _G[k]
	end
	env._G = env
	env.bit = bitlib
	env.time = function() return BASE + math.floor(NOW) end
	env.GetServerTime = env.time
	env.date = os.date
	env.GetTime = function() return NOW end
	env.debugprofilestop = function() return os.clock() * 1000 end
	env.debugstack = function() return "" end
	env.geterrorhandler = function() return function(e) print("ERROR", c.name, e) end end
	env.seterrorhandler = function() end
	env.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
	env.strsplit = function() end
	env.Mixin = function(t, ...) for _, m in ipairs({ ... }) do for k, v in pairs(m) do t[k] = v end end return t end
	env.CreateFrame = function(kind, name, parent)
		local f = NewFrame(c, kind, name)
		f._parent = parent
		return f
	end
	env.CreateFont = function(name)
		local f = NewFrame(c, "Font", name)
		f.SetFont = function(self, path, size) self._font = { path, size } end
		f.GetFont = function(self) return self._font and self._font[1], self._font and self._font[2] end
		return f
	end
	env.C_Timer = {
		After = function(d, fn) Schedule(d, fn, c) end,
		NewTicker = function(d, fn, n)
			local t = { cancelled = false, left = n }
			local function Tick()
				if t.cancelled or not c.online then return end
				fn(t)
				if t.left then t.left = t.left - 1 if t.left <= 0 then return end end
				Schedule(d, Tick, c)
			end
			function t:Cancel() self.cancelled = true end
			Schedule(d, Tick, c)
			return t
		end,
	}
	env.C_ChatInfo = {
		RegisterAddonMessagePrefix = function() return true end,
		SendAddonMessage = function(p, m, d, t) return Deliver(c, p, m, d, t, false) end,
		SendAddonMessageLogged = function(p, m, d, t) return Deliver(c, p, m, d, t, true) end,
	}
	env.JoinChannelByName = function(name)
		if locked[name] and not (channels[name] and channels[name][c]) then
			Schedule(0.2, function() Fire(c, "CHAT_MSG_CHANNEL_NOTICE", "WRONG_PASSWORD", "", "", name, "", "", 0, 0, name) end, c)
			return
		end
		channels[name] = channels[name] or {}
		channels[name][c] = true
		local n = 0
		for _ in pairs(c.chans) do n = n + 1 end
		c.chans[name] = 3 + n
	end
	env.LeaveChannelByName = function(name)
		if channels[name] then channels[name][c] = nil end
		c.chans[name] = nil
	end
	env.GetChannelName = function(name) return c.chans[name] or 0 end
	env.UnitFullName = function(u) if u == "player" then return c.name, c.realm end end
	env.UnitName = function(u)
		if u == "player" then return c.name end
		if u == "target" and c.target then return c.target.name end
	end
	env.GetNormalizedRealmName = function() return c.realm end
	env.GetRealmName = function() return c.realm end
	env.UnitFactionGroup = function() return c.faction, c.faction end
	env.UnitLevel = function() return c.level end
	env.UnitClass = function() return c.class:lower(), c.class end
	env.UnitGUID = function(u)
		if u == "target" and c.target then return c.target.guid end
		return "Player-1-" .. c.name
	end
	env.UnitExists = function(u) return u == "target" and c.target ~= nil end
	env.UnitIsDead = function() return false end
	env.UnitCanAttack = function() return true end
	env.UnitClassification = function() return c.target and c.target.class end
	env.GetGuildInfo = function() return c.guild end
	env.IsInGroup = function() return #c.party > 0 end
	env.GetNumGroupMembers = function() return #c.party > 0 and #c.party + 1 or 0 end
	env.UnitInParty = function(n) for _, p in ipairs(c.party) do if p == n then return true end end return false end
	env.UnitInRaid = function() return nil end
	env.InCombatLockdown = function() return false end
	env.IsInInstance = function() return false end
	env.GetRealZoneText = function() return "Zone" .. c.map end
	env.C_Map = {
		GetBestMapForUnit = function() return c.map end,
		GetPlayerMapPosition = function() return { x = c.x, y = c.y } end,
		GetMapInfo = function(m) return { name = "Zone" .. m } end,
	}
	env.C_PartyInfo = { InviteUnit = function(n) invites[#invites + 1] = { from = c.name, to = n } end }
	env.LibStub = setmetatable({}, { __call = function(_, lib)
		if lib == "HereBeDragons-2.0" then return FakeHBD() end
		if lib == "HereBeDragons-Pins-2.0" then return Stub("Pins") end
	end })
	env.GameTooltip = Stub("GameTooltip")
	-- (As newer clients have it: SetText(text, r, g, b, alpha, wrap). An old-style wrap in the
	-- alpha's place is an error there.)
	env.GameTooltip.SetText = function(_, text, r, g, b, alpha)
		if alpha ~= nil and type(alpha) ~= "number" then error("bad argument #5 to 'SetText'", 2) end
	end
	env.UIParent = NewFrame(c, "Frame", "UIParent")
	env.Minimap = NewFrame(c, "Frame", "Minimap")
	env.MinimapCluster = NewFrame(c, "Frame", "MinimapCluster")
	env.WorldMapFrame = NewFrame(c, "Frame", "WorldMapFrame")
	env.SlashCmdList = {}
	env.UISpecialFrames = {}
	env.NUM_CHAT_WINDOWS = 0
	env.RAID_CLASS_COLORS = { MAGE = { colorStr = "ff3fc7eb" } }
	env.IsShiftKeyDown = function() return c.shift == true end
	-- The game's link functions as newer clients have them: the old name wraps the new one.
	env.hooksecurefunc = function(a, b, fn)
		local t, name = env, a
		if type(a) == "table" then t, name = a, b else fn = b end
		local old = t[name]
		t[name] = function(...) local r = { old(...) } fn(...) return unpack(r) end
	end
	env.ChatFrameUtil = { InsertLink = function() return false end }
	env.ChatEdit_InsertLink = function(link) return env.ChatFrameUtil.InsertLink(link) end
	-- (Item buttons call the new one directly, not the old name: a hook on the old name alone
	-- never hears a bag click, the MoP Classic bug of 2026-11-03.)
	env.HandleModifiedItemClick = function(link) return env.ChatFrameUtil.InsertLink(link) end
	env.IsMouseButtonDown = function() return false end
	-- Chat text: on a channel only inside a click (else blocked, as the game does), to every
	-- member, the sender too.
	env.SendChatMessage = function(text, chatType, _, target)
		if type(text) ~= "string" or #text > 255 or (text:find("|", 1, true) and not text:find("|H", 1, true)) then
			badText[#badText + 1] = tostring(text)
			return
		end
		if chatType ~= "CHANNEL" then return end
		local name
		for n, idx in pairs(c.chans) do if idx == target then name = n end end
		if not name then return end
		if not HW then
			c.blocked = (c.blocked or 0) + 1
			Schedule(0, function() Fire(c, "ADDON_ACTION_BLOCKED", "Pugger", "SendChatMessage()") end, c)
			return
		end
		sent.total = sent.total + 1
		sent.byDist.TEXT = (sent.byDist.TEXT or 0) + 1
		local kind = text:match("^(%u%d)~")
		if kind then sent.kinds = sent.kinds or {} sent.kinds[kind] = (sent.kinds[kind] or 0) + 1 end
		if #text > sent.maxLen then sent.maxLen = #text end
		for m in pairs(channels[name] or {}) do
			if m.online then
				Schedule(0.05, function()
					Fire(m, "CHAT_MSG_CHANNEL", text, c.full, "", m.chans[name] .. ". " .. name, c.full, "", 0, m.chans[name], name)
				end, m)
			end
		end
	end
	-- The Chat Channels window's lists: channels in number order, and each one's members.
	local function Displayed()
		local list = {}
		for n, idx in pairs(c.chans) do list[#list + 1] = { n, idx } end
		table.sort(list, function(a, b) return a[2] < b[2] end)
		return list
	end
	local function Members(name)
		local list = {}
		for m in pairs(channels[name] or {}) do if m.online then list[#list + 1] = m end end
		table.sort(list, function(a, b) return a.name < b.name end)
		return list
	end
	-- (As Forever: no member count until the list was asked for, by selecting the channel.)
	c.rosterLoaded = {}
	env.SetSelectedDisplayChannel = function(i)
		local e = Displayed()[i]
		if e then Schedule(c.rosterDelay or 1, function() c.rosterLoaded[e[1]] = true end, c) end
	end
	env.GetNumDisplayChannels = function() return #Displayed() end
	env.GetChannelDisplayInfo = function(i)
		local e = Displayed()[i]
		if e then return e[1], false, false, e[2], c.rosterLoaded[e[1]] and #Members(e[1]) or nil, true, "CHANNEL_CATEGORY_CUSTOM" end
	end
	env.C_ChatInfo.GetChannelRosterInfo = function(i, j)
		local e = Displayed()[i]
		if not (e and c.rosterLoaded[e[1]]) then return nil end
		local m = e and Members(e[1])[j]
		if m then return m.name, false, false, "Player-1-" .. m.name end
	end
	env.GetPlayerInfoByGUID = function(guid)
		for _, m in pairs(clients) do
			if "Player-1-" .. m.name == guid then
				return "", m.class, "", "", 2, m.name, m.realm == c.realm and "" or m.realm
			end
		end
	end
	env.PlaySound = function() end
	env.GetBuildInfo = function() return "1.16.1", "1", "", 16001 end
	env.GetLocale = function() return "enUS" end
	env.ERR_CHAT_PLAYER_NOT_FOUND_S = "No player named '%s' is currently playing."
	setmetatable(env, { __index = function(_, k)
		if type(k) == "string" and k:find("DB$") then return nil end
		return nil
	end })
	local ns = {}
	c.ns = ns
	for _, file in ipairs(FILES) do
		local chunk, err = loadfile(ROOT .. file:gsub("\\", "/"))
		if not chunk then error("PARSE " .. err) end
		setfenv(chunk, env)
		local prev = current
		current = c
		local ok, e = pcall(chunk, "Pugger", ns)
		current = prev
		if not ok then error("LOAD " .. file .. ": " .. tostring(e)) end
	end
	ns.TEST_COPY = o.testCopy
	if o.db then env.PuggerDB = o.db end
	clients[c.name] = c
	return c
end

local function Login(c)
	c.online = true
	Fire(c, "ADDON_LOADED", "Pugger")
	Fire(c, "PLAYER_LOGIN")
	Fire(c, "PLAYER_ENTERING_WORLD")
end

local function Logout(c)
	c.online = false
	for name in pairs(c.chans) do if channels[name] then channels[name][c] = nil end end
	c.chans = {}
end

local function Call(c, fn, ...)
	local prev, hw = current, HW
	current, HW = c, true -- (a player's click)
	local res = { pcall(fn, ...) }
	current, HW = prev, hw
	if not res[1] then error(c.name .. ": " .. tostring(res[2]), 2) end
	return unpack(res, 2)
end

---------------------------------------------------------------------------
-- Checks
---------------------------------------------------------------------------

local passed, failed = 0, 0
local function Check(cond, what)
	if cond then passed = passed + 1 print("  ok   " .. what)
	else failed = failed + 1 print("  FAIL " .. what) end
end
local function Errors(c)
	local db = c.env.PuggerDB
	return db and db.errors or {}
end
local function Kinds(k) return (sent.kinds or {})[k] or 0 end
local function PostBy(c, author, text)
	for _, p in pairs(c.ns.rdb.posts) do
		if p.a == author and (not text or p.x == text) then return p end
	end
end

---------------------------------------------------------------------------
-- The scenario
---------------------------------------------------------------------------

print("== login")
local A = NewClient({ name = "Aria", class = "MAGE", x = 0.50, y = 0.50 })
local B = NewClient({ name = "Bran", class = "WARRIOR", x = 0.55, y = 0.50 }) -- 50 yd from Aria
local Cc = NewClient({ name = "Cass", class = "PRIEST", x = 0.95, y = 0.50, level = 12 }) -- 450 yd away
local H = NewClient({ name = "Hork", faction = "Horde" })
for _, c in ipairs({ A, B, Cc, H }) do Login(c) end
Advance(90)
Check(A.chans["PuggerA1"] and B.chans["PuggerA1"] and Cc.chans["PuggerA1"], "Alliance clients joined PuggerA1")
Check(H.chans["PuggerH1"] and not H.chans["PuggerA1"], "Horde client joined PuggerH1 only")
Check(A.ns.Identity.Ready() and B.ns.Identity.Ready(), "signing keys made")
Check(A.ns.rdb.profiles[B.full] and A.ns.rdb.profiles[B.full].pk == B.ns.Identity.PublicKey(), "Aria pinned Bran's key from his profile")
Check(not H.ns.rdb.profiles[A.full], "Horde never hears Alliance profiles")

print("== posting")
local done
Call(A, A.ns.Feed.Post, "Hello realm #Onyxia @Bran", {}, function(ok, why) done = { ok, why } end)
Advance(1)
Check(done == nil, "first post waits for the privacy note")
Call(A, function() A.env.Pugger_Dialog.ok:Click() end)
Advance(10)
Check(done and done[1], "post sent after OK" .. (done and done[2] and (": " .. done[2]) or ""))
local pb = PostBy(B, A.full)
Check(pb and pb.v == "direct", "Bran has Aria's post, heard directly")
Check(PostBy(Cc, A.full) ~= nil, "Cass has it too")
Check(PostBy(H, A.full) == nil, "Horde doesn't")
Advance(5)
Check(pb and pb.sv == true, "Bran checked its signature (relayable)")
Check(B.ns.Feed.MentionsMe(pb), "Bran sees the mention")
Check((B.ns.rdb.unreadMentions or 0) == 1, "one unread mention for Bran")
Check(#B.ns.Feed.Timeline({ tag = "onyxia" }) == 1, "tag view finds #Onyxia")

local long = string.rep("a", 81)
local why = Call(A, A.ns.Feed.Check, long)
Check(why ~= nil, "81 characters refused")
Check(Call(A, A.ns.Feed.Check, string.rep("b", 80)) == nil, "80 characters allowed")
local lowWhy
Cc.level = 9
lowWhy = Call(Cc, Cc.ns.Feed.Check, "hi")
Cc.level = 12
Check(lowWhy ~= nil, "level 9 can't post")

-- An 80-character post with a pin: does it fit one message?
local before = Kinds("P1")
Call(B, function() B.env.PuggerDB.consented = 1 end)
Call(B, B.ns.Feed.Post, string.rep("x", 80), {}, function() end)
Advance(5)
Check(Kinds("P1") - before == 1, ("an 80-character post with a pin is one message (%d sent)"):format(Kinds("P1") - before))

-- Every post says where it was written: zone and coordinates; in a dungeon (no position) the zone.
local function Newest(c, author)
	local best
	for _, p in pairs(c.ns.rdb.posts) do if p.a == author and (not best or p.t > best.t) then best = p end end
	return best
end
local own = Newest(B, B.ns.me)
Check(own and own.pin and own.pin:find("^%d+:%d+:%d+$") ~= nil, "a post carries its author's zone and coordinates")
Check(Newest(A, B.ns.me) and Newest(A, B.ns.me).pin == own.pin, "readers get the place with the post")
local bx, by = B.x, B.y
B.x, B.y = nil, nil
Advance(30)
Call(B, B.ns.Feed.Post, "In a dungeon", {}, function() end)
Advance(5)
B.x, B.y = bx, by
local inside = Newest(A, B.ns.me)
Check(inside and inside.x == "In a dungeon" and inside.pin == tostring(B.map), "with no position, a post carries the zone alone")
Check(Call(A, A.ns.UI.PinText, inside.pin) ~= nil, "a zone without coordinates shows as a place")

print("== likes, replies, reposts")
Call(B, B.ns.Feed.Like, pb.id, true)
Advance(5)
local pa = A.ns.rdb.posts[pb.id]
Check(A.ns.Store.Likes(pa) == 1 and Cc.ns.Store.Likes(Cc.ns.rdb.posts[pb.id]) == 1, "the like reached Aria and Cass")
Call(B, B.ns.Feed.Post, "Hi back", { reply = pb.id }, function() end)
Advance(5)
Check(A.ns.Store.Replies(pa) == 1, "Aria sees one reply")
Call(Cc, function() Cc.env.PuggerDB.consented = 1 end)
Call(Cc, Cc.ns.Feed.Repost, pb.id)
Advance(5)
Check(A.ns.Store.Reposts(pa) == 1, "Aria sees one repost")
Check(#A.ns.Feed.Timeline({ thread = pb.id }) == 2, "the thread reads post then reply")

print("== catch-up sync")
local D = NewClient({ name = "Dara" })
Login(D)
Advance(200)
-- Until Aria is heard, her relayed posts wait greyed; once she says anything, Dara asks her
-- for her profile (R0) and checks them.
Call(A, A.ns.Feed.Like, pb.id, true)
Advance(30)
local pd = D.ns.rdb.posts[pb.id]
Check(pd ~= nil, "Dara, logged in later, got Aria's post from someone")
Check(pd and pd.v == "ok", "...and verified it (" .. tostring(pd and pd.v) .. ")")
Check(D.ns.Store.Total() >= 4, ("Dara holds %d posts"):format(D.ns.Store.Total()))
Check(pd and D.ns.Store.Likes(pd) >= 1, "Dara has the like count")

print("== forged relays")
local forged = { id = A.ns.Codec.PostId(A.full, BASE + math.floor(NOW), 99), a = A.full, t = BASE + math.floor(NOW),
	x = "I am not Aria", s = string.rep("A", 86) }
Call(B, function() B.ns.Comm.Send(B.ns.Codec.EncodePost(forged), { to = "Dara" }) end)
Advance(10)
Check(D.ns.rdb.posts[forged.id] == nil, "a forged post relayed by Bran was refused")
-- A forged post from an author Dara has never heard: kept greyed, dropped when the key comes.
local E = NewClient({ name = "Emry" })
local forgedE = { id = A.ns.Codec.PostId(E.full, BASE + math.floor(NOW), 1), a = E.full, t = BASE + math.floor(NOW),
	x = "not really Emry", s = string.rep("B", 86) }
Call(B, function() B.ns.Comm.Send(B.ns.Codec.EncodePost(forgedE), { to = "Dara" }) end)
Advance(5)
local fe = D.ns.rdb.posts[forgedE.id]
Check(fe ~= nil and fe.v == nil, "unknown author: kept as unverified")
Login(E)
Advance(60)
Check(D.ns.rdb.posts[forgedE.id] == nil, "dropped once Emry's real key arrived")

print("== deletes")
local snapshot = {}
for k, v in pairs(A.ns.rdb.posts[pb.id]) do snapshot[k] = v end
Call(A, A.ns.Feed.Delete, pb.id)
Advance(10)
Check(B.ns.rdb.posts[pb.id] == nil and B.ns.rdb.tombs[pb.id], "Bran dropped the deleted post")
Check(D.ns.rdb.posts[pb.id] == nil, "Dara too")
-- Fynn was offline with the post saved: logging in, the post must not come back to anyone.
local F = NewClient({ name = "Fynn" })
Login(F)
Call(F, function()
	local p = {}
	for k, v in pairs(snapshot) do p[k] = v end
	p.lk = {}
	F.ns.rdb.posts[p.id] = p
	F.ns.Store.Rebuild()
end)
Advance(30)
Call(B, B.ns.Sync.SendDigest, true)
Advance(60)
Call(A, A.ns.Sync.SendDigest, true) -- (Aria says something: Fynn can ask for her profile)
Advance(60)
Check(F.ns.rdb.posts[pb.id] == nil and F.ns.rdb.tombs[pb.id] ~= nil, "Fynn got the delete through sync")
Check(B.ns.rdb.posts[pb.id] == nil, "the deleted post never came back to Bran")

print("== flood")
Call(Cc, function()
	for i = 1, 40 do Cc.env.SendChatMessage("L1~x:1:1~1", "CHANNEL", nil, Cc.chans.PuggerA1) end
end)
Advance(2)
Check(A.ns.Comm.stats.flood >= 1, "a burst of 40 messages is cut off")

print("== garbage")
math.randomseed(7)
local junkErrors = #Errors(A)
for i = 1, 3000 do
	local len = math.random(0, 255)
	local t = {}
	for j = 1, len do t[j] = string.char(math.random(0, 255)) end
	local s = table.concat(t)
	local kinds = { "P1~", "D1~", "L1~", "R1~", "H2~", "I2~", "Q1~", "C1~", "M1~", "M2~", "J1~", "J2~", "B1~", "O2~", "C1:1:2:" }
	if i % 2 == 0 then s = kinds[math.random(#kinds)] .. s:gsub("~", "") .. "~" .. s end
	local dist = i % 3 == 0 and "WHISPER" or "CHANNEL"
	Call(A, A.ns.Comm.OnAddonMessage, "PUGGER", s:sub(1, 255), dist, "Junk" .. (i % 5) .. "-Forever", "", 0, A.chans.PuggerA1)
end
Advance(5)
Check(#Errors(A) == junkErrors, "3000 garbage messages: no error (" .. (#Errors(A) - junkErrors) .. ")")

Advance(65) -- (Cass's flood ban runs out)
print("== the feed's size")
-- Everyone sends a profile at login: each Alliance client counts the others it heard, and
-- itself; the Horde client, on its own channel, is never counted.
local onA = Call(A, A.ns.Comm.Online)
local alliance = 0
for _, c in pairs(clients) do if c.faction ~= "Horde" and c.ns and c.ns.rdb then alliance = alliance + 1 end end
Check(onA >= 3 and onA <= alliance, ("Aria counts the Alliance players online (%d of %d clients)"):format(onA, alliance))
Check(Call(A, function() local n = 1 for k in pairs(A.ns.rdb.profiles) do if k:find("^Junk") then n = n + 1 end end return n end) == 1,
	"garbage senders make no profile, so they are never counted")
local horde = false
Call(A, function() if A.ns.Comm.HeardWithin(H.ns.me, 3600) then horde = true end end)
Check(not horde, "...and never the Horde player")

print("== hours kept, and a busy feed")
-- Six hours of posts (two on a busy feed); mentions of the player a day, their own a week. Past
-- BUSY_PER_HOUR posts an hour the faction's tab shows who the player follows, then posts near
-- them, and says how many it left out.
local function Fake(c, author, ago, map, text)
	local t = c.ns.Now() - ago
	local p = { id = c.ns.Codec.PostId(author, t, math.random(1, 1e6)), a = author, t = t, x = text,
		pin = c.ns.Codec.EncodePin(map, 0.5, 0.5), v = "direct", lk = {} }
	c.ns.Store.Add(p)
	return p
end
local old = Call(Cc, Fake, Cc, "Oldtimer-Forever", 60, Cc.map, "from this morning")
local four = Call(Cc, Fake, Cc, "Fourhours-Forever", 60, Cc.map, "four hours ago")
local mineOld = Call(Cc, Fake, Cc, Cc.ns.me, 60, Cc.map, "my own, this morning")
local mention = Call(Cc, Fake, Cc, "Pal-Forever", 60, Cc.map, "thanks @" .. Cc.ns.me)
local oldMention = Call(Cc, Fake, Cc, "Pal-Forever", 60, Cc.map, "yesterday, @" .. Cc.ns.me)
old.t, mineOld.t, four.t = old.t - 7 * 3600, mineOld.t - 7 * 3600, four.t - 4 * 3600
mention.t, oldMention.t = mention.t - 10 * 3600, oldMention.t - 25 * 3600
Call(Cc, Cc.ns.Store.Prune)
Check(Cc.ns.Store.Get(old.id) == nil and Cc.ns.Store.Get(four.id) ~= nil, "a quiet feed: four hours kept, seven gone")
Check(Cc.ns.Store.Get(mineOld.id) ~= nil, "...the player's own post stays")
Check(Cc.ns.Store.Get(mention.id) ~= nil and Cc.ns.Store.Get(oldMention.id) == nil, "...a mention of them a day: ten hours kept, twenty-five gone")
Check(not Call(Cc, Cc.ns.Feed.Busy), "a quiet feed is not busy")
Call(Cc, function()
	Cc.ns.Feed.Follow("Friend-Forever", true)
	for i = 1, 70 do Fake(Cc, "Far" .. i .. "-Forever", i * 30, 9999, "far away " .. i) end
	for i = 1, 60 do Fake(Cc, "Near" .. i .. "-Forever", i * 30 + 7, Cc.map, "close by " .. i) end
	Fake(Cc, "Friend-Forever", 3000, 9999, "a friend, far away")
end)
Check(Call(Cc, Cc.ns.Feed.Busy), "130 posts in an hour: a busy feed")
Call(Cc, Cc.ns.Store.Prune)
Check(Cc.ns.Store.Get(four.id) == nil and Cc.ns.Store.Get(mention.id) ~= nil, "a busy feed keeps two hours (the four-hour post goes; the mention stays)")
local tl = Call(Cc, Cc.ns.Feed.Timeline, "realm", 40)
local friend, far, near = false, 0, 0
for _, p in ipairs(tl) do
	if p.a == "Friend-Forever" then friend = true
	elseif p.a:find("^Far") then far = far + 1
	elseif p.a:find("^Near") then near = near + 1 end
end
Check(friend and far == 0 and near > 0, ("busy: the friend's post (far away) and posts nearby, none from far (%d near)"):format(near))
Check(Cc.ns.Feed.leftOut >= 70, ("...and it says how many it left out (%d)"):format(Cc.ns.Feed.leftOut))
Cc.ns.Feed.showAll = true
far = 0
for _, p in ipairs(Call(Cc, Cc.ns.Feed.Timeline, "realm", 200)) do if p.a:find("^Far") then far = far + 1 end end
Check(far == 70, "\"show all\": everything again")
Cc.ns.Feed.showAll = false
Call(Cc, function() for id, p in pairs(Cc.ns.rdb.posts) do if p.a:find("^Far") or p.a:find("^Near") or p.a == "Friend-Forever" then Cc.ns.Store.Remove(id) end end end)

print("== quiet in group instances")
-- Bran goes into a dungeon with a group: the window steps aside and no card shows; a rare
-- called meanwhile catches up as a card on the way out, while it is still up.
local bFeed = B.env.Pugger_FeedBasic or B.env.Pugger_Feed
Call(B, function() bFeed:Show() end)
local inInstance = B.env.IsInInstance
B.env.IsInInstance = function() return true, "party" end
B.party = { "Dungeonmate" }
Fire(B, "PLAYER_ENTERING_WORLD")
Check(not bFeed:IsShown() and Call(B, B.ns.Popups.Count) == 0, "in a group instance: the window steps aside, no cards")
A.target = { name = "Quiet Rare", class = "rare", guid = "Creature-0-1-2-3-999-0000" }
Call(A, A.ns.Calls.Rare)
A.target = nil
Advance(5)
Check(Call(B, B.ns.Popups.Count) == 0, "a rare called meanwhile makes no card inside")
Call(B, B.ns.Feed.Post, "Hey @" .. B.ns.me .. "!", {}, function() end)
B.env.IsInInstance = inInstance
B.party = {}
Fire(B, "PLAYER_ENTERING_WORLD")
Check(bFeed:IsShown(), "out again: the window is back")
Check(Call(B, B.ns.Popups.Count) == 1, "out again: the rare still up catches up as one card")
Call(B, B.ns.Popups.CloseAll)

print("== notifications: off, paused, only some")
-- Bran turns cards off: a rare makes none, the chat button greys; an ask on his own call still
-- shows. Paused for an hour: none until then. Dungeon groups only for the dungeons he picked.
local bs = B.ns.db.settings
bs.cardsOff = true
A.target = { name = "Muted Rare", class = "rare", guid = "Creature-0-1-2-3-998-0000" }
Call(A, A.ns.Calls.Rare)
A.target = nil
Advance(5)
Check(Call(B, B.ns.Popups.Count) == 0 and Call(B, B.ns.Popups.Paused), "cards off: a rare makes no card")
Call(B, B.ns.Popups.Card, { key = "x", title = "ask", body = "", always = true })
Check(Call(B, B.ns.Popups.Count) == 1, "...but an ask on his own call still shows")
Call(B, B.ns.Popups.CloseAll)
bs.cardsOff = false
bs.pauseUntil = B.ns.Now() + 3600
Call(B, B.ns.Popups.Card, { key = "y", title = "t", body = "" })
Check(Call(B, B.ns.Popups.Count) == 0, "paused for an hour: no cards")
bs.pauseUntil = B.ns.Now() - 1
Call(B, B.ns.Popups.Card, { key = "y", title = "t", body = "" })
Check(Call(B, B.ns.Popups.Count) == 1, "the hour over: cards again")
Call(B, B.ns.Popups.CloseAll)
Check(pcall(B.ns.UI.NotifyMenu, B.env.UIParent) and pcall(B.ns.UI.DungeonMenu, B.env.UIParent), "the Notifications and dungeon menus open")
Check(Call(B, B.ns.UI.NotifyState) == "on", "...and say notifications are on")

print("== the compose box keeps the cursor")
-- A redraw (a new post, the 30-second tick, the box growing as it gets the cursor) never hides
-- the compose box: hiding it would take the cursor out.
local box = A.env.Pugger_ComposeBox
local hidden = 0
local parent = box:GetParent()
Check(type(parent) == "table" and parent.SetScript ~= nil, "the compose box has its frame")
Call(A, function()
	parent:SetScript("OnHide", function() hidden = hidden + 1 end)
	A.ns.UI.Open(nil)
	box:SetFocus()
	box._scripts.OnEditFocusGained(box) -- (the box grows)
	A.ns.UI.Render()
	A.ns.UI.Render() -- (as a new post would; the bench runs no OnUpdate, so drawn by hand)
end)
Check(hidden == 0, ("redraws never hide the compose box (%d hides)"):format(hidden))

print("== the button by the chat, and the setup")
-- Closed, the window leaves a button by the chat (the logo in a rounded square); open, it goes.
local feedA = A.env.Pugger_FeedBasic or A.env.Pugger_Feed
Call(A, function() A.ns.UI.Toggle(false) end)
local chatB = A.env.Pugger_ChatButton
Check(chatB ~= nil and chatB:IsShown(), "the window closed: the button by the chat shows")
Call(A, function() A.ns.UI.Toggle(true) end)
Check(feedA:IsShown() and not chatB:IsShown(), "the window open: the button goes")

-- The first launch asked where things go; by default no minimap button. Picking "On the
-- minimap" in the setup moves the button there (the window closed: nothing by the chat).
local setupA = A.env.Pugger_Setup
Check(setupA ~= nil and A.ns.db.settings.setupDone == false, "the first launch shows the setup")
Check(A.env.Pugger_MinimapButton == nil, "by default, no minimap button")
Call(A, function()
	local rows = setupA.rows
	rows[1].buttons[2]:GetScript("OnClick")(rows[1].buttons[2])
	A.ns.UI.Toggle(false)
end)
Check(A.env.Pugger_MinimapButton and A.env.Pugger_MinimapButton:IsShown() and not chatB:IsShown(),
	"setup, \"On the minimap\": the minimap button, none by the chat")
Call(A, function()
	setupA.rows[1].buttons[1]:GetScript("OnClick")(setupA.rows[1].buttons[1])
	setupA.done:GetScript("OnClick")(setupA.done)
	A.ns.UI.Toggle(true)
end)
Check(A.ns.db.settings.launcher == "chat" and A.ns.db.settings.setupDone == true and not A.env.Pugger_MinimapButton:IsShown(),
	"back to \"By the chat\", and Done: the setup won't show again")

-- The title bar's "i": the limits, on hover.
Check(A.env.Pugger_LimitsButton ~= nil and pcall(A.ns.UI.LimitsTip, A.env.Pugger_LimitsButton), "the title bar's \"i\" shows the limits")
do
	local tip = feedA.titleTip
	tip.hint, tip.online = "The realm's feed", true
	Check(tip:GetScript("OnEnter") and pcall(tip:GetScript("OnEnter"), tip), "the title's tooltip (the feed, its users) shows")
end

print("== links into the compose box")
-- A shift-clicked item reaches the box (bag click -> HandleModifiedItemClick ->
-- ChatFrameUtil.InsertLink: two hooks fire), once, and only while the box has the cursor.
local cbox = A.env.Pugger_ComposeBox
local item = "|cff1eff00|Hitem:2105::::::::14:::::::|h[Grizzly Pants of Power]|h|r"
A.shift = true
Call(A, function() cbox:SetText("Who needs these ") cbox:SetFocus() A.env.HandleModifiedItemClick(item) end)
Check(cbox:GetText() == "Who needs these " .. item, "a shift-clicked item goes into the box, once")
Advance(1)
Call(A, function() cbox:SetText("") cbox:ClearFocus() A.env.HandleModifiedItemClick(item) end)
Check(cbox:GetText() == "", "...and never while the box doesn't have the cursor")
A.shift = false
Call(A, function() cbox:SetText("") cbox:ClearFocus() end)

print("== map calls")
A.target = { name = "Foe Reaper 4000", class = "rareelite", guid = "Creature-0-1-2-3-573-0000" }
Call(A, A.ns.Calls.Rare)
Advance(5)
local rareB
for _, c in ipairs(Call(B, B.ns.Calls.List, "all")) do if c.kind == "R" then rareB = c end end
Check(rareB ~= nil, "Bran sees the rare call")
A.target = nil
local noTarget = #Call(Cc, Cc.ns.Calls.List, "all")
Call(Cc, Cc.ns.Calls.Rare)
Advance(3)
Check(#Call(A, A.ns.Calls.List, "all") == noTarget, "a rare call without a rare target is refused")
Call(B, B.ns.Calls.Vote, rareB.id, "d")
Call(Cc, function()
	for _, c in ipairs(Cc.ns.Calls.List("all")) do if c.kind == "R" then Cc.ns.Calls.Vote(c.id, "d") end end
end)
Advance(5)
local rareA = A.ns.Calls.Get(rareB.id)
Check(rareA and rareA.ended == "d", "the rare call closed on two \"Dead\"")
-- Called dead: the same rare can't be called again in that zone for a while.
A.target = { name = "Foe Reaper 4000", class = "rareelite", guid = "Creature-0-1-2-3-573-0000" }
Call(A, A.ns.Calls.Rare)
A.target = nil
local again = 0
for _, c in ipairs(Call(A, A.ns.Calls.List, "all")) do if c.kind == "R" and c.c == "573" and not c.ended then again = again + 1 end end
Check(again == 0, "a rare just called dead can't be called again yet")

-- One rare, five calls an hour at most (whoever calls it); another rare is its own count.
local function CallRare(npc, name)
	A.target = { name = name, class = "rare", guid = "Creature-0-1-2-3-" .. npc .. "-0000" }
	Call(A, A.ns.Calls.Rare)
	A.target = nil
	Advance(2)
	local made
	for _, c in ipairs(Call(A, A.ns.Calls.List, "all")) do if c.kind == "R" and c.c == npc and c.mine and not c.ended then made = c end end
	if made then Call(A, A.ns.Calls.End, made.id, "x") end
	return made ~= nil
end
local five = 0
for _ = 1, 5 do if CallRare("777", "Fivefold") then five = five + 1 end end
Check(five == 5 and not CallRare("777", "Fivefold"), "one rare: five calls an hour, the sixth refused")
Check(CallRare("778", "Another Rare"), "...while a different rare can still be called")

Call(A, A.ns.Calls.Group, "The Defias Brotherhood", 2)
Advance(5)
local gB, gC
for _, c in ipairs(Call(B, B.ns.Calls.List, "nearby")) do if c.kind == "G" then gB = c end end
for _, c in ipairs(Call(Cc, Cc.ns.Calls.List, "all")) do if c.kind == "G" then gC = c end end
Check(gB ~= nil, "Bran (50 yd) sees the quest group")
Check(gC == nil, "Cass (450 yd) never does")
Call(B, B.ns.Calls.Ask, gB.id)
Advance(5)
local gA = A.ns.Calls.Get(gB.id)
local askB = gA and gA.asks[B.full]
Check(askB and askB.yards == 50, "Aria got Bran's ask, 50 yd away")
Call(A, A.ns.Calls.Decide, gA.id, B.full, true)
Check(invites[#invites] and invites[#invites].to == "Bran", "Invite sent the game's invite to Bran")

-- Roles: a quest group needing a tank and two damage. Bran asks as damage; once invited, the
-- call needs a tank and one damage, on every client.
Call(A, A.ns.Calls.Group, "Hogger", "DTD")
Advance(5)
local rB
for _, c in ipairs(Call(B, B.ns.Calls.List, "nearby")) do if c.kind == "G" and c.a == "Hogger" then rB = c end end
Check(rB and rB.roles == "TDD" and rB.need == 3, "the roles reach Bran, in order: tank, damage, damage")
Check(rB and Call(B, A.ns.UI.CallTitle, rB):find("UI%-LFG%-ICON%-ROLES") ~= nil, "the card shows the role icons")
local bRoles = Call(B, B.ns.Calls.MyRoles, rB)
Check(#bRoles >= 1 and bRoles[#bRoles] == "D", "Bran may join as damage")
Call(B, B.ns.Calls.Ask, rB.id, "H")
Check(not rB.asked, "nobody asks as a role the group doesn't need")
Call(B, B.ns.Calls.Ask, rB.id, "D")
Advance(5)
local rA = A.ns.Calls.Get(rB.id)
Check(rA and rA.asks[B.full] and rA.asks[B.full].role == "D", "Aria's card: Bran asks to join as damage")
Call(A, A.ns.Calls.Decide, rB.id, B.full, true)
Advance(5)
Check(rA.roles == "TD" and rB.roles == "TD" and not rA.ended, "invited: the call needs a tank and one damage, for Bran too")

-- A dungeon group at the Deadmines stone (its spot recorded first).
Call(A, A.ns.Stones.Record, "dm")
Call(B, function() B.env.PuggerDB.stones.dm = { map = 1436, x = 0.5, y = 0.5 } end)
Call(Cc, function() Cc.env.PuggerDB.stones.dm = { map = 1436, x = 0.5, y = 0.5 } end)
Call(A, A.ns.Calls.Dungeon, "dm", 2)
Advance(5)
local dC
for _, c in ipairs(Call(Cc, Cc.ns.Calls.List, "groups")) do if c.kind == "D" then dC = c end end
Check(dC ~= nil, "Cass, far away, sees the Deadmines group in Groups")
Check(dC and Call(Cc, Cc.ns.Calls.CantAsk, dC) ~= nil, "...but level 12 can't ask (levels 17-26)")
-- Dungeon group cards only for the dungeons picked (as if Cass were near, at the level).
do
	local cs, near = Cc.ns.db.settings, Cc.ns.Calls.Near
	Cc.ns.Calls.Near = function() return true end
	cs.groupLevelOnly = false
	Call(Cc, Cc.ns.Popups.CloseAll)
	cs.dungeons = { wc = true }
	Call(Cc, Cc.ns.Popups.Call, dC)
	local none = Call(Cc, Cc.ns.Popups.Count)
	cs.dungeons = { dm = true }
	Call(Cc, Cc.ns.Popups.Call, dC)
	Check(dC and none == 0 and Call(Cc, Cc.ns.Popups.Count) == 1, "dungeon group cards only for the dungeons picked")
	Call(Cc, Cc.ns.Popups.CloseAll)
	cs.dungeons, cs.groupLevelOnly, Cc.ns.Calls.Near = {}, true, near
end
A.x = 0.9
Call(A, A.ns.Calls.Dungeon, "ubrs", 2)
Advance(3)
A.x = 0.5
-- A dungeon call ends once its caller is 200 yards from where they made it (at the stone).
Call(A, A.ns.Calls.Dungeon, "dm", 2)
Advance(6)
local dmA
for _, c in pairs(Call(A, A.ns.Calls.List, "groups")) do if c.mine and c.a == "dm" then dmA = c end end
A.x = 0.65
Advance(6)
Check(dmA and not dmA.ended, "150 yards from the stone: the dungeon call stays")
A.x = 0.75
Advance(6)
Check(dmA and dmA.ended == "x", "250 yards from the stone: the dungeon call ends")
A.x = 0.5

print("== a meeting stone on a client with other zone numbers (MoP)")
local P = NewClient({ name = "Pell", map = 85, x = 0.40, y = 0.60, level = 20 })
local Q = NewClient({ name = "Quin", map = 85, x = 0.90, y = 0.90, level = 20 })
Login(P) Login(Q)
Advance(60)
Call(P, function() P.env.PuggerDB.consented = 1 end)
Call(P, P.ns.Calls.StartAtStone)
Check(not Call(P, P.ns.Calls.NearSeenStone), "no stone hovered yet: Look for group says how")
local tip = { GetUnit = function() return nil end, GetName = function() return "GameTooltip" end }
P.env.GameTooltipTextLeft1 = { GetText = function() return "Meeting Stone" end }
Call(P, P.ns.Calls.OnTooltip, tip)
Check(Call(P, P.ns.Calls.NearSeenStone), "hovering a meeting stone counts as at a stone")
local list = Call(P, P.ns.Stones.OfZone, 85)
Check(#list > 5 and list[1].lo <= 20 and list[1].hi >= 20, "every dungeon offered, one that fits level 20 first (" .. list[1].name .. ")")
Call(P, P.ns.Calls.Dungeon, "wc", 2)
Advance(5)
local seenQ
for _, c in ipairs(Call(Q, Q.ns.Calls.List, "groups")) do if c.kind == "D" then seenQ = c end end
Check(seenQ ~= nil, "Quin, on the same zone numbers, sees the Wailing Caverns group")
Check(P.env.PuggerDB.stones.wc and P.env.PuggerDB.stones.wc.learned, "Pell's client learned the stone's spot")
P.x = 0.9
Advance(130)
Check(not Call(P, P.ns.Calls.NearSeenStone), "walked away and time passed: no longer at the stone")
P.x = 0.4
Check(Call(P, P.ns.Calls.AtStone, P.ns.Stones.Get("wc")), "back at the learned spot: at the stone without hovering")
Logout(P) Logout(Q)

print("== stones learned from other players (the gossip)")
local function Hover(c)
	c.env.GameTooltipTextLeft1 = { GetText = function() return "Meeting Stone" end }
	Call(c, c.ns.Calls.OnTooltip, { GetUnit = function() return nil end, GetName = function() return "GameTooltip" end })
end
local W = {}
for i = 1, 6 do W[i] = NewClient({ name = "Walker" .. i, map = 1436, x = 0.30 + i * 0.001, y = 0.30 }) Login(W[i]) end
local O = NewClient({ name = "Obel", map = 1436, x = 0.9, y = 0.9 })
local Lia = NewClient({ name = "Liar", map = 1436, x = 0.8, y = 0.8 })
Login(O) Login(Lia)
Advance(60)
local s1 = Kinds("S1")
-- On Forever the tooltip's text can be a secret value: it is left alone (no report, no error).
W[1].env.issecretvalue = function(v) return v == "Meeting Stone" end
Hover(W[1])
Advance(15)
W[1].env.issecretvalue = nil
Check(Kinds("S1") == s1, "a secret tooltip text: left alone, no report")
Hover(W[1])
Advance(15)
Check(Kinds("S1") - s1 >= 1 and Kinds("S1") - s1 <= W[1].ns.Comm.REACH,
	("hovering a stone sends one report (whispered to %d players)"):format(Kinds("S1") - s1))
Check(Call(O, O.ns.Stones.Agreed, "dm") == nil, "one report: not agreed")
Hover(W[2])
Advance(15)
Check(Call(O, O.ns.Stones.Agreed, "dm") == nil, "two players: not agreed yet")
Hover(W[3])
Advance(15)
local m, ax, ay, votes = Call(O, O.ns.Stones.Agreed, "dm")
Check(m == 1436 and votes >= 3, ("three players agree: Obel, never there, knows the Deadmines stone (%s votes)"):format(tostring(votes)))
Check(Call(W[3], W[3].ns.Stones.Agreed, "dm") ~= nil, "...and so does the third walker (own sighting + two answers)")
Hover(W[4])
Advance(15)
local before = Kinds("S1")
Hover(W[5])
Advance(15)
Check(Kinds("S1") == before, "a stone already agreed is not reported again")
-- At most two answers to one report, however many saw the stone.
W[6].x = 0.30
local sc = Call(W[6], function() return W[6].env.PuggerDB.stoneReported end)
for k in pairs(sc) do sc[k] = nil end
local s2 = Kinds("S2")
Call(W[6], W[6].ns.Stones.Sighted, 1436, 0.30, 0.30, nil, true)
Advance(15)
-- (Answers go to the reporter alone, a whisper each: the others don't hear them to stay quiet.)
Check(Kinds("S2") - s2 <= 5, ("one report, %d answers, one from each walker who saw it"):format(Kinds("S2") - s2))
s2 = Kinds("S2")
-- A liar alone: never agreed, however often.
for i = 1, 5 do
	Call(Lia, function() Lia.ns.Comm.Send("S1~1436~8000~8000~dm") end)
	Advance(3)
end
Advance(15)
local lm, lx = Call(O, O.ns.Stones.Agreed, "dm")
Check(lm == 1436 and lx < 0.5, "a liar's spot, sent five times, changes nothing")
Check(Kinds("S2") == s2, "nobody vouches for the liar's spot (nobody saw a stone there)")
-- Learned spots help, never block: a call far from the agreed spot still reaches everyone.
Call(Lia, function()
	Lia.ns.Comm.Send(("M1~D~1~1436~9000~9000~%s~dm~2~17-26~WARRIOR~"):format(Lia.ns.Codec.Base36(BASE + math.floor(NOW) + 600)), { logged = true, now = true })
end)
Advance(5)
local farCall
for _, c in ipairs(Call(O, O.ns.Calls.List, "groups")) do if c.caller == Lia.full then farCall = c end end
Check(farCall ~= nil, "a call far from an agreed spot is not dropped (only the shipped table can do that)")
Check(select(3, Call(O, O.ns.Stones.Counts)) >= 1, "/pug status counts the agreed stone")
-- The Barrens: three stones in one zone; hovering can't say which, a call names it.
local Bn = {}
for i = 1, 3 do Bn[i] = NewClient({ name = "Barren" .. i, map = 1413, x = 0.50 + i * 0.001, y = 0.40, level = 20 }) Login(Bn[i]) end
Advance(60)
for i = 1, 3 do Hover(Bn[i]) Advance(15) end
Check(Call(O, O.ns.Stones.Agreed, "wc") == nil, "the Barrens: three agree there's a stone, but not which dungeon")
Call(Bn[1], function() Bn[1].env.PuggerDB.consented = 1 end)
Call(Bn[1], Bn[1].ns.Calls.Dungeon, "wc", 2)
Advance(10)
Check(Call(O, O.ns.Stones.Agreed, "wc") ~= nil, "...until a Wailing Caverns call there names it")
Check(Call(O, O.ns.Stones.Agreed, "rfk") == nil, "...and Razorfen Kraul stays unknown")
for _, c in ipairs(W) do Logout(c) end
for _, c in ipairs(Bn) do Logout(c) end
Logout(O) Logout(Lia)

print("== a locked channel")
-- One player alone saying "moved" moves nobody.
for i = 1, 5 do Call(E, function() E.env.SendChatMessage("B1~2", "CHANNEL", nil, E.chans.PuggerA1) end) Advance(2) end
Check(A.ns.rdb.channel == 1, "one player's fake \"moved\" moves nobody")
Call(A, A.ns.Comm.OnChannelNotice, "PASSWORD_CHANGED", "Griefer-Forever", "", "3. PuggerA1", "", "", 0, 0, "PuggerA1")
Call(B, B.ns.Comm.OnChannelNotice, "PASSWORD_CHANGED", "Griefer-Forever", "", "3. PuggerA1", "", "", 0, 0, "PuggerA1")
Call(F, F.ns.Comm.OnChannelNotice, "PASSWORD_CHANGED", "Griefer-Forever", "", "3. PuggerA1", "", "", 0, 0, "PuggerA1")
Call(D, D.ns.Comm.OnChannelNotice, "PASSWORD_CHANGED", "Griefer-Forever", "", "3. PuggerA1", "", "", 0, 0, "PuggerA1")
-- (Cass missed the notice: the word of three others on the old channel moves her.)
locked.PuggerA1 = true
local G2 = NewClient({ name = "Gale" })
Login(G2)
Advance(30)
Check(A.chans.PuggerA2 and B.chans.PuggerA2, "Aria and Bran moved to PuggerA2")
Check(G2.chans.PuggerA2 ~= nil, "Gale, locked out of PuggerA1, ended up on PuggerA2")
Check(Cc.chans.PuggerA2 ~= nil, "Cass, who missed the notice, followed when told on the old channel")

print("== the window")
for _, c in ipairs({ A, B }) do
	Call(c, function()
		for _, tab in ipairs({ "realm", "following", "mentions", "groups", "nearby", "me" }) do
			c.ns.UI.SetTab(tab)
			c.ns.UI.Render()
		end
		c.ns.UI.Open({ tag = "onyxia" }) c.ns.UI.Render()
		c.ns.UI.Open({ author = A.full }) c.ns.UI.Render()
		c.ns.UI.Open(nil) c.ns.UI.Render()
		c.ns.Demo.On()
		for _, tab in ipairs({ "realm", "mentions", "groups", "nearby", "me" }) do
			c.ns.UI.SetTab(tab)
			c.ns.UI.Render()
		end
		c.ns.Demo.Off()
		c.ns.UI.WindowMenu(c.env.UIParent)
		c.ns.MapPins.Refresh()
		c.ns.Diagnostics.Bug()
		c.ns.Measure.Report()
		c.env.SlashCmdList.PUGGER("help")
		c.env.SlashCmdList.PUGGER("status")
		c.env.SlashCmdList.PUGGER("measure echo")
	end)
end
Advance(6)
Check(#Errors(A) == 0 and #Errors(B) == 0, "every tab, the demo, the menus and the reports drew without error")
local ec = A.ns.db.measure.echo
Check(type(ec) == "table" and type(ec.number) == "number" and ec.channel == "sent 0, back no" and type(ec.whisper) == "string" and ec.whisper:find("^sent"),
	"/pug measure echo sends on each way and saves what came back")
local feed = A.env.Pugger_FeedBasic or A.env.Pugger_Feed -- (the stub has no portrait frame)
Call(A, function()
	A.ns.UI.Toggle(true)
	feed:SetHeight(500)
	A.ns.cdb.window.h = 500
	A.ns.UI.ApplyCollapse(true)
	feed._scripts.OnDragStop(feed) -- dragged while collapsed
	A.ns.UI.ApplyCollapse(false)
end)
Check(feed:GetHeight() == 500, ("collapse, drag, open: back at its height (%s)"):format(tostring(feed:GetHeight())))
Call(A, function() A.ns.cdb.window.h = 28 end)
Check(Call(A, A.ns.UI.SavedHeight) == A.ns.UI.HEIGHT, "a 28-pixel saved height (the old bug) opens at the normal height")
Check(A.env.Pugger_Font_body and A.env.Pugger_Font_body._font[1]:find("SourceSans3%-Regular") ~= nil, "post text in Source Sans 3")
Check(A.env.Pugger_Font_title and A.env.Pugger_Font_title._font[1]:find("Cinzel") ~= nil, "titles in Cinzel")

print("== the test transport (MoP Classic)")
local M1 = NewClient({ name = "Mopa", guild = "Test Guild", testCopy = true })
local M2 = NewClient({ name = "Mopb", guild = "Test Guild", testCopy = true })
for _, c in ipairs({ M1, M2 }) do
	c.env.PuggerDB = { testNet = "GUILD", consented = 1 }
	Login(c)
end
Advance(60)
Call(M1, M1.ns.Feed.Post, "over the guild", {}, function() end)
Advance(10)
Check(PostBy(M2, M1.full, "over the guild") ~= nil, "a post crossed over GUILD between two test copies")
Check(M2.ns.rdb.profiles[M1.full] ~= nil, "...with the profile")

print("== posts from one spot")
-- Three posts from one spot in fifteen minutes; a fourth is refused there, by the poster's add-on
-- and, should it skip the check, by everyone's. A hundred yards on, posting is open again.
Advance(1000)
local why4
for i = 1, 3 do
	Call(A, A.ns.Feed.Post, "spot " .. i, {}, function() end)
	Advance(3)
end
Call(A, A.ns.Feed.Post, "spot 4", {}, function(ok, why) why4 = not ok and why end)
Advance(3)
Check(why4 and why4:find("from this spot") ~= nil, "a fourth post from the same spot is refused, saying why")
local function Heard(c, text)
	for _, p in pairs(c.ns.rdb.posts) do if p.a == A.ns.me and p.x == text then return true end end
	return false
end
Check(Heard(B, "spot 3") and not Heard(B, "spot 4"), "Bran got three of them")
Call(A, function() A.ns.rdb.spots = {} end) -- (as a changed add-on would: no check of its own)
Call(A, A.ns.Feed.Post, "spot 5", {}, function() end)
Advance(3)
Check(Heard(A, "spot 5") and not Heard(B, "spot 5"), "...and drops a fourth from a changed add-on that sent it anyway")
A.x = 0.62
Call(A, A.ns.Feed.Post, "moved on", {}, function() end)
Advance(3)
Check(Heard(B, "moved on"), "120 yards on: posting again")
A.x = 0.5

print("== channel numbers")
-- Forever: our channel joined before the game's own took /1 and pushed General to /2. Moved past
-- the game's (zone) channels, General and Trade get /1 and /2 back; a player's own keeps its number.
do
	local ours = A.ns.Comm.ChannelName()
	local zone = { General = 1, Trade = 2 }
	local saved = A.chans
	A.chans = { [ours] = 1, General = 2, Trade = 3, Mine = 4 }
	A.env.GetChannelList = function()
		local t = {}
		for name, id in pairs(A.chans) do t[#t + 1] = { id, name } end
		table.sort(t, function(x, y) return x[1] < y[1] end)
		local out = {}
		for _, e in ipairs(t) do out[#out + 1] = e[1] out[#out + 1] = e[2] out[#out + 1] = false end
		return unpack(out)
	end
	A.env.C_ChatInfo.GetChannelInfoFromIdentifier = function(name) return { zoneChannelID = zone[name] or 0 } end
	A.env.C_ChatInfo.SwapChatChannelsByChannelIndex = function(a, b)
		local na, nb
		for name, id in pairs(A.chans) do if id == a then na = name elseif id == b then nb = name end end
		A.chans[na], A.chans[nb] = b, a
	end
	Call(A, A.ns.Comm.KeepLast)
	Check(A.chans.General == 1 and A.chans.Trade == 2 and A.chans[ours] == 3 and A.chans.Mine == 4
		and A.ns.Comm.ChannelIndex() == 3, "our channel moves after General and Trade, the player's own stays")
	A.chans = saved
	A.env.GetChannelList, A.env.C_ChatInfo.GetChannelInfoFromIdentifier, A.env.C_ChatInfo.SwapChatChannelsByChannelIndex = nil, nil, nil
	Call(A, function() A.ns.Comm.JoinChannel() end)
end
-- A /reload: already in the channel, the add-on says it's here (profile, digest) all the same.
do
	local fired = 0
	Call(B, function() B.ns.On("CHANNEL_READY", function() fired = fired + 1 end) end)
	local d0 = B.ns.Sync.stats.digests
	Call(B, function() B.ns.Comm.SetIndexForTest(0) B.ns.Comm.JoinChannel() end)
	Advance(45)
	Check(fired == 1 and B.ns.Sync.stats.digests > d0, "after a /reload the add-on sends its digest without waiting 15 minutes")
end

-- Heard from, but no profile yet (only a digest came): asked for it by whisper, so they count
-- as online within seconds, not at their next profile ten minutes on.
do
	-- (Gale: new, no posts, so nothing else makes Aria want their key; their profile at login is
	-- lost to Aria, as when Aria logs in after them)
	local G = NewClient({ name = "Gale" })
	Login(G)
	Advance(60)
	Call(A, function() A.ns.rdb.profiles[G.ns.me] = nil end)
	Advance(610) -- (past an ask made at Gale's login)
	Call(G, G.ns.Sync.SendDigest, true, A.ns.me)
	Advance(10)
	Check(Call(A, function() local pr = A.ns.rdb.profiles[G.ns.me] return pr and pr.pk ~= nil end),
		"a digest from someone without a profile: their profile follows in seconds")
end

print("== Forever's channel")
-- Add-on messages on the channel never arrive (CHANNEL_ADDON_DROPPED): everything above went as
-- chat text inside a click, or by whisper. Never text outside a click (the game blocks it and
-- says "Interface action failed").
do
	local blocked = 0
	for _, c in pairs(clients) do blocked = blocked + (c.blocked or 0) end
	Check(blocked == 0, ("no channel text outside a click (%d blocked)"):format(blocked))
	Check(#badText == 0, ("no chat text the game would refuse (%d)"):format(#badText))
	Check((sent.byDist.TEXT or 0) > 0 and (sent.byDist.WHISPER or 0) > 0, "posts went as channel text, the rest by whisper")
	-- The member count, from the channel's list: right at once, for someone who just logged in.
	local N = NewClient({ name = "Nova" })
	Login(N)
	Advance(30)
	local members = 0
	for m in pairs(channels[N.ns.Comm.ChannelName()] or {}) do if m.online then members = members + 1 end end
	Check(Call(N, N.ns.Comm.Online) == members and members > 1,
		("someone who logged in half a minute ago counts everyone in the channel (%d)"):format(members))
	-- A post by a click reaches someone who never whispered with its author.
	Call(N, function() N.env.PuggerDB.consented = 1 end)
	Call(N, N.ns.Feed.Post, "hello from Nova", {}, function() end)
	Advance(5)
	local got = 0
	for m in pairs(channels[N.ns.Comm.ChannelName()] or {}) do
		if m ~= N and m.online and PostBy(m, N.ns.me, "hello from Nova") then got = got + 1 end
	end
	Check(got == members - 1, ("a post reaches everyone in the channel at once (%d of %d)"):format(got, members - 1))
	local checkedBy = 0
	for m in pairs(channels[N.ns.Comm.ChannelName()] or {}) do
		local p = m ~= N and m.online and PostBy(m, N.ns.me, "hello from Nova")
		if p and p.sv then checkedBy = checkedBy + 1 end
	end
	Check(checkedBy == got, ("...and its signature checks out for them all: the profile went first (%d)"):format(checkedBy))
	Logout(N)
	-- A player of another realm in the same channel (Forever's channels reach further than a
	-- whisper): reads and writes posts there, and nobody ever whispers them.
	local Z = NewClient({ name = "Zed", realm = "Far" })
	Login(Z)
	Advance(40)
	Call(Z, function() Z.env.PuggerDB.consented = 1 end)
	Call(Z, Z.ns.Feed.Post, "hello from afar", {}, function() end)
	Call(A, A.ns.Feed.Post, "hello Zed", {}, function() end)
	Advance(120)
	local zp = PostBy(A, Z.ns.me, "hello from afar")
	Check(zp and zp.sv, "a post from another realm arrives and checks out (its profile came first)")
	Check(PostBy(Z, A.ns.me, "hello Zed") ~= nil, "...and posts reach that realm")
	Check((sent.lostWhispers or 0) == 0, ("nobody whispers a realm a whisper can't reach (%d \"no player named\")"):format(sent.lostWhispers or 0))
	Logout(Z)
	-- Just after login the member list isn't loaded: a background message waits for it.
	local Q = NewClient({ name = "Quin" })
	Q.rosterDelay = 15
	Login(Q)
	Advance(22)
	Check(Call(Q, Q.ns.Comm.Ready) and Call(Q, Q.ns.Comm.Roster) == nil and #Call(Q, Q.ns.Comm.Peers, 3) == 0,
		"Quin is in the channel, its member list not loaded yet: nobody to whisper to")
	Call(Q, Q.ns.Comm.Send, "X1~held~1")
	Advance(30)
	local got = 0
	for _, m in pairs(clients) do
		local x = m ~= Q and m.online and m.env.PuggerDB.measure and m.env.PuggerDB.measure.x1_held
		if x and x.from == Q.ns.me then got = got + 1 end
	end
	Check(got > 0, ("...a message sent then waits for the list, and goes when it comes (%d got it)"):format(got))
	Logout(Q)
end

print("== totals")
local all = 0
for _, c in pairs(clients) do
	for _, e in ipairs(Errors(c)) do
		all = all + 1
		print("  error", c.name, e.where, e.msg)
	end
end
Check(all == 0, "no errors captured on any client")
print(("messages sent: %d (largest %d bytes) %s"):format(sent.total, sent.maxLen,
	(function() local t = {} for k, v in pairs(sent.byDist) do t[#t + 1] = k .. "=" .. v end return table.concat(t, " ") end)()))
print(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
