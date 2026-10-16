--[[
  GentleGC - unified edition (for OctoWoW / Turtle-based 1.12 clients, Lua 5.0)

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
local EnterCombatThreshold    -- defined below, used by Sync()

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
-- other addons may use, so it is only touched while debugging.
local function StartTimer()
  if DebugLevel() > 0 and debugprofilestart then
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

-- reason: label for debug output
-- ignoreInterval: true for moments where a pause is free (loading screen)
--                 or urgent (heap about to trigger the automatic collector)
local function TryCollect(reason, ignoreInterval)
  if inCombat then return end
  if not ignoreInterval and GetTime() - lastGC < db.minInterval then return end
  if not WorthCollecting() then
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
    frame:UnregisterEvent("ADDON_LOADED")
  elseif event == "PLAYER_REGEN_DISABLED" then
    EnterCombat()
  elseif event == "PLAYER_REGEN_ENABLED" then
    LeaveCombat()
  elseif event == "PLAYER_LEAVING_WORLD" or event == "PLAYER_ENTERING_WORLD" then
    inCombat = UnitAffectingCombat("player") and true or false
    TryCollect("loading screen", true)
  elseif event == "PLAYER_FLAGS_CHANGED" then
    if UnitIsAFK("player") then TryCollect("afk") end
  elseif SAFE_EVENTS[event] then
    TryCollect(SAFE_EVENTS[event])
  end
end)

-- Fallback: once a second, out of combat only.
frame:SetScript("OnUpdate", function()
  tick = tick + arg1
  if tick < 1 then return end
  reportElapsed = reportElapsed + tick
  tick = 0

  Sync()
  if not inCombat then
    local used, threshold = gcinfo()
    if used >= threshold * db.pressurePct / 100 then
      -- the automatic collector is about to fire anyway; do it now, out of combat
      TryCollect("pressure", true)
    elseif GetTime() - lastGC >= db.maxInterval then
      TryCollect("idle")
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
end)

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
}

local function PrintStatus()
  Sync()
  local used, threshold = gcinfo()
  Msg(format("heap %.1fmb, auto-GC at %.1fmb, live ~%.1fmb, garbage ~%.1fmb%s",
    MB(used), MB(threshold), MB(liveKB), MB(GarbageKB()), inCombat and " (in combat)" or ""))
  Msg(format("session: %d collections, %d skipped, freed %.1fmb, avg %dms, worst %dms; %d automatic (%d in combat)",
    total.count, total.skipped, MB(total.freed),
    total.count > 0 and total.ms / total.count or 0, total.worst, total.auto, total.autoCombat))
  Msg(format("debug=%d interval=%ds maxinterval=%ds garbage=%dmb garbagepct=%d%% pressure=%d%% headroom=%dmb report=%ds",
    DebugLevel(), db.minInterval, db.maxInterval, db.minGarbageMB, db.minGarbagePct,
    db.pressurePct, db.combatHeadroomMB, db.reportInterval))
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
  elseif cmd == "reset" then
    for k, v in pairs(DEFAULTS) do db[k] = v end
    Msg("settings reset to defaults")
  elseif OPTIONS[cmd] and tonumber(val) then
    db[OPTIONS[cmd]] = tonumber(val)
    Msg(cmd .. " = " .. val)
  else
    Msg("/ggc [status] | now | debug [0-2] | reset")
    Msg("/ggc interval|maxinterval|report <sec>  garbage|headroom <mb>  garbagepct|pressure <%>")
  end
end
