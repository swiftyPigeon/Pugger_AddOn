local ADDON, ns = ...

-- Loaded first (before the libraries), so that:
-- 1. errors raised while the rest of the add-on loads are still captured (Diagnostics.lua
--    stores them once the SavedVariables are ready), and
-- 2. the world map exists before HereBeDragons-Pins hooks into it. On Classic clients
--    Blizzard_WorldMap is load-on-demand and the library breaks without it.
-- Adapted from Guild Master Forever's Bootstrap.lua (MIT, see LICENSE.txt).

ns.earlyErrors = {}

-- The errors of the add-on's own files seen this session, deduplicated (nothing of any other
-- add-on's). Kept in the SavedVariables for /fax bug.
ns.allErrors = {}
local index = {}
local others, nOthers = {}, 0 -- the other add-ons' errors seen, 200 at most

-- Ours: the message names one of our files, or a line of the stack does. Not this handler's
-- own line, which tops every stack it reads.
local OURS = "AddOns[\\/]Faxion[\\/]"
local HANDLER = "AddOns[\\/]Faxion[\\/]Bootstrap%.lua"
function ns.OwnError(msg, stack)
	if tostring(msg or ""):find(OURS) then return true end
	for line in tostring(stack or ""):gmatch("[^\n]+") do
		if line:find(OURS) and not line:find(HANDLER) then return true end
	end
	return false
end

-- Not with Blizzard's gamepad UI on (WoW: Forever): every error would then run the game's
-- error window from this handler, which the game blocks there.
local function GamepadUI()
	local current = C_InputInterfaceStyle and C_InputInterfaceStyle.GetCurrentStyle
	local gamepad = Enum and Enum.InputDeviceInterfaceType and Enum.InputDeviceInterfaceType.Gamepad
	if not current or gamepad == nil then return false end
	local ok, style = pcall(current)
	return ok and style == gamepad
end
ns.GamepadUI = GamepadUI

-- Every error still goes on to the handler that was there before, as it came.
local previous = not GamepadUI() and geterrorhandler and geterrorhandler()
if previous then seterrorhandler(function(err, ...)
	pcall(function()
		local msg = tostring(err)
		local key = msg:sub(1, 240)
		local e = index[key]
		if e then
			e.count = e.count + 1
		elseif others[key] then
			return
		elseif #ns.allErrors < 40 then
			local stack = debugstack and debugstack(3, 10, 0) or ""
			if not ns.OwnError(msg, stack) then
				if nOthers < 200 and msg:find("AddOns[\\/]") then others[key], nOthers = true, nOthers + 1 end
				return
			end
			e = { msg = msg, count = 1, stack = stack, t = date and date("%H:%M:%S") }
			index[key] = e
			ns.allErrors[#ns.allErrors + 1] = e
		end
		if msg:find(OURS) then
			if ns.CaptureError and ns.db then
				ns.CaptureError("global", msg)
			elseif #ns.earlyErrors < 20 then
				ns.earlyErrors[#ns.earlyErrors + 1] = { msg, debugstack and debugstack(3, 10, 0) or "" }
			end
		end
	end)
	return previous(err, ...)
end) end

if not WorldMapFrame then
	local load = (C_AddOns and C_AddOns.LoadAddOn) or LoadAddOn
	if load then pcall(load, "Blizzard_WorldMap") end
end
