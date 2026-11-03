local ADDON, ns = ...

-- The add-on's names, its saved data and the helpers every other file uses. The event and
-- timer helpers, and the way names are written, follow Guild Master Forever's Core.lua (MIT,
-- see LICENSE.txt).

ns.NAME = "Pugger"
ns.VERSION = "0.1.0"
ns.PREFIX = "PUGGER"                  -- add-on message prefix (16 characters at most)
ns.CHANNELS = { Alliance = "PuggerA", Horde = "PuggerH" } -- + 1, 2, 3...: the numbered channels
ns.CHANNEL_MAX = 6                   -- the last backup channel tried
ns.ICON = "Interface\\AddOns\\Pugger\\media\\logo64"  -- the logo: a white @ on blue (the add-on list, cards)
ns.ICON_SMALL = "Interface\\AddOns\\Pugger\\media\\logo32" -- ...drawn for 18-20 px: the header, the minimap and map buttons
ns.ICON_MENTION = "Interface\\AddOns\\Pugger\\media\\bubble64" -- the Mentions tab and its cards: a speech bubble
ns.ICON_GROUPS = "Interface\\AddOns\\Pugger\\media\\stone64" -- the Groups tab and dungeon groups: a meeting stone
ns.COLOR = "ffe2b65c"                -- the gold of the window's trim
-- Test copies only (tools/install-test-mop.sh sets it; nil in a release): /pug testnet then
-- sends the feed over the guild or the party instead of the channel (Comm.lua).
ns.TEST_COPY = nil

-- What every character starts with (ns.db.settings), each switchable in the window's menu.
local DEFAULTS = {
	daysKept = 3,           -- days of posts kept (1-7)
	showFollows = false,    -- others may see who this player follows (on the profile)
	mentionPopups = true,   -- a card beside the minimap when someone mentions this player
	mentionsFollowedOnly = false, -- ...only from people this player follows
	rarePopups = true,      -- a card for a rare call in this zone
	groupPopups = true,     -- a card for a group call nearby or at a stone close by
	groupLevelOnly = true,  -- group cards only at a fitting level
	showRares = true, showCamps = true, showGroups = true, -- on the world map and minimap
	groupsInRealm = true,   -- dungeon calls as a small line in the Realm timeline
	asks = "all",           -- who may ask to join this player's calls: all | friends | off
	minimapAngle = 200,
	hideMinimap = false,
	alpha = 1,              -- the window's transparency
	hideInCombat = false,
	quietInGroups = true,   -- in a dungeon, raid, battleground or arena with others: no window, no cards
	debug = false,
	words = {},             -- the word filter: lower-case words or #tags that hide a post
}
ns.DEFAULTS = DEFAULTS

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

-- Server time when the game gives it: every client stamps posts with the same clock.
function ns.Now()
	if GetServerTime then
		local t = GetServerTime()
		if t and t > 0 then return t end
	end
	return time()
end

function ns.Print(msg)
	print("|c" .. ns.COLOR .. ns.NAME .. ":|r " .. tostring(msg))
end

-- At most n bytes of s, never half a letter (an accented letter is two bytes or more).
function ns.Cut(s, n)
	s = tostring(s or "")
	if #s <= n then return s end
	local b = s:byte(n + 1)
	while n > 0 and b and b >= 128 and b < 192 do
		n = n - 1
		b = s:byte(n + 1)
	end
	return s:sub(1, n)
end

-- Letters, not bytes (the 200-character limit of a post counts what the player sees).
function ns.Letters(s)
	local _, n = tostring(s or ""):gsub("[^\128-\191]", "")
	return n
end

function ns.Ago(t)
	local d = math.max(0, ns.Now() - (tonumber(t) or 0))
	if d < 60 then return ns.L.AGO_NOW end
	if d < 3600 then return ns.L.AGO_MIN:format(math.floor(d / 60)) end
	if d < 86400 then return ns.L.AGO_HOUR:format(math.floor(d / 3600)) end
	return ns.L.AGO_DAY:format(math.floor(d / 86400))
end

function ns.Count(t)
	local n = 0
	for _ in pairs(t or {}) do n = n + 1 end
	return n
end

---------------------------------------------------------------------------
-- Names. Identity is always "Name-Realm", as the server stamps add-on messages. WoW: Forever's
-- names are a first name and a surname ("Firstname Surname"): its unit functions hand the
-- surname back where the realm goes (UnitFullName gives "Firstname", "Surname"; GetUnitName
-- "Firstname-Surname"), while the server writes "Firstname Surname-Realm". ns.splitNames: this
-- client splits names so.
---------------------------------------------------------------------------

