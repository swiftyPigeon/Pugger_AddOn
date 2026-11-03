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
-- Quiet in a group instance (ns.Quiet): no cards and no sounds. Calls heard meanwhile, and asks
-- to join the player's own, are held and caught up on the way out if still live; posts and
-- mentions are not (the feed and the Mentions tab keep them).
local held = {}    -- [call id] = true

local function UIx() return ns.UI end

-- Where the cards stack (ns.db.settings.cardsAt): "chat", upward from just above the chat
-- window (clear of its tabs), on the side of Pugger's button; "minimap", down beside the minimap;
-- "top", down from the top of the screen. The newest is nearest its start.
local function Layout()
	local at = ns.db and ns.db.settings.cardsAt or "chat"
	local chat = _G.ChatFrame1 or DEFAULT_CHAT_FRAME
	if type(chat) ~= "table" or not chat.GetObjectType then chat = nil end
	local corner = MinimapCluster or Minimap or UIParent
	for i, c in ipairs(cards) do
		c:ClearAllPoints()
		if at == "chat" then
			if i > 1 then c:SetPoint("BOTTOMLEFT", cards[i - 1], "TOPLEFT", 0, 6)
			elseif chat then c:SetPoint("BOTTOMLEFT", chat, "TOPLEFT", -4, 34)
			else c:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", 40, 260) end
		elseif at == "top" then
			if i > 1 then c:SetPoint("TOP", cards[i - 1], "BOTTOM", 0, -6)
			else c:SetPoint("TOP", UIParent, "TOP", 0, -110) end
		else
			if i > 1 then c:SetPoint("TOPRIGHT", cards[i - 1], "BOTTOMRIGHT", 0, -6)
			else c:SetPoint("TOPRIGHT", corner, "TOPLEFT", -8, -8) end
		end
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
	if ns.Quiet() then return nil end
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
		key = "m" .. p.id, title = L.CARD_MENTION:format(who), icon = ns.ICON_MENTION,
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
	if ns.Quiet() then held[c.id] = true return end
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
	if ns.Quiet() then held[c.id] = true return end
	local UI = UIx()
	local class = (LOCALIZED_CLASS_NAMES_MALE or {})[ask.class] or ask.class
	local where = ask.yards and L.YARDS_AWAY:format(ask.yards) or (ask.zone ~= "" and L.IN_ZONE:format(ask.zone) or "")
	Popups.Card({
		key = "a" .. c.id .. ask.name, kind = c.kind, life = Popups.ASK_LIFE,
		title = ask.role and L.CARD_ASK_AS:format(UI.Hex(UI.ClassColor(ask.class), ns.DisplayName(ask.name)), UI.RoleIcon(ask.role) .. " " .. L["ROLE_" .. ask.role])
			or L.CARD_ASK:format(UI.Hex(UI.ClassColor(ask.class), ns.DisplayName(ask.name))),
		body = L.ASK_BODY:format(ask.level, class or "?", where, UI.CallTitle(c)),
		buttons = {
			{ label = L.INVITE, go = function() ns.Calls.Decide(c.id, ask.name, true) end, kind = "main" },
			{ label = L.NO, go = function() ns.Calls.Decide(c.id, ask.name, false) end },
		},
	})
end

-- Every card closed (on the way into a group instance).
function Popups.CloseAll()
	for i = #cards, 1, -1 do Close(cards[i]) end
end

-- Cards shown now (for the test bench).
function Popups.Count() return #cards end

