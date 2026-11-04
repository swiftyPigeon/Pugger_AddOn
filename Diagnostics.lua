local ADDON, ns = ...

-- Errors and the bug report (after Guild Master Forever's Diagnostics.lua): errors of the
-- add-on's own files are kept (deduplicated, 40 at most) and /pug bug shows a report to copy,
-- with the version, the client, the channel, the queue and the last lines of the log.
-- /pug status: what the add-on sees, in a few lines.

local Diagnostics = {}
ns.Diagnostics = Diagnostics

function ns.CaptureError(where, err)
	local db = ns.db
	if not db then return end
	local msg = tostring(err)
	for _, e in ipairs(db.errors) do
		if e.msg == msg then
			e.count = (e.count or 1) + 1
			return
		end
	end
	if #db.errors >= 40 then return end
	db.errors[#db.errors + 1] = { where = where, msg = msg, count = 1, t = date("%m-%d %H:%M:%S"), v = ns.VERSION,
		stack = debugstack and debugstack(3, 8, 0) or "" }
	ns.Log("error in %s: %s", tostring(where), msg)
end

ns.On("LOADED", function()
	for _, e in ipairs(ns.earlyErrors) do ns.CaptureError("load", e[1]) end
	wipe(ns.earlyErrors)
end)

-- A copy box: the text selected, Ctrl+C away.
local box
function Diagnostics.ShowCopy(title, text)
	if not box then
		local UI = ns.UI
		box = CreateFrame("Frame", "Pugger_Copy", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
		UI.Backdrop(box, { 1, 1, 1, 1 }, { 1, 1, 1, 1 }, "dialog")
		box:SetSize(480, 320)
		box:SetPoint("CENTER")
		box:SetFrameStrata("DIALOG")
		box:EnableMouse(true)
		box.title = UI.Font(box, "big")
		box.title:SetPoint("TOPLEFT", 18, -18)
		local scroll = CreateFrame("ScrollFrame", "Pugger_CopyScroll", box, "UIPanelScrollFrameTemplate")
		scroll:SetPoint("TOPLEFT", 18, -40)
		scroll:SetPoint("BOTTOMRIGHT", -38, 46)
		local edit = CreateFrame("EditBox", nil, scroll)
		edit:SetMultiLine(true)
		edit:SetAutoFocus(false)
		edit:SetFontObject("GameFontHighlightSmall")
		edit:SetWidth(430)
		edit:SetScript("OnEscapePressed", function() box:Hide() end)
		scroll:SetScrollChild(edit)
		box.edit = edit
		box.close = UI.Button(box, ns.L.CLOSE, function() box:Hide() end, "main")
		box.close:SetPoint("BOTTOMRIGHT", -18, 16)
		box.tip = UI.Font(box, nil, { 0.62, 0.58, 0.50 })
		box.tip:SetPoint("BOTTOMLEFT", 18, 21)
		box.tip:SetText(ns.L.COPY_TIP)
		if UISpecialFrames then table.insert(UISpecialFrames, "Pugger_Copy") end
	end
	box.title:SetText(title or "")
	box.edit:SetText(text or "")
	box:Show()
	box.edit:SetFocus()
	box.edit:HighlightText()
end

function Diagnostics.Status()
	local Comm, Sync, Store = ns.Comm, ns.Sync, ns.Store
	local lines = {
		(ns.NAME .. " %s · %s · %s"):format(ns.VERSION, tostring(ns.me), tostring(ns.faction)),
		("Channel: %s (%s)%s"):format(tostring(Comm.ChannelName() or "-"), Comm.Ready() and "joined" or "not joined",
			ns.TestNet() and (" · test transport " .. ns.TestNet()) or ""),
		("Posts held: %d · profiles: %d · following: %d · key: %s"):format(Store.Total(), ns.Count(ns.rdb.profiles),
			ns.Count(ns.rdb.follows), ns.Identity.Ready() and "ready" or "making"),
		("Sent %d · received %d · failed %d · flood cut %d · queue %d"):format(Comm.stats.sent, Comm.stats.recv,
			Comm.stats.fails, Comm.stats.flood, Comm.QueueSize()),
		("Sync: digests %d sent, %d heard · answers %d · asked %d · sent %d posts"):format(Sync.stats.digests,
			Sync.stats.heard, Sync.stats.offers, Sync.stats.asked, Sync.stats.sent),
		("Stones known: %d in the table, %d recorded here, %d agreed by players"):format(ns.Stones.Counts()),
	}
	return table.concat(lines, "\n")
end

function Diagnostics.Bug()
	local db = ns.db
	local out = { ns.NAME .. " bug report", Diagnostics.Status(),
		("Client: %s %s · %s"):format(tostring((GetBuildInfo())), tostring(select(4, GetBuildInfo())), GetLocale and GetLocale() or "?"),
		"", "Errors:" }
	if #db.errors == 0 then out[#out + 1] = "  none" end
	for _, e in ipairs(db.errors) do
		out[#out + 1] = ("  [%s x%d %s] %s: %s"):format(e.t or "?", e.count or 1, e.v or "?", e.where or "?", e.msg)
		if e.stack and e.stack ~= "" then out[#out + 1] = "    " .. e.stack:gsub("\n", "\n    ") end
	end
	out[#out + 1] = ""
	out[#out + 1] = "Log:"
	for i = math.max(1, #db.log - 40), #db.log do out[#out + 1] = "  " .. db.log[i] end
	local text = table.concat(out, "\n"):gsub("|", "!")
	Diagnostics.ShowCopy(ns.L.BUG_TITLE, text)
end
