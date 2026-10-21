--[[
  GentleGC - unified edition (for WoW 1.18.1 clients, Lua 5.0)

  Lua 5.0 has no incremental collector: every collection is a full
  stop-the-world mark + sweep, and the automatic collector fires whenever the
  heap reaches its threshold. Stock Lua 5.0 sets that threshold to 2x live
  memory after every collection, but the 1.12 client replaces that rule
  (luaM_adjustGC): threshold = live + max(min(carry-over headroom, allocator
  pool capacity), live/4), so at least 1.25x and variable. GentleGC measures
  the ratio from full collections and plans with the lowest one seen.
  We can't make a single collection cheaper, but we can choose WHEN it happens:

    * collect at moments the player won't feel (loading screens, AFK, NPC
      windows, right after combat)                     -- from jrc13245's fork
    * run from event handlers, keeping the OnUpdate path only as a fallback
                                                       -- from jrc13245's fork
    * keep reporting on its own timer, separate from collecting
                                                       -- from TheRealFayz's fork
  and new in this version:
    * skip collections that would free little (a pause costs about the same
      whether it frees 1 MB or 100 MB, because marking live data dominates)
    * collect pre-emptively out of combat when the heap is close to the
      threshold, so the automatic collector doesn't fire on the next pull
    * raise the threshold for the duration of combat so the automatic
      collector is pushed to after the fight, then restore it
    * saved settings and a /ggc slash command
  optional, used only when the ClassicAPI client mod is installed:
    * collect when you've been standing still for a few seconds (GetUnitSpeed)
    * run the once-a-second check from C_Timer instead of a frame OnUpdate
  when collections are slow (default: averaging 100 ms or more):
    * careful mode: no stand-still or idle collections, only loading screens,
      death, taxi, NPC windows, AFK, after combat, and pressure
  diagnostics:
    * per-addon memory, measured at the loading screen by the optional
      !!!!GentleGC_Memory companion (it has to load before other addons)
    * collections run by other addons are timed and attributed by name
    * garbage creation rate (MB/s), with a warning when it is very high
    * /ggc hitch: report frames that take too long, and whether a garbage
      collection (ours, the game's, or another addon's) happened in them
]]

local ADDON = "GentleGC"

-- The collectgarbage GentleGC itself uses. The global is wrapped further down
-- so collections run by other addons can be attributed; our own calls go
-- straight to the function that was there when we loaded.
local rawCollect = collectgarbage

local DEFAULTS = {
  debug            = 0,    -- 0 off, 1 periodic summary, 2 also every collection
  minInterval      = 30,   -- seconds: never collect more often than this
  maxInterval      = 300,  -- seconds: out-of-combat fallback collection
  minGarbageMB     = 4,    -- skip a collection that would free less than this...
  minGarbagePct    = 15,   -- ...or less than this % of live memory (the larger wins)
  pressureRoomPct  = 70,   -- out of combat: collect early once garbage fills this % of the room
                           -- between live memory and the auto-GC threshold (70 = 85% of a 2x threshold)
  combatHeadroomMB = 32,   -- extra room before auto-GC during combat (0 = off)
  reportInterval   = 300,  -- seconds between debug summaries
  stillSeconds     = 3,    -- ClassicAPI only: collect after standing still this long (0 = off)
  hitchMs          = 0,    -- freeze detector: report frames longer than this (0 = off)
  slowMs           = 100,  -- careful mode when collections average this long (0 = never)
  allocWarnMB      = 10,   -- warn when garbage is created faster than this, MB/s (0 = off)
}

local db = {}

local function ApplyDefaults()
  if type(GentleGCDB) ~= "table" then GentleGCDB = {} end
  db = GentleGCDB
  for k, v in pairs(DEFAULTS) do
    if db[k] == nil then db[k] = v end
  end
  db.pressurePct = nil   -- replaced by pressureRoomPct in 2.3
end
ApplyDefaults()   -- usable immediately; re-run once saved settings load

local frame = CreateFrame("Frame")
local inCombat = false
local lastGC = 0           -- GetTime() of our last collection
local liveKB = 0           -- heap size right after the last collection (live-data estimate)
local savedThreshold = nil -- threshold before we raised it for combat
local knownThreshold = 0   -- last threshold we saw or set (detects automatic GCs)
local ratioLast, ratioMin = nil, nil   -- threshold / live after full collections (last, lowest)
local lastUsed = 0         -- heap at the last sample (per frame)
local allocTotalKB, allocPeriodKB, allocWindowKB = 0, 0, 0
local allocRate = 0        -- KB/s, ~30 s moving average
local nextAllocWarn = 0
local pauseAvg = nil       -- ms, moving average of our own collections
local careful = false
local extByName = {}       -- session: collections run by other addons, by addon name
local extSeq, extMs, extName = 0, 0, nil   -- last external collection (freeze detector)
do
  local used, threshold = gcinfo()
  -- before any collection we can only assume the stock 2x ratio; the first
  -- collection (usually the login loading screen) measures the real one
  liveKB = math.min(used, math.floor(threshold / 2))
  knownThreshold = threshold
  lastUsed = used