-- On the way out of a group instance: the held calls still live, each as its card (the rare
-- only if it is in the zone the player is now in, as any card); asks on the player's own calls.
function Popups.CatchUp()
	local ids = held
	held = {}
	for id in pairs(ids) do
		local c = ns.Calls.Get(id)
		if c and ns.Calls.Shown(c) then
			if c.mine then Popups.ShowAsks(c) else Popups.Call(c) end
		end
	end
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
local rolePick, roleMax = nil, 4 -- the dialog's roles: { T, H, D } counts (nil: no roles row), the open spots
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
	d.title:SetWidth(290)
	d.title:SetJustifyH("CENTER")
	ns.UI.Wrap(d.title)
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
	-- Roles needed (a group call): the group finder's round icons. Tank and healer: needed or
	-- not; damage counts 1, 2, 3, then none. Never more than the open spots (roleMax).
	d.roleLabel = UI.Font(d, nil, { 0.62, 0.58, 0.50 })
	d.roleTotal = UI.Font(d, "gold")
	d.roleButtons = {}
	local function RoleTotal() return rolePick.T + rolePick.H + rolePick.D end
	local function ShowRoles()
		for r, b in pairs(d.roleButtons) do
			local n = rolePick[r]
			b.icon:SetDesaturated(n == 0)
			b.icon:SetAlpha(n == 0 and 0.45 or 1)
			b.check:SetShown(n > 0)
			b.count:SetText(r == "D" and n > 1 and ("x" .. n) or "")
			b.name:SetTextColor(unpack(n > 0 and { 0.93, 0.90, 0.84 } or { 0.62, 0.58, 0.50 }))
		end
		local total = RoleTotal()
		d.roleTotal:SetText(L.NEEDS_TOTAL:format(total))
		d.ok:SetOn(total > 0)
	end
	for i, r in ipairs({ "T", "H", "D" }) do
		local b = CreateFrame("Button", nil, d)
		b:SetSize(40, 40)
		b.icon = b:CreateTexture(nil, "ARTWORK")
		b.icon:SetAllPoints()
		b.icon:SetTexture(UI.ROLE_TEX)
		local q = UI.ROLE_COORDS[r]
		b.icon:SetTexCoord(q[1] / 256, q[2] / 256, q[3] / 256, q[4] / 256)
		-- The game's checkbox at the lower left, as the group finder's role buttons have it.
		b.box = b:CreateTexture(nil, "OVERLAY")
		b.box:SetSize(20, 20)
		b.box:SetPoint("BOTTOMLEFT", -5, -5)
		b.box:SetTexture("Interface\\Buttons\\UI-CheckBox-Up")
		b.check = b:CreateTexture(nil, "OVERLAY", nil, 1)
		b.check:SetAllPoints(b.box)
		b.check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
		b.count = UI.Font(b, "big")
		b.count:SetPoint("TOPRIGHT", 8, 2)
		b.count:SetShadowOffset(1, -1)
		b.name = UI.Font(b, "dim")
		b.name:SetPoint("TOP", b, "BOTTOM", 0, -5)
		b.name:SetText(L["ROLE_" .. r])
		b.shine = b:CreateTexture(nil, "HIGHLIGHT")
		b.shine:SetAllPoints()
		b.shine:SetTexture(UI.ROLE_TEX)
		b.shine:SetTexCoord(q[1] / 256, q[2] / 256, q[3] / 256, q[4] / 256)
		b.shine:SetBlendMode("ADD")
		b.shine:SetAlpha(0.3)
		b:SetScript("OnClick", function()
			local n, room = rolePick[r], roleMax - RoleTotal()
			if r == "D" then
				n = (n < 3 and room > 0) and n + 1 or 0
			else
				n = (n == 0 and room > 0) and 1 or 0
			end
			rolePick[r] = n
			ShowRoles()
		end)
		b:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_TOP")
			GameTooltip:SetText(L["ROLE_" .. r])
			GameTooltip:AddLine(r == "D" and L.ROLE_TIP_D or L.ROLE_TIP, 1, 1, 1, true)
			GameTooltip:Show()
		end)
		b:SetScript("OnLeave", function() GameTooltip:Hide() end)
		d.roleButtons[r] = b
	end
	d.ShowRoles = ShowRoles
	d.ok = UI.Button(d, "OK", nil, "main")
	d.ok:SetPoint("BOTTOMRIGHT", d, "BOTTOM", -3, 16)
	d.cancel = UI.Button(d, L.CANCEL, function() d:Hide() end, "line")
	d.cancel:SetPoint("BOTTOMLEFT", d, "BOTTOM", 3, 16)
	d.okButton = d.ok
	if UISpecialFrames then table.insert(UISpecialFrames, "Pugger_Dialog") end
	dialog = d
	return d
end

---------------------------------------------------------------------------
-- Setup: where Pugger's button and its cards go. Shown once at the first launch, and from the
-- menu or /pug setup. Each choice applies at once (a sample card shows where cards will be).
---------------------------------------------------------------------------

local SETUP = {
	{ key = "launcher", label = "SETUP_BUTTON", opts = { { "chat", "WHERE_CHAT" }, { "minimap", "WHERE_MINIMAP" }, { "both", "WHERE_BOTH" } } },
	{ key = "cardsAt", label = "SETUP_CARDS", opts = { { "chat", "CARDS_CHAT" }, { "minimap", "CARDS_MINIMAP" }, { "top", "CARDS_TOP" } } },
}
local setup

