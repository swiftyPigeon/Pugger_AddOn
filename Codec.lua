local ADDON, ns = ...

-- Wire format. Pure functions, no WoW API, covered by tools/sim.lua.
--
-- Every message is "<type>~<fields>", fields split by "~"; a player's text is always the last
-- field, so it may hold a "~". Longer than one add-on message (255 bytes): pieces,
-- C<id>:<i>:<n>:<piece>, put together again by the receiver (Codec.Feed).
--
--   P1~author~t36~n36~flags~parent~pin~sig~text     a post (flags: "" | "p" reply | "r" repost)
--   D1~author~t36~n36~deletedAt36~sig               a delete of the post author:t:n
--   L1~postId~1|0                                   a like (the sender likes; never relayed)
--   R1~pk~level~class~guild~showFollows~t36~sig~bio a profile (only ever heard from its owner)
--   R0~                                             "send me your profile" (whisper)
--   H2~bucket~c.h,c.h,...                           "what I have": 12 buckets of an hour back
--   O2~asker~bucket                                 "I answer this one" (the others stay quiet)
--   I2~bucket~s,s,...                               the short ids of my posts in a bucket (whisper)
--   (H1, O1, I1 were 0.1.0's, with six-hour buckets: renamed so the two never misread each other)
--   Q1~s,s,...                                      "send me these" (whisper)
--   C1~id=l.r,...                                   like and repost counts (whisper)
--   M1~kind~cid~map~x~y~expires36~a~b~c~class~note  a map call (Calls.lua)
--   M2~caller~cid~u|d|f|x                           a call's update (still up, dead, full, closed)
--   J1~cid~level~class~map~x~y~zone                 ask to join (whisper to the caller)
--   J2~cid~ok|no|full|far|many|off                  the caller's answer (whisper)
--   B1~n                                            "the feed moved to channel n"
--   S1~map~x~y~key                                  "a meeting stone is here" (Stones.lua, the gossip)
--   S2~map~x~y~key~reporter                         "I saw one there too" (a first-hand answer)
--   X0~n / X1~n                                     Phase 0's rate test (Measure.lua)
--
-- Post id: "<author>:<t36>:<n36>" (the author's name, the server time in base 36, a counter).

local Codec = {}
ns.Codec = Codec

Codec.CHUNK = 236
Codec.MAX_LETTERS = 80  -- a post's text, in letters the reader sees (links count by their names)
Codec.MAX_BYTES = 400   -- ...and in bytes, links included
Codec.MAX_CHUNKS = 30
Codec.SEP = "~"

local function split(s, sep, max)
	local out, start = {}, 1
	while true do
		if max and #out == max - 1 then
			out[#out + 1] = s:sub(start)
			return out
		end
		local i = s:find(sep, start, true)
		if not i then
			out[#out + 1] = s:sub(start)
			return out
		end
		out[#out + 1] = s:sub(start, i - 1)
		start = i + #sep
	end
end
Codec.Split = split

-- The fields of a message of `n` fields, the last one taking the rest (the text).
function Codec.Fields(msg, n)
	return split(msg, "~", n)
end

-- A field from someone else may not carry a separator, a "|" or a control byte.
function Codec.Clean(s)
	return (tostring(s or ""):gsub("[~|%c]", ""))
end

---------------------------------------------------------------------------
-- Numbers
---------------------------------------------------------------------------

local DIGITS = "0123456789abcdefghijklmnopqrstuvwxyz"
function Codec.Base36(n)
	n = math.floor(tonumber(n) or 0)
	if n <= 0 then return "0" end
	local out = {}
	while n > 0 do
		local d = n % 36
		table.insert(out, 1, DIGITS:sub(d + 1, d + 1))
		n = math.floor(n / 36)
	end
	return table.concat(out)
end

function Codec.UnBase36(s)
	if type(s) ~= "string" or s == "" or #s > 10 or s:find("[^0-9a-z]") then return nil end
	return tonumber(s, 36)
end

-- A whole number from the wire, within [lo, hi]; nil otherwise.
function Codec.Int(s, lo, hi)
	local n = tonumber(s)
	if not n or n ~= n or n ~= math.floor(n) then return nil end
	if (lo and n < lo) or (hi and n > hi) then return nil end
	return n
end

-- 32-bit string hash (djb2 and a second one, mixed), in plain arithmetic.
function Codec.Hash(s)
	local h1, h2 = 5381, 52711
	for i = 1, #s do
		local b = s:byte(i)
		h1 = (h1 * 33 + b) % 4294967296
		h2 = (h2 * 31 + b * 7) % 4294967291
	end
	return (h1 + h2 * 65599) % 4294967296
end

-- A post's short id in a list (5 base-36 letters): sync compares these, not whole ids.
function Codec.ShortId(id)
	local s = Codec.Base36(Codec.Hash(id) % 60466176) -- 36^5
	return ("00000" .. s):sub(-5)
end

---------------------------------------------------------------------------
-- Post ids and map pins
---------------------------------------------------------------------------

function Codec.PostId(author, t, n)
	return ("%s:%s:%s"):format(author, Codec.Base36(t), Codec.Base36(n))
end

-- author, time, counter from an id; nil for anything else.
function Codec.ParseId(id)
	if type(id) ~= "string" or #id > 80 then return nil end
	local author, t36, n36 = id:match("^([^:~|]+):([0-9a-z]+):([0-9a-z]+)$")
	if not author then return nil end
	local t, n = Codec.UnBase36(t36), Codec.UnBase36(n36)
	if not t or not n then return nil end
	return author, t, n
end

-- A map pin: "<uiMapID>:<x>:<y>", x and y in ten-thousandths of the map; or "<uiMapID>" alone
-- where the game gives no position (in a dungeon): the zone without coordinates.
function Codec.EncodePin(mapID, x, y)
	if not mapID then return "" end
	if not x or not y then return ("%d"):format(mapID) end
	return ("%d:%d:%d"):format(mapID, math.floor(x * 10000 + 0.5), math.floor(y * 10000 + 0.5))
end
function Codec.DecodePin(s)
	if type(s) ~= "string" or s == "" then return nil end
	if s:match("^%d+$") then
		local m = Codec.Int(s, 1, 100000)
		return m, nil, nil
	end
	local m, x, y = s:match("^(%d+):(%d+):(%d+)$")
	m, x, y = Codec.Int(m, 1, 100000), Codec.Int(x, 0, 10000), Codec.Int(y, 0, 10000)
	if not m or not x or not y then return nil end
	return m, x / 10000, y / 10000
end

---------------------------------------------------------------------------
-- Links. A post may carry item, spell, enchant and quest links exactly as the game writes
-- them (shift-click); anything else with a "|" in it shows as plain text. From Guild Master
-- Forever's Codec.SanitizeChat.
---------------------------------------------------------------------------

local LINK_TYPES = { item = true, spell = true, enchant = true, quest = true }
Codec.LINK_TYPES = LINK_TYPES

-- A link's data as the game writes it for these types: an id from 1, then at most 31 more
-- fields, each empty or a whole number, 120 bytes at most.
local function LinkData(data)
	if #data > 120 then return false end
	local n = 0
	for field in (data .. ":"):gmatch("([^:]*):") do
		n = n + 1
		if n == 1 and not field:find("^[1-9]%d?%d?%d?%d?%d?%d?%d?%d?$") then return false end
		if n > 32 or #field > 11 or not (field == "" or field:find("^%-?%d+$")) then return false end
	end
	return true
end

-- Length of a link we let through that starts at i, or nil, and its shown name.
local function LinkAt(s, i)
	local j = i
	local color = s:match("^|c%x%x%x%x%x%x%x%x", j) or s:match("^|cn[%w_]+:", j)
	if color then
		if #color > 40 then return nil end
		j = j + #color
	end
	local kind, data, text = s:match("^|H(%a+):([^|]*)|h%[([^|%[%]%c]*)%]|h", j)
	if not kind or not LINK_TYPES[kind] or not LinkData(data) or text == "" or #text > 100 then return nil end
	j = j + #kind + #data + #text + 9 -- "|H" ":" "|h[" "]|h"
	if color then
		if s:sub(j, j + 1) ~= "|r" then return nil end
		j = j + 2
	end
	return j - i, text
end
Codec.LinkAt = LinkAt

-- Text as it may be shown: whitelisted links and "||" stay, every other "|" becomes "||",
-- control bytes go, runs of spaces become one. Idempotent.
function Codec.Sanitize(s)
	s = tostring(s or "")
	local out, i, n = {}, 1, #s
	while i <= n do
		local j = s:find("[%z\1-\31|\127]", i)
		if not j then
			out[#out + 1] = s:sub(i)
			break
		end
		if j > i then out[#out + 1] = s:sub(i, j - 1) end
		if s:byte(j) ~= 124 then
			out[#out + 1] = s:byte(j) == 10 and " " or ""
			i = j + 1
		elseif s:byte(j + 1) == 124 then
			out[#out + 1] = "||"
			i = j + 2
		else
			local len = LinkAt(s, j)
			out[#out + 1] = len and s:sub(j, j + len - 1) or "||"
			i = j + (len or 1)
		end
	end
	return (table.concat(out):gsub("%s%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- What the reader sees of a text: links by their names in brackets, "||" as "|".
function Codec.Visible(s)
	s = tostring(s or "")
	local out, i = {}, 1
	while i <= #s do
		if s:byte(i) == 124 then
			if s:byte(i + 1) == 124 then
				out[#out + 1] = "|"
				i = i + 2
			else
				local len, name = LinkAt(s, i)
				if len then
					out[#out + 1] = "[" .. name .. "]"
					i = i + len
				else
					out[#out + 1] = "|"
					i = i + 1
				end
			end
		else
			local j = s:find("|", i, true) or (#s + 1)
			out[#out + 1] = s:sub(i, j - 1)
			i = j
		end
	end
	return table.concat(out)
end

-- Hashtags and mentions of a text (lower case, without # or @), each once.
function Codec.Tags(s)
	local tags, seen = {}, {}
	for tag in (" " .. Codec.Visible(s)):gmatch("[%s%p]#([%w_]+)") do
		local k = tag:lower()
		if #k >= 2 and #k <= 30 and not seen[k] then seen[k] = true tags[#tags + 1] = k end
	end
	return tags
end
function Codec.Mentions(s)
	local out, seen = {}, {}
	for name in (" " .. Codec.Visible(s)):gmatch("[%s%p]@([%a\128-\255]+)") do
		local k = name:lower()
		if not seen[k] then seen[k] = true out[#out + 1] = k end
	end
	return out
end

---------------------------------------------------------------------------
-- Pieces (from Guild Master Forever's Codec.Chunk and Codec.Feed)
---------------------------------------------------------------------------

function Codec.Chunk(payload, id)
	local n = math.max(1, math.ceil(#payload / Codec.CHUNK))
	local out = {}
	for i = 1, n do
		out[i] = ("C%s:%d:%d:"):format(id, i, n) .. payload:sub((i - 1) * Codec.CHUNK + 1, i * Codec.CHUNK)
	end
	return out
end

-- Pieces waiting for the rest are bounded: a few open messages per sender and a few hundred
-- in all, so nobody can fill memory with pieces that never complete.
Codec.OPEN_PER_SENDER = 6
Codec.OPEN_MAX = 400
function Codec.NewAssembler()
	return { buf = {}, open = 0, bySender = {}, refused = 0 }
end

function Codec.Close(asm, key)
	local e = asm.buf[key]
	if not e then return end
	asm.buf[key] = nil
	asm.open = math.max(0, asm.open - 1)
	local left = (asm.bySender[e.sender] or 1) - 1
	asm.bySender[e.sender] = left > 0 and left or nil
end

-- The full payload once every piece from this sender and id arrived; nil before.
function Codec.Feed(asm, sender, msg, now)
	local id, i, n, body = msg:match("^C(%w+):(%d+):(%d+):(.*)$")
	if not id then return nil end
	i, n = tonumber(i), tonumber(n)
	if n < 1 or n > Codec.MAX_CHUNKS or i < 1 or i > n then return nil end
	local key = sender .. "#" .. id
	local e = asm.buf[key]
	if not e or e.n ~= n then
		if e then Codec.Close(asm, key) end
		local mine = asm.bySender[sender] or 0
		if mine >= Codec.OPEN_PER_SENDER or asm.open >= Codec.OPEN_MAX then
			asm.refused = asm.refused + 1
			return nil
		end
		asm.bySender[sender], asm.open = mine + 1, asm.open + 1
		e = { n = n, parts = {}, got = 0, t = now, sender = sender }
		asm.buf[key] = e
	end
	if not e.parts[i] then
		e.parts[i] = body
		e.got = e.got + 1
	end
	if e.got == n then
		Codec.Close(asm, key)
		return table.concat(e.parts)
	end
	return nil
end

-- Drops assemblies older than 60 s; returns how many.
function Codec.Gc(asm, now)
	local dropped = 0
	for k, e in pairs(asm.buf) do
		if now - e.t > 60 then
			dropped = dropped + 1
			Codec.Close(asm, k)
		end
	end
	return dropped
end

---------------------------------------------------------------------------
-- What a signature covers. Each starts with a word of its own, so a signature made for one
-- kind of message can never pass for another.
---------------------------------------------------------------------------

function Codec.PostSigned(p)
	return table.concat({ "PUG1P", p.id, p.f or "", p.par or "", p.pin or "", p.x or "" }, "\31")
end
function Codec.DeleteSigned(id, at)
	return table.concat({ "PUG1D", id, Codec.Base36(at) }, "\31")
end
function Codec.ProfileSigned(name, pr)
	return table.concat({ "PUG1R", name, pr.pk or "", tostring(pr.level or ""), pr.class or "", pr.guild or "",
		pr.showFollows and "1" or "0", Codec.Base36(pr.t or 0), pr.bio or "" }, "\31")
end

---------------------------------------------------------------------------
-- Posts on the wire
---------------------------------------------------------------------------

Codec.FLAGS = { [""] = true, p = true, r = true }

function Codec.EncodePost(p)
	local author, t, n = Codec.ParseId(p.id)
	return table.concat({ "P1", author, Codec.Base36(t), Codec.Base36(n), p.f or "", p.par or "", p.pin or "", p.s or "", p.x or "" }, "~")
end

-- A post from the wire, checked field by field; nil and why for anything malformed.
function Codec.DecodePost(msg)
	local f = Codec.Fields(msg, 9)
	if #f ~= 9 or f[1] ~= "P1" then return nil, "fields" end
	local author = f[2]
	if author == "" or #author > 60 or author:find("[:~|%c]") then return nil, "author" end
	local t, n = Codec.UnBase36(f[3]), Codec.UnBase36(f[4])
	if not t or not n then return nil, "id" end
	if not Codec.FLAGS[f[5]] then return nil, "flags" end
	local par = f[6] ~= "" and f[6] or nil
	if par and not Codec.ParseId(par) then return nil, "parent" end
	if f[5] ~= "" and not par then return nil, "parent" end
	local pin = f[7] ~= "" and f[7] or nil
	if pin and not Codec.DecodePin(pin) then return nil, "pin" end
	if #f[8] ~= 86 or f[8]:find("[^%w%-_]") then return nil, "sig" end
	local text = Codec.Sanitize(f[9])
	if ns.Letters(Codec.Visible(text)) > Codec.MAX_LETTERS or #text > Codec.MAX_BYTES then return nil, "long" end
	if text == "" and f[5] ~= "r" then return nil, "empty" end
	return { id = Codec.PostId(author, t, n), a = author, t = t, f = f[5] ~= "" and f[5] or nil, par = par, pin = pin, s = f[8], x = text }
end

function Codec.EncodeDelete(id, at, sig)
	local author, t, n = Codec.ParseId(id)
	return table.concat({ "D1", author, Codec.Base36(t), Codec.Base36(n), Codec.Base36(at), sig }, "~")
end
function Codec.DecodeDelete(msg)
	local f = Codec.Fields(msg, 6)
	if #f ~= 6 or f[1] ~= "D1" then return nil end
	local t, n, at = Codec.UnBase36(f[3]), Codec.UnBase36(f[4]), Codec.UnBase36(f[5])
	if f[2] == "" or f[2]:find("[:~|%c]") or not t or not n or not at then return nil end
	if #f[6] ~= 86 or f[6]:find("[^%w%-_]") then return nil end
	return { id = Codec.PostId(f[2], t, n), a = f[2], at = at, s = f[6] }
end

-- Counts: "id=likes.reposts" in base 36, as many as fit in one message.
function Codec.EncodeCounts(list)
	local out, size = {}, 3
	for _, c in ipairs(list) do
		local e = ("%s=%s.%s"):format(c.id, Codec.Base36(c.l), Codec.Base36(c.r))
		if size + #e + 1 > 250 then break end
		out[#out + 1] = e
		size = size + #e + 1
	end
	return "C1~" .. table.concat(out, ",")
end
function Codec.DecodeCounts(msg)
	local body = msg:match("^C1~(.*)$")
	if not body then return nil end
	local out = {}
	for e in body:gmatch("[^,]+") do
		local id, l, r = e:match("^(.+)=([0-9a-z]+)%.([0-9a-z]+)$")
		l, r = Codec.UnBase36(l), Codec.UnBase36(r)
		if id and Codec.ParseId(id) and l and r and l < 100000 and r < 100000 then out[#out + 1] = { id = id, l = l, r = r } end
		if #out >= 40 then break end
	end
	return out
end
