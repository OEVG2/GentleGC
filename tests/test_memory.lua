-- Per-addon memory: the !!!!GentleGC_Memory companion measuring a simulated
-- login, and Gentle GC reporting it.
-- Run: lua5.0 tests/test_memory.lua GentleGC.lua "!!!!GentleGC_Memory/GentleGC_Memory.lua"
local MAIN, COMPANION = arg[1], arg[2]
format = string.format
local now = 1000
function GetTime() return now end
function UnitAffectingCombat() return false end
function UnitIsAFK() return false end
function date() return "2026-10-21 12:00" end
local log = {}
DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) table.insert(log, m); print("  " .. m) end }

local origCG = collectgarbage
local ADDONS, LOADED

-- frames, with events dispatched in registration order like the client
local FRAMES
function CreateFrame()
  local f = { scripts = {}, events = {} }
  function f:RegisterEvent(e) self.events[e] = true end
  function f:UnregisterEvent(e) self.events[e] = nil end
  function f:UnregisterAllEvents() self.events = {} end
  function f:RegisterAllEvents() end
  function f:SetScript(k, fn) self.scripts[k] = fn end
  table.insert(FRAMES, f)
  return f
end
local function fire(e, a1)
  for _, f in ipairs(FRAMES) do
    if f.events[e] and f.scripts.OnEvent then event, arg1 = e, a1; this = f; f.scripts.OnEvent() end
  end
end

function GetNumAddOns() return table.getn(ADDONS) end
function GetAddOnInfo(i)
  local a = type(i) == "number" and ADDONS[i] or nil
  if not a then return nil end
  return a.name, a.name, "", a.enabled and 1 or nil
end
function IsAddOnLoaded(name) return LOADED[name] and 1 or nil end

local function count(pat) local n = 0; for _, m in ipairs(log) do if string.find(m, pat) then n = n + 1 end end; return n end
local function lastMatch(pat) for i = table.getn(log), 1, -1 do if string.find(log[i], pat) then return log[i] end end; return "" end
local function check(name, c) print((c and "PASS " or "FAIL ") .. name); if not c then FAILED = true end end

-- an addon's data: tables kept in a global, roughly `mb` megabytes
KEEP = {}
local function allocate(name, mb)
  local t = {}
  for i = 1, mb * 9000 do t[i] = { i } end
  KEEP[name] = t
end

-- one full login: every enabled addon in order, then login and world events
-- sizes: MB per addon; withCompanion: install the companion
local function login(sizes, withCompanion)
  FRAMES, LOADED, KEEP = {}, {}, {}
  collectgarbage = origCG
  SlashCmdList = {}
  GentleGCMemory = nil
  origCG()
  for _, a in ipairs(ADDONS) do
    if a.enabled and (withCompanion or a.name ~= "!!!!GentleGC_Memory") then
      if a.name == "!!!!GentleGC_Memory" then
        dofile(COMPANION)
      elseif a.name == "GentleGC" then
        dofile(MAIN)
      else
        allocate(a.name, sizes[a.name] or 0)
      end
      LOADED[a.name] = true
      fire("ADDON_LOADED", a.name)
    end
  end
  allocate("variables", 0.5)
  fire("PLAYER_LOGIN")
  allocate("login setup", 3)
  fire("PLAYER_ENTERING_WORLD")
end

local SIZES = { ["!!!ClassicAPI"] = 1, Atlas = 2, Bagshui = 5, pfQuest = 20, Wrekkit = 1 }
ADDONS = {
  { name = "!!!ClassicAPI", enabled = true },
  { name = "!!!!GentleGC_Memory", enabled = true },
  { name = "Atlas", enabled = true },
  { name = "Bagshui", enabled = true },
  { name = "GentleGC", enabled = true },
  { name = "pfQuest", enabled = true },
  { name = "Wrekkit", enabled = true },
}
-- (the client loads "!!!!" before "!!!", but the test puts ClassicAPI first to
-- check the "loaded before" list)

local function rowMB(name)
  local m = GentleGCMemoryDB.measured
  for i = 1, table.getn(m.rows) do if m.rows[i][1] == name then return m.rows[i][2] / 1024 end end
end
local function near(v, want) return v and math.abs(v - want) <= math.max(0.35, want * 0.15) end

print("1. first login with the companion: measured")
login(SIZES, true)
local m = GentleGCMemoryDB and GentleGCMemoryDB.measured
check("a measurement was saved", m ~= nil and table.getn(m.rows) >= 5)
check("first login is the reason", m and m.reason == "first login")
check("Atlas ~2 MB", near(rowMB("Atlas"), 2))
check("Bagshui ~5 MB", near(rowMB("Bagshui"), 5))
check("pfQuest ~20 MB", near(rowMB("pfQuest"), 20))
check("Wrekkit ~1 MB", near(rowMB("Wrekkit"), 1))
check("ClassicAPI listed as loaded before", m and m.before[1] == "!!!ClassicAPI")
check("summary printed after loading", string.find(lastMatch("measured your addons"), "Biggest: pfQuest") ~= nil)
check("companion stopped measuring", GentleGCMemory.measuring == false)

print("2. /ggc addons")
local cmd = SlashCmdList.GENTLEGC
cmd("addons")
check("header line", count("addon memory at login on 2026%-10%-21") == 1)
local first
for i = 1, table.getn(log) do if string.find(log[i], "addon memory at login") then first = log[i + 1] end end
check("biggest addon on the first row", first and string.find(first, "pfQuest") ~= nil)
check("login stage shown", count("then addons setting up at login") == 1)
check("loaded-before line", count("counted in the interface number: !!!ClassicAPI") == 1)
cmd("")
check("status names the biggest addons", string.find(lastMatch("biggest addons"), "pfQuest") ~= nil)
check("measuring collections not counted as other addons'", count("by other addons") == 0)
check("nor as automatic", string.find(lastMatch("session:"), "0 automatic") ~= nil)

print("3. next login, same addons: not measured again")
local when = m
login(SIZES, true)
check("same measurement kept", GentleGCMemoryDB.measured == when)
check("no summary this time", count("measured your addons") == 1)

print("4. an addon added: measured again")
table.insert(ADDONS, { name = "ShaguTweaks", enabled = true })
SIZES.ShaguTweaks = 3
login(SIZES, true)
check("new measurement", GentleGCMemoryDB.measured ~= when and GentleGCMemoryDB.measured.reason == "addons changed")
check("ShaguTweaks ~3 MB", near(rowMB("ShaguTweaks"), 3))

print("5. /ggc addons measure: measured on the next reload")
local before = GentleGCMemoryDB.measured
SlashCmdList.GENTLEGC("addons measure")
check("asks for a reload", count("type /reload to measure") == 1)
login(SIZES, true)
check("measured because it was requested", GentleGCMemoryDB.measured ~= before and GentleGCMemoryDB.measured.reason == "requested")

print("6. without the companion")
GentleGCMemoryDB = nil
login(SIZES, false)
SlashCmdList.GENTLEGC("addons")
check("explains the companion folder", count("needs the !!!!GentleGC_Memory folder") == 1)

print(FAILED and "SOME TESTS FAILED" or "ALL TESTS PASSED")