function ns.CurrentRealm()
	local realm = GetNormalizedRealmName and GetNormalizedRealmName()
	if not realm or realm == "" then realm = ((GetRealmName and GetRealmName()) or ""):gsub("[%s%-]", "") end
	return realm ~= "" and realm or "?"
end

ns.knownRealms = {} -- realms seen in the senders' names this session

function ns.IsRealmName(realm)
	if type(realm) ~= "string" or realm == "" then return false end
	return realm == ns.realm or realm == ns.CurrentRealm() or ns.knownRealms[realm] == true
end

function ns.ShortName(name)
	if not name then return nil end
	return (name:gsub("%-[^%-]*$", ""))
end

function ns.RealmOf(name)
	return name and name:match("%-([^%-]+)$")
end

function ns.FullName(name, realm)
	if not name or name == "" or name:find("-", 1, true) then return name end
	realm = realm or ns.realm
	if not realm or realm == "" or realm == "?" then return name end
	return name .. "-" .. realm
end

-- A name the game's functions give ("First-Surname" on Forever), as the server writes it.
function ns.Normal(name)
	if not ns.splitNames or type(name) ~= "string" then return name end
	local first, rest = name:match("^([^%-]+)%-(.+)$")
	if not first or first:find(" ", 1, true) then return name end
	local surname, realm = rest:match("^([^%-]+)%-(.+)$")
	if surname and ns.IsRealmName(realm) then return first .. " " .. surname .. "-" .. realm end
	if ns.IsRealmName(rest) then return name end
	return first .. " " .. rest
end

-- Any name from the wire or the game, as the add-on keeps it: "Name-Realm".
function ns.Key(name)
	if type(name) ~= "string" or name == "" then return nil end
	return ns.FullName(ns.Normal(name))
end

function ns.PlayerName()
	local name, realm = UnitFullName("player")
	if not name then name = UnitName("player") end
	if not name then return "?" end
	local home = ns.realm or ns.CurrentRealm()
	if realm and realm ~= "" and realm ~= home and not ns.IsRealmName(realm) then
		ns.splitNames = true
		name, realm = name .. " " .. realm, nil
	end
	if not realm or realm == "" then realm = home end
	if realm and realm ~= "" and realm ~= "?" then return name .. "-" .. realm end
	return name
end

-- Short name for people on our realm, Name-Realm for anyone else.
function ns.DisplayName(name)
	if not name then return "?" end
	local realm = ns.RealmOf(name)
	if not realm or realm == ns.realm then return ns.ShortName(name) end
	return name
end

-- The name a whisper or an invite takes: the short name on our realm.
function ns.TellName(name)
	if type(name) ~= "string" or name == "" then return name end
	local base, realm = name:match("^(.+)%-([^%-]+)$")
	if realm and (realm == ns.realm or realm == ns.CurrentRealm()) then return base end
	return name
end

function ns.IsMe(name) return name ~= nil and name == ns.me end

---------------------------------------------------------------------------
-- Log (a ring buffer in the SavedVariables, read by /pug bug)
---------------------------------------------------------------------------

