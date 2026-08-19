local gentleGC = CreateFrame("FRAME")

-- Collection and reporting run on independent timers.
local GC_INTERVAL     = 15   -- seconds between garbage collections (keeps memory clean)
local REPORT_INTERVAL = 300  -- seconds between chat reports (5 minutes)

ggc_debug = true             -- set false to silence reports entirely

local gc_elapsed      = 0
local report_elapsed  = 0
local gc_count        = 0    -- collections since last report
local freed_kb        = 0    -- memory freed (KB) since last report

gentleGC:SetScript("OnUpdate", function ()
  gc_elapsed     = gc_elapsed     + arg1
  report_elapsed = report_elapsed + arg1

  -- Run collection on the short interval, silently.
  if gc_elapsed > GC_INTERVAL then
    local before = gcinfo()
    collectgarbage()
    local after = gcinfo()
    freed_kb = freed_kb + (before - after)
    gc_count = gc_count + 1
    gc_elapsed = 0
  end

  -- Report only on the long interval.
  if report_elapsed > REPORT_INTERVAL then
    if ggc_debug then
      print(format("GentleGC: %d collections in last %d min, freed %.1fmb, now %.1fmb",
        gc_count, REPORT_INTERVAL / 60, freed_kb / 1024, gcinfo() / 1024))
    end
    gc_count       = 0
    freed_kb       = 0
    report_elapsed = 0
  end
end)
