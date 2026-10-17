--[[
  GentleGC - unified edition (for WoW 1.18.1 clients, Lua 5.0)

  Lua 5.0 has no incremental collector: every collection is a full
  stop-the-world mark + sweep, and the automatic collector fires whenever the
  heap reaches its threshold (2x live memory after the last collection).
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
  diagnostics:
    * /ggc hitch: report frames that take too long, and whether a garbage
      collection (ours, the game's, or another addon's) happened in them
]]

local ADDON = "GentleGC"

local DEFAULTS = {
  debug            = 0,    -- 0 off, 1 periodic summary, 2 also every collection
  minInterval      = 30,   -- seconds: never collect more often than this
  maxInterval      = 300,  -- seconds: out-of-combat fallback collection
  minGarbageMB     = 4,    -- skip a collection that would free less than this...
  minGarbagePct    = 15,   -- ...or less than this % of live memory (the larger wins)
  pressurePct      = 85,   -- out of combat: collect early once heap reaches this % of threshold
  combatHeadroomMB = 32,   -- extra room before auto-GC during combat (0 = off)
  reportInterval   = 300,  -- seconds between debug summaries
  stillSeconds     = 3,    -- ClassicAPI only: collect after standing still this long (0 = off)
  hitchMs          = 0,    -- freeze detector: report frames longer than this (0 = off)
}

local db = {}

local function ApplyDefaults()
  if type(GentleGCDB) ~= "table" then GentleGCDB = {} end
  db = GentleGCDB
  for k, v in pairs(DEFAULTS) do
    if db[k] == nil then db[k] = v end
  end
end
ApplyDefaults()   -- usable immediately; re-run once saved settings load

local frame = CreateFrame("Frame")
local inCombat = false
local lastGC = 0           -- GetTime() of our last collection
local liveKB = 0           -- heap size right after the last collection (live-data estimate)
local savedThreshold = nil -- threshold before we raised it for combat
local knownThreshold = 0   -- last threshold we saw or set (detects automatic GCs)
do
  local used, threshold = gcinfo()
  liveKB = math.min(used, math.floor(threshold / 2))
  knownThreshold = threshold
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

local function NewStats() return { count = 0, freed = 0, skipped = 0, ms = 0, worst = 0, auto = 0, autoCombat = 0 } end
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
  s.count, s.freed, s.skipped, s.ms, s.worst, s.auto, s.autoCombat = 0, 0, 0, 0, 0, 0, 0
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

