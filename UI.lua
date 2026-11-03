local ADDON, ns = ...

-- The feed's own window (section 9 of the plan), built from the game's own frames so it looks
-- like it belongs in WoW, as Guild Master Forever's does: the portrait frame (stone border, title
-- bar, close button, the Pugger icon in the round portrait), a dark inset holding the feed with
-- the game's scroll bar, the game's red panel buttons, tooltip-bordered cards, and icon tabs
-- hanging off both sides (RightSideTabTemplate, Guild Master Forever's SideTab): Realm,
-- Following, Mentions on the left; Groups, Nearby, Me on the right.
-- Narrow, docked under the minimap where the Objectives list sits, movable anywhere by its title,
-- lockable, collapsible, its height dragged at the bottom right. Never Blizzard's chat box: the
-- compose box is the add-on's own, and a shift-clicked link goes into it only while the player
-- has it focused. Nothing is drawn while the window is hidden; a change marks it dirty and it
-- redraws at most every REDRAW seconds.

local UI = {}
ns.UI = UI
local Codec, Store = ns.Codec, ns.Store
local L = setmetatable({}, { __index = function(_, k) return ns.L[k] end })

UI.WIDTH = 300
UI.HEIGHT = 470
UI.MIN_H, UI.MAX_H = 260, 900
UI.HEAD = 48          -- the title bar and the thin header under it (56 if the round portrait stays)
UI.ROW_W = 246        -- a card's width in the list (the inset less the scroll bar)
UI.REDRAW = 0.3
UI.ROWS_MAX = 60
UI.TAB_STEP = 46      -- between two side tabs

-- The mockup's colours: hex for text, { r, g, b, a } for backdrops.
local function RGB(hex, a)
	return { tonumber(hex:sub(1, 2), 16) / 255, tonumber(hex:sub(3, 4), 16) / 255, tonumber(hex:sub(5, 6), 16) / 255, a or 1 }
end
UI.RGB = RGB
local C = {
	gold = "ffe2b65c", text = "ffece5d6", dim = "ff9d9480", soft = "ffb3a98f", where = "ffc9c0ab", tag = "ff7fb6e8",
	rare = "ffff8f7a", camp = "ffc7dd86", quest = "ff8cc8f0", dungeon = "ff9fd18b", like = "ffe2667a",
	card = RGB("211c15"), edge = RGB("362c1f"), panel = RGB("1b1712", 0.96), panelEdge = RGB("6b5631"),
	button = RGB("e2b65c"), buttonText = RGB("1b1712"), lineEdge = RGB("6b5631"),
	offBg = RGB("2a251d"), offText = RGB("8d8471"), offEdge = RGB("3d3220"),
}
UI.C = C
local function Hex(c, s) return "|c" .. c .. tostring(s) .. "|r" end
UI.Hex = Hex

local TABS = {
	{ key = "realm", side = "left", label = "TAB_REALM", icon = "Interface\\Icons\\INV_Misc_Map_01" },
	{ key = "following", side = "left", label = "TAB_FOLLOWING", icon = "Interface\\Icons\\Spell_Holy_MindVision" },
	{ key = "mentions", side = "left", label = "TAB_MENTIONS", icon = ns.ICON_MENTION },
	{ key = "groups", side = "right", label = "TAB_GROUPS", icon = "Interface\\Icons\\Spell_Holy_PrayerOfFortitude" },
	{ key = "nearby", side = "right", label = "TAB_NEARBY", icon = "Interface\\Icons\\INV_Misc_Spyglass_02" },
	{ key = "me", side = "right", label = "TAB_ME", portrait = true },
}

local frame
local combatHidden, quietHidden -- the window put away by the add-on (combat, a group instance), to come back
local view = { tab = "realm" } -- + sub = { thread = id } | { tag = "x" } | { author = name }
local dirty, lastDraw = true, 0
local replyTo -- post id the compose box answers

---------------------------------------------------------------------------
-- Small parts
---------------------------------------------------------------------------

local function Template(kind, name, parent, template)
	local ok, f = pcall(CreateFrame, kind, name, parent, template)
	if ok and f then return f, true end
	return CreateFrame(kind, name, parent), false
end
UI.Template = Template

-- The mockup's fonts, bundled (media/fonts, SIL Open Font License): Cinzel for titles, Source
-- Sans 3 for everything else. Font objects of our own; the game's own fonts are untouched.
local FONT_DIR = "Interface\\AddOns\\Pugger\\media\\fonts\\"
local FONT_DEFS = {
	title = { "Cinzel-Bold.ttf", 15 },      -- the view's name beside the portrait
	big = { "SourceSans3-Bold.ttf", 13 },   -- names, card titles
	body = { "SourceSans3-Regular.ttf", 13 }, -- post text
	small = { "SourceSans3-Regular.ttf", 11 }, -- meta, hints, where
	label = { "SourceSans3-Bold.ttf", 10 },  -- RARE CALL, CAMP...
	button = { "SourceSans3-Semibold.ttf", 11 },
	badge = { "SourceSans3-Bold.ttf", 9 },
}
local fontObjects = {}
local function FontObject(kind)
	if fontObjects[kind] then return fontObjects[kind] end
	local def = FONT_DEFS[kind] or FONT_DEFS.small
	local f = CreateFont("Pugger_Font_" .. kind)
	-- (SetFont returns nothing on some clients: GetFont says whether the file took.)
	if f and f.SetFont then pcall(f.SetFont, f, FONT_DIR .. def[1], def[2], "") end
	if not (f and f.GetFont and f:GetFont()) then
		-- (Without the file: the game's own font of that size.)
		if f and f.SetFontObject then f:SetFontObject(def[2] >= 13 and "GameFontHighlight" or "GameFontHighlightSmall") end
	end
	fontObjects[kind] = f
	return f
end
UI.FontObject = FontObject

-- A backdrop: "flat" (the default: the mockup's cards and buttons, a 1-pixel edge), "tooltip"
-- (menus) or "dialog" (the game's popup dialogs' border). bg and border tint it.
local STYLES = {
	flat = { bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 },
	tooltip = { bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true, tileSize = 16, edgeSize = 14, insets = { left = 3, right = 3, top = 3, bottom = 3 } },
	dialog = { bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background", edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		tile = true, tileSize = 32, edgeSize = 32, insets = { left = 11, right = 12, top = 12, bottom = 11 } },
}
local function Backdrop(f, bg, border, style)
	if not f.SetBackdrop and BackdropTemplateMixin then Mixin(f, BackdropTemplateMixin) end
	if not f.SetBackdrop then return end
	f:SetBackdrop(STYLES[style or "flat"])
	f:SetBackdropColor(unpack(bg or C.card))
	f:SetBackdropBorderColor(unpack(border or C.edge))
end
UI.Backdrop = Backdrop

-- Lets a font string break inside a word too (a long word without spaces would otherwise be cut
-- with "..."), and grow to as many lines as it needs.
local function Wrap(fs)
	fs:SetWordWrap(true)
	if fs.SetNonSpaceWrap then fs:SetNonSpaceWrap(true) end
	if fs.SetMaxLines then fs:SetMaxLines(0) end
	return fs
end
UI.Wrap = Wrap

-- A font string in the mockup's font and colour. kind: nil the post text, "big" bold, "title"
-- Cinzel gold, "gold" small gold, "dim" small grey, "soft", "where", "label", "badge".
local FONT_KIND = { gold = "small", dim = "small", soft = "small", where = "small" }
local FONT_COLOR = { title = C.gold, gold = C.gold, dim = C.dim, soft = C.soft, where = C.where }
local function Font(parent, kind, color)
	local fs = parent:CreateFontString(nil, "OVERLAY")
	fs:SetFontObject(FontObject(FONT_KIND[kind] or kind or "body"))
	fs:SetJustifyH("LEFT")
	if color then fs:SetTextColor(unpack(color))
	else fs:SetTextColor(unpack(RGB((FONT_COLOR[kind] or C.text):sub(3)))) end
	return fs
end
UI.Font = Font

-- A button as the mockup draws them: "main" filled gold, "line" outlined gold, "text" bare
-- (a post's Reply, Repost, Like); greyed when off.
local function Button(parent, label, onClick, kind)
	kind = kind or "line"
	local b = CreateFrame("Button", nil, parent, BackdropTemplateMixin and "BackdropTemplate" or nil)
	b.kind = kind
	b.label = b:CreateFontString(nil, "OVERLAY")
	b.label:SetFontObject(FontObject("button"))
	b.label:SetPoint("CENTER", 0, 0)
	if kind ~= "text" then
		b.shine = b:CreateTexture(nil, "HIGHLIGHT")
		b.shine:SetAllPoints()
		b.shine:SetColorTexture(1, 1, 1, 0.08)
	end
	function b:SetLabel(text)
		self.label:SetText(text)
		local w = self.label:GetStringWidth() or 30
		if self.kind == "text" then self:SetSize(w + 4, 16) else self:SetSize(math.max(26, w + 16), 20) end
	end
	function b:SetOn(enabled)
		enabled = enabled and true or false
		self:SetEnabled(enabled)
		if self.kind == "text" then
			self.label:SetTextColor(unpack(enabled and RGB(C.soft:sub(3)) or C.offText))
		elseif not enabled then
			Backdrop(self, C.offBg, C.offEdge)
			self.label:SetTextColor(unpack(C.offText))
		elseif self.kind == "main" then
			Backdrop(self, C.button, C.button)
			self.label:SetTextColor(unpack(C.buttonText))
		else
			Backdrop(self, { 0, 0, 0, 0 }, C.lineEdge)
			self.label:SetTextColor(unpack(C.button))
		end
	end
	if kind == "text" then
		b:SetScript("OnEnter", function(self) if self:IsEnabled() then self.label:SetTextColor(unpack(RGB(C.text:sub(3)))) end end)
		b:SetScript("OnLeave", function(self) self:SetOn(self:IsEnabled()) end)
	end
	b:SetScript("OnClick", function(self, ...) if onClick then ns.SafeCall("button", onClick, self, ...) end end)
	b:SetLabel(label or "")
	b:SetOn(true)
	return b
end
UI.Button = Button

-- A small menu of our own, in a tooltip's border (never UIDropDownMenu, which taints):
-- items { text, go, check, title, disabled }.
function UI.Menu()
	local m = CreateFrame("Frame", nil, UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
	Backdrop(m, RGB("1b1712"), C.panelEdge) -- (opaque: nothing shows through)
	m:SetFrameStrata("DIALOG")
	m:SetClampedToScreen(true)
	m:EnableMouse(true)
	m:Hide()
	m.rows = {}
	function m:Open(anchor, items)
		for _, r in ipairs(self.rows) do r:Hide() end
		local y, w = -8, 120
		for i, it in ipairs(items) do
			local r = self.rows[i]
			if not r then
				r = CreateFrame("Button", nil, self)
				r:SetHeight(18)
				r.text = r:CreateFontString(nil, "OVERLAY")
				r.text:SetPoint("LEFT", 22, 0)
				r.check = r:CreateTexture(nil, "ARTWORK")
				r.check:SetSize(14, 14)
				r.check:SetPoint("LEFT", 4, 0)
				r.check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
				r:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
				self.rows[i] = r
			end
			r.text:SetFontObject(FontObject(it.title and "label" or "button"))
			r.text:SetTextColor(unpack(it.title and C.button or RGB("ece5d6")))
			r.text:ClearAllPoints()
			r.text:SetPoint("LEFT", it.title and 8 or 22, 0)
			r.text:SetText(it.text)
			if it.check then r.check:Show() else r.check:Hide() end
			r:SetEnabled(not it.title and not it.disabled)
			r:SetScript("OnClick", function()
				self:Hide()
				if it.go then ns.SafeCall("menu", it.go) end
			end)
			r:ClearAllPoints()
			r:SetPoint("TOPLEFT", 4, y)
			r:SetPoint("TOPRIGHT", -4, y)
			r:Show()
			w = math.max(w, (r.text:GetStringWidth() or 100) + 34)
			y = y - 18
		end
		self:SetSize(w, -y + 8)
		self:ClearAllPoints()
		-- Beside what was clicked; in the middle of the screen when that isn't shown.
		if anchor and anchor ~= UIParent and anchor.IsVisible and anchor:IsVisible() then
			self:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
		else
			self:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
		end
		self:Show()
	end
	m:SetScript("OnShow", function(self) self.shownAt = GetTime() end)
	m:SetScript("OnUpdate", function(self)
		-- A click anywhere else closes it.
		if GetTime() - (self.shownAt or 0) > 0.2 and IsMouseButtonDown and IsMouseButtonDown("LeftButton") and not self:IsMouseOver() then self:Hide() end
	end)
	return m
end
local menu

---------------------------------------------------------------------------
-- Text: links, #tags and @mentions made clickable (pug: links, read by the row itself, never
-- by SetItemRef).
---------------------------------------------------------------------------

local function Decorate(s)
	local out, i = {}, 1
	local function Plain(seg)
		seg = seg:gsub("([%s%p]?)#([%w_]+)", function(pre, tag)
			if pre == "|" then return pre .. "#" .. tag end
			return ("%s|Hpug:tag:%s|h|c%s#%s|r|h"):format(pre, tag:lower(), C.tag, tag)
		end)
		seg = seg:gsub("([%s%p]?)@([%a\128-\255]+)", function(pre, name)
			if pre == "|" then return pre .. "@" .. name end
			return ("%s|Hpug:at:%s|h|c%s@%s|r|h"):format(pre, name:lower(), C.tag, name)
		end)
		return seg
	end
	while i <= #s do
		local j = s:find("|", i, true)
		if not j then out[#out + 1] = Plain(s:sub(i)) break end
		if j > i then out[#out + 1] = Plain(s:sub(i, j - 1)) end
		if s:byte(j + 1) == 124 then
			out[#out + 1] = "||"
			i = j + 2
		else
			local len = Codec.LinkAt(s, j)
			if len then
				out[#out + 1] = s:sub(j, j + len - 1)
				i = j + len
			else
				out[#out + 1] = "||"
				i = j + 1
			end
		end
	end
	return table.concat(out)
end
UI.Decorate = Decorate

local function ClassColor(class)
	local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
	if c and c.colorStr then return c.colorStr end
	if c then return ("ff%02x%02x%02x"):format(c.r * 255, c.g * 255, c.b * 255) end
	return C.gold
end
UI.ClassColor = ClassColor

local CLASS_NAMES = LOCALIZED_CLASS_NAMES_MALE or {}
-- A name in its class colour (from the profile, or the class a message carried), and the profile.
function UI.Who(name, class)
	local pr = ns.rdb.profiles[name] or (ns.Demo and ns.Demo.profiles[name])
	local color = ClassColor((pr and pr.class ~= "" and pr.class) or class or (name == ns.me and select(2, UnitClass("player"))))
	return Hex(color, ns.DisplayName(name)), pr
end
local function Name(name, class) return (UI.Who(name, class)) end
UI.Name = Name
local function Meta(pr)
	if not pr or not pr.level then return "" end
	local class = CLASS_NAMES[pr.class or ""] or ((pr.class or ""):sub(1, 1) .. (pr.class or ""):sub(2):lower())
	return ("%s %d"):format(class, pr.level)
end

local function Short(t)
	local d = math.max(0, ns.Now() - (t or 0))
	if d < 60 then return L.NOW_SHORT end
	if d < 3600 then return math.floor(d / 60) .. "m" end
	if d < 86400 then return math.floor(d / 3600) .. "h" end
	return math.floor(d / 86400) .. "d"
end

-- A place as a post shows it: "Durotar (45, 12)", or the zone alone without coordinates.
local function Place(m, x, y)
	if not m then return nil end
	if not x then return ns.Calls.ZoneName(m) end
	return ("%s (%d, %d)"):format(ns.Calls.ZoneName(m), x * 100, y * 100)
end

-- Where the player is, as their next post will show it.
function UI.MySpot() return Place(ns.Calls.MyPlace()) end

function UI.PinText(pin) return Place(Codec.DecodePin(pin)) end

---------------------------------------------------------------------------
-- Calls as words
---------------------------------------------------------------------------

-- The game's round role icons (the group finder's): one texture, a 67-pixel square each.
UI.ROLE_TEX = "Interface\\LFGFrame\\UI-LFG-ICON-ROLES"
UI.ROLE_COORDS = { T = { 0, 67, 67, 134 }, H = { 67, 134, 0, 67 }, D = { 67, 134, 67, 134 } }

-- A role's icon inside text, size pixels.
function UI.RoleIcon(r, size)
	local q = UI.ROLE_COORDS[r]
	if not q then return "" end
	size = size or 14
	return ("|T%s:%d:%d:0:0:256:256:%d:%d:%d:%d|t"):format(UI.ROLE_TEX, size, size, q[1], q[2], q[3], q[4])
end

-- A call's roles as icons, one each ("THDD": shield, cross, sword, sword).
function UI.RoleIcons(roles)
	local out = {}
	for r in tostring(roles or ""):gmatch("[THD]") do out[#out + 1] = UI.RoleIcon(r) end
	return table.concat(out, "")
end

-- Ask to join: with the role to fill picked from what the call needs and this player's class
-- can do (one: asked straight away; several: a menu at the button).
function UI.AskJoin(c, anchor)
	if not c.roles then return ns.Calls.Ask(c.id) end
	local roles = ns.Calls.MyRoles(c)
	if #roles == 1 then return ns.Calls.Ask(c.id, roles[1]) end
	local items = { { text = L.ASK_AS, title = true } }
	for _, r in ipairs(roles) do
		items[#items + 1] = { text = UI.RoleIcon(r, 16) .. "  " .. L["ROLE_" .. r], go = function() ns.Calls.Ask(c.id, r) end }
	end
	UI.MenuAt(anchor, items)
end

function UI.CallTitle(c)
	if c.kind == "R" then return ("%s (%s)"):format(c.a, ns.Calls.CLASS_NAME[c.b] or "rare") end
	if c.kind == "C" then return c.note ~= "" and c.note or L.CAMP_DEFAULT end
	local what = c.kind == "G" and (c.a ~= "" and c.a or L.GROUP_DEFAULT) or (c.stone and c.stone.name or "?")
	if c.roles then return L.NEED_ROLES:format(UI.RoleIcons(c.roles), what) end
	if c.kind == "G" or c.kind == "D" then return L.NEED_N:format(c.need or 1, what) end
	return "?"
end

function UI.CallWhere(c)
	local zone = ns.Calls.ZoneName(c.map)
	if c.kind == "G" then
		local d = ns.Calls.DistanceToMe(c.map, c.x, c.y)
		return d and L.YARDS_AWAY:format(math.floor(d)) or zone
	end
	if c.kind == "D" then return L.AT_STONE_IN:format(zone) end
	return ("%s (%d, %d)"):format(zone, c.x * 100, c.y * 100)
end

local KIND = {
	R = { label = "KIND_RARE", color = C.rare, icon = "Interface\\TargetingFrame\\UI-TargetingFrame-Skull", bg = RGB("2a1715"), border = RGB("8a3b2e") },
	C = { label = "KIND_CAMP", color = C.camp, icon = "Interface\\Icons\\Spell_Fire_Fire", bg = RGB("1d2016"), border = RGB("5b6b33") },
	G = { label = "KIND_QUEST", color = C.quest, icon = "Interface\\Icons\\INV_Misc_Note_01", bg = RGB("16202a"), border = RGB("3b6a8a") },
	D = { label = "KIND_DUNGEON", color = C.dungeon, icon = "Interface\\Icons\\Spell_Holy_PrayerOfFortitude", bg = RGB("18221a"), border = RGB("4f7a45") },
}
UI.KIND = KIND

---------------------------------------------------------------------------
-- Rows: posts and calls, from pools, laid out top to bottom in the scroll child.
---------------------------------------------------------------------------

local postPool, callPool, linePool = {}, {}, {}
local shown = {}

local function OnLinkEnter(self, link)
	local kind = link:match("^(%a+):")
	if kind and Codec.LINK_TYPES[kind] then
		GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
		if pcall(GameTooltip.SetHyperlink, GameTooltip, link) then GameTooltip:Show() else GameTooltip:Hide() end
	end
end
local function OnLinkClick(self, link, text)
	local tag = link:match("^pug:tag:(.+)$")
	if tag then return UI.Open({ tag = tag }) end
	local at = link:match("^pug:at:(.+)$")
	if at then return UI.OpenName(at) end
	local kind = link:match("^(%a+):")
	if kind and Codec.LINK_TYPES[kind] and IsShiftKeyDown and IsShiftKeyDown() then UI.InsertLink(text) end
end

local function NewPostRow(parent)
	local r = CreateFrame("Frame", nil, parent, BackdropTemplateMixin and "BackdropTemplate" or nil)
	Backdrop(r)
	r:SetWidth(UI.ROW_W)
	if r.SetHyperlinksEnabled then r:SetHyperlinksEnabled(true) end
	r:SetScript("OnHyperlinkEnter", OnLinkEnter)
	r:SetScript("OnHyperlinkLeave", function() GameTooltip:Hide() end)
	r:SetScript("OnHyperlinkClick", OnLinkClick)
	r.nameBtn = CreateFrame("Button", nil, r)
	r.name = Font(r.nameBtn, "big")
	r.name:SetPoint("LEFT")
	r.nameBtn:SetPoint("TOPLEFT", 8, -7)
	r.nameBtn:SetHeight(14)
	r.nameBtn:SetScript("OnClick", function(self) if self.author then UI.Open({ author = self.author }) end end)
	r.meta = Font(r, "dim")
	r.meta:SetPoint("LEFT", r.nameBtn, "RIGHT", 5, 0)
	r.meta:SetPoint("RIGHT", r, "RIGHT", -8, 0)
	r.meta:SetWordWrap(false)
	r.note = Font(r, "dim") -- "reposted by", "unverified", "reply to"
	r.text = Font(r, "body")
	r.text:SetWidth(UI.ROW_W - 18)
	Wrap(r.text)
	if r.text.SetSpacing then r.text:SetSpacing(2) end
	r.pinIcon = r:CreateTexture(nil, "ARTWORK")
	r.pinIcon:SetSize(12, 12)
	r.pinIcon:SetTexture("Interface\\Minimap\\Tracking\\None")
	r.pin = Font(r, "gold")
	r.pinBtn = CreateFrame("Button", nil, r)
	r.pinBtn:SetAllPoints(r.pin)
	r.pinBtn:SetScript("OnClick", function(self)
		local m, x, y = Codec.DecodePin(self.pin or "")
		if m and x then UI.PinOnMap({ map = m, x = x, y = y, kind = "P" }) end
	end)
	r.pinBtn:SetScript("OnEnter", function(self)
		local _, x = Codec.DecodePin(self.pin or "")
		if not x then return end
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText(L.SPOT_TIP_POST)
		GameTooltip:Show()
	end)
	r.pinBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
	r.line = r:CreateTexture(nil, "ARTWORK")
	r.line:SetHeight(1)
	r.line:SetColorTexture(unpack(C.edge))
	r.reply = Button(r, "", function(b) UI.StartReply(b:GetParent().post) end, "text")
	r.repost = Button(r, "", function(b) ns.Feed.Repost(b:GetParent().post) end, "text")
	r.like = Button(r, "", function(b) ns.Feed.Like(b:GetParent().post) end, "text")
	r.more = Button(r, "...", function(b) UI.PostMenu(b, b:GetParent().post) end, "text")
	r.open = Button(r, "", function(b) UI.Open({ thread = ns.Feed.Root(b:GetParent().post) }) end, "text")
	return r
end

-- Fills a post row; returns its height.
local function FillPost(r, p)
	local shownPost = p
	local note = nil
	if p.f == "r" and p.par then
		local o = Store.Get(p.par)
		note = L.REPOSTED_BY:format(Name(p.a))
		if o then shownPost = o else note = note .. " " .. L.ORIGINAL_MISSING end
	elseif p.f == "p" and p.par and view.sub == nil then
		local o = Store.Get(p.par)
		note = L.REPLY_TO:format(o and Name(o.a) or "?")
	end
	local unverified = (shownPost.v == nil and shownPost.a ~= ns.me and not shownPost.demo) or shownPost.demoUnverified == true
	if unverified then note = (note and (note .. " · ") or "") .. L.UNVERIFIED end
	r.post = shownPost.id
	local who, pr = UI.Who(shownPost.a)
	r.name:SetText(who)
	r.nameBtn:SetWidth((r.name:GetStringWidth() or 60) + 2)
	r.nameBtn.author = shownPost.a
	local meta = Meta(pr)
	r.meta:SetText((meta ~= "" and (meta .. " · ") or "") .. Short(shownPost.t))
	local y = -24
	if note then
		r.note:ClearAllPoints()
		r.note:SetPoint("TOPLEFT", 8, y)
		r.note:SetText(note)
		r.note:Show()
		y = y - 13
	else
		r.note:Hide()
	end
	r.text:ClearAllPoints()
	r.text:SetPoint("TOPLEFT", 8, y)
	r.text:SetText(shownPost.x ~= "" and Decorate(shownPost.x) or Hex(C.dim, L.EMPTY_REPOST))
	y = y - math.max(13, r.text:GetStringHeight() or 13) - 4
	-- Every post says where it was written; one without (an old or changed copy) says so.
	local pinText = shownPost.pin and UI.PinText(shownPost.pin)
	if not pinText and shownPost.x ~= "" and not shownPost.demo then pinText = Hex(C.dim, L.NO_PLACE) end
	if pinText then
		r.pinIcon:ClearAllPoints()
		r.pinIcon:SetPoint("TOPLEFT", 7, y)
		r.pinIcon:Show()
		r.pin:ClearAllPoints()
		r.pin:SetPoint("LEFT", r.pinIcon, "RIGHT", 3, 0)
		r.pin:SetText(pinText)
		r.pin:Show()
		r.pinBtn.pin = shownPost.pin
		r.pinBtn:Show()
		y = y - 15
	else
		r.pin:Hide()
		r.pinIcon:Hide()
		r.pinBtn:Hide()
	end
	r.line:ClearAllPoints()
	r.line:SetPoint("TOPLEFT", 6, y)
	r.line:SetPoint("TOPRIGHT", -6, y)
	y = y - 3
	local liked = shownPost.lk and shownPost.lk[ns.me]
	r.reply:SetLabel(L.REPLY_N:format(Store.Replies(shownPost)))
	r.repost:SetLabel(L.REPOST_N:format(Store.Reposts(shownPost)))
	r.like:SetLabel((liked and Hex(C.like, L.LIKED_N) or L.LIKE_N):format(Store.Likes(shownPost)))
	local x = 6
	for _, b in ipairs({ r.reply, r.repost, r.like }) do
		b:ClearAllPoints()
		b:SetPoint("TOPLEFT", x, y)
		b:SetEnabled(not unverified)
		x = x + (b:GetWidth() or 40) + 8
	end
	r.more:ClearAllPoints()
	r.more:SetPoint("TOPRIGHT", -6, y)
	local replies = Store.Replies(shownPost)
	if view.sub == nil and replies > 0 then
		r.open:SetLabel(L.OPEN_THREAD)
		r.open:ClearAllPoints()
		r.open:SetPoint("RIGHT", r.more, "LEFT", -6, 0)
		r.open:Show()
	else
		r.open:Hide()
	end
	y = y - 20
	r:SetAlpha(unverified and 0.55 or 1)
	r:SetHeight(-y)
	return -y
end

local function NewCallRow(parent)
	local r = CreateFrame("Frame", nil, parent, BackdropTemplateMixin and "BackdropTemplate" or nil)
	r:SetWidth(UI.ROW_W)
	r.icon = r:CreateTexture(nil, "ARTWORK")
	r.icon:SetSize(14, 14)
	r.icon:SetPoint("TOPLEFT", 8, -7)
	r.kind = Font(r, "label")
	r.kind:SetPoint("LEFT", r.icon, "RIGHT", 4, 0)
	-- "AT THE STONE": the mockup's green tag.
	r.badge = CreateFrame("Frame", nil, r, BackdropTemplateMixin and "BackdropTemplate" or nil)
	Backdrop(r.badge, RGB("9fd18b"), RGB("9fd18b"))
	r.badge:SetHeight(12)
	r.badge.text = Font(r.badge, "badge", C.buttonText)
	r.badge.text:SetPoint("CENTER", 0, 0)
	r.badge:SetPoint("LEFT", r.kind, "RIGHT", 5, 0)
	r.time = Font(r, "dim")
	r.title = Font(r, "big")
	r.title:SetWidth(UI.ROW_W - 16)
	Wrap(r.title)
	r.where = Font(r, "where")
	r.where:SetWidth(UI.ROW_W - 16)
	Wrap(r.where)
	r.buttons = {}
	return r
end

-- The buttons a call card shows: { label, go, kind, disabled }.
function UI.CallActions(c)
	local Calls = ns.Calls
	local acts = {}
	local function Add(label, go, kind, disabled) acts[#acts + 1] = { label = label, go = go, kind = kind or "line", disabled = disabled } end
	if c.ended then
		Add(L["ENDED_" .. c.ended:upper()] or L.ENDED_X, nil, "line", true)
		return acts
	end
	if c.mine then
		local waiting = 0
		for _, a in pairs(c.asks or {}) do if a.state == "waiting" then waiting = waiting + 1 end end
		if (c.kind == "G" or c.kind == "D") and waiting > 0 then Add(L.ASKS_N:format(waiting), function() ns.Popups.ShowAsks(c) end, "main") end
		if c.kind == "C" then Add(L.RENEW, function() Calls.Renew(c.id) end) end
		if c.kind == "R" then Add(L.DEAD, function() Calls.Vote(c.id, "d") end) end
		Add(L.END_CALL, function() Calls.End(c.id, "x") end)
		return acts
	end
	if c.kind == "R" then
		local mineVote = c.votes[ns.me]
		Add(mineVote == "u" and L.SAID_UP or L.STILL_UP, function() Calls.Vote(c.id, "u") end, "main", mineVote == "u")
		Add(mineVote == "d" and L.SAID_DEAD or L.DEAD, function() Calls.Vote(c.id, "d") end, "line", mineVote == "d")
	elseif c.kind == "G" or c.kind == "D" then
		local why = Calls.CantAsk(c)
		Add(why or L.ASK_JOIN, function(b) UI.AskJoin(c, b) end, "main", why ~= nil)
	end
	Add(L.WHISPER, function() ns.Popups.Whisper(c.caller) end)
	Add(L.PIN, function() UI.PinOnMap(c) end)
	return acts
end

local function FillCall(r, c)
	local k = KIND[c.kind]
	Backdrop(r, k.bg, k.border)
	r.icon:SetTexture(k.icon)
	r.kind:SetText(Hex(k.color, L[k.label]))
	if c.kind == "D" then
		r.badge.text:SetText(c.stone and ns.Stones.Spot(c.stone) and L.AT_THE_STONE or L.AT_THE_STONE_UNCHECKED)
		r.badge:SetWidth((r.badge.text:GetStringWidth() or 60) + 8)
		r.badge:Show()
	else
		r.badge:Hide()
	end
	r.time:ClearAllPoints()
	r.time:SetPoint("LEFT", c.kind == "D" and r.badge or r.kind, "RIGHT", 5, 0)
	r.time:SetText(("%s · %s"):format(Short(c.t), Name(c.caller, c.cls)))
	local y = -24
	r.title:ClearAllPoints()
	r.title:SetPoint("TOPLEFT", 8, y)
	r.title:SetText(UI.CallTitle(c))
	y = y - math.max(14, r.title:GetStringHeight() or 14) - 2
	local detail
	if c.kind == "R" then
		local up = ns.Calls.Votes(c)
		detail = L.UP_N:format(up)
	elseif c.kind == "C" then
		detail = L.LEFT_MIN:format(math.max(0, math.floor((c.expires - ns.Now()) / 60)))
	elseif c.lo then
		detail = L.LEVELS:format(c.lo, c.hi)
	end
	if c.kind ~= "C" and c.note and c.note ~= "" then detail = (detail and (detail .. " · ") or "") .. c.note end
	r.where:ClearAllPoints()
	r.where:SetPoint("TOPLEFT", 8, y)
	r.where:SetText(UI.CallWhere(c) .. (detail and (" · " .. detail) or ""))
	y = y - math.max(12, r.where:GetStringHeight() or 12) - 6
	for _, b in ipairs(r.buttons) do b:Hide() end
	local x = 8
	for i, a in ipairs(UI.CallActions(c)) do
		local b = r.buttons[i]
		if not b or b.kind ~= a.kind then
			if b then b:Hide() end
			b = Button(r, "", nil, a.kind)
			r.buttons[i] = b
		end
		b:SetScript("OnClick", function(self) if a.go then ns.SafeCall("call action", a.go, self) end end)
		b:SetLabel(a.label)
		b:SetOn(not a.disabled)
		if x + (b:GetWidth() or 40) > UI.ROW_W - 8 then
			x = 8
			y = y - 23
		end
		b:ClearAllPoints()
		b:SetPoint("TOPLEFT", x, y)
		b:Show()
		x = x + (b:GetWidth() or 40) + 5
	end
	y = y - 27
	r:SetHeight(-y)
	return -y
end

-- A one-line row: a dungeon call inside the Realm timeline.
local function NewLineRow(parent)
	local r = CreateFrame("Button", nil, parent)
	r:SetWidth(UI.ROW_W)
	r:SetHeight(18)
	r.icon = r:CreateTexture(nil, "ARTWORK")
	r.icon:SetSize(14, 14)
	r.icon:SetPoint("LEFT", 4, 0)
	r.icon:SetTexture(KIND.D.icon)
	r.text = Font(r, "where")
	r.text:SetPoint("LEFT", r.icon, "RIGHT", 4, 0)
	r.text:SetPoint("RIGHT", -4, 0)
	r.text:SetWordWrap(false)
	r:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
	return r
end

local function Take(pool, make, parent)
	local r = table.remove(pool) or make(parent)
	r.pool = pool
	r:Show()
	shown[#shown + 1] = r
	return r
end

local function ClearRows()
	for _, r in ipairs(shown) do
		r:Hide()
		r:ClearAllPoints()
		table.insert(r.pool, r)
	end
	wipe(shown)
end

---------------------------------------------------------------------------
-- What each view lists: { post = p } | { call = c } | { line = text, go = fn }
---------------------------------------------------------------------------

local function Merge(posts, lines)
	local out = {}
	local i, j = 1, 1
	while posts[i] or lines[j] do
		local p, l = posts[i], lines[j]
		if p and (not l or p.t >= l.t) then out[#out + 1] = { post = p } i = i + 1
		else out[#out + 1] = l j = j + 1 end
	end
	return out
end

local function Items()
	local sub = view.sub
	if sub then
		local out = {}
		for _, p in ipairs(ns.Feed.Timeline(sub, UI.ROWS_MAX)) do out[#out + 1] = { post = p } end
		return out
	end
	local tab = view.tab
	if tab == "groups" or tab == "nearby" then
		local out = {}
		for _, c in ipairs(ns.Calls.List(tab)) do out[#out + 1] = { call = c } end
		return out
	end
	local posts = ns.Feed.Timeline(tab, UI.ROWS_MAX)
	if tab == "realm" and ns.db.settings.groupsInRealm then
		local lines = {}
		for _, c in ipairs(ns.Calls.List("realm")) do
			lines[#lines + 1] = { t = c.t, line = L.REALM_GROUP_LINE:format(Name(c.caller, c.cls), c.need or 1,
				Hex(C.dungeon, c.stone and c.stone.name or "?"), ns.Calls.ZoneName(c.map), c.lo or 0, c.hi or 0), go = function() UI.ShowCall(c.id) end }
		end
		return Merge(posts, lines)
	end
	local out = {}
	for _, p in ipairs(posts) do out[#out + 1] = { post = p } end
	return out
end

---------------------------------------------------------------------------
-- The side tabs (Guild Master Forever's SideTab: the Guild & Communities window's tab, or the
-- same built from the spellbook's tab art where the client lacks the template).
---------------------------------------------------------------------------

local function SideTabEnter(self)
	GameTooltip:SetOwner(self, self.onLeft and "ANCHOR_LEFT" or "ANCHOR_RIGHT")
	GameTooltip:SetText(L[self.def.label])
	GameTooltip:AddLine(L["HINT_" .. self.def.key:upper()]:gsub("%%s", L.YOUR_ZONE), 1, 1, 1, true)
	GameTooltip:Show()
end

local function SideTab(parent)
	local ok, tab = pcall(CreateFrame, "CheckButton", nil, parent, "RightSideTabTemplate")
	if ok and tab and type(tab.Icon) == "table" then
		for _, region in ipairs({ tab:GetRegions() }) do
			if region.GetDrawLayer and region:GetDrawLayer() == "BORDER" then tab.Art = region break end
		end
		return tab
	end
	if ok and tab then tab:Hide() end
	tab = CreateFrame("CheckButton", nil, parent)
	tab:SetSize(32, 32)
	local art = tab:CreateTexture(nil, "BORDER")
	art:SetTexture("Interface\\SpellBook\\SpellBook-SkillLineTab")
	art:SetSize(64, 64)
	art:SetPoint("TOPLEFT", -3, 11)
	tab.Art = art
	tab.Icon = tab:CreateTexture(nil, "ARTWORK")
	tab.Icon:SetSize(30, 30)
	tab.Icon:SetPoint("CENTER")
	tab.Icon:SetTexCoord(0.06, 0.94, 0.06, 0.94)
	tab:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
	tab:SetCheckedTexture("Interface\\Buttons\\CheckButtonHilight")
	local checked = tab.GetCheckedTexture and tab:GetCheckedTexture()
	if checked and checked.SetBlendMode then checked:SetBlendMode("ADD") end
	return tab
end

-- A tab on the left: its art turned round, its open side against the window.
local function SideTabOnLeft(tab)
	tab.onLeft = true
	local art = tab.Art
	if not art then return end
	art:ClearAllPoints()
	art:SetPoint("TOPRIGHT", 3, 11)
	art:SetTexCoord(1, 0, 0, 1)
end

local function TabCount(key)
	if key == "mentions" then return ns.rdb.unreadMentions or 0 end
	if key == "groups" then return #ns.Calls.List("groups") end
	if key == "nearby" then return #ns.Calls.List("nearby") end
	return 0
end

---------------------------------------------------------------------------
-- The window
---------------------------------------------------------------------------

local function Title()
	local sub = view.sub
	if sub then
		if sub.thread then return L.VIEW_THREAD end
		if sub.tag then return "#" .. sub.tag end
		if sub.author then return ns.DisplayName(sub.author) end
	end
	-- The Realm tab is named for the player's side: one feed per faction.
	if view.tab == "realm" and ns.faction then return _G["FACTION_" .. ns.faction:upper()] or ns.faction end
	return L["TAB_" .. (view.tab):upper()]
end

local function Hint()
	local sub = view.sub
	if sub and sub.tag then return L.HINT_TAG:format(sub.tag) end
	if sub and sub.thread then return L.HINT_THREAD end
	if sub and sub.author then
		local pr = ns.rdb.profiles[sub.author] or (ns.Demo and ns.Demo.profiles[sub.author])
		local state = (not pr or not pr.pk) and L.KEY_UNKNOWN or (pr.newKeyAt and L.KEY_NEW or L.KEY_VERIFIED)
		return ("%s · %s"):format(Meta(pr) ~= "" and Meta(pr) or "?", state)
	end
	if view.tab == "nearby" then
		local z = ns.Calls.MyZone()
		return L.HINT_NEARBY:format(z and ns.Calls.ZoneName(z) or "?")
	end
	return L["HINT_" .. view.tab:upper()]
end

local function SavePosition()
	local w = ns.cdb.window
	local point, _, rel, x, y = frame:GetPoint(1)
	w.point, w.rel, w.x, w.y = point, rel, x, y
	if not w.collapsed then w.h = frame:GetHeight() end
end

local function Dock()
	frame:ClearAllPoints()
	local anchor = MinimapCluster or Minimap or UIParent
	-- Clear of the right-hand tabs, under the minimap.
	frame:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", -34, -4)
end

function UI.ResetPosition()
	if not frame then UI.Build() end
	ns.cdb.window = { shown = true }
	frame:SetHeight(UI.HEIGHT)
	Dock()
	UI.ApplyCollapse(false)
	frame:Show()
end


-- The height to open at: the saved one, never below MIN_H (0.1.0's first build saved the
-- collapsed height when the window was dragged collapsed, and opened at it).
function UI.SavedHeight()
	local h = tonumber(ns.cdb.window.h) or UI.HEIGHT
	if h < UI.MIN_H or h > UI.MAX_H then h = UI.HEIGHT end
	ns.cdb.window.h = h
	return h
end
function UI.ApplyCollapse(collapsed)
	ns.cdb.window.collapsed = collapsed or nil
	local parts = { frame.inset, frame.compose, frame.callbar, frame.groupbar, frame.head, frame.grip }
	if collapsed then
		for _, p in ipairs(parts) do p:Hide() end
		for _, t in ipairs(frame.tabs) do t:Hide() end
		frame:SetHeight(UI.HEAD + 4)
	else
		frame.inset:Show()
		frame.grip:Show()
		for _, t in ipairs(frame.tabs) do t:Show() end
		frame:SetHeight(UI.SavedHeight())
		dirty = true
	end
	frame.collapse:SetLabel(collapsed and "+" or "-")
end

-- The compose box: an edit box of our own in a tooltip's border (the game's multi-line input
-- template reads fields at creation that an add-on can't set first).
local function Compose(parent)
	local box = CreateFrame("Frame", nil, parent)
	box:SetHeight(88)
	local edit = CreateFrame("EditBox", "Pugger_ComposeBox", box, BackdropTemplateMixin and "BackdropTemplate" or nil)
	Backdrop(edit, RGB("120f0b"), RGB("4a3c24"))
	edit:SetMultiLine(true)
	edit:SetTextInsets(7, 7, 6, 6)
	edit:SetPoint("TOPLEFT", 0, 0)
	edit:SetPoint("TOPRIGHT", 0, 0)
	edit:SetHeight(26)
	edit:SetAutoFocus(false)
	edit:SetFontObject(FontObject("body"))
	edit:SetTextColor(unpack(RGB("ece5d6")))
	edit:SetMaxBytes(Codec.MAX_BYTES + 20)
	edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	edit:SetScript("OnEnterPressed", function(self)
		if IsShiftKeyDown and IsShiftKeyDown() then self:Insert("\n") return end
		UI.Send()
	end)
	-- One line until the player writes (focus or text), then tall enough for a whole post.
	local function Fit()
		local tall = edit:HasFocus() or (edit:GetText() or "") ~= ""
		if tall ~= box.tall then
			box.tall = tall
			edit:SetHeight(tall and 46 or 26)
			dirty = true
		end
		UI.Counter()
	end
	edit:HookScript("OnTextChanged", Fit)
	edit:HookScript("OnEditFocusGained", Fit)
	edit:HookScript("OnEditFocusLost", Fit)
	-- A click anywhere in the box puts the cursor in it (not only on a line of text).
	edit:HookScript("OnMouseDown", function(self) if not self:HasFocus() then self:SetFocus() end end)
	edit.placeholder = Font(edit, "dim")
	edit.placeholder:SetPoint("TOPLEFT", 8, -7)
	box.edit = edit
	-- Where the next post will say it was written: every post carries it. Kept current while
	-- the window is open (once a second).
	local place = CreateFrame("Frame", nil, box)
	place:SetPoint("TOPLEFT", edit, "BOTTOMLEFT", 0, -2)
	place:SetPoint("TOPRIGHT", edit, "BOTTOMRIGHT", 0, -2)
	place:SetHeight(14)
	place.icon = place:CreateTexture(nil, "ARTWORK")
	place.icon:SetSize(12, 12)
	place.icon:SetPoint("LEFT", 1, 0)
	place.icon:SetTexture("Interface\\Minimap\\Tracking\\None")
	place.text = Font(place, "gold")
	place.text:SetPoint("LEFT", place.icon, "RIGHT", 3, 0)
	place.text:SetPoint("RIGHT", place, "RIGHT", 0, 0)
	place.text:SetWordWrap(false)
	function place:Refresh()
		local here = UI.MySpot()
		self.text:SetText(here and L.POSTING_FROM:format(here) or L.NO_POSITION)
	end
	local since = 1
	place:SetScript("OnUpdate", function(self, elapsed)
		since = since + elapsed
		if since < 1 then return end
		since = 0
		self:Refresh()
	end)
	place:EnableMouse(true)
	place:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText(L.PLACE_TITLE)
		GameTooltip:AddLine(L.PLACE_TIP, 1, 1, 1, true)
		GameTooltip:Show()
	end)
	place:SetScript("OnLeave", function() GameTooltip:Hide() end)
	box.place = place
	box.call = Button(box, L.CALL_MENU, function(b) UI.CallMenu(b) end, "line")
	box.call:SetPoint("BOTTOMLEFT", 2, 2)
	box.count = Font(box, "dim")
	box.count:SetPoint("LEFT", box.call, "RIGHT", 6, 0)
	box.post = Button(box, L.POST, function() UI.Send() end, "main")
	box.post:SetPoint("BOTTOMRIGHT", -2, 2)
	box.cancel = Button(box, L.CANCEL_REPLY, function() UI.StartReply(nil) end, "text")
	box.cancel:SetPoint("RIGHT", box.post, "LEFT", -4, 0)
	return box
end

-- The call buttons the Nearby tab shows instead of the compose box.
local function CallBar(parent)
	local bar = CreateFrame("Frame", nil, parent)
	bar:SetHeight(26)
	bar.rare = Button(bar, L.CALL_RARE, function() ns.Calls.Rare() end, "main")
	bar.rare:SetPoint("LEFT", 2, 0)
	bar.camp = Button(bar, L.CALL_CAMP, function() ns.Popups.CampAsk() end, "line")
	bar.camp:SetPoint("LEFT", bar.rare, "RIGHT", 0, 0)
	bar.group = Button(bar, L.CALL_GROUP, function() ns.Popups.GroupAsk() end, "line")
	bar.group:SetPoint("LEFT", bar.camp, "RIGHT", 0, 0)
	return bar
end

-- The Groups tab's bar: a dungeon group from the meeting stone the player stands at.
local function GroupBar(parent)
	local bar = CreateFrame("Frame", nil, parent)
	bar:SetHeight(26)
	bar.look = Button(bar, L.LOOK_HERE, function(b) ns.Calls.StartAtStone(b) end, "main")
	bar.look:SetPoint("LEFT", 2, 0)
	bar.tip = Font(bar, "dim")
	bar.tip:SetPoint("LEFT", bar.look, "RIGHT", 6, 0)
	bar.tip:SetPoint("RIGHT", -2, 0)
	bar.tip:SetWordWrap(true)
	bar.tip:SetText(L.LOOK_HERE_TIP)
	return bar
end

-- The Me tab's and a profile's head: the bio, and what can be done.
local function ProfileHead(parent)
	local h = CreateFrame("Frame", nil, parent, BackdropTemplateMixin and "BackdropTemplate" or nil)
	Backdrop(h, C.card, C.edge)
	h:SetHeight(56)
	h.meta = Font(h, "gold")
	h.meta:SetPoint("TOPLEFT", 8, -8)
	h.meta:SetPoint("RIGHT", -90, 0)
	h.meta:SetWordWrap(false)
	h.bio = Font(h, "body")
	h.bio:SetPoint("TOPLEFT", h.meta, "BOTTOMLEFT", 0, -4)
	h.bio:SetWidth(UI.WIDTH - 12 - 16 - 84)
	Wrap(h.bio)
	h.bio:SetJustifyV("TOP")
	h:EnableMouse(true)
	h:SetScript("OnEnter", function(self)
		if not self.fullBio or self.fullBio == "" then return end
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
		GameTooltip:AddLine(self.fullBio, 1, 1, 1, true)
		GameTooltip:Show()
	end)
	h:SetScript("OnLeave", function() GameTooltip:Hide() end)
	h.b1 = Button(h, "", nil, "main")
	h.b1:SetPoint("TOPRIGHT", -6, -6)
	h.b2 = Button(h, "", nil, "line")
	h.b2:SetPoint("TOPRIGHT", h.b1, "BOTTOMRIGHT", 0, -2)
	return h
end

local function SetTitle(text)
	if frame.SetTitle then frame:SetTitle(text)
	elseif type(frame.TitleText) == "table" then frame.TitleText:SetText(text)
	elseif type(frame.TitleContainer) == "table" and type(frame.TitleContainer.TitleText) == "table" then frame.TitleContainer.TitleText:SetText(text) end
end

function UI.Build()
	if frame then return frame end
	ns.cdb.window = ns.cdb.window or { shown = true }
	local w = ns.cdb.window
	local templated
	frame, templated = Template("Frame", "Pugger_Feed", UIParent, "PortraitFrameTemplate")
	frame.hasPortrait = templated and type(frame.CloseButton) == "table"
	if not frame.hasPortrait then
		frame:Hide()
		frame = Template("Frame", "Pugger_FeedBasic", UIParent, "BasicFrameTemplateWithInset")
	end
	frame:SetSize(UI.WIDTH, UI.SavedHeight())
	frame:SetFrameStrata("MEDIUM")
	frame:SetClampedToScreen(true)
	if frame.SetClampRectInsets then frame:SetClampRectInsets(-34, 34, 0, 0) end -- (the side tabs stay on screen)
	frame:SetMovable(true)
	frame:SetResizable(true)
	if frame.SetResizeBounds then frame:SetResizeBounds(UI.WIDTH, UI.MIN_H, UI.WIDTH, UI.MAX_H)
	elseif frame.SetMinResize then frame:SetMinResize(UI.WIDTH, UI.MIN_H) frame:SetMaxResize(UI.WIDTH, UI.MAX_H) end
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", function() if not ns.cdb.window.locked then frame:StartMoving() end end)
	frame:SetScript("OnDragStop", function() frame:StopMovingOrSizing() SavePosition() end)
	if w.point then
		frame:SetPoint(w.point, UIParent, w.rel or w.point, w.x or 0, w.y or 0)
	else
		Dock()
	end
	-- Its close button hides it itself (as Guild Master Forever's: the template's would call
	-- HideUIPanel, which does nothing in combat).
	if type(frame.CloseButton) == "table" then frame.CloseButton:SetScript("OnClick", function() UI.Toggle(false) end) end

	-- No round portrait (it made the header tall): the game's own way to take it off, which also
	-- squares the corner. Where that fails the portrait stays, with the Pugger icon in it.
	local portrait = frame.portrait or frame.Portrait or (type(frame.PortraitContainer) == "table" and frame.PortraitContainer.portrait)
	if type(portrait) ~= "table" then portrait = nil end
	local slim = not frame.hasPortrait
	if frame.hasPortrait and ButtonFrameTemplate_HidePortrait then
		slim = pcall(ButtonFrameTemplate_HidePortrait, frame) and not (portrait and portrait:IsShown())
	end
	if slim then
		UI.HEAD = 48
	else
		UI.HEAD = 56
		if portrait then
			portrait:SetTexture(ns.ICON)
			if portrait.SetMask and not portrait.pugMasked then
				portrait.pugMasked = pcall(portrait.SetMask, portrait, "Interface\\CharacterFrame\\TempPortraitAlphaMask")
			end
		elseif frame.SetPortraitToAsset then
			pcall(frame.SetPortraitToAsset, frame, ns.ICON)
		end
	end
	SetTitle("Pugger")

	-- The header: what this view is, and its buttons, one row as thick as the buttons (with the
	-- icon small at its left when the portrait is off).
	local hx = slim and 30 or 62
	if slim then
		frame.eye = frame:CreateTexture(nil, "ARTWORK")
		frame.eye:SetSize(18, 18)
		frame.eye:SetPoint("TOPLEFT", 8, -28)
		frame.eye:SetTexture(ns.ICON)
		if frame.eye.SetMask then pcall(frame.eye.SetMask, frame.eye, "Interface\\CharacterFrame\\TempPortraitAlphaMask") end
	end
	frame.viewTitle = Font(frame, "title")
	frame.viewTitle:SetPoint("TOPLEFT", hx, slim and -30 or -32)
	-- What the view is shows on the title's tooltip (a line of its own took too much height).
	frame.titleTip = CreateFrame("Frame", nil, frame)
	frame.titleTip:SetAllPoints(frame.viewTitle)
	frame.titleTip:EnableMouse(true)
	frame.titleTip:SetScript("OnEnter", function(self)
		if not self.hint or self.hint == "" then return end
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
		GameTooltip:SetText(self.hint, 1, 1, 1, true)
		GameTooltip:Show()
	end)
	frame.titleTip:SetScript("OnLeave", function() GameTooltip:Hide() end)
	frame.menuBtn = Button(frame, L.MENU, function(b) UI.WindowMenu(b) end, "line")
	frame.menuBtn:SetPoint("TOPRIGHT", -8, -27)
	frame.collapse = Button(frame, "-", function() UI.ApplyCollapse(not ns.cdb.window.collapsed) end, "line")
	frame.collapse:SetPoint("RIGHT", frame.menuBtn, "LEFT", 0, 0)
	frame.back = Button(frame, L.BACK, function() UI.Open(nil) end, "line")
	frame.back:SetPoint("RIGHT", frame.collapse, "LEFT", 0, 0)

	frame.compose = Compose(frame)
	frame.callbar = CallBar(frame)
	frame.groupbar = GroupBar(frame)
	frame.head = ProfileHead(frame)

	-- The feed, in the game's dark inset, with the game's scroll bar.
	local inset = Template("Frame", nil, frame, "InsetFrameTemplate")
	frame.inset = inset
	inset.tint = inset:CreateTexture(nil, "BACKGROUND", nil, 1)
	inset.tint:SetPoint("TOPLEFT", 3, -3)
	inset.tint:SetPoint("BOTTOMRIGHT", -3, 3)
	inset.tint:SetColorTexture(unpack(C.panel))
	local scroll = Template("ScrollFrame", "Pugger_FeedScroll", inset, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 4, -4)
	scroll:SetPoint("BOTTOMRIGHT", -26, 4)
	local content = CreateFrame("Frame", nil, scroll)
	content:SetSize(UI.ROW_W + 4, 10)
	scroll:SetScrollChild(content)
	frame.scroll, frame.content = scroll, content
	frame.empty = Font(content, "dim")
	frame.empty:SetPoint("TOPLEFT", 8, -10)
	frame.empty:SetWidth(UI.ROW_W - 16)

	-- The bottom right corner: drag to change the height.
	local grip = CreateFrame("Button", nil, frame)
	grip:SetSize(16, 16)
	grip:SetPoint("BOTTOMRIGHT", -4, 4)
	grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
	grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
	grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
	grip:SetFrameLevel(frame:GetFrameLevel() + 10)
	grip:SetScript("OnMouseDown", function() if not ns.cdb.window.locked then frame:StartSizing("BOTTOM") end end)
	grip:SetScript("OnMouseUp", function() frame:StopMovingOrSizing() SavePosition() dirty = true end)
	frame.grip = grip

	-- The side tabs.
	frame.tabs = {}
	local n = { left = 0, right = 0 }
	for _, t in ipairs(TABS) do
		local tab = SideTab(frame)
		tab.def = t
		if t.side == "left" then
			SideTabOnLeft(tab)
			tab:SetPoint("TOPRIGHT", frame, "TOPLEFT", 0, -70 - n.left * UI.TAB_STEP)
		else
			tab:SetPoint("TOPLEFT", frame, "TOPRIGHT", 0, -40 - n.right * UI.TAB_STEP)
		end
		n[t.side] = n[t.side] + 1
		if t.portrait and SetPortraitTexture then
			pcall(SetPortraitTexture, tab.Icon, "player")
			tab.Icon:SetTexCoord(0.1, 0.9, 0.1, 0.9)
		else
			tab.Icon:SetTexture(t.icon)
		end
		tab.badge = tab:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
		tab.badge:SetPoint("BOTTOMRIGHT", tab, "BOTTOMRIGHT", -1, 2)
		tab:SetScript("OnClick", function() UI.SetTab(t.key) end)
		tab:SetScript("OnEnter", SideTabEnter)
		tab:SetScript("OnLeave", function() GameTooltip:Hide() end)
		frame.tabs[#frame.tabs + 1] = tab
	end

	frame:SetAlpha(ns.db.settings.alpha or 1)
	frame:SetScript("OnUpdate", function()
		if dirty and GetTime() - lastDraw >= UI.REDRAW then UI.Render() end
	end)
	frame:SetScript("OnShow", function() dirty = true quietHidden = nil ns.cdb.window.shown = true end)
	frame:SetScript("OnHide", function()
		if not combatHidden and not quietHidden then ns.cdb.window.shown = false end
	end)
	if w.collapsed then UI.ApplyCollapse(true) end
	frame:Hide()
	return frame
end

-- What sits between the header and the inset (the compose box, the call bar, a profile's head),
-- and where the inset starts.
local function LayoutTop()
	local tab, sub = view.tab, view.sub
	local y = UI.HEAD + 2
	-- Only the parts leaving the view are hidden: hiding the compose box, even for a moment,
	-- would take the cursor out of it.
	local placed = {}
	local function Place(part, h)
		part:ClearAllPoints()
		part:SetPoint("TOPLEFT", frame, "TOPLEFT", 6, -y)
		part:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -6, -y)
		part:SetHeight(h)
		part:Show()
		placed[part] = true
		y = y + h + 2
	end
	if (tab == "me" and not sub) or (sub and sub.author) then
		local h = frame.head
		local name = sub and sub.author or ns.me
		local _, pr = UI.Who(name)
		local guild = pr and pr.guild and pr.guild ~= "" and ("  <" .. pr.guild .. ">") or ""
		local follows = name == ns.me and ("  " .. L.FOLLOWING_N:format(ns.Count(ns.rdb.follows))) or ""
		h.meta:SetText(Name(name) .. "  " .. Hex(C.soft, (Meta(pr) ~= "" and Meta(pr) or "?") .. guild .. follows))
		h.fullBio = pr and pr.bio or ""
		h.bio:SetText(h.fullBio ~= "" and h.fullBio or Hex(C.dim, name == ns.me and L.NO_BIO_MINE or L.NO_BIO))
		if name == ns.me then
			h.b1:SetLabel(L.EDIT_BIO)
			h.b1:SetScript("OnClick", function() ns.Popups.EditBio() end)
			h.b2:SetLabel(L.SETTINGS)
			h.b2:SetScript("OnClick", function(b) UI.WindowMenu(b) end)
		else
			local following = ns.Feed.IsFollowing(name)
			h.b1:SetLabel(following and L.UNFOLLOW or L.FOLLOW)
			h.b1:SetScript("OnClick", function() ns.Feed.Follow(name, not following) end)
			h.b2:SetLabel(L.MORE)
			h.b2:SetScript("OnClick", function(b) UI.PersonMenu(b, name) end)
		end
		Place(h, math.max(56, 8 + 14 + 4 + (h.bio:GetStringHeight() or 13) + 8))
	end
	if tab == "groups" and not sub then
		Place(frame.groupbar, 26)
	elseif tab == "nearby" and not sub then
		Place(frame.callbar, 26)
	elseif (not sub and (tab == "realm" or tab == "following" or tab == "me")) or (sub and sub.thread) then
		Place(frame.compose, frame.compose.tall and 88 or 68)
	end
	for _, part in ipairs({ frame.compose, frame.callbar, frame.groupbar, frame.head }) do
		if not placed[part] then part:Hide() end
	end
	frame.inset:ClearAllPoints()
	frame.inset:SetPoint("TOPLEFT", frame, "TOPLEFT", 4, -y)
	frame.inset:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -6, 22)
end

function UI.Render()
	if not frame or not frame:IsShown() then return end
	dirty, lastDraw = false, GetTime()
	if view.tab == "mentions" and not view.sub then ns.rdb.unreadMentions = 0 end
	local title = Title()
	SetTitle("Pugger")
	if view.sub and view.sub.author then
		frame.viewTitle:SetText((UI.Who(view.sub.author)))
	else
		frame.viewTitle:SetText(title)
	end
	frame.titleTip.hint = Hint()
	if view.sub then frame.back:Show() else frame.back:Hide() end
	for _, tab in ipairs(frame.tabs) do
		tab:SetChecked(view.tab == tab.def.key and not view.sub)
		local n = TabCount(tab.def.key)
		tab.badge:SetText(n > 0 and tostring(n) or "")
	end
	if ns.cdb.window.collapsed then return end
	LayoutTop()
	UI.Counter()
	ClearRows()
	local content = frame.content
	local y = 2
	local items = Items()
	for i, it in ipairs(items) do
		if i > UI.ROWS_MAX then break end
		local r, h
		if it.post then
			r = Take(postPool, NewPostRow, content)
			h = FillPost(r, it.post)
		elseif it.call then
			r = Take(callPool, NewCallRow, content)
			h = FillCall(r, it.call)
		else
			r = Take(linePool, NewLineRow, content)
			r.text:SetText(it.line)
			r:SetScript("OnClick", it.go)
			h = 18
		end
		r:SetPoint("TOPLEFT", content, "TOPLEFT", 2, -y)
		y = y + h + 3
	end
	frame.empty:SetText(#items == 0 and L["EMPTY_" .. (view.sub and "SUB" or view.tab:upper())] or "")
	content:SetHeight(math.max(10, y))
end

function UI.Dirty() dirty = true end
function UI.Frame() return frame end

function UI.SetTab(key)
	view.tab, view.sub = key, nil
	if key ~= "realm" and key ~= "following" and key ~= "me" then replyTo = nil end
	if frame then frame.scroll:SetVerticalScroll(0) end
	dirty = true
end

-- A thread, a tag or a profile, over the current tab (Back returns); nil: back.
function UI.Open(sub)
	UI.Toggle(true)
	view.sub = sub
	replyTo = sub and sub.thread or nil
	frame.scroll:SetVerticalScroll(0)
	dirty = true
end

-- @name clicked: the profile of a known player with that name.
function UI.OpenName(word)
	local function Find(list)
		for name in pairs(list or {}) do
			local short = ns.ShortName(name):lower()
			if short:gsub("%s", "") == word or short:match("^(%S+)") == word then return name end
		end
	end
	local name = Find(ns.rdb.profiles) or Find(ns.Demo and ns.Demo.profiles)
	if name then return UI.Open({ author = name }) end
	ns.Print(L.NOBODY_NAMED:format(word))
end

function UI.ShowCall(id)
	local c = ns.Calls.Get(id)
	if not c then return end
	UI.Toggle(true)
	UI.SetTab(c.kind == "D" and "groups" or "nearby")
end

function UI.Toggle(on)
	if not frame then UI.Build() end
	if on == nil then on = not frame:IsShown() end
	if on then frame:Show() else frame:Hide() end
end

---------------------------------------------------------------------------
-- Compose
---------------------------------------------------------------------------

function UI.Counter()
	if not frame then return end
	local box = frame.compose
	local text = box.edit:GetText() or ""
	local n = ns.Letters(Codec.Visible(text))
	local max = ns.Feed.MAX_LETTERS
	box.count:SetText(Hex(n > max - 10 and C.rare or C.dim, ("%d/%d"):format(n, max)))
	box.edit.placeholder:SetText((text == "" and not box.edit:HasFocus()) and (ns.Safety.CanPost() and L.PLACEHOLDER or L.PLACEHOLDER_LOW) or "")
	box.place:Refresh()
	local p = replyTo and Store.Get(replyTo)
	if p then
		box.cancel:Show()
		box.post:SetLabel(L.REPLY)
		if text == "" and not box.edit:HasFocus() then box.edit.placeholder:SetText(L.REPLYING_TO:format(ns.DisplayName(p.a))) end
	else
		box.cancel:Hide()
		box.post:SetLabel(L.POST)
	end
	box.post:SetOn(n <= max)
end

function UI.StartReply(id)
	replyTo = id
	if id and not (view.sub and view.sub.thread) then
		UI.Open({ thread = ns.Feed.Root(id) })
		replyTo = id
	end
	if frame and id then frame.compose.edit:SetFocus() end
	dirty = true
end

function UI.Send()
	local edit = frame.compose.edit
	local text = edit:GetText() or ""
	ns.Feed.Post(text, { reply = replyTo }, function(ok, why)
		if not ok then return ns.Print(why) end
		edit:SetText("")
		edit:ClearFocus()
		dirty = true
	end)
end

-- A shift-clicked link: into the compose box, only while the player has it focused.
function UI.InsertLink(link)
	if not frame or not frame:IsShown() or type(link) ~= "string" then return false end
	local edit = frame.compose.edit
	if not edit:IsVisible() or not edit:HasFocus() then return false end
	edit:Insert(link)
	return true
end

---------------------------------------------------------------------------
-- Menus
---------------------------------------------------------------------------

local function Menu()
	menu = menu or UI.Menu()
	return menu
end

-- The window's menu, opened beside anchor with these items (for the other files).
function UI.MenuAt(anchor, items) Menu():Open(anchor, items) end

function UI.PostMenu(anchor, id)
	local p = Store.Get(id)
	if not p then return end
	local items = { { text = ns.DisplayName(p.a), title = true } }
	if p.a == ns.me then
		items[#items + 1] = { text = L.DELETE, go = function() ns.Popups.Confirm(L.DELETE_CONFIRM, function() ns.Feed.Delete(id) end) end }
	else
		local following = ns.Feed.IsFollowing(p.a)
		items[#items + 1] = { text = following and L.UNFOLLOW or L.FOLLOW, go = function() ns.Feed.Follow(p.a, not following) end }
		items[#items + 1] = { text = L.PROFILE, go = function() UI.Open({ author = p.a }) end }
		items[#items + 1] = { text = L.MUTE, go = function() ns.Safety.Mute(p.a, true) end }
		items[#items + 1] = { text = L.BLOCK, go = function() ns.Safety.Block(p.a, true) end }
		items[#items + 1] = { text = L.REPORT, go = function() ns.Safety.Report(p.a) end }
	end
	items[#items + 1] = { text = L.COPY_LINK, go = function() ns.Diagnostics.ShowCopy(L.COPY_LINK, "pugger:" .. id) end }
	Menu():Open(anchor, items)
end

function UI.PersonMenu(anchor, name)
	local S = ns.Safety
	Menu():Open(anchor, {
		{ text = ns.DisplayName(name), title = true },
		{ text = S.IsMuted(name) and L.UNMUTE or L.MUTE, go = function() S.Mute(name, not S.IsMuted(name)) end },
		{ text = S.IsBlocked(name) and L.UNBLOCK or L.BLOCK, go = function() S.Block(name, not S.IsBlocked(name)) end },
		{ text = L.WHISPER, go = function() ns.Popups.Whisper(name) end },
		{ text = L.REPORT, go = function() S.Report(name) end },
	})
end

function UI.CallMenu(anchor)
	Menu():Open(anchor, {
		{ text = L.CALL_MENU, title = true },
		{ text = L.CALL_RARE, go = function() ns.Calls.Rare() end },
		{ text = L.CALL_CAMP, go = function() ns.Popups.CampAsk() end },
		{ text = L.CALL_GROUP, go = function() ns.Popups.GroupAsk() end },
	})
end

function UI.WindowMenu(anchor)
	local s, w = ns.db.settings, ns.cdb.window
	local function Flip(t, k) return function() t[k] = not t[k] or nil dirty = true end end
	Menu():Open(anchor, {
		{ text = L.MENU_WINDOW, title = true },
		{ text = L.LOCK, check = w.locked == true, go = Flip(w, "locked") },
		{ text = L.HIDE_IN_COMBAT, check = s.hideInCombat, go = function() s.hideInCombat = not s.hideInCombat end },
		{ text = L.QUIET_IN_GROUPS, check = s.quietInGroups, go = function() s.quietInGroups = not s.quietInGroups UI.CheckQuiet() end },
		{ text = L.TRANSPARENCY, go = function()
			s.alpha = (s.alpha or 1) <= 0.55 and 1 or (s.alpha - 0.15)
			frame:SetAlpha(s.alpha)
		end },
		{ text = L.RESET_POSITION, go = UI.ResetPosition },
		{ text = L.MENU_FEED, title = true },
		{ text = L.SHOW_FOLLOWS, check = s.showFollows, go = function() s.showFollows = not s.showFollows ns.Identity.SendProfile(true) end },
		{ text = L.MENTION_POPUPS, check = s.mentionPopups, go = function() s.mentionPopups = not s.mentionPopups end },
		{ text = L.MENTIONS_FOLLOWED, check = s.mentionsFollowedOnly, go = function() s.mentionsFollowedOnly = not s.mentionsFollowedOnly end },
		{ text = L.GROUPS_IN_REALM, check = s.groupsInRealm, go = function() s.groupsInRealm = not s.groupsInRealm dirty = true end },
		{ text = L.ASKS_FROM:format(L["ASKS_" .. (s.asks or "all"):upper()]), go = function()
			s.asks = s.asks == "all" and "friends" or (s.asks == "friends" and "off" or "all")
		end },
		{ text = L.DAYS_KEPT:format(s.daysKept), go = function() s.daysKept = s.daysKept >= 7 and 1 or s.daysKept + 1 end },
		{ text = L.WORD_FILTER, go = function() ns.Popups.WordFilter() end },
		{ text = L.MAP_CALLS, go = function() ns.MapPins.ToggleMenu(anchor) end },
		{ text = L.PRIVACY, go = function() ns.Consent.Show() end },
	})
end

function UI.PinOnMap(c)
	if C_Map and C_Map.SetUserWaypoint and UiMapPoint and UiMapPoint.CreateFromCoordinates then
		local ok = pcall(C_Map.SetUserWaypoint, UiMapPoint.CreateFromCoordinates(c.map, c.x, c.y))
		if ok then return ns.Print(L.PINNED) end
	end
	ns.Print(L.PIN_AT:format(UI.CallWhere(c)))
end

---------------------------------------------------------------------------
-- The minimap button (drag around the minimap's edge)
---------------------------------------------------------------------------

local function MinimapButton()
	if ns.db.settings.hideMinimap or not Minimap then return end
	local b = CreateFrame("Button", "Pugger_MinimapButton", Minimap)
	b:SetSize(31, 31)
	b:SetFrameStrata("MEDIUM")
	b:SetFrameLevel(8)
	local icon = b:CreateTexture(nil, "BACKGROUND")
	icon:SetSize(20, 20)
	icon:SetPoint("CENTER", 0, 1)
	icon:SetTexture(ns.ICON)
	local border = b:CreateTexture(nil, "OVERLAY")
	border:SetSize(53, 53)
	border:SetPoint("TOPLEFT")
	border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
	b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
	local function Place()
		local a = math.rad(ns.db.settings.minimapAngle or 200)
		b:ClearAllPoints()
		b:SetPoint("CENTER", Minimap, "CENTER", math.cos(a) * 80, math.sin(a) * 80)
	end
	Place()
	b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	b:RegisterForDrag("LeftButton")
	b:SetScript("OnClick", function(_, button)
		if button == "RightButton" then UI.WindowMenu(b) else UI.Toggle() end
	end)
	b:SetScript("OnDragStart", function(self)
		self:SetScript("OnUpdate", function()
			local mx, my = Minimap:GetCenter()
			local px, py = GetCursorPosition()
			local scale = Minimap:GetEffectiveScale()
			ns.db.settings.minimapAngle = math.deg(math.atan2(py / scale - my, px / scale - mx))
			Place()
		end)
	end)
	b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
	b:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:AddLine("Pugger")
		GameTooltip:AddLine(L.MINIMAP_TIP, 1, 1, 1, true)
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

-- The key binding (Bindings.xml).
function Pugger_ToggleBinding() ns.SafeCall("binding", UI.Toggle) end
BINDING_HEADER_PUGGER = "Pugger"
BINDING_NAME_PUGGER_TOGGLE = "Toggle the Pugger feed"

ns.On("LOGIN", function()
	UI.Build()
	MinimapButton()
	if ns.cdb.window.shown ~= false then frame:Show() end
	ns.On("FEED_CHANGED", UI.Dirty)
	ns.On("CALLS_CHANGED", UI.Dirty)
	C_Timer.NewTicker(30, function() dirty = true end) -- times ("4m") and distances
	if hooksecurefunc and ChatEdit_InsertLink then
		-- After the game's own: only a box the player focused, the game's chat untouched.
		hooksecurefunc("ChatEdit_InsertLink", function(link) ns.SafeCall("insert link", UI.InsertLink, link) end)
	end
	ns.RegisterEvent("PLAYER_REGEN_DISABLED", function()
		if ns.db.settings.hideInCombat and frame:IsShown() then combatHidden = true frame:Hide() end
	end)
	ns.RegisterEvent("PLAYER_REGEN_ENABLED", function()
		if combatHidden then
			combatHidden = nil
			if not quietHidden then frame:Show() end
		end
	end)
	for _, e in ipairs({ "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA", "GROUP_ROSTER_UPDATE" }) do
		ns.RegisterEvent(e, UI.CheckQuiet)
	end
	UI.CheckQuiet()
end)

-- Quiet in a group instance (ns.Quiet), acted on only as it starts and ends: on the way in the
-- window steps aside (opened by hand meanwhile, it stays) and the cards close; on the way out
-- the window comes back and the calls heard meanwhile catch up (Popups.CatchUp).
local quiet = false
function UI.CheckQuiet()
	if not frame then return end
	local q = ns.Quiet()
	if q == quiet then return end
	quiet = q
	if q then
		ns.Popups.CloseAll()
		if frame:IsShown() then quietHidden = true frame:Hide() end
	else
		if quietHidden then
			quietHidden = nil
			if not combatHidden then frame:Show() end
		end
		ns.Popups.CatchUp()
	end
end
