-- Freeze detector tests. Run: lua5.0 tests/test_hitch.lua GentleGC.lua
format = string.format
local now = 1000
function GetTime() return now end
local combat = false
function UnitAffectingCombat() return combat end
function UnitIsAFK() return false end
local log = {}
DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) table.insert(log, m); print("  " .. m) end }
SlashCmdList = {}

-- a dragged window: an anonymous child of a named frame
local auxFrame = { GetName = function() return "AuxFrame" end }
local auxButton = { GetName = function() return nil end, GetParent = function() return auxFrame end }
local focus = nil
function GetMouseFocus() return focus end

FRAMES = {}
function CreateFrame()
  local f = { scripts = {} }
  function f:RegisterEvent() end
  function f:UnregisterEvent() end
  function f:SetScript(k, fn) self.scripts[k] = fn end
  table.insert(FRAMES, f)
  return f
end

LIVE = {}
for i = 1, 300000 do LIVE[i] = { i } end
collectgarbage()
dofile(arg[1])
local F, HF = FRAMES[1], FRAMES[2]
local function fire(e, a1) event, arg1 = e, a1; F.scripts.OnEvent() end
fire("ADDON_LOADED", "GentleGC")
local cmd = SlashCmdList.GENTLEGC

-- one rendered frame taking `sec` seconds; `during` runs inside it
local function frame(sec, during)
  if during then during() end
  now = now + sec
  arg1 = sec
  if F.scripts.OnUpdate then F.scripts.OnUpdate() end
  if HF.scripts.OnUpdate then HF.scripts.OnUpdate() end
end
local function frames(n) for i = 1, n do frame(0.016) end end
local function last() return log[table.getn(log)] or "" end
local function freezes() local n = 0; for _, m in ipairs(log) do if string.find(m, "freeze %d") then n = n + 1 end end; return n end
local function check(name, c) print((c and "PASS " or "FAIL ") .. name); if not c then FAILED = true end end

check("off by default", HF.scripts.OnUpdate == nil)
cmd("hitch")
check("/ggc hitch turns it on at 250ms", HF.scripts.OnUpdate ~= nil and GentleGCDB.hitchMs == 250)

frames(5); frame(0.2); frames(3)
check("normal and 200ms frames are not reported", freezes() == 0)

print("-- freeze with no GC while dragging AuxFrame")
focus = auxButton
frame(2.0)
check("2s freeze reported", freezes() == 1)
check("blamed on something other than GC", string.find(last(), "no garbage collection") ~= nil)
check("names the window under the mouse", string.find(last(), "mouse over AuxFrame") ~= nil)
focus = nil
frames(3)

print("-- freeze containing the game's automatic GC")
frame(0.6, function()
  local _, t = gcinfo()
  local junk = {}
  while true do                      -- allocate until Lua collects on its own
    local used, thr = gcinfo()
    if thr ~= t then break end
    table.insert(junk, { 1, 2, 3 })
    if table.getn(junk) > 5000 then junk = {} end
  end
end)
check("automatic GC identified", string.find(last(), "not run by GentleGC") ~= nil)
frames(3)

print("-- freeze containing a GentleGC collection")
local g = {}; for i = 1, 60000 do g[i] = { i } end; g = nil
frame(0.4, function() cmd("now") end)
check("GentleGC collection identified", string.find(last(), "GentleGC collection %(manual%)") ~= nil)
frames(3)

print("-- freeze that allocates a lot without collecting")
local keep = {}
frame(0.5, function() for i = 1, 40000 do keep[i] = { i, i } end end)
check("allocation reported", string.find(last(), "allocated during it") ~= nil)
check("still not blamed on GC", string.find(last(), "no garbage collection") ~= nil)
keep = nil
frames(3)

print("-- entering combat (threshold raise) inside a freeze is not a GC")
combat = true
frame(0.5, function() fire("PLAYER_REGEN_DISABLED") end)
check("threshold raise not mistaken for GC", string.find(last(), "no garbage collection") ~= nil)
check("marked in combat", string.find(last(), "%(in combat%)") ~= nil)
combat = false; fire("PLAYER_REGEN_ENABLED"); frames(3)

print("-- loading screens are ignored")
local before = freezes()
fire("PLAYER_LEAVING_WORLD"); frame(15); frame(5)
fire("PLAYER_ENTERING_WORLD"); frame(1.5); frame(1.0); frame(0.8)
check("no reports for loading screen or the frames right after", freezes() == before)
frame(1.0)
check("reports again afterwards", freezes() == before + 1)

print("-- history and off")
local n0 = table.getn(log)
cmd("hitches")
check("/ggc hitches lists recorded freezes", table.getn(log) - n0 >= 5)
cmd("hitch 0")
check("/ggc hitch 0 turns it off", HF.scripts.OnUpdate == nil)
local b = freezes(); frame(3); check("no reports when off", freezes() == b)
cmd("hitch 500"); frame(0.4); check("custom limit respected (400ms < 500ms)", freezes() == b)

print(FAILED and "SOME TESTS FAILED" or "ALL TESTS PASSED")