end
local tick, reportElapsed = 0, 0
local hasSpeed, hasTicker = false, false   -- ClassicAPI features, detected at load
local stillFor, lastCheck = 0, 0
local loadTime = 0                         -- the idle fallback counts from login
-- for the freeze detector: counters, because GetTime() only ticks every ~15ms
local ownCollectSeq, ownCollectMs, ownCollectReason = 0, 0, nil
local ownThresholdSeq = 0                  -- bumped when we change the threshold without collecting
local EnterCombatThreshold    -- defined below, used by Sync()
local StartScheduler          -- defined below, called on ADDON_LOADED
local HitchLoading, HitchEnable -- freeze detector, defined below
local ShowAddonSummary        -- per-addon memory, defined below

local function NewStats() return { count = 0, freed = 0, skipped = 0, ms = 0, worst = 0, auto = 0, autoCombat = 0, ext = 0, extCombat = 0 } end
local period, total = NewStats(), NewStats()

---------------------------------------------------------------------------
-- helpers
---------------------------------------------------------------------------

local function Msg(text)
  DEFAULT_CHAT_FRAME:AddMessage("|cff88ff88GentleGC|r " .. text)
end

local function DebugLevel()
  -- old builds used the global `ggc_debug`; still honour it
  if ggc_debug then return 2 end
  return db.debug or 0
end

local function MB(kb) return kb / 1024 end

local function ResetStats(s)
  s.count, s.freed, s.skipped, s.ms, s.worst, s.auto, s.autoCombat, s.ext, s.extCombat = 0, 0, 0, 0, 0, 0, 0, 0, 0
end

-- Wall-clock timing. debugprofilestop() has ms precision but resets a timer
-- other addons may use, so it is only touched while debugging or detecting freezes.
local function StartTimer()
  if (DebugLevel() > 0 or db.hitchMs > 0) and debugprofilestart then
    debugprofilestart()
    return nil
  end
  return GetTime()
end

local function StopTimer(t0)
  if t0 == nil then return debugprofilestop() end
  return (GetTime() - t0) * 1000
end

-- How much would a collection free? Estimate: everything allocated since
-- the last collection beyond the live set we measured then.
local function GarbageKB()
  return gcinfo() - liveKB
end

-- Allocation accounting: heap growth between samples is new allocation.
local function AddAlloc(kb)
  if kb <= 0 then return end
  allocTotalKB = allocTotalKB + kb
  allocPeriodKB = allocPeriodKB + kb
  allocWindowKB = allocWindowKB + kb
end

local function Account(used)
  AddAlloc(used - lastUsed)
  lastUsed = used
end

-- Record a full collection's threshold ratio. The client's rule makes it
-- vary (at least 1.25x), so planning uses the lowest ratio seen.
local function LearnRatio(after, threshold)
  if after <= 1024 then return end
  local f = threshold / after
  if f <= 1.05 or f >= 10 then return end
  local first = ratioMin == nil
  ratioLast = f
  if not ratioMin or f < ratioMin then ratioMin = f end
  if first and DebugLevel() >= 1 then
    Msg(format("collector threshold measured: %.2fx live memory", f))
  end
end

local function CountExternal(name, ms, freed)
  for _, s in ipairs({ period, total }) do
    s.ext = s.ext + 1
    if inCombat then s.extCombat = s.extCombat + 1 end
  end
  name = name or "unknown addon"
  extByName[name] = (extByName[name] or 0) + 1
  extSeq, extMs, extName = extSeq + 1, ms, name
  if DebugLevel() >= 2 then
    Msg(format("collection by %s%s%s", name,
      freed and format(": freed %.1fmb", MB(freed)) or "",
      ms and format(" in %dms", ms) or ""))
  end
end

-- After someone else's collection the collector has set a fresh threshold,
-- and any raised combat threshold is gone: in combat, grant the headroom again.
local function AfterForeignCollection()
  savedThreshold = nil
  if inCombat then EnterCombatThreshold() end
end

-- Detect collections we didn't run and thresholds we didn't set. A heap
-- drop means a collection; a changed threshold without a drop means someone
-- set it with collectgarbage(n). For a collection: the game's
-- collector only fires when the heap reaches the threshold, so if the heap
-- was well below it one frame earlier, another addon ran it.
local function Sync()
  local used, threshold = gcinfo()
  -- the heap only shrinks through a collection, which may leave the
  -- threshold unchanged if live memory happens to be the same as before
  if threshold == knownThreshold and used >= lastUsed - 1024 then Account(used); return end
  local oldThreshold = knownThreshold
  knownThreshold = threshold
  if oldThreshold == 0 then Account(used); return end

  if used < lastUsed - 1024 and GentleGCMemory and GentleGCMemory.measuring then
    -- the memory companion collecting between addons at the loading screen
    liveKB = used
    lastUsed = used
    return
  end

  if used < lastUsed - 1024 then
    local est = used
    if ratioMin then est = math.min(used, math.floor(threshold / ratioMin)) end
    liveKB = est
    if lastUsed < oldThreshold * 0.9 then
      AddAlloc(used - est)
      CountExternal(nil, nil, lastUsed - est)
    else
      AddAlloc(oldThreshold - lastUsed)
      AddAlloc(used - est)
      for _, s in ipairs({ period, total }) do
        s.auto = s.auto + 1
        if inCombat then s.autoCombat = s.autoCombat + 1 end
      end
      if DebugLevel() >= 2 then
        Msg(format("automatic GC detected%s (live ~%.1fmb)", inCombat and " in combat" or "", MB(liveKB)))
      end
    end
    lastUsed = used
    AfterForeignCollection()
  else
    -- threshold set by someone without collecting; live memory is unchanged
    Account(used)
    if inCombat then EnterCombatThreshold() end
  end
