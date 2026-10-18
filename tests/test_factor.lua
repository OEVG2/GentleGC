-- Collector-ratio tests: simulates a client mod (like wow_turbo) whose collector
-- sets the threshold to 1.25x live instead of Lua 5.0's 2x.
-- Run: lua5.0 tests/test_factor.lua GentleGC.lua
format = string.format
local now = 1000
function GetTime() return now end
function UnitAffectingCombat() return false end
function UnitIsAFK() return false end
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

local FACTOR = 1.25
local origCG = collectgarbage
local function setThreshold() local u = gcinfo(); origCG(math.floor(u * FACTOR)) end
-- the modded collector: a full collection leaves the threshold at FACTOR x live
collectgarbage = function(n)
  if n == nil or n == 0 then origCG(); setThreshold() else origCG(n) end
end
-- the game's own automatic collection under the mod
local function autoGC() origCG(); setThreshold() end

LIVE = {}
for i = 1, 300000 do LIVE[i] = { i } end
autoGC()

dofile(arg[1])
local F = FRAMES[1]
local function fire(e, a1) event, arg1 = e, a1; this = F; F.scripts.OnEvent() end
fire("ADDON_LOADED", "GentleGC")
local cmd = SlashCmdList.GENTLEGC
cmd("debug 2")

local function count(pat) local n = 0; for _, m in ipairs(log) do if string.find(m, pat) then n = n + 1 end end; return n end
local function lastMatch(pat) for i = table.getn(log), 1, -1 do if string.find(log[i], pat) then return log[i] end end; return "" end
local function check(name, c) print((c and "PASS " or "FAIL ") .. name); if not c then FAILED = true end end
local function tick(sec) local n = sec * 10; for i = 1, n do now = now + 0.1; arg1 = 0.1; this = F; F.scripts.OnUpdate() end end
local function liveMB() local _, _, v = string.find(lastMatch("heap .* live ~"), "live ~([%d%.]+)mb"); return tonumber(v) end
local function realLiveMB() local u = gcinfo(); return u / 1024 end
-- garbage that stays below the 1.25x threshold so Lua never collects on its own
local function garbage(kb)
  local target = gcinfo() + kb
  local t = {}
  local i = 0
  while gcinfo() < target do i = i + 1; t[i] = { i, i } end
end

print("1. automatic GC before GentleGC has measured the ratio")
now = now + 60
garbage(512)
autoGC()
tick(1.1)
check("automatic GC detected", count("automatic GC detected") == 1)
cmd("status")
local _, thr = gcinfo()
check("live estimate is not threshold/2", liveMB() > (thr / 2) / 1024 + 1)
check("status says the ratio isn't measured yet", count("not measured yet") == 1)

print("2. no useless collection right after it (the bug)")
now = now + 60
fire("MERCHANT_SHOW")
check("skipped: almost no garbage", count("merchant:") == 0)

print("3. own collection measures the ratio")
cmd("now")
cmd("status")
check("ratio measured as 1.25x", string.find(lastMatch("collector:"), "threshold = 1%.25x live %(measured%)") ~= nil)
check("garbage minimum capped at half the 25% room", string.find(lastMatch("collector:"), "collecting from 12%.5%% garbage") ~= nil)

print("4. automatic GC after measuring: live estimate is right")
garbage(512)
autoGC()
tick(1.1)
cmd("status")
local real = realLiveMB()
check("live estimate within 1mb of real live memory", math.abs(liveMB() - real) < 1)
now = now + 60
fire("BANKFRAME_OPENED")
check("still no useless collection", count("bank:") == 0)

print("5. enough garbage: normal collections still happen")
local live = gcinfo()
garbage(math.floor(live * 0.14))     -- 14% of live: above the 12.5% minimum
now = now + 60
fire("MAIL_SHOW")
check("mailbox collection ran", count("mailbox:") == 1)
check("it freed real garbage", string.find(lastMatch("mailbox:"), "freed [1-9]") ~= nil)

print("6. pressure fires before the 1.25x threshold")
now = now + 60
local l2, t2 = gcinfo()
-- pressure point = live + 70% of the room = 1.175x live; stop short of 1.25x
garbage(math.floor(l2 * 0.19))
local used = gcinfo()
check("heap is between pressure point and threshold", used > l2 * 1.175 and used < t2)
tick(1.1)
check("pressure collection ran", count("pressure:") == 1)
check("pressure collection freed garbage", string.find(lastMatch("pressure:"), "freed [1-9]") ~= nil)
check("no automatic GC needed", count("automatic GC detected") == 2)

print("7. pressure can't loop")
tick(10)
check("one pressure collection only", count("pressure:") == 1)

print(FAILED and "SOME TESTS FAILED" or "ALL TESTS PASSED")
