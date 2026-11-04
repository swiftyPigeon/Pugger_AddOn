local ADDON, ns = ...

-- Phase 0's measurements, in game on Forever (the plan's section 12). Each writes its result
-- to the SavedVariables (PuggerDB.measure) and prints it; /pug measure report shows them all to
-- copy. Two or three characters (or friends) with the add-on, on one realm and faction:
--   /pug measure rate <count> <per second>  sends numbered X0 messages on the channel; every
--                                           other client counts what arrived (/pug measure heard)
--   /pug measure logged                     one logged message on the channel: do others get it?
--   /pug measure near                       an add-on message on SAY and YELL: does Forever allow
--                                           them, and how far do they reach?
--   /pug measure sign                       Ed25519 sign and verify, timed in this client
--   /pug measure events                     every event for 20 s: use a meeting stone meanwhile
--   /pug measure report                     everything above, to copy into the results note

local Measure = {}
ns.Measure = Measure
local Ed = ns.Ed25519

local heard = {}   -- [sender] = { n = count, first, last, max = highest number, logged = count }

local function Save(key, value)
	ns.db.measure[key] = value
	ns.Print(("measure %s: %s"):format(key, type(value) == "table" and "saved" or tostring(value)))
end

function Measure.Rate(count, perSec)
	count = math.max(1, math.min(500, tonumber(count) or 50))
	perSec = math.max(0.2, math.min(20, tonumber(perSec) or 2))
	if not ns.Comm.Ready() then return ns.Print(ns.L.NOT_CONNECTED) end
	local i, run = 0, ns.Now()
	local send = C_ChatInfo.SendAddonMessage
	local channel = GetChannelName(ns.Comm.ChannelName() or "") or 0
	local fails = 0
	ns.Print(("rate test: %d messages at %.1f a second"):format(count, perSec))
	local ticker
	ticker = C_Timer.NewTicker(1 / perSec, function()
		i = i + 1
		local dist, target = "CHANNEL", channel
		if ns.TestNet() then dist, target = ns.TestNet(), nil end
		local ok, res = pcall(send, ns.PREFIX, ("X0~%d~%d~%d"):format(run, i, count), dist, target)
		if not ok or not (res == nil or res == true or res == 0) then fails = fails + 1 end
		if i >= count then
			ticker:Cancel()
			Save("rate_sent", { count = count, perSec = perSec, fails = fails, t = run })
		end
	end, count)
end

ns.Comm.Handle("X0", function(dist, sender, text, logged)
	local run, i, count = text:match("^X0~(%d+)~(%d+)~(%d+)$")
	if not run then return end
	local h = heard[sender .. run]
	if not h then
		h = { sender = sender, run = tonumber(run), n = 0, count = tonumber(count), first = GetTime() }
		heard[sender .. run] = h
	end
	h.n, h.last = h.n + 1, GetTime()
	ns.db.measure.heard = ns.db.measure.heard or {}
	ns.db.measure.heard[sender .. run] = { from = sender, got = h.n, of = h.count, seconds = h.last - h.first }
end)

function Measure.Heard()
	local any = false
	for _, h in pairs(heard) do
		any = true
		ns.Print(("%s: %d of %d in %.1f s"):format(ns.DisplayName(h.sender), h.n, h.count, (h.last or h.first) - h.first))
	end
	if not any then ns.Print("nothing heard yet") end
end

function Measure.Logged()
	if not ns.Comm.Ready() then return ns.Print(ns.L.NOT_CONNECTED) end
	ns.Comm.Send("X1~logged~" .. ns.Now(), { logged = true })
	ns.Print("logged test sent: the others type /pug measure report")
end
ns.Comm.Handle("X1", function(dist, sender, text, logged)
	local kind = text:match("^X1~(%a+)~")
	ns.db.measure["x1_" .. tostring(kind)] = { from = sender, dist = dist, logged = logged == true, t = ns.Now() }
	ns.Print(("heard %s test from %s (%s, logged %s)"):format(tostring(kind), ns.DisplayName(sender), dist, tostring(logged == true)))
end)

-- SAY and YELL: if Forever carries add-on messages there, group calls could use the server's own
-- range (Calls.GROUP_DIST).
function Measure.Near()
	local out = {}
	for _, dist in ipairs({ "SAY", "YELL" }) do
		local ok, res = pcall(C_ChatInfo.SendAddonMessage, ns.PREFIX, "X1~" .. dist:lower() .. "~" .. ns.Now(), dist)
		out[dist] = ok and tostring(res) or ("error: " .. tostring(res))
	end
	Save("near_send", out)
