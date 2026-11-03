local ADDON, ns = ...

-- Cards beside the minimap (like Guild Master Forever's Mentions.lua): a mention, a rare call in
-- this zone, a group nearby, someone asking to join, the meeting stone prompt. And the add-on's
-- own small dialogs (a confirm, a whisper box, the bio, a camp's note, a group's details, the
-- word filter): never the game's StaticPopup, never Blizzard's chat box.

local Popups = {}
ns.Popups = Popups
local L = setmetatable({}, { __index = function(_, k) return ns.L[k] end })

Popups.MAX_CARDS = 4
Popups.LIFE = 20   -- seconds a card stays (an ask: ASK_LIFE)
Popups.ASK_LIFE = 90
Popups.CARD_W = 250

local cards = {}   -- shown, top to bottom
local spare = {}

local function UIx() return ns.UI end

local function Layout()
	local anchor = MinimapCluster or Minimap or UIParent
	for i, c in ipairs(cards) do
		c:ClearAllPoints()
		if i == 1 then c:SetPoint("TOPRIGHT", anchor, "TOPLEFT", -8, -8)
		else c:SetPoint("TOPRIGHT", cards[i - 1], "BOTTOMRIGHT", 0, -6) end
	end
end

local function Close(card)
	for i, c in ipairs(cards) do
		if c == card then table.remove(cards, i) break end
	end
	card:Hide()
	card.key = nil
	spare[#spare + 1] = card
	Layout()
end

local function NewCard()
	local UI = UIx()
	local f = CreateFrame("Frame", nil, UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
	f:SetWidth(Popups.CARD_W)
	f:SetFrameStrata("HIGH")
	f.icon = f:CreateTexture(nil, "ARTWORK")
	f.icon:SetSize(30, 30)
	f.icon:SetPoint("TOPLEFT", 9, -9)
	f.title = UI.Font(f, "big")
	f.title:SetPoint("TOPLEFT", 46, -9)
	f.title:SetPoint("TOPRIGHT", -24, -9)
	f.title:SetWordWrap(false)
	f.body = UI.Font(f)
	f.body:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 0, -3)
	f.body:SetWidth(Popups.CARD_W - 56)
	UI.Wrap(f.body)
	local x = UI.Template("Button", nil, f, "UIPanelCloseButton")
	x:SetSize(24, 24)
	x:SetPoint("TOPRIGHT", 0, 0)
	x:SetScript("OnClick", function() Close(f) end)
	f.x = x
	f.buttons = {}
	f:SetScript("OnUpdate", function(self)
		if self.expires and GetTime() > self.expires then Close(self) end
	end)
	return f
end

-- spec: { key, title, body, kind (UI.KIND key) | color, life, buttons = { { label, go, kind, keep } } }
function Popups.Card(spec)
	local UI = UIx()
	if spec.key then
		for _, c in ipairs(cards) do if c.key == spec.key then Close(c) break end end
	end
	if #cards >= Popups.MAX_CARDS then Close(cards[#cards]) end
	local f = table.remove(spare) or NewCard()
	f.key = spec.key
	local k = spec.kind and UI.KIND[spec.kind]
	UI.Backdrop(f, k and k.bg or UI.C.panel, k and k.border or UI.C.panelEdge)
	f.icon:SetTexture(spec.icon or (k and k.icon) or ns.ICON)
	f.title:SetText(k and UI.Hex(k.color, spec.title or "") or (spec.title or ""))
	f.body:SetText(spec.body or "")
	for _, b in ipairs(f.buttons) do b:Hide() end
	local h = math.max(48, 16 + (f.title:GetStringHeight() or 12) + 3 + (f.body:GetStringHeight() or 24))
	local x = 8
	for i, def in ipairs(spec.buttons or {}) do
		local b = f.buttons[i]
		if not b or b.kind ~= (def.kind or "line") then
			if b then b:Hide() end
			b = UI.Button(f, "", nil, def.kind or "line")
			f.buttons[i] = b
		end
		b:SetLabel(def.label)
		b:SetOn(not def.disabled)
		b:SetScript("OnClick", function(self)
			if def.go then ns.SafeCall("card button", def.go, self) end
			if not def.keep then Close(f) end
		end)
		b:ClearAllPoints()
		b:SetPoint("BOTTOMLEFT", x, 8)
		b:Show()
		x = x + (b:GetWidth() or 50)
	end
	if spec.buttons and #spec.buttons > 0 then h = h + 28 end
	f:SetHeight(h)
	f.expires = GetTime() + (spec.life or Popups.LIFE)
	f:Show()
	table.insert(cards, 1, f)
	Layout()
	if spec.sound ~= false and PlaySound and SOUNDKIT then pcall(PlaySound, SOUNDKIT.TELL_MESSAGE or 3081) end
	return f
end

---------------------------------------------------------------------------
-- The cards
---------------------------------------------------------------------------

function Popups.Mention(p)
	local UI = UIx()
	local who = UI.Who(p.a)
	Popups.Card({
		key = "m" .. p.id, title = L.CARD_MENTION:format(who), icon = "Interface\\Icons\\INV_Letter_15",
		body = ns.Codec.Visible(p.x):sub(1, 160),
		buttons = {
			{ label = L.OPEN, go = function() UI.Open({ thread = ns.Feed.Root(p.id) }) end, kind = "main" },
			{ label = L.REPLY, go = function() UI.StartReply(p.id) end },
		},
	})
end

-- A new call heard: a card when it is for this player (the switches decide).
function Popups.Call(c)
	local s, Calls = ns.db.settings, ns.Calls
	if c.mine then return end
	local UI = UIx()
	if c.kind == "R" then
		if not s.rarePopups or Calls.MyZone() ~= c.map then return end
	elseif c.kind == "G" then
		if not s.groupPopups or (s.groupLevelOnly and not Calls.LevelFits(c)) then return end
	elseif c.kind == "D" then
		if not s.groupPopups or (s.groupLevelOnly and not Calls.LevelFits(c)) or not Calls.Near(c.map) then return end
	else
		return -- (a camp makes no card)
	end
	local buttons = {}
	for _, a in ipairs(UI.CallActions(c)) do
		if #buttons < 3 then buttons[#buttons + 1] = { label = a.label, go = a.go, kind = a.kind, disabled = a.disabled } end
	end
	Popups.Card({
		key = "c" .. c.id, kind = c.kind,
		title = L[UI.KIND[c.kind].label] .. "|r  " .. UI.Name(c.caller, c.cls),
		body = UI.CallTitle(c) .. "\n" .. UI.CallWhere(c), buttons = buttons,
	})
end

function Popups.Ask(c, ask)
	local UI = UIx()
	local class = (LOCALIZED_CLASS_NAMES_MALE or {})[ask.class] or ask.class
	local where = ask.yards and L.YARDS_AWAY:format(ask.yards) or (ask.zone ~= "" and L.IN_ZONE:format(ask.zone) or "")
	Popups.Card({
		key = "a" .. c.id .. ask.name, kind = c.kind, life = Popups.ASK_LIFE,
		title = L.CARD_ASK:format(UI.Hex(UI.ClassColor(ask.class), ns.DisplayName(ask.name))),
		body = L.ASK_BODY:format(ask.level, class or "?", where, UI.CallTitle(c)),
		buttons = {
			{ label = L.INVITE, go = function() ns.Calls.Decide(c.id, ask.name, true) end, kind = "main" },
			{ label = L.NO, go = function() ns.Calls.Decide(c.id, ask.name, false) end },
		},
	})
end

-- Closes the card made with this key, if it is shown.
function Popups.CloseKey(key)
	for _, c in ipairs(cards) do
		if c.key == key then return Close(c) end
	end
end

-- Every ask still waiting on one of our calls, each as a card.
function Popups.ShowAsks(c)
	for _, a in pairs(c.asks or {}) do
		if a.state == "waiting" then Popups.Ask(c, a) end
	end
end

-- "At the Deadmines stone. Look for a group?": never automatic, the player's click makes it.
-- With several stones (the Barrens, Blackrock Mountain) the card names each.
function Popups.StonePrompt(list)
	local UI = UIx()
	local s = list[1]
	local buttons = {
		{ label = L.LOOK_FOR_GROUP, go = function() Popups.GroupAsk(s) end, kind = "main" },
		{ label = L.NO },
	}
	if #list > 1 then
		buttons[2] = { label = L.OTHER_STONE, go = function()
			local rest = {}
			for i = 2, #list do rest[#rest + 1] = list[i] end
			rest[#rest + 1] = s
			Popups.StonePrompt(rest)
		end }
		buttons[3] = { label = L.NO }
	end
	Popups.Card({
		key = "stone", kind = "D", life = 60, sound = false,
		title = L.STONE_PROMPT:format(s.name), body = L.STONE_BODY:format(s.lo, s.hi), buttons = buttons,
	})
end

-- A meeting stone under the mouse (Calls.OnTooltip): never automatic, the player's click.
function Popups.StoneSeen()
	Popups.Card({
		key = "stone", kind = "D", life = 60, sound = false,
		title = L.STONE_SEEN_TITLE, body = L.STONE_SEEN_BODY,
		-- (Kept open: the dungeon menu opens beside its button, and the card closes once one is picked.)
		buttons = { { label = L.LOOK_FOR_GROUP, go = function(b) ns.Calls.StartAtStone(b) end, kind = "main", keep = true }, { label = L.NO } },
	})
end

---------------------------------------------------------------------------
-- Dialogs: one window of our own, centred, with up to two edit boxes.
---------------------------------------------------------------------------

local dialog
local function Dialog()
	if dialog then return dialog end
	local UI = UIx()
	local d = CreateFrame("Frame", "Pugger_Dialog", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
	UI.Backdrop(d, { 1, 1, 1, 1 }, { 1, 1, 1, 1 }, "dialog")
	d:SetSize(320, 150)
	d:SetPoint("CENTER", 0, 120)
	d:SetFrameStrata("DIALOG")
	d:EnableMouse(true)
	d:SetMovable(true)
	d:RegisterForDrag("LeftButton")
	d:SetScript("OnDragStart", d.StartMoving)
	d:SetScript("OnDragStop", d.StopMovingOrSizing)
	d.title = UI.Font(d, "title")
	d.title:SetPoint("TOP", 0, -18)
	d.title:SetJustifyH("CENTER")
	d.body = UI.Font(d, nil)
	d.body:SetPoint("TOP", d.title, "BOTTOM", 0, -6)
	d.body:SetWidth(280)
	d.body:SetJustifyH("CENTER")
	ns.UI.Wrap(d.body)
	d.edits = {}
	for i = 1, 2 do
		local e, templated = UI.Template("EditBox", nil, d, "InputBoxTemplate")
		if not templated then
			UI.Backdrop(e, { 0, 0, 0, 0.8 })
			e:SetTextInsets(5, 5, 2, 2)
		end
		e:SetAutoFocus(false)
		e:SetFontObject(UI.FontObject("body"))
		e:SetSize(270, 20)
		e:SetScript("OnEscapePressed", function() d:Hide() end)
		e:SetScript("OnEnterPressed", function() if d.okButton then d.okButton:Click() end end)
		e.label = UI.Font(e, nil, { 0.62, 0.58, 0.50 })
		e.label:SetPoint("BOTTOMLEFT", e, "TOPLEFT", 1, 1)
		d.edits[i] = e
	end
	d.ok = UI.Button(d, "OK", nil, "main")
	d.ok:SetPoint("BOTTOMRIGHT", d, "BOTTOM", -3, 16)
	d.cancel = UI.Button(d, L.CANCEL, function() d:Hide() end, "line")
	d.cancel:SetPoint("BOTTOMLEFT", d, "BOTTOM", 3, 16)
	d.okButton = d.ok
	if UISpecialFrames then table.insert(UISpecialFrames, "Pugger_Dialog") end
	dialog = d
	return d
end

-- spec: { title, body, edits = { { label, text, max } }, ok, cancel (false: none), go = fn(t1, t2) }
function Popups.Dialog(spec)
	local d = Dialog()
	d.title:SetText(spec.title or "")
	d.body:SetText(spec.body or "")
	local y = -24 - (d.title:GetStringHeight() or 14) - (d.body:GetStringHeight() or 14) - 10
	for i, e in ipairs(d.edits) do
		local def = spec.edits and spec.edits[i]
		if def then
			y = y - 14
			e:ClearAllPoints()
			e:SetPoint("TOP", d, "TOP", 3, y)
			e.label:SetText(def.label or "")
			e:SetMaxLetters(def.max or 80)
			e:SetText(def.text or "")
			e:Show()
			y = y - 24
		else
			e:Hide()
		end
	end
	d:SetHeight(-y + 50)
	d.ok:SetLabel(spec.ok or "OK")
	d.ok:SetScript("OnClick", function()
		d:Hide()
		if spec.go then ns.SafeCall("dialog", spec.go, d.edits[1]:GetText(), d.edits[2]:GetText()) end
	end)
	d.ok:ClearAllPoints()
	if spec.cancel == false then
		d.cancel:Hide()
		d.ok:SetPoint("BOTTOM", 0, 16)
	else
		d.cancel:SetLabel(spec.cancel or L.CANCEL)
		d.cancel:Show()
		d.ok:SetPoint("BOTTOMRIGHT", d, "BOTTOM", -3, 16)
	end
	d:Show()
	if spec.edits and spec.edits[1] then d.edits[1]:SetFocus() end
end

function Popups.Confirm(text, go)
	Popups.Dialog({ title = "Pugger", body = text, ok = L.YES, go = go })
end

-- A whisper from the add-on's own box (sent with SendChatMessage on the player's Enter or
-- click; the game's chat box never opens).
function Popups.Whisper(name)
	Popups.Dialog({
		title = L.WHISPER_TO:format(ns.DisplayName(name)), edits = { { label = L.MESSAGE, max = 255 } }, ok = L.SEND,
		go = function(text)
			if text and text ~= "" then SendChatMessage(text, "WHISPER", nil, ns.TellName(name)) end
		end,
	})
end

function Popups.EditBio()
	Popups.Dialog({
		title = L.EDIT_BIO, body = L.BIO_BODY, edits = { { label = L.BIO, text = ns.cdb.bio or "", max = ns.Identity.BIO_MAX } },
		ok = L.SAVE, go = function(text) ns.Identity.SetBio(text or "") end,
	})
end

function Popups.CampAsk()
	Popups.Dialog({
		title = L.CALL_CAMP, body = L.CAMP_BODY, edits = { { label = L.NOTE, max = ns.Calls.NOTE_MAX } },
		ok = L.CAMP_HERE, go = function(note) ns.Calls.Camp(note) end,
	})
end

-- A group call: at a stone (s given) a dungeon group; elsewhere a quest / farm group.
function Popups.GroupAsk(s)
	Popups.CloseKey("stone")
	if s then
		local need = 4 - math.max(0, (GetNumGroupMembers and GetNumGroupMembers() or 0) - 1)
		return Popups.Dialog({
			title = L.STONE_PROMPT:format(s.name), body = L.DUNGEON_BODY:format(s.lo, s.hi),
			edits = { { label = L.HOW_MANY, text = tostring(math.max(1, need)), max = 1 }, { label = L.NOTE, max = ns.Calls.NOTE_MAX } },
			ok = L.LOOK_FOR_GROUP, go = function(n, note) ns.Calls.Dungeon(s.key, n, note) end,
		})
	end
	Popups.Dialog({
		title = L.CALL_GROUP, body = L.GROUP_BODY:format(ns.Calls.GROUP_YARDS),
		edits = { { label = L.GROUP_WHAT, max = 60 }, { label = L.HOW_MANY, text = "1", max = 1 } },
		ok = L.LOOK_FOR_GROUP, go = function(what, n) ns.Calls.Group(what, n) end,
	})
end

function Popups.WordFilter()
	local words = table.concat(ns.db.settings.words, " ")
	Popups.Dialog({
		title = L.WORD_FILTER, body = L.WORD_FILTER_BODY, edits = { { label = L.WORDS, text = words, max = 250 } },
		ok = L.SAVE, go = function(text)
			wipe(ns.db.settings.words)
			for w in tostring(text or ""):gmatch("%S+") do ns.Safety.AddWord(w) end
			ns.Fire("FEED_CHANGED")
		end,
	})
end
