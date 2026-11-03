local ADDON, ns = ...

-- The one short note before the first post or call (once per account): posts are public to
-- everyone on the realm and faction with the add-on, and deleting isn't guaranteed. Reading
-- needs nothing. /pug privacy shows the whole page again: the honest limits, said plainly.

local Consent = {}
ns.Consent = Consent

function Consent.Ask(go)
	if ns.db.consented then return go() end
	ns.Popups.Dialog({
		title = ns.L.CONSENT_TITLE, body = ns.L.CONSENT_BODY, ok = ns.L.OK, cancel = ns.L.NOT_NOW,
		go = function()
			ns.db.consented = ns.Now()
			go()
		end,
	})
end

function Consent.Show()
	ns.Popups.Dialog({ title = ns.L.PRIVACY_TITLE, body = ns.L.PRIVACY_BODY, ok = ns.L.OK, cancel = false })
end