-- Lua 5.0 resets the threshold to exactly 2x live memory after every
-- collection. If the threshold changed and we didn't change it, the automatic
-- collector ran (a pause we didn't schedule): resync our live estimate.
local function Sync()
  local used, threshold = gcinfo()
  if threshold ~= knownThreshold then
    if knownThreshold ~= 0 then
      liveKB = math.floor(threshold / 2)
      for _, s in ipairs({ period, total }) do
        s.auto = s.auto + 1
        if inCombat then s.autoCombat = s.autoCombat + 1 end
      end
      if DebugLevel() >= 2 then
        Msg(format("automatic GC detected%s (live ~%.1fmb)", inCombat and " in combat" or "", MB(liveKB)))
      end
      if inCombat and savedThreshold then
        -- our raised threshold was consumed; grant the headroom again
        savedThreshold = nil
        knownThreshold = threshold
        EnterCombatThreshold()
        return
      end
      savedThreshold = nil
    end
    knownThreshold = threshold
  end
end

local function WorthCollecting()
  Sync()
  local need = math.max(db.minGarbageMB * 1024, liveKB * db.minGarbagePct / 100)
  return GarbageKB() >= need
end

---------------------------------------------------------------------------
-- collection
---------------------------------------------------------------------------

local function Collect(reason)
  Sync()
  local before = gcinfo()
  local t0 = StartTimer()
  collectgarbage()               -- full collection; threshold resets to 2x live
  local ms = StopTimer(t0)
  local after, threshold = gcinfo()

  liveKB = after
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
    collectgarbage(want)         -- raising the threshold never triggers a collection
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
    collectgarbage(savedThreshold)
    savedThreshold = nil
    local _, t = gcinfo()
    knownThreshold = t
    ownThresholdSeq = ownThresholdSeq + 1
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

  if inCombat then
    stillFor = 0
  else
    if hasSpeed then
      local speed = GetUnitSpeed("player")
      local falling = IsFalling and IsFalling()
      if speed == 0 and not falling then stillFor = stillFor + dt else stillFor = 0 end
    end

    local used, threshold = gcinfo()
    if used >= threshold * db.pressurePct / 100 then
      -- the automatic collector is about to fire anyway; do it now, out of combat
      TryCollect("pressure", true)
    elseif hasSpeed and db.stillSeconds > 0 and stillFor >= db.stillSeconds then
      TryCollect("standing still", false, true)
    elseif GetTime() - math.max(lastGC, loadTime) >= db.maxInterval then
      TryCollect("idle", false, true)
    end
  end

  if reportElapsed >= db.reportInterval then
    if DebugLevel() >= 1 and (period.count > 0 or period.skipped > 0 or period.auto > 0) then
      Msg(format("last %d min: %d collections (%d skipped), freed %.1fmb, avg %dms, worst %dms; %d automatic (%d in combat); now %.1fmb",
        reportElapsed / 60, period.count, period.skipped, MB(period.freed),
        period.count > 0 and period.ms / period.count or 0, period.worst,
        period.auto, period.autoCombat, MB(gcinfo())))
    end
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
---------------------------------------------------------------------------

local hitchFrame = CreateFrame("Frame")
local hPrevTime, hPrevUsed, hPrevThreshold = 0, 0, 0
local hPrevCollectSeq, hPrevThresholdSeq = 0, 0
local hLoading, hSkip = false, 0
local hitchLog = {}   -- last 10 freezes, newest last
local HITCH_LOG_SIZE = 10

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
  hPrevCollectSeq, hPrevThresholdSeq = ownCollectSeq, ownThresholdSeq
end

local function HitchOnUpdate()
  local now = GetTime()
  local used, threshold = gcinfo()
  local gap = now - hPrevTime
  local prevUsed, prevThreshold = hPrevUsed, hPrevThreshold
  local weCollected = ownCollectSeq ~= hPrevCollectSeq
  local weMovedThreshold = ownThresholdSeq ~= hPrevThresholdSeq
  hPrevTime, hPrevUsed, hPrevThreshold = now, used, threshold
  hPrevCollectSeq, hPrevThresholdSeq = ownCollectSeq, ownThresholdSeq

  if hLoading then return end
  if hSkip > 0 then hSkip = hSkip - 1; return end
  if gap * 1000 < db.hitchMs then return end

  local cause
  if weCollected then
    cause = format("GentleGC collection (%s) took %dms", ownCollectReason or "?", ownCollectMs)
  elseif used < prevUsed - 256 or (threshold ~= prevThreshold and not weMovedThreshold) then
    cause = format("garbage collection not run by GentleGC (game's automatic GC or another addon's collectgarbage): heap %.1fmb -> %.1fmb",
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

  local line = format("freeze %.2fs%s: %s%s%s", gap, combat, cause, alloc, where)
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
  else
    hitchFrame:SetScript("OnUpdate", nil)
  end
end

---------------------------------------------------------------------------
-- /ggc
---------------------------------------------------------------------------

local OPTIONS = {
  interval = "minInterval",
  maxinterval = "maxInterval",
  garbage = "minGarbageMB",
  garbagepct = "minGarbagePct",
  pressure = "pressurePct",
  headroom = "combatHeadroomMB",
  report = "reportInterval",
  still = "stillSeconds",
}

local function PrintStatus()
  Sync()
  local used, threshold = gcinfo()
  Msg(format("heap %.1fmb, auto-GC at %.1fmb, live ~%.1fmb, garbage ~%.1fmb%s",
    MB(used), MB(threshold), MB(liveKB), MB(GarbageKB()), inCombat and " (in combat)" or ""))
  Msg(format("session: %d collections, %d skipped, freed %.1fmb, avg %dms, worst %dms; %d automatic (%d in combat)",
    total.count, total.skipped, MB(total.freed),
    total.count > 0 and total.ms / total.count or 0, total.worst, total.auto, total.autoCombat))
  Msg(format("debug=%d interval=%ds maxinterval=%ds garbage=%dmb garbagepct=%d%% pressure=%d%% headroom=%dmb report=%ds still=%ds",
    DebugLevel(), db.minInterval, db.maxInterval, db.minGarbageMB, db.minGarbagePct,
    db.pressurePct, db.combatHeadroomMB, db.reportInterval, db.stillSeconds))
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
    Msg("/ggc [status] | now | debug [0-2] | hitch [ms] | hitches | reset")
    Msg("/ggc interval|maxinterval|report|still <sec>  garbage|headroom <mb>  garbagepct|pressure <%>")
  end
end