function Popups.Setup()
	local UI = UIx()
	local s = ns.db.settings
	if not setup then
		local d = CreateFrame("Frame", "Pugger_Setup", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
		UI.Backdrop(d, { 1, 1, 1, 1 }, { 1, 1, 1, 1 }, "dialog")
		d:SetSize(370, 252)
		d:SetPoint("CENTER", 0, 120)
		d:SetFrameStrata("DIALOG")
		d:EnableMouse(true)
		d:SetMovable(true)
		d:RegisterForDrag("LeftButton")
		d:SetScript("OnDragStart", d.StartMoving)
		d:SetScript("OnDragStop", d.StopMovingOrSizing)
		d.title = UI.Font(d, "title")
		d.title:SetPoint("TOP", 0, -18)
		d.title:SetText(L.SETUP_TITLE)
		d.body = UI.Font(d, nil)
		d.body:SetPoint("TOP", d.title, "BOTTOM", 0, -6)
		d.body:SetWidth(320)
		d.body:SetJustifyH("CENTER")
		ns.UI.Wrap(d.body)
		d.body:SetText(L.SETUP_BODY)
		d.rows = {}
		for r, row in ipairs(SETUP) do
			local label = UI.Font(d, nil, { 0.62, 0.58, 0.50 })
			label:SetPoint("TOP", d, "TOP", 0, -92 - (r - 1) * 52)
			label:SetText(L[row.label])
			local buttons = {}
			for i, o in ipairs(row.opts) do
				buttons[i] = UI.Button(d, L[o[2]], function()
					s[row.key] = o[1]
					Popups.Setup()
					if row.key == "launcher" then ns.UI.ApplyLauncher()
					else
						Layout()
						Popups.Card({ key = "setup", title = L.SETUP_SAMPLE, body = L.SETUP_SAMPLE_BODY, life = 8, sound = false })
					end
				end, "line")
			end
			d.rows[r] = { def = row, label = label, buttons = buttons }
		end
		d.done = UI.Button(d, L.DONE, function() d:Hide() end, "main")
		d.done:SetPoint("BOTTOM", 0, 16)
		d:SetScript("OnHide", function() s.setupDone = true Popups.CloseKey("setup") end)
		if UISpecialFrames then table.insert(UISpecialFrames, "Pugger_Setup") end
		setup = d
	end
	-- The choices, each row centred under its label, the one in use lit.
	for _, row in ipairs(setup.rows) do
		local total = 0
		for i, b in ipairs(row.buttons) do
			b.kind = (s[row.def.key] == row.def.opts[i][1]) and "main" or "line"
			b:SetOn(true)
			total = total + (b:GetWidth() or 80) + (i > 1 and 6 or 0)
		end
		local x = -total / 2
		for _, b in ipairs(row.buttons) do
			b:ClearAllPoints()
			b:SetPoint("TOPLEFT", row.label, "BOTTOM", x, -6)
			x = x + (b:GetWidth() or 80) + 6
		end
	end
	setup:Show()
end

-- spec: { title, body, edits = { { label, text, max } }, roles = { max, pick = "THDD" },
-- ok, cancel (false: none), go = fn(t1, t2, roles) }
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
	if spec.roles then
		local n = ns.Calls.RoleCounts(spec.roles.pick)
		rolePick, roleMax = { T = n.T, H = n.H, D = n.D }, spec.roles.max or 4
		y = y - 14
		d.roleLabel:ClearAllPoints()
		-- "Roles needed" and "Needs 4" on one line (as wide as the boxes above), the three
		-- buttons centred under it, each with its name below.
		d.roleLabel:SetPoint("TOPLEFT", d, "TOP", -132, y + 13)
		d.roleLabel:SetText(L.ROLES_NEEDED)
		d.roleLabel:Show()
		d.roleTotal:ClearAllPoints()
		d.roleTotal:SetPoint("TOPRIGHT", d, "TOP", 138, y + 13)
		d.roleTotal:Show()
		for i, r in ipairs({ "T", "H", "D" }) do
			local b = d.roleButtons[r]
			b:ClearAllPoints()
			b:SetPoint("TOP", d, "TOP", 3 + (i - 2) * 76, y - 8)
			b:Show()
		end
		y = y - 70
	else
		rolePick = nil
		d.roleLabel:Hide()
		d.roleTotal:Hide()
		for _, b in pairs(d.roleButtons) do b:Hide() end
	end
	d:SetHeight(-y + 50)
	d.ok:SetLabel(spec.ok or "OK")
	d.ok:SetOn(true)
	if rolePick then d.ShowRoles() end
	d.ok:SetScript("OnClick", function()
		if rolePick and rolePick.T + rolePick.H + rolePick.D == 0 then return end
		d:Hide()
		local roles = rolePick and ns.Calls.Roles(rolePick.T, rolePick.H, rolePick.D)
		if spec.go then ns.SafeCall("dialog", spec.go, d.edits[1]:GetText(), d.edits[2]:GetText(), roles) end
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
	-- The open spots: a group of five, less the players already in it.
	local open = math.max(1, 4 - math.max(0, (GetNumGroupMembers and GetNumGroupMembers() or 0) - 1))
	if s then
		return Popups.Dialog({
			title = s.name, body = L.DUNGEON_BODY:format(s.lo, s.hi),
			edits = { { label = L.NOTE, max = ns.Calls.NOTE_MAX } },
			roles = { max = open, pick = ("THDD"):sub(1, open) },
			ok = L.LOOK_FOR_GROUP, go = function(note, _, roles) ns.Calls.Dungeon(s.key, roles, note) end,
		})
	end
	Popups.Dialog({
		title = L.CALL_GROUP, body = L.GROUP_BODY:format(ns.Calls.GROUP_YARDS),
		edits = { { label = L.GROUP_WHAT, max = 60 } },
		roles = { max = open, pick = "D" },
		ok = L.LOOK_FOR_GROUP, go = function(what, _, roles) ns.Calls.Group(what, roles) end,
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
