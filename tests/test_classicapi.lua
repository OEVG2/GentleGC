-- WoW + ClassicAPI stubs
format = string.format
local now = 1000
function GetTime() return now end
local combat, speed, falling = false, 7, false
function UnitAffectingCombat() return combat end
function UnitIsAFK() return false end
function GetUnitSpeed(u) return speed, 7, 0, 4.7 end
function IsFalling() return falling end
local log = {}
DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) table.insert(log, m); print("  " .. m) end }
SlashCmdList = {}
local tickerFn, tickerPeriod
C_Timer = { NewTicker = function(p, f) tickerPeriod, tickerFn = p, f; return {} end }
FRAMES = {}
function CreateFrame()
  local F = { scripts = {} }
  function F:RegisterEvent() end
  function F:UnregisterEvent() end
  function F:SetScript(k, f) self.scripts[k] = f end
  table.insert(FRAMES, F)
  return F
end
local function fire(e, a1) event, arg1 = e, a1; F.scripts.OnEvent() end
local function seconds(n) for i = 1, n do now = now + 1; tickerFn() end end

LIVE = {}
for i = 1, 300000 do LIVE[i] = { i } end
local function makeGarbage(mb) local t = {}; for i = 1, mb * 6000 do t[i] = { i, i } end end
local function count(pat) local n = 0; for _, m in ipairs(log) do if string.find(m, pat) then n = n + 1 end end; return n end
local function check(name, c) print((c and "PASS " or "FAIL ") .. name); if not c then FAILED = true end end

collectgarbage()
dofile(arg[1])
F = FRAMES[1]
HF = FRAMES[2]
fire("ADDON_LOADED", "GentleGC")
SlashCmdList.GENTLEGC("debug 2")

check("C_Timer ticker used (1s)", tickerFn ~= nil and tickerPeriod == 1)
check("no frame OnUpdate when C_Timer exists", F.scripts.OnUpdate == nil)

makeGarbage(12)
speed = 7; seconds(10)
check("no stand-still collection while moving", count("standing still:") == 0)

speed = 0; seconds(2)
check("not yet after 2s still", count("standing still:") == 0)
seconds(2)
check("collects after 3s standing still", count("standing still:") == 1)

seconds(20)
check("does not repeat while still with no new garbage", count("standing still:") == 1)
SlashCmdList.GENTLEGC("status")
check("idle retries don't inflate skip count", count("collections, 0 skipped") == 1)

makeGarbage(12); seconds(15)
check("respects minInterval, then collects again", count("standing still:") == 2)

makeGarbage(12); falling = true; speed = 0; now = now + 60; seconds(5)
check("falling is not standing still", count("standing still:") == 2)
falling = false

combat = true; fire("PLAYER_REGEN_DISABLED"); seconds(10)
check("never while in combat", count("standing still:") == 2)
combat = false; fire("PLAYER_REGEN_ENABLED")

SlashCmdList.GENTLEGC("still 0"); makeGarbage(12); now = now + 60; seconds(10)
check("still 0 disables it", count("standing still:") == 2 or count("standing still:") == 3 and false)

print(FAILED and "SOME TESTS FAILED" or "ALL TESTS PASSED")