end

-- The garbage share at which the automatic collector fires is (ratio - 1):
-- 25% of live on this client, 100% on stock Lua. Never demand more than half.
local function EffectiveGarbagePct()
  return math.min(db.minGarbagePct, ((ratioMin or 2) - 1) * 50)
end

local function WorthCollecting()
  Sync()
  local need = math.max(db.minGarbageMB * 1024, liveKB * EffectiveGarbagePct() / 100)
  return GarbageKB() >= need
end

-- Heap size at which a pressure collection runs: a share of the room between
-- live memory and the threshold, so it works for any ratio.
local function PressurePointKB(threshold)
  local room = threshold - liveKB
  if room <= 0 then return threshold * 0.9 end
  return liveKB + room * db.pressureRoomPct / 100
end

-- Careful mode: collections are slow enough to be seen during play.
local function UpdateCareful(ms)
  pauseAvg = pauseAvg and (pauseAvg * 0.7 + ms * 0.3) or ms
  local was = careful
  if db.slowMs <= 0 then
    careful = false
  elseif careful then
    careful = pauseAvg >= db.slowMs * 0.75
  else
    careful = pauseAvg >= db.slowMs
  end
  if careful ~= was and DebugLevel() >= 1 then
    if careful then
      Msg(format("collections average %dms: careful mode - no stand-still or idle collections", pauseAvg))
    else
      Msg(format("collections average %dms: normal mode", pauseAvg))
    end
  end
end

---------------------------------------------------------------------------
-- collection
---------------------------------------------------------------------------

local function Collect(reason)
  Sync()
  local before, thresholdBefore = gcinfo()
  local t0 = StartTimer()
  rawCollect()                   -- full collection; the client sets a fresh threshold
  local ms = StopTimer(t0)
  local after, threshold = gcinfo()

  if threshold == thresholdBefore and after >= before - 256 then
    -- nothing happened: an addon that wraps collectgarbage blocked the call
    lastGC = GetTime()
    if DebugLevel() >= 1 then
      Msg(reason .. ": collection did not run (another addon blocks collectgarbage)")
    end
    return
  end

  liveKB = after
  lastUsed = after
  LearnRatio(after, threshold)
  UpdateCareful(ms)
  knownThreshold = threshold
  lastGC = GetTime()
  savedThreshold = nil           -- collectgarbage() already set a fresh threshold
  ownCollectSeq, ownCollectMs, ownCollectReason = ownCollectSeq + 1, ms, reason

  local freed = before - after
  for _, s in ipairs({ period, total }) do
    s.count = s.count + 1
    s.freed = s.freed + freed
    s.ms = s.ms + ms
    if ms > s.worst then s.worst = ms end
  end

  if DebugLevel() >= 2 then
    Msg(format("%s: %.1fmb -> %.1fmb (freed %.1fmb, next auto-GC at %.1fmb) in %dms",
      reason, MB(before), MB(after), MB(freed), MB(threshold), ms))
  end
end

-- reason:         label for debug output
-- ignoreInterval: true for moments where a pause is free (loading screen)
--                 or urgent (heap about to trigger the automatic collector)
-- silent:         don't count a skip (periodic checks retry every second)
local function TryCollect(reason, ignoreInterval, silent)
  if inCombat then return end
  if not ignoreInterval and GetTime() - lastGC < db.minInterval then return end
  if not WorthCollecting() then
    if silent then return end
    period.skipped = period.skipped + 1
    total.skipped = total.skipped + 1
    return
  end
  Collect(reason)
end

---------------------------------------------------------------------------
-- combat: push the automatic collector past the end of the fight
---------------------------------------------------------------------------

EnterCombatThreshold = function()
  if db.combatHeadroomMB <= 0 then return end
  local used, threshold = gcinfo()
  local want = used + db.combatHeadroomMB * 1024
  if want > threshold then
    savedThreshold = savedThreshold or threshold
    rawCollect(want)             -- raising the threshold never triggers a collection
    local _, t = gcinfo()
    knownThreshold = t
    ownThresholdSeq = ownThresholdSeq + 1
  end
end

local function EnterCombat()
  Sync()
  inCombat = true
  EnterCombatThreshold()
end

local function LeaveCombat()
  Sync()
  inCombat = false
  local used = gcinfo()
  if savedThreshold and used >= savedThreshold then
    -- we deferred a collection that was due during the fight: do it now
    Collect("post-combat (deferred)")
    return
  end
  TryCollect("post-combat")
  if savedThreshold then
    rawCollect(savedThreshold)
    savedThreshold = nil
    local _, t = gcinfo()
    knownThreshold = t
    ownThresholdSeq = ownThresholdSeq + 1
  end
end

---------------------------------------------------------------------------
-- other addons' collections
---------------------------------------------------------------------------

local gfind = string.gfind or string.gmatch