end
-- (What arrives on SAY or YELL reaches the X1 handler only if Comm lets those through: test
-- copies print it here instead.)
ns.On("LOGIN", function()
	ns.RegisterEvent("CHAT_MSG_ADDON", function(prefix, text, dist, sender)
		if prefix == ns.PREFIX and (dist == "SAY" or dist == "YELL") and type(text) == "string" and text:find("^X1~") then
			local map, x, y = ns.Calls.MyPosition()
			ns.db.measure["near_heard_" .. dist] = { from = sender, t = ns.Now(), map = map, x = x, y = y }
			ns.Print(("heard %s from %s"):format(dist, tostring(sender)))
		end
	end)
end)

function Measure.Sign()
	local seed = Ed.SHA512("pugger measure"):sub(1, 32)
	local t0 = debugprofilestop()
	local pk = Ed.PublicKey(seed)
	local t1 = debugprofilestop()
	local sig = Ed.Sign(seed, "a post of about two hundred characters" .. string.rep("x", 160), pk)
	local t2 = debugprofilestop()
	local ok = Ed.Verify(pk, "a post of about two hundred characters" .. string.rep("x", 160), sig)
	local t3 = debugprofilestop()
	Save("sign_ms", { key = math.floor(t1 - t0), sign = math.floor(t2 - t1), verify = math.floor(t3 - t2), ok = ok })
	ns.Print(("key %d ms, sign %d ms, verify %d ms (%s)"):format(t1 - t0, t2 - t1, t3 - t2, tostring(ok)))
end

-- Every event for 20 s (with its first arguments), to find what a meeting stone fires.
local spy
function Measure.Events()
	spy = spy or CreateFrame("Frame")
	local log, t0 = {}, GetTime()
	spy:RegisterAllEvents()
	spy:SetScript("OnEvent", function(_, event, a, b, c)
		if #log < 400 and not event:find("^CHAT_MSG_ADDON") and event ~= "COMBAT_LOG_EVENT_UNFILTERED" then
			log[#log + 1] = ("%.1f %s %s %s %s"):format(GetTime() - t0, event, tostring(a), tostring(b), tostring(c))
		end
	end)
	ns.Print("logging every event for 20 s: use the meeting stone now")
	C_Timer.After(20, function()
		spy:UnregisterAllEvents()
		spy:SetScript("OnEvent", nil)
		local map, x, y = ns.Calls.MyPosition()
		Save("events", { map = map, x = x, y = y, lines = log })
	end)
end

function Measure.Report()
	local out = { ns.NAME .. " Phase 0 results", ns.Diagnostics.Status(), "" }
	local function Dump(k, v, indent)
		if type(v) == "table" then
			out[#out + 1] = indent .. tostring(k) .. ":"
			local keys = {}
			for kk in pairs(v) do keys[#keys + 1] = kk end
			table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
			for _, kk in ipairs(keys) do Dump(kk, v[kk], indent .. "  ") end
		else
			out[#out + 1] = indent .. tostring(k) .. " = " .. tostring(v)
		end
	end
	local keys = {}
	for k in pairs(ns.db.measure) do keys[#keys + 1] = k end
	table.sort(keys)
	for _, k in ipairs(keys) do Dump(k, ns.db.measure[k], "") end
	ns.Diagnostics.ShowCopy(ns.NAME .. " Phase 0", (table.concat(out, "\n"):gsub("|", "!")))
end

function Measure.Slash(rest)
	local cmd, a, b = tostring(rest or ""):match("^(%S*)%s*(%S*)%s*(%S*)")
	if cmd == "rate" then return Measure.Rate(a, b) end
	if cmd == "heard" then return Measure.Heard() end
	if cmd == "logged" then return Measure.Logged() end
	if cmd == "near" then return Measure.Near() end
	if cmd == "sign" then return Measure.Sign() end
	if cmd == "events" then return Measure.Events() end
	if cmd == "report" then return Measure.Report() end
	if cmd == "clear" then wipe(ns.db.measure) wipe(heard) return ns.Print("measurements cleared") end
	ns.Print("/pug measure rate <count> <per second> | heard | logged | near | sign | events | report | clear")
end
