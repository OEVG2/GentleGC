-- WoW API stubs ------------------------------------------------------------
format = string.format
local now = 1000
function GetTime() return now end
local combat, afk = false, false
function UnitAffectingCombat() return combat end
function UnitIsAFK() return afk end
local log = {}
DEFAULT_CHAT_FRAME = { AddMessage = function(self, m) table.insert(log, m); print("  chat: " .. m) end }
SlashCmdList = {}
FRAMES = {}
function CreateFrame()
  local F = { scripts = {}, events = {} }
  function F:RegisterEvent(e) self.events[e] = true end
  function F:UnregisterEvent(e) self.events[e] = nil end
  function F:SetScript(k, f) self.scripts[k] = f end
  table.insert(FRAMES, F)
  return F
end
local function fire(e, a1)
  assert(F.events[e], "not registered: " .. e)
  event, arg1 = e, a1; this = F
  F.scripts.OnEvent()
end
local function update(sec)            -- advance time in 0.1s frames
  local n = sec * 10
  for i = 1, n do now = now + 0.1; arg1 = 0.1; this = F; F.scripts.OnUpdate() end
end

-- live data (~8 MB) and a garbage generator -------------------------------
LIVE = {}
for i = 1, 60000 do LIVE[i] = { i, "x" .. i } end
local function makeGarbage(mb)
  local t = {}
  for i = 1, mb * 6000 do t[i] = { i, i } end   -- roughly 1 MB per 6000 small tables
end

collectgarbage()
dofile(arg[1])
F = FRAMES[1]
HF = FRAMES[2]
fire("ADDON_LOADED", "GentleGC")
local cmd = SlashCmdList.GENTLEGC
cmd("debug 2")

local function count() local n = 0; for _, m in ipairs(log) do if string.find(m, "%->") then n = n + 1 end end; return n end
local function check(name, cond) print((cond and "PASS " or "FAIL ") .. name); if not cond then FAILED = true end end

print("1. login loading screen collects")
makeGarbage(6); fire("PLAYER_ENTERING_WORLD"); check("collected at login", count() == 1)

print("2. small garbage is skipped")
makeGarbage(1); now = now + 60; fire("MERCHANT_SHOW"); check("skipped (little garbage)", count() == 1)

print("3. interval respected")
makeGarbage(6); fire("BANKFRAME_OPENED"); fire("MAIL_SHOW")
check("one collection for two quick events", count() == 2)
makeGarbage(6); fire("MAIL_SHOW"); check("within minInterval -> no collect", count() == 2)

print("4. combat: threshold raised, no automatic GC, deferred collection after")
now = now + 100
local used0, thr0 = gcinfo()
fire("PLAYER_REGEN_DISABLED"); combat = true
local _, thr1 = gcinfo()
check("threshold raised by headroom", thr1 >= used0 + 32 * 1024 - 1)
-- allocate past the ORIGINAL threshold but keep it alive so we can see it
local keep = {}
local target = thr0 + 1024
while gcinfo() < target do table.insert(keep, { 1, 2, 3 }) end
local usedMid = gcinfo()
check("heap went past old threshold without auto-GC", usedMid > thr0)
update(20); check("no collection in combat (fallback timer)", count() == 2)
fire("ZONE_CHANGED_NEW_AREA"); check("no collection on safe event in combat", count() == 2)
keep = nil
fire("PLAYER_REGEN_ENABLED"); combat = false
check("collected after combat", count() == 3)
local u2, t2 = gcinfo(); check("threshold back to normal (2x live)", t2 <= u2 * 2 + 64)

print("5. short fight with nothing to collect restores threshold")
now = now + 100
local _, tb = gcinfo(); fire("PLAYER_REGEN_DISABLED"); fire("PLAYER_REGEN_ENABLED")
local _, ta = gcinfo(); check("threshold restored", ta == tb); check("no collection", count() == 3)

print("6. pressure: collect pre-emptively near threshold, out of combat")
now = now + 40
local keep2 = {}
local _, thr = gcinfo()
while gcinfo() < thr * 0.86 do table.insert(keep2, { 1, 2 }) end
keep2 = nil
update(1.5); check("pressure collection", count() == 4)

print("7. fallback idle collection after maxInterval")
makeGarbage(8); update(310); check("idle collection", count() == 5)

print("8. AFK")
makeGarbage(8); now = now + 60; afk = true; fire("PLAYER_FLAGS_CHANGED"); afk = false
check("afk collection", count() == 6)

print("8b. automatic GC is detected and resynced")
cmd("debug 2")
local nAuto = 0
for _, m in ipairs(log) do if string.find(m, "automatic GC detected") then nAuto = nAuto + 1 end end
makeGarbage(25)   -- more than the threshold allows: Lua collects on its own
update(1.1)
local nAuto2 = 0
for _, m in ipairs(log) do if string.find(m, "automatic GC detected") then nAuto2 = nAuto2 + 1 end end
check("automatic GC detected", nAuto2 > nAuto)
local u, t = gcinfo()
check("pressure not falsely triggered after auto GC", u < t * 0.85)

print("9. slash commands")
cmd("interval 45"); check("interval set", GentleGCDB.minInterval == 45)
cmd("now"); check("manual collect", count() >= 7)
cmd(""); cmd("bogus"); cmd("reset"); check("reset", GentleGCDB.minInterval == 30)

print("10. summary report")
cmd("debug 1"); update(301)
local found = false
for _, m in ipairs(log) do if string.find(m, "last %d+ min") then found = true end end
check("summary printed", found)

print(FAILED and "SOME TESTS FAILED" or "ALL TESTS PASSED")