function ns.Log(fmt, ...)
	local msg
	if select("#", ...) > 0 then
		local ok, res = pcall(string.format, fmt, ...)
		msg = ok and res or tostring(fmt)
	else
		msg = tostring(fmt)
	end
	local db = ns.db
	if not db then return end
	local log = db.log
	log[#log + 1] = date("%m-%d %H:%M:%S ") .. msg
	while #log > 300 do table.remove(log, 1) end
	if db.settings.debug then ns.Print("|cff999999" .. msg .. "|r") end
end

---------------------------------------------------------------------------
-- Internal callbacks and WoW events. Every handler runs protected, so one bug never breaks
-- the rest of the add-on; errors go to ns.CaptureError (Diagnostics.lua).
---------------------------------------------------------------------------

function ns.SafeCall(where, fn, ...)
	ns.lastWhere = where
	local ok, err = pcall(fn, ...)
	if not ok and ns.CaptureError then ns.CaptureError(where, err) end
	return ok, err
end

local listeners = {}
function ns.On(name, fn)
	listeners[name] = listeners[name] or {}
	table.insert(listeners[name], fn)
end
function ns.Fire(name, ...)
	local l = listeners[name]
	if not l then return end
	for i = 1, #l do ns.SafeCall("callback " .. name, l[i], ...) end
end

local eventFrame = CreateFrame("Frame")
local handlers = {}
function ns.RegisterEvent(event, fn)
	if not handlers[event] then
		handlers[event] = {}
		eventFrame:RegisterEvent(event)
	end
	table.insert(handlers[event], fn)
end
eventFrame:SetScript("OnEvent", function(_, event, ...)
	local h = handlers[event]
	if not h then return end
	for i = 1, #h do ns.SafeCall("event " .. event, h[i], ...) end
end)

-- Quiet: in a group instance (a dungeon, raid, battleground, arena or scenario with at least one
-- other player), when the player keeps the switch on. The window steps aside and cards wait.
function ns.Quiet()
	if not (ns.db and ns.db.settings.quietInGroups) then return false end
	local inside, kind = false, nil
	if IsInInstance then inside, kind = IsInInstance() end
	if not inside or kind == "none" then return false end
	return (IsInGroup and IsInGroup()) or (GetNumGroupMembers and GetNumGroupMembers() > 1) or false
end

function ns.After(seconds, where, fn)
	C_Timer.After(seconds, function() ns.SafeCall(where, fn) end)
end
-- A ticker that starts after a random part of its period (at most a minute), so the tickers
-- started at login don't all tick on one frame.
function ns.Every(seconds, where, fn)
	local ticker, cancelled = nil, false
	local handle = {}
	function handle.Cancel()
		cancelled = true
		if ticker and ticker.Cancel then ticker:Cancel() end
	end
	local function Tick() if not cancelled then ns.SafeCall(where, fn) end end
	C_Timer.After(math.min(seconds, 60) * math.random(), function()
		if not cancelled then ticker = C_Timer.NewTicker(seconds, Tick) end
	end)
	return handle
end

---------------------------------------------------------------------------
-- Saved data. PuggerDB = {
--   settings = {...} (DEFAULTS), log = {}, errors = {},
--   chars = { [Name-Realm] = { window = {...}, seed = <secret key, base64>, pk = ... } },
--   feeds = { [Realm-Faction] = the feed this character's realm and faction share (Store.lua) },
-- }
-- Each feed belongs to one realm and faction: Horde and Alliance never share one.
---------------------------------------------------------------------------

local function Fill(t, defaults)
	for k, v in pairs(defaults) do
		if t[k] == nil then
			if type(v) == "table" then
				local copy = {}
				for kk, vv in pairs(v) do copy[kk] = vv end
				t[k] = copy
			else
				t[k] = v
			end
		end
	end
end

function ns.Faction()
	local f = UnitFactionGroup and UnitFactionGroup("player")
	return (f == "Horde" or f == "Alliance") and f or nil
end

-- The feed of this realm and faction: made the first time.
function ns.FeedKey()
	return ns.realm .. "-" .. (ns.faction or "?")
end

local function OpenFeed()
	local db = ns.db
	local key = ns.FeedKey()
	db.feeds[key] = db.feeds[key] or {}
	ns.rdb = db.feeds[key]
	Fill(ns.rdb, {
		posts = {}, tombs = {}, profiles = {}, follows = {}, mutes = {}, blocks = {},
		myLikes = {}, counter = 0, channel = 1, trusted = {}, slow = {},
	})
end
ns.OpenFeed = OpenFeed

ns.RegisterEvent("ADDON_LOADED", function(name)
	if name ~= ADDON then return end
	PuggerDB = PuggerDB or {}
	local db = PuggerDB
	ns.db = db
	db.settings = db.settings or {}
	Fill(db.settings, DEFAULTS)
	db.log = db.log or {}
	db.errors = db.errors or {}
	db.chars = db.chars or {}
	db.feeds = db.feeds or {}
	db.stones = db.stones or {}  -- meeting stones this player recorded (/pug stone here)
	db.measure = db.measure or {} -- Phase 0's results (Measure.lua)
	ns.Fire("LOADED")
end)

ns.RegisterEvent("PLAYER_LOGIN", function()
	ns.realm = ns.CurrentRealm()
	ns.faction = ns.Faction()
	ns.me = ns.PlayerName()
	ns.db.chars[ns.me] = ns.db.chars[ns.me] or {}
	ns.cdb = ns.db.chars[ns.me]
	OpenFeed()
	ns.Log("login %s (%s) %s", ns.me, tostring(ns.faction), ns.VERSION)
	ns.Fire("LOGIN")
end)

-- A slow load can leave the faction unknown at login: the feed opens once the game says it.
ns.RegisterEvent("PLAYER_ENTERING_WORLD", function()
	if ns.faction or not ns.db or not ns.me then return end
	ns.faction = ns.Faction()
	if ns.faction then
		OpenFeed()
		ns.Fire("FACTION")
	end
end)