-- Name the addon that called us, from the call stack (Interface\AddOns\Name\...).
local function CallerAddon()
  if not debugstack then return nil end
  local ok, stack = pcall(debugstack)
  if not ok or type(stack) ~= "string" then return nil end
  for name in gfind(stack, "[Aa][Dd][Dd][Oo][Nn][Ss][\\/]([^\\/]+)[\\/]") do
    if name ~= ADDON then return name end
  end
  return nil
end

-- Wraps the global so a collection another addon runs is timed, attributed,
-- and doesn't throw off our live-memory estimate. Queries ("count" and other
-- string options) pass straight through without allocating.
local function WrappedCollect(a, b)
  if type(a) == "string" and a ~= "collect" then return rawCollect(a, b) end
  Sync()
  local before = gcinfo()
  local t0 = GetTime()
  local r = rawCollect(a, b)
  local ms = (GetTime() - t0) * 1000
  local after, threshold = gcinfo()
  local full = a == nil or a == 0 or a == "collect"
  if after < before - 256 or (full and threshold ~= knownThreshold) then
    -- a full collection (or a threshold set below the heap, which collects)
    liveKB = after
    lastUsed = after
    knownThreshold = threshold
    LearnRatio(after, threshold)
    CountExternal(CallerAddon(), ms, before - after)
    AfterForeignCollection()
  elseif threshold ~= knownThreshold then
    knownThreshold = threshold
    Account(after)
    if inCombat then EnterCombatThreshold() end
  end
  return r
end

if type(rawCollect) == "function" then
  collectgarbage = WrappedCollect
end

-- Per-frame heap sample: one gcinfo() call, no allocation. It keeps lastUsed
-- one frame old, which is what tells the game's collector apart from a
-- collection run by an addon we couldn't wrap.
local sampleFrame             -- created on ADDON_LOADED
local function SampleOnUpdate()
  local used, threshold = gcinfo()
  if threshold ~= knownThreshold or used < lastUsed - 1024 then
    Sync()
  else
    AddAlloc(used - lastUsed)
    lastUsed = used
  end
end

---------------------------------------------------------------------------
-- events
---------------------------------------------------------------------------

-- Moments when a short stall goes unnoticed. Window-*close* events and
-- frequent sub-zone events are left out: closing means you're about to move,
-- and ZONE_CHANGED/INDOORS fire constantly (and in combat).
local SAFE_EVENTS = {
  PLAYER_DEAD           = "dead",
  PLAYER_ALIVE          = "released",
  PLAYER_UNGHOST        = "resurrected",
  PLAYER_CAMPING        = "logout",
  PLAYER_CONTROL_LOST   = "flight/control lost",
  ZONE_CHANGED_NEW_AREA = "new zone",
  MERCHANT_SHOW         = "merchant",
  BANKFRAME_OPENED      = "bank",
  MAIL_SHOW             = "mailbox",
  AUCTION_HOUSE_SHOW    = "auction house",
  TRAINER_SHOW          = "trainer",
  TAXIMAP_OPENED        = "flight master",
}

frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LEAVING_WORLD")   -- loading screen is about to show
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PLAYER_REGEN_DISABLED")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:RegisterEvent("PLAYER_FLAGS_CHANGED")   -- AFK
for e in pairs(SAFE_EVENTS) do frame:RegisterEvent(e) end

frame:SetScript("OnEvent", function()
  if event == "ADDON_LOADED" then
    if arg1 ~= ADDON then return end
    ApplyDefaults()
    StartScheduler()
    HitchEnable()
    frame:UnregisterEvent("ADDON_LOADED")
  elseif event == "PLAYER_REGEN_DISABLED" then
    EnterCombat()
  elseif event == "PLAYER_REGEN_ENABLED" then
    LeaveCombat()
  elseif event == "PLAYER_LEAVING_WORLD" or event == "PLAYER_ENTERING_WORLD" then
    HitchLoading(event == "PLAYER_LEAVING_WORLD")
    if event == "PLAYER_ENTERING_WORLD" and GentleGCMemory and GentleGCMemory.justMeasured then
      GentleGCMemory.justMeasured = false
      ShowAddonSummary()
    end
    inCombat = UnitAffectingCombat("player") and true or false
    TryCollect("loading screen", true)
  elseif event == "PLAYER_FLAGS_CHANGED" then
    if UnitIsAFK("player") then TryCollect("afk") end
  elseif SAFE_EVENTS[event] then
    TryCollect(SAFE_EVENTS[event])
  end
end)

