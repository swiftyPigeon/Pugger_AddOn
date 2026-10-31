local ADDON, ns = ...

-- Each player decides (section 7 of the plan): mute hides someone's posts, block hides them
-- everywhere (their posts, their replies, their likes, their asks), the word filter hides posts
-- with chosen words or #tags. All local; nobody is told. Plus the honest limits, and Report:
-- the game's own report for that player when an add-on may open it, instructions otherwise.

local Safety = {}
ns.Safety = Safety
local Codec = ns.Codec

Safety.POSTS_PER_HOUR = 20  -- live posts a sender may make in an hour; more are ignored
Safety.LEVEL_TO_POST = 10

function Safety.IsMuted(name) return ns.rdb.mutes[name] ~= nil end
function Safety.IsBlocked(name) return ns.rdb and ns.rdb.blocks[name] ~= nil end

function Safety.Mute(name, on)
	ns.rdb.mutes[name] = on and ns.Now() or nil
	ns.Print((on and ns.L.MUTED or ns.L.UNMUTED):format(ns.DisplayName(name)))
	ns.Fire("FEED_CHANGED")
end
function Safety.Block(name, on)
	ns.rdb.blocks[name] = on and ns.Now() or nil
	if on then ns.rdb.follows[name] = nil end
	ns.Print((on and ns.L.BLOCKED or ns.L.UNBLOCKED):format(ns.DisplayName(name)))
	ns.Fire("FEED_CHANGED")
end

-- The word filter: whole words or #tags, any case.
function Safety.AddWord(w)
	w = tostring(w or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
	if w == "" then return end
	local words = ns.db.settings.words
	for _, x in ipairs(words) do if x == w then return end end
	words[#words + 1] = w
	ns.Fire("FEED_CHANGED")
end
function Safety.RemoveWord(w)
	local words = ns.db.settings.words
	for i = #words, 1, -1 do if words[i] == tostring(w or ""):lower() then table.remove(words, i) end end
	ns.Fire("FEED_CHANGED")
end

local function Filtered(text)
	local words = ns.db.settings.words
	if #words == 0 then return false end
	local plain = " " .. Codec.Visible(text):lower() .. " "
	for _, w in ipairs(words) do
		local pat = "[%s%p]" .. w:gsub("%p", "%%%0") .. "[%s%p]"
		if plain:find(pat) then return true end
	end
	return false
end

-- Should this post stay out of sight?
function Safety.Hidden(p)
	if p.a == ns.me then return false end
	if Safety.IsBlocked(p.a) or Safety.IsMuted(p.a) then return true end
	if p.x and Filtered(p.x) then return true end
	-- A repost of something hidden is hidden too.
	if p.f == "r" and p.par then
		local o = ns.Store.Get(p.par)
		if o and o.a ~= ns.me and (Safety.IsBlocked(o.a) or Safety.IsMuted(o.a)) then return true end
	end
	return false
end

-- Live posts per sender per hour.
local recent = {}
function Safety.AdmitPost(sender, now)
	local list = recent[sender]
	if not list then list = {} recent[sender] = list end
	while list[1] and now - list[1] > 3600 do table.remove(list, 1) end
	if #list >= Safety.POSTS_PER_HOUR then return false end
	list[#list + 1] = now
	return true
end

-- The player may post: level 10 or more.
function Safety.CanPost()
	return (UnitLevel("player") or 0) >= Safety.LEVEL_TO_POST
end

-- Report: instructions for the game's own report (posts go through the logged API, so
-- Blizzard holds the text). Whether an add-on may open the report window itself is a Phase 0
-- check on Forever; until then, nothing here calls it.
function Safety.Report(name)
	ns.Print(ns.L.REPORT_HOW:format(ns.DisplayName(name)))
end
