format = string.format; local now = 1000; function GetTime() return now end
function UnitAffectingCombat() return true end function UnitIsAFK() return false end
DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) print("  " .. m) end }; SlashCmdList = {}
local F; function CreateFrame() F = { e = {} }; function F:RegisterEvent(x) end; function F:UnregisterEvent() end; function F:SetScript(k, f) self[k] = f end; return F end
collectgarbage(); dofile(arg[1]); event, arg1 = "ADDON_LOADED", "GentleGC"; F.OnEvent()
SlashCmdList.GENTLEGC("headroom 4"); SlashCmdList.GENTLEGC("debug 2")
event = "PLAYER_REGEN_DISABLED"; F.OnEvent()
local _, t1 = gcinfo()
local keep = {} for i = 1, 60000 do keep[i] = {i} end   -- live growth past raised threshold
keep = nil; local g = {} for i = 1, 60000 do g[i] = {i} end g = nil
arg1 = 1.1; F.OnUpdate()
local used, t2 = gcinfo()
print("re-raised headroom after in-combat auto GC:", t2 >= used + 4*1024 - 1 and "PASS" or "FAIL", t1, t2, used)
event = "PLAYER_REGEN_ENABLED"; F.OnEvent()
SlashCmdList.GENTLEGC("status")
