-- Raid-scale behaviour: careful mode when collections are slow, collections
-- run by other addons, and the garbage creation rate.
-- Run: lua5.0 tests/test_raid.lua GentleGC.lua
format = string.format
local now = 1000
function GetTime() return now end
local combat, speed = false, 7
function UnitAffectingCombat() return combat end
function UnitIsAFK() return false end
function GetUnitSpeed() return speed, 7, 0, 4.7 end   -- ClassicAPI: enables stand-still
local log = {}
DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) table.insert(log, m); print("  " .. m) end }
SlashCmdList = {}
FRAMES = {}
function CreateFrame()
  local f = { scripts = {} }
  function f:RegisterEvent() end
  function f:UnregisterEvent() end
  function f:SetScript(k, fn) self.scripts[k] = fn end
  table.insert(FRAMES, f)
  return f
end

-- the call stack another addon's collectgarbage() call is made from
local caller = nil
function debugstack()
  local s = "Interface\\AddOns\\GentleGC\\GentleGC.lua:400: in function `WrappedCollect'\n"
  if caller then s = s .. "Interface\\AddOns\\" .. caller .. "\\core.lua:12: in function `FreeMemory'\n" end
  return s .. "[C]: ?\n"
end

-- a slow collector: every full collection advances the clock by `gcCost`
local gcCost = 0.3
local origCG = collectgarbage
collectgarbage = function(n)
  if n == nil or n == 0 then now = now + gcCost end
  return origCG(n)
end
local unwrappedCG = collectgarbage   -- what an addon that localized it before us holds

LIVE = {}
for i = 1, 300000 do LIVE[i] = { i } end
origCG()

dofile(arg[1])
local F = FRAMES[1]
local function fire(e, a1) event, arg1 = e, a1; this = F; F.scripts.OnEvent() end
fire("ADDON_LOADED", "GentleGC")
local SF = FRAMES[4]
local cmd = SlashCmdList.GENTLEGC
cmd("debug 2")

local function count(pat) local n = 0; for _, m in ipairs(log) do if string.find(m, pat) then n = n + 1 end end; return n end
local function lastMatch(pat) for i = table.getn(log), 1, -1 do if string.find(log[i], pat) then return log[i] end end; return "" end
local function check(name, c) print((c and "PASS " or "FAIL ") .. name); if not c then FAILED = true end end
-- one rendered frame: per-frame sampler, then the main frame's OnUpdate
local HF = FRAMES[2]
local function frame(dt)
  now = now + dt
  SF.scripts.OnUpdate()
  arg1 = dt; this = F
  F.scripts.OnUpdate()
  if HF.scripts.OnUpdate then HF.scripts.OnUpdate() end
end
local function seconds(n) for i = 1, n * 10 do frame(0.1) end end
local function garbageMB(mb)
  local t = {}
  for i = 1, mb * 7000 do t[i] = { i, i } end
end
local function liveMB() local _, _, v = string.find(lastMatch("heap .* live ~"), "live ~([%d%.]+)mb"); return tonumber(v) end

---------------------------------------------------------------------------
print("1. slow collections switch to careful mode")
garbageMB(8)
fire("PLAYER_LEAVING_WORLD")
fire("PLAYER_ENTERING_WORLD")
check("loading-screen collection ran", count("loading screen:") >= 1)
cmd("status")
check("status shows careful mode", string.find(lastMatch("collections take"), "~[23]%d%dms: careful mode") ~= nil)

print("2. careful mode: no stand-still or idle collections")
garbageMB(8)
speed = 0
seconds(10)
check("no stand-still collection", count("standing still:") == 0)
now = now + 400
seconds(3)
check("no idle collection", count("idle:") == 0)
speed = 7

print("3. careful mode: NPC windows and pressure still collect")
fire("MERCHANT_SHOW")
check("merchant collection ran", count("merchant:") == 1)
local _, thr = gcinfo()
do
  local junk = {}
  local i = 0
  while gcinfo() < thr * 0.9 do
    for k = 1, 500 do i = i + 1; junk[i] = { i } end
    if i > 30000 then junk = {}; i = 0 end
    SF.scripts.OnUpdate()
  end
end
seconds(6)
check("pressure collection ran", count("pressure:") == 1)

print("4. fast collections switch back to normal")
gcCost = 0.01
for k = 1, 6 do now = now + 40; garbageMB(8); fire("MAIL_SHOW") end
cmd("status")
check("back to normal mode", string.find(lastMatch("collections take"), "normal mode") ~= nil)
garbageMB(8)
now = now + 40
speed = 0
seconds(5)
check("stand-still collection runs again", count("standing still:") == 1)
speed = 7