-- Once-a-second check: auto-GC detection, pressure, stand-still, fallback, report.
local function Check(dt)
  reportElapsed = reportElapsed + dt
  Sync()

  -- garbage creation rate, ~30 s moving average
  if dt > 0 then
    local inst = allocWindowKB / dt
    allocWindowKB = 0
    allocRate = allocRate + (inst - allocRate) * math.min(1, dt / 30)
  end

  if inCombat then
    stillFor = 0
  else
    if hasSpeed then
      local speed = GetUnitSpeed("player")
      local falling = IsFalling and IsFalling()
      if speed == 0 and not falling then stillFor = stillFor + dt else stillFor = 0 end
    end

    local used, threshold = gcinfo()
    if used >= PressurePointKB(threshold) and GetTime() - lastGC >= 5 then
      -- The automatic collector is about to fire anyway and would cost the
      -- same pause, so collect now, out of combat, without the garbage minimum.
      Collect("pressure")
    elseif careful then
      -- collections are slow enough to see: wait for a loading screen, NPC
      -- window, taxi, death, AFK or the end of combat (or pressure)
    elseif hasSpeed and db.stillSeconds > 0 and stillFor >= db.stillSeconds then
      TryCollect("standing still", false, true)
    elseif GetTime() - math.max(lastGC, loadTime) >= db.maxInterval then
      TryCollect("idle", false, true)
    end

    local now = GetTime()
    if db.allocWarnMB > 0 and allocRate > db.allocWarnMB * 1024 and now >= nextAllocWarn
        and now - loadTime > 60 then
      nextAllocWarn = now + 600
      local room = threshold - liveKB
      Msg(format("garbage is being created at %.1f MB/s (last 30 s): at this rate the heap fills up every ~%ds. "
        .. "/ggc hitch shows which events the memory jumps follow.",
        MB(allocRate), room > 0 and room / allocRate or 0))
    end
  end

  if reportElapsed >= db.reportInterval then
    if DebugLevel() >= 1 and (period.count > 0 or period.skipped > 0 or period.auto > 0 or period.ext > 0) then
      Msg(format("last %d min: %d collections (%d skipped), freed %.1fmb, avg %dms, worst %dms; %d automatic (%d in combat), %d by other addons; garbage %.1f MB/s; now %.1fmb",
        reportElapsed / 60, period.count, period.skipped, MB(period.freed),
        period.count > 0 and period.ms / period.count or 0, period.worst,
        period.auto, period.autoCombat, period.ext, MB(allocPeriodKB / reportElapsed), MB(gcinfo())))
    end
    allocPeriodKB = 0
    ResetStats(period)
    reportElapsed = 0
  end
end

local function OnUpdate()
  tick = tick + arg1
  if tick < 1 then return end
  local dt = tick
  tick = 0
  Check(dt)
end

-- C_Timer callbacks run once per frame from the world tick, outside the
-- frame OnUpdate walk. Without ClassicAPI, fall back to a frame OnUpdate.
StartScheduler = function()
  sampleFrame = sampleFrame or CreateFrame("Frame")
  sampleFrame:SetScript("OnUpdate", SampleOnUpdate)
  hasSpeed = type(GetUnitSpeed) == "function"
  hasTicker = type(C_Timer) == "table" and type(C_Timer.NewTicker) == "function"
  lastCheck = GetTime()
  loadTime = lastCheck
  if hasTicker then
    frame:SetScript("OnUpdate", nil)
    C_Timer.NewTicker(1, function()
      local now = GetTime()
      local dt = now - lastCheck
      lastCheck = now
      Check(dt)
    end)
  else
    frame:SetScript("OnUpdate", OnUpdate)
  end
end

---------------------------------------------------------------------------
-- freeze detector (/ggc hitch)
--
-- Runs on its own frame's OnUpdate, only while enabled. Each frame it reads
-- the clock and gcinfo() (no allocation). When the gap since the previous
-- frame exceeds the limit, it reports what happened inside that gap:
--   * a GentleGC collection (with its measured duration)
--   * a collection we didn't run: the game's automatic GC, or another
--     addon calling collectgarbage() (detected by the heap shrinking or
--     the threshold changing)
--   * no collection at all: the freeze came from something else
-- plus how much Lua memory was allocated during it and which frame was
-- under the mouse (the window being dragged, usually).
--
-- It also records every game event (RegisterAllEvents) into a fixed ring
-- buffer: name, first argument, time and Lua memory, assigning numbers and
-- existing values only, so nothing is allocated per event. A report lists
-- the events that fired during the freeze and where the time went: the
-- longest gap between them, and the event the biggest memory jump followed.
---------------------------------------------------------------------------

local hitchFrame = CreateFrame("Frame")
local hPrevTime, hPrevUsed, hPrevThreshold = 0, 0, 0
local hPrevCollectSeq, hPrevThresholdSeq, hPrevExtSeq = 0, 0, 0
local hLoading, hSkip = false, 0
local hitchLog = {}   -- last 10 freezes, newest last
local HITCH_LOG_SIZE = 10

-- event ring buffer
local EV_N = 64
local evFrame = CreateFrame("Frame")
local evName, evArg, evTime, evMem = {}, {}, {}, {}
local evPos, evSeq = 0, 0          -- last written slot, events recorded so far
local hFrameStartSeq = 0           -- evSeq at the previous OnUpdate
local hasAllEvents = evFrame.RegisterAllEvents ~= nil

local function EvOnEvent()
  evSeq = evSeq + 1
  evPos = evPos + 1
  if evPos > EV_N then evPos = 1 end
  evName[evPos] = event
  evArg[evPos] = arg1
  evTime[evPos] = GetTime()
  evMem[evPos] = gcinfo()
end

local function ArgText(a)
  local t = type(a)
  if t == "string" then
    if string.len(a) > 24 then a = string.sub(a, 1, 24) .. "..." end
    return " (" .. a .. ")"
  elseif t == "number" then
    return " (" .. a .. ")"
  end
  return ""
end

