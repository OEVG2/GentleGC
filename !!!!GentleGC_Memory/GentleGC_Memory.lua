--[[
  Gentle GC - Memory: how much memory each addon keeps.

  The 1.12 client has no per-addon memory numbers (GetAddOnMemoryUsage came
  in 2.x); gcinfo() only gives the size of the whole Lua heap. So this addon
  loads before the others (the "!!!!" sorts first) and, each time another
  addon finishes loading, runs a full collection and reads gcinfo(). The rise
  since the previous addon is what that addon kept: its code, its data and
  its saved variables. Same approach as AddonMemory by Salahaja.

  It only measures at the loading screen, where the extra collections can't
  be seen, and only when it's useful:
    * the first login after it's installed
    * when the set of enabled addons has changed since the last measurement
    * the next /reload after /ggc addons measure
  Any other time it does nothing. Gentle GC reads the results (/ggc addons).
--]]

local ME = "!!!!GentleGC_Memory"

local M = { measuring = false, justMeasured = false }
GentleGCMemory = M

-- Our own reference, taken before Gentle GC wraps the global, so these
-- measuring collections aren't reported as another addon's.
local collect = collectgarbage

local run, last
local frame = CreateFrame("Frame")

local function Live()
  collect()
  return (gcinfo())
end

-- The enabled addons, as one string: a change means a new measurement.
local function Signature()
  local names = {}
  for i = 1, GetNumAddOns() do
    local name, _, _, enabled = GetAddOnInfo(i)
    if name and enabled then table.insert(names, name) end
  end
  table.sort(names)
  return table.concat(names, ",")
end

local function Start(db)
  local sig = Signature()
  local reason
  if db.measureNext then
    reason = "requested"
  elseif not db.measured then
    reason = "first login"
  elseif db.signature ~= sig then
    reason = "addons changed"
  end
  db.measureNext = nil
  if not reason then return end

  M.measuring = true
  run = {
    when = date and date("%Y-%m-%d %H:%M") or "?",
    reason = reason,
    base = Live(),
    before = {},
    rows = {},
    stages = {},
  }
  last = run.base
  -- anything that loaded before us is inside the base number; name it
  for i = 1, GetNumAddOns() do
    local name = GetAddOnInfo(i)
    if name and name ~= ME and IsAddOnLoaded(name) then table.insert(run.before, name) end
  end
  db.signature = sig
end

local function Record(list, label)
  local kb = Live()
  table.insert(list, { label, kb - last })
  last = kb
end

local function Finish()
  local total = 0
  for i = 1, table.getn(run.rows) do total = total + run.rows[i][2] end
  run.total = total
  run.after = last
  GentleGCMemoryDB.measured = run
  M.measuring = false
  M.justMeasured = true
  run = nil
end

frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:SetScript("OnEvent", function()
  if event == "ADDON_LOADED" then
    if arg1 == ME then
      if type(GentleGCMemoryDB) ~= "table" then GentleGCMemoryDB = {} end
      Start(GentleGCMemoryDB)
    elseif M.measuring then
      -- this addon's files and saved variables; setup it does in its own
      -- ADDON_LOADED handler runs after ours and lands on the next addon
      Record(run.rows, arg1)
    end
  elseif event == "PLAYER_LOGIN" then
    if M.measuring then Record(run.stages, "after the last addon loaded (setup, saved variables)") end
  elseif event == "PLAYER_ENTERING_WORLD" then
    if M.measuring then
      Record(run.stages, "addons setting up at login")
      Finish()
    end
    -- load-on-demand addons come later, in play: never measured
    frame:UnregisterAllEvents()
  end
end)