print("5. /ggc slow 0 turns careful mode off")
gcCost = 0.3
cmd("slow 0")
for k = 1, 3 do now = now + 40; garbageMB(8); fire("BANKFRAME_OPENED") end
cmd("status")
check("normal mode despite slow collections", string.find(lastMatch("collections take"), "normal mode") ~= nil)
cmd("slow 100")
gcCost = 0.01

---------------------------------------------------------------------------
print("6. another addon's collectgarbage() is attributed, not 'automatic'")
local autoBefore = count("automatic GC detected")
garbageMB(10)
seconds(1)
caller = "Wrekkit"
collectgarbage()
caller = nil
seconds(2)
check("logged as Wrekkit's collection", string.find(lastMatch("collection by"), "collection by Wrekkit: freed") ~= nil)
check("not counted as automatic", count("automatic GC detected") == autoBefore)
cmd("status")
check("status lists it by name", string.find(lastMatch("by other addons"), "Wrekkit 1") ~= nil)
local real = gcinfo() / 1024
check("live estimate matches real live memory", math.abs(liveMB() - real) < 1)

print("7. an addon setting the threshold (no collection) changes nothing")
local liveBefore = liveMB()
caller = "FpsWatch"
local u = gcinfo()
collectgarbage(u * 3)
caller = nil
seconds(2)
cmd("status")
check("no collection counted", string.find(lastMatch("by other addons"), "FpsWatch") == nil)
check("no automatic GC counted", count("automatic GC detected") == autoBefore)
check("live estimate unchanged", math.abs(liveMB() - liveBefore) < 0.5)
origCG(math.floor(u * 1.5) + 2048)   -- (back to a normal threshold for the next steps)
seconds(1)

print("8. an addon we couldn't wrap: detected from the heap dropping below the threshold")
garbageMB(10)
seconds(1)
unwrappedCG()
seconds(2)
check("counted as another addon's (unknown)", string.find(lastMatch("collection by"), "collection by unknown addon") ~= nil)
check("still not counted as automatic", count("automatic GC detected") == autoBefore)

print("9. the game's collector firing at the threshold is still 'automatic'")
do
  local _, t = gcinfo()
  local junk = {}
  local i = 0
  local _, cur = gcinfo()
  while cur == t do
    for k = 1, 500 do i = i + 1; junk[i] = { i } end
    if i > 30000 then junk = {}; i = 0 end
    SF.scripts.OnUpdate()
    _, cur = gcinfo()
  end
end
seconds(1)
check("counted as automatic", count("automatic GC detected") == autoBefore + 1)

print("10. another addon collecting in combat: combat headroom is restored")
combat = true; fire("PLAYER_REGEN_DISABLED")
garbageMB(6)
caller = "Wrekkit"
collectgarbage()
caller = nil
local used, t = gcinfo()
check("threshold raised again after it", t >= used + 32 * 1024 - 64)
combat = false; fire("PLAYER_REGEN_ENABLED")
seconds(1)

print("11. freeze detector names the addon")
cmd("hitch")
seconds(1)
garbageMB(10)
caller = "Wrekkit"
now = now + 0.4
collectgarbage()
caller = nil
frame(0.05)
check("freeze blamed on Wrekkit", string.find(lastMatch("freeze"), "run by Wrekkit") ~= nil)
cmd("hitch 0")

---------------------------------------------------------------------------
print("12. garbage creation rate")
cmd("allocwarn 1")
now = now + 120
for s = 1, 40 do
  for f = 1, 10 do
    garbageMB(0.2)           -- ~2 MB/s
    frame(0.1)
  end
end
cmd("status")
local _, _, rate = string.find(lastMatch("garbage created"), "([%d%.]+) MB/s now")
rate = tonumber(rate)
check("rate is measured (about 2 MB/s)", rate and rate > 1.2 and rate < 3.5)
check("warning shown above the limit", count("garbage is being created at") == 1)
for s = 1, 20 do for f = 1, 10 do garbageMB(0.2); frame(0.1) end end
check("warning not repeated within 10 minutes", count("garbage is being created at") == 1)

---------------------------------------------------------------------------
print("13. a wrapper that blocks collectgarbage is reported, not counted")
FRAMES = {}
log = {}
DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) table.insert(log, m); print("  " .. m) end }
GentleGCDB = nil
SlashCmdList = {}
collectgarbage = function(n) end      -- an addon loaded before us that swallows every call
dofile(arg[1])
F = FRAMES[1]
fire("ADDON_LOADED", "GentleGC")
SlashCmdList.GENTLEGC("debug 1")
garbageMB(8)
SlashCmdList.GENTLEGC("now")
check("reported as blocked", count("did not run") == 1)
SlashCmdList.GENTLEGC("status")
check("not counted as a collection", string.find(lastMatch("session:"), "0 collections") ~= nil)
check("ratio not learned from it", count("not measured yet") == 1)

print(FAILED and "SOME TESTS FAILED" or "ALL TESTS PASSED")