-- Describe the events recorded after event number startSeq.
-- frameStart/frameEnd: GetTime() at the two OnUpdates; memStart/memEnd: gcinfo() then.
local function EventReport(startSeq, frameStart, frameEnd, memStart, memEnd)
  if not hasAllEvents then return "" end
  local n = evSeq - startSeq
  if n <= 0 then return "; no game events fired during it" end
  local kept = n
  if kept > EV_N then kept = EV_N end

  -- slots oldest -> newest
  local first = evPos - kept + 1
  if first < 1 then first = first + EV_N end

  local counts, order = {}, {}
  local bestGap, bestAfter, bestBefore = -1, nil, nil
  local bestAlloc, bestAllocAfter = 0, nil
  local prevT, prevM, prevLabel = frameStart, memStart, nil
  if kept < n then prevT, prevM = nil, nil end   -- start of the frame was lost
  local i = first
  for k = 1, kept do
    local name = evName[i]
    if not counts[name] then counts[name] = 0; table.insert(order, name) end
    counts[name] = counts[name] + 1
    local label = name .. ArgText(evArg[i])
    if prevT then
      local g = evTime[i] - prevT
      if g > bestGap then bestGap, bestAfter, bestBefore = g, prevLabel, label end
      local a = evMem[i] - prevM
      if a > bestAlloc then bestAlloc, bestAllocAfter = a, prevLabel or "frame start" end
    end
    prevT, prevM, prevLabel = evTime[i], evMem[i], label
    i = i + 1
    if i > EV_N then i = 1 end
  end
  local g = frameEnd - prevT
  if g > bestGap then bestGap, bestAfter, bestBefore = g, prevLabel, nil end
  local a = memEnd - prevM
  if a > bestAlloc then bestAlloc, bestAllocAfter = a, prevLabel end

  table.sort(order, function(x, y) return counts[x] > counts[y] end)
  local parts = {}
  for k = 1, math.min(4, table.getn(order)) do
    local nm = order[k]
    table.insert(parts, counts[nm] > 1 and (nm .. " x" .. counts[nm]) or nm)
  end
  if table.getn(order) > 4 then table.insert(parts, "...") end

  local text = format("; %d event%s: %s", n, n == 1 and "" or "s", table.concat(parts, ", "))
  if kept < n then text = text .. format(" (last %d kept)", kept) end

  local where
  if not bestAfter then
    where = "before the first event"
  elseif not bestBefore then
    where = "after " .. bestAfter .. ", the last event"
  else
    where = "after " .. bestAfter
  end
  text = text .. format("; longest gap %.2fs %s", bestGap, where)
  if bestAlloc > 1024 then
    text = text .. format("; %.1fmb allocated after %s", MB(bestAlloc), bestAllocAfter)
  end
  return text
end

local function FocusName()
  if not GetMouseFocus then return nil end
  local f = GetMouseFocus()
  if not f or not f.GetName then return nil end
  local name = f:GetName()
  -- walk up to the first named ancestor for anonymous child frames
  local depth = 0
  while not name and f.GetParent and depth < 10 do
    f = f:GetParent()
    if not f or not f.GetName then break end
    name = f:GetName()
    depth = depth + 1
  end
  return name
end

local function HitchReset()
  hPrevTime = GetTime()
  hPrevUsed, hPrevThreshold = gcinfo()
  hPrevCollectSeq, hPrevThresholdSeq, hPrevExtSeq = ownCollectSeq, ownThresholdSeq, extSeq
  hFrameStartSeq = evSeq
end

local function HitchOnUpdate()
  local now = GetTime()
  local used, threshold = gcinfo()
  local gap = now - hPrevTime
  local prevTime, prevUsed, prevThreshold = hPrevTime, hPrevUsed, hPrevThreshold
  local startSeq = hFrameStartSeq
  local weCollected = ownCollectSeq ~= hPrevCollectSeq
  local weMovedThreshold = ownThresholdSeq ~= hPrevThresholdSeq
  local otherAddon = extSeq ~= hPrevExtSeq
  hPrevTime, hPrevUsed, hPrevThreshold = now, used, threshold
  hPrevCollectSeq, hPrevThresholdSeq, hPrevExtSeq = ownCollectSeq, ownThresholdSeq, extSeq
  hFrameStartSeq = evSeq

  if hLoading then return end
  if hSkip > 0 then hSkip = hSkip - 1; return end
  if gap * 1000 < db.hitchMs then return end

  local cause
  if weCollected then
    cause = format("GentleGC collection (%s) took %dms", ownCollectReason or "?", ownCollectMs)
  elseif otherAddon then
    cause = format("garbage collection run by %s%s", extName or "another addon",
      extMs and format(" took %dms", extMs) or "")
  elseif used < prevUsed - 256 or (threshold ~= prevThreshold and not weMovedThreshold) then
    cause = format("the game's automatic garbage collection: heap %.1fmb -> %.1fmb",
      MB(prevUsed), MB(used))
  else
    cause = "no garbage collection - something else caused it"
  end

  local grew = used - prevUsed
  local alloc = ""
  if grew > 1024 then alloc = format("; %.1fmb of Lua memory allocated during it", MB(grew)) end
  local focus = FocusName()
  local where = focus and ("; mouse over " .. focus) or ""
  local combat = inCombat and " (in combat)" or ""

  local events = EventReport(startSeq, prevTime, now, prevUsed, used)

  local line = format("freeze %.2fs%s: %s%s%s%s", gap, combat, cause, alloc, where, events)
  Msg("|cffff8888" .. line .. "|r")

  table.insert(hitchLog, format("%s %s", date and date("%H:%M:%S") or format("%.0f", now), line))
  if table.getn(hitchLog) > HITCH_LOG_SIZE then table.remove(hitchLog, 1) end
