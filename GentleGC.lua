local gentleGC = CreateFrame("FRAME")
local gc_count = 1
local lastGC = 0

-- ggc_debug = true

-- Run GC from event handlers rather than OnUpdate.
-- Event handlers execute before the engine's frame-tree OnUpdate walk,
-- so collectgarbage() won't interfere with frame child-list traversal.

-- Transition events: player is briefly idle, GC stall won't be noticed
gentleGC:RegisterEvent("PLAYER_ENTERING_WORLD")
gentleGC:RegisterEvent("PLAYER_REGEN_ENABLED")
gentleGC:RegisterEvent("PLAYER_REGEN_DISABLED")
gentleGC:RegisterEvent("PLAYER_DEAD")
gentleGC:RegisterEvent("PLAYER_UNGHOST")
gentleGC:RegisterEvent("PLAYER_CAMPING")
gentleGC:RegisterEvent("ZONE_CHANGED")
gentleGC:RegisterEvent("ZONE_CHANGED_NEW_AREA")
gentleGC:RegisterEvent("ZONE_CHANGED_INDOORS")
gentleGC:RegisterEvent("MERCHANT_SHOW")
gentleGC:RegisterEvent("MERCHANT_CLOSED")
gentleGC:RegisterEvent("BANKFRAME_OPENED")
gentleGC:RegisterEvent("BANKFRAME_CLOSED")
gentleGC:RegisterEvent("MAIL_SHOW")
gentleGC:RegisterEvent("MAIL_CLOSED")
gentleGC:RegisterEvent("AUCTION_HOUSE_SHOW")
gentleGC:RegisterEvent("AUCTION_HOUSE_CLOSED")

local function doGC(source)
  local now = GetTime()
  if now - lastGC < 180 then return end
  lastGC = now
  local x, d1 = gcinfo(), now
  collectgarbage()
  local y, d2 = gcinfo(), GetTime()
  if ggc_debug then
    DEFAULT_CHAT_FRAME:AddMessage(format(
      "|cff88ff88GentleGC|r %s gc %d, was %.1fmb, is %.1fmb, saved %.1fmb, took %.2fs",
      source, gc_count, x / 1024, y / 1024, (x - y) / 1024, d2 - d1))
  end
  gc_count = gc_count + 1
end

-- Prefer event-driven GC (runs outside of frame tree iteration)
gentleGC:SetScript("OnEvent", function()
  doGC("event")
end)

-- Fallback: if no safe events fire, run GC from OnUpdate but only
-- when the player is out of combat (fewer active frames being iterated)
gentleGC:SetScript("OnUpdate", function()
  this.elapsed = (this.elapsed or 0) + arg1
  if this.elapsed > 200 then
    this.elapsed = 0
    if not UnitAffectingCombat("player") then
      doGC("idle")
    end
  end
end)
