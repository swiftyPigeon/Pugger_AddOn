local ADDON, ns = ...

-- Commands: /pugger, and /pug unless another add-on already has it.

local L = setmetatable({}, { __index = function(_, k) return ns.L[k] end })

local function Name(rest)
	rest = tostring(rest or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if rest == "" then return nil end
	return ns.Key(rest)
end

local COMMANDS = {
	[""] = function() ns.UI.Toggle() end,
	show = function() ns.UI.Toggle(true) end,
	hide = function() ns.UI.Toggle(false) end,
	reset = function() ns.UI.ResetPosition() end,
	lock = function()
		local w = ns.cdb.window
		w.locked = not w.locked or nil
		ns.Print(w.locked and L.LOCKED or L.UNLOCKED)
	end,
	rare = function() ns.Calls.Rare() end,
	camp = function(rest) if rest ~= "" then ns.Calls.Camp(rest) else ns.Popups.CampAsk() end end,
	group = function(rest)
		local n, what = rest:match("^(%d)%s*(.*)$")
		if n then ns.Calls.Group(what, n) else ns.Popups.GroupAsk() end
	end,
	map = function() ns.MapPins.ToggleMenu() end,
	privacy = function() ns.Consent.Show() end,
	status = function() for line in ns.Diagnostics.Status():gmatch("[^\n]+") do ns.Print(line) end end,
	bug = function() ns.Diagnostics.Bug() end,
	measure = function(rest) ns.Measure.Slash(rest) end,
	demo = function(rest) if rest == "off" then ns.Demo.Off() else ns.Demo.On() end end,
	mute = function(rest) local n = Name(rest) if n then ns.Safety.Mute(n, not ns.Safety.IsMuted(n)) end end,
	block = function(rest) local n = Name(rest) if n then ns.Safety.Block(n, not ns.Safety.IsBlocked(n)) end end,
	follow = function(rest) local n = Name(rest) if n then ns.Feed.Follow(n, not ns.Feed.IsFollowing(n)) end end,
	filter = function() ns.Popups.WordFilter() end,
	bio = function() ns.Popups.EditBio() end,
	stone = function(rest)
		local cmd, arg = rest:match("^(%S*)%s*(.*)$")
		if cmd == "here" then return ns.Stones.Record(arg) end
		if cmd == "export" then return ns.Stones.Export() end
		ns.Print("/pug stone here <dungeon> | export")
	end,
	-- Test copies only: the feed over the guild or the party, for clients that refuse add-on
	-- messages on custom channels (MoP Classic).
	testnet = function(rest)
		if not ns.TEST_COPY then return ns.Print(L.NOT_TEST_COPY) end
		local net = rest:upper()
		ns.db.testNet = (net == "GUILD" or net == "PARTY") and net or "OFF"
		ns.Comm.Reset()
		ns.Print(L.TESTNET:format(ns.TestNet() or "off (the channel)"))
		if ns.TestNet() then ns.Fire("CHANNEL_READY") end
	end,
	help = function() for line in L.HELP:gmatch("[^\n]+") do ns.Print(line) end end,
}

local function Run(msg)
	local cmd, rest = tostring(msg or ""):match("^%s*(%S*)%s*(.-)%s*$")
	local fn = COMMANDS[cmd:lower()]
	if not fn then return COMMANDS.help() end
	ns.SafeCall("slash " .. cmd, fn, rest or "")
end

SLASH_PUGGER1 = "/pugger"
SlashCmdList.PUGGER = Run

ns.On("LOGIN", function()
	-- /pug only when nobody else uses it.
	for k, v in pairs(_G) do
		if type(k) == "string" and k:find("^SLASH_") and type(v) == "string" and v:lower() == "/pug" then return end
	end
	SLASH_PUGGERSHORT1 = "/pug"
	SlashCmdList.PUGGERSHORT = Run
end)