end

-- loading screens are long "frames" by design; ignore them
HitchLoading = function(leaving)
  hLoading = leaving
  if not leaving then
    hSkip = 3
    HitchReset()
  end
end

HitchEnable = function()
  if db.hitchMs > 0 then
    HitchReset()
    hSkip = 1
    hitchFrame:SetScript("OnUpdate", HitchOnUpdate)
    if hasAllEvents then
      evFrame:SetScript("OnEvent", EvOnEvent)
      evFrame:RegisterAllEvents()
    end
  else
    hitchFrame:SetScript("OnUpdate", nil)
    if hasAllEvents then
      evFrame:UnregisterAllEvents()
      evFrame:SetScript("OnEvent", nil)
    end
  end
end

---------------------------------------------------------------------------
-- per-addon memory (measured by the !!!!GentleGC_Memory companion)
---------------------------------------------------------------------------

local COMPANION = "!!!!GentleGC_Memory"
local ADDONS_TOP = 15

local function Size(kb)
  if kb < 0 then return "-" .. Size(-kb) end
  if kb < 1024 then return format("%d KB", kb) end
  return format("%.1f MB", kb / 1024)
end

local function Measurement()
  return type(GentleGCMemoryDB) == "table" and GentleGCMemoryDB.measured or nil
end

local function SortedRows(m)
  local rows = {}
  for i = 1, table.getn(m.rows) do table.insert(rows, m.rows[i]) end
  table.sort(rows, function(a, b) return a[2] > b[2] end)
  return rows
end

local function Biggest(m, n)
  local rows, parts = SortedRows(m), {}
  for i = 1, math.min(n, table.getn(rows)) do
    table.insert(parts, rows[i][1] .. " " .. Size(rows[i][2]))
  end
  return table.concat(parts, ", ")
end

ShowAddonSummary = function()
  local m = Measurement()
  if not m then return end
  Msg(format("measured your addons at this loading screen: %s in %d addons. Biggest: %s. /ggc addons lists them all.",
    Size(m.total or 0), table.getn(m.rows), Biggest(m, 3)))
end

local function PrintAddons(all)
  if not GentleGCMemory then
    Msg("per-addon memory needs the " .. COMPANION .. " folder from the Gentle GC zip in Interface/AddOns. "
      .. "It has to load before your other addons, which is what the !!!! is for.")
    return
  end
  local m = Measurement()
  if not m or table.getn(m.rows) == 0 then
    Msg("no per-addon measurement yet: /ggc addons measure, then /reload.")
    return
  end
  local rows = SortedRows(m)
  Msg(format("addon memory at login on %s: your addons kept %s; the game's own interface %s.",
    m.when or "?", Size(m.total or 0), Size(m.base or 0)))
  local shown = table.getn(rows)
  if not all and shown > ADDONS_TOP then shown = ADDONS_TOP end
  for i = 1, shown do
    DEFAULT_CHAT_FRAME:AddMessage(format("   %9s  %s", Size(rows[i][2]), rows[i][1]))
  end
  if shown < table.getn(rows) then
    DEFAULT_CHAT_FRAME:AddMessage(format("   ...and %d more (/ggc addons all)", table.getn(rows) - shown))
  end
  for i = 1, table.getn(m.stages or {}) do
    DEFAULT_CHAT_FRAME:AddMessage(format("   then %s: %s", m.stages[i][1], Size(m.stages[i][2])))
  end
  if m.before and table.getn(m.before) > 0 then
    DEFAULT_CHAT_FRAME:AddMessage("   loaded before the measurement, so counted in the interface number: "
      .. table.concat(m.before, ", "))
  end
  -- if the client held its load events back, one row gets everything
  if rows[1] and (m.total or 0) > 10240 and rows[1][2] > m.total * 0.8 and table.getn(rows) > 3 then
    Msg("one addon got almost all of it: this client may send its load events late, so the split may not be per addon.")
  end
  local grown = liveKB - (m.after or liveKB)
  Msg(format("live memory now ~%s, %s%s since that measurement.", Size(liveKB), grown >= 0 and "+" or "", Size(grown)))
end

local function MeasureNext()
  if not GentleGCMemory or type(GentleGCMemoryDB) ~= "table" then
    PrintAddons(false)   -- explains the missing companion
    return
  end
  GentleGCMemoryDB.measureNext = true
  Msg("type /reload to measure every addon. The loading screen takes a little longer, once.")
end

---------------------------------------------------------------------------
-- /ggc
---------------------------------------------------------------------------

local OPTIONS = {
  interval = "minInterval",
  maxinterval = "maxInterval",
  garbage = "minGarbageMB",
  garbagepct = "minGarbagePct",
  pressure = "pressureRoomPct",
  headroom = "combatHeadroomMB",
  report = "reportInterval",
  still = "stillSeconds",
  slow = "slowMs",
  allocwarn = "allocWarnMB",
}

local function PrintStatus()
  Sync()
  local used, threshold = gcinfo()
  Msg(format("heap %.1fmb, auto-GC at %.1fmb, live ~%.1fmb, garbage ~%.1fmb%s",
    MB(used), MB(threshold), MB(liveKB), MB(GarbageKB()), inCombat and " (in combat)" or ""))
  if ratioMin then
    Msg(format("collector: threshold %.2fx live after the last full collection, lowest %.2fx; collecting from %.1f%% garbage, pressure at %.1fmb",
      ratioLast, ratioMin, EffectiveGarbagePct(), MB(PressurePointKB(threshold))))
  else
    Msg(format("collector: threshold ratio not measured yet (no full collection this session); collecting from %.1f%% garbage, pressure at %.1fmb",
      EffectiveGarbagePct(), MB(PressurePointKB(threshold))))
  end
  if pauseAvg then
    Msg(format("collections take ~%dms: %s", pauseAvg, careful
      and "careful mode - only loading screens, death, taxi, NPC windows, AFK, after combat and pressure"
      or "normal mode"))
  end
  Msg(format("session: %d collections, %d skipped, freed %.1fmb, avg %dms, worst %dms; %d automatic (%d in combat)",
    total.count, total.skipped, MB(total.freed),
    total.count > 0 and total.ms / total.count or 0, total.worst, total.auto, total.autoCombat))
  if total.ext > 0 then
    local parts = {}
    for name, n in pairs(extByName) do table.insert(parts, name .. " " .. n) end
    table.sort(parts)
    Msg(format("by other addons: %d (%d in combat) - %s", total.ext, total.extCombat, table.concat(parts, ", ")))
  end
  local up = GetTime() - loadTime
  if up >= 60 then
    Msg(format("garbage created: %.1f MB/s now (30 s average), %.1f MB/s this session",
      MB(allocRate), MB(allocTotalKB / up)))
  else
    Msg(format("garbage created: %.1f MB/s now (30 s average)", MB(allocRate)))
  end
  Msg(format("debug=%d interval=%ds maxinterval=%ds garbage=%dmb garbagepct=%d%% pressure=%d%% headroom=%dmb report=%ds still=%ds slow=%dms allocwarn=%dmb",
    DebugLevel(), db.minInterval, db.maxInterval, db.minGarbageMB, db.minGarbagePct,
    db.pressureRoomPct, db.combatHeadroomMB, db.reportInterval, db.stillSeconds, db.slowMs, db.allocWarnMB))
  local m = Measurement()
  if m and table.getn(m.rows) > 0 then
    Msg(format("biggest addons (measured %s): %s - /ggc addons", m.when or "?", Biggest(m, 3)))
  end
  Msg(db.hitchMs > 0 and ("freeze detector: on (" .. db.hitchMs .. "ms)") or "freeze detector: off (/ggc hitch)")
  Msg("ClassicAPI: stand-still " .. (hasSpeed and "on" or "not available") ..
    ", C_Timer " .. (hasTicker and "on" or "not available (using OnUpdate)"))
end

SLASH_GENTLEGC1 = "/ggc"
SLASH_GENTLEGC2 = "/gentlegc"
SlashCmdList["GENTLEGC"] = function(msg)
  local _, _, cmd, val = string.find(string.lower(msg or ""), "^%s*(%S*)%s*(.-)%s*$")
  if cmd == "" or cmd == "status" then
    PrintStatus()
  elseif cmd == "now" then
    if inCombat then Msg("in combat - not collecting") else Collect("manual") end
  elseif cmd == "debug" then
    local n = tonumber(val)
    if n == nil then n = (db.debug > 0) and 0 or 1 end
    db.debug = n
    ggc_debug = nil
    Msg("debug " .. n .. (n == 0 and " (off)" or n == 1 and " (summaries)" or " (every collection)"))
  elseif cmd == "hitch" then
    local n = tonumber(val)
    if n == nil then n = (db.hitchMs > 0) and 0 or 250 end
    db.hitchMs = n
    HitchEnable()
    if n > 0 then
      Msg("freeze detector on: reporting frames longer than " .. n .. "ms (/ggc hitch 0 to stop)")
    else
      Msg("freeze detector off")
    end
  elseif cmd == "addons" then
    if val == "measure" then
      MeasureNext()
    else
      PrintAddons(val == "all")
    end
  elseif cmd == "hitches" then
    if table.getn(hitchLog) == 0 then
      Msg(db.hitchMs > 0 and "no freezes recorded this session" or "freeze detector is off - /ggc hitch to turn it on")
    else
      for _, l in ipairs(hitchLog) do Msg(l) end
    end
  elseif cmd == "reset" then
    for k, v in pairs(DEFAULTS) do db[k] = v end
    HitchEnable()
    Msg("settings reset to defaults")
  elseif OPTIONS[cmd] and tonumber(val) then
    db[OPTIONS[cmd]] = tonumber(val)
    Msg(cmd .. " = " .. val)
  else
    Msg("/ggc [status] | now | debug [0-2] | addons [all|measure] | hitch [ms] | hitches | reset")
    Msg("/ggc interval|maxinterval|report|still <sec>  garbage|headroom|allocwarn <mb>  garbagepct|pressure <%>  slow <ms>")
  end
end
