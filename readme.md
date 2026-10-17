Gentle Garbage Collection — unified edition (v2.2)
---
For WoW 1.18.1 clients (Lua 5.0).

In Lua 5.0 every garbage collection is a full stop-the-world pause, and the
automatic collector fires whenever addon memory reaches twice what was live
after the last collection, which often happens in the middle of a fight. A
pause can't be made shorter, but it can be moved. GentleGC moves it to
moments you won't notice.

**When it collects**
- Loading screens, logging out, death/release, AFK, flight masters, and when you
  open a merchant, bank, mailbox, auction house or trainer.
- Right after combat ends, if enough garbage built up.
- Out of combat, early, when memory is close to the point where the automatic
  collector would fire anyway, so the next pull starts with room to spare.
- Fallback: every 5 minutes out of combat.
- With the ClassicAPI client mod installed: after you've stood still for
  3 seconds out of combat. When the camera isn't moving, a hitch is much
  harder to notice. GentleGC detects ClassicAPI and works the same without it.

**When it doesn't**
- Never in combat. On entering combat it also raises the automatic-GC
  threshold (32 MB of extra room by default), so that collection is pushed past
  the end of the fight where possible, and restores the threshold afterwards.
- It skips collections that would free little. A pause costs about the same
  whether it frees 1 MB or 50 MB, because scanning live data is most of the work.

**Commands**
- `/ggc`: status, including how many *automatic* (unscheduled) collections
  happened, which are the ones that cause stutter.
- `/ggc debug 1`: chat summary every 5 minutes. `/ggc debug 2` also prints each collection. `/ggc debug 0` turns it off.
- `/ggc now`: collect immediately.
- `/ggc interval|maxinterval|report <sec>`, `/ggc garbage|headroom <mb>`,
  `/ggc garbagepct|pressure <%>`, `/ggc still <sec>` (0 turns stand-still
  collection off), `/ggc reset`.
- The old `/run ggc_debug = 1` still works.

**Freeze detector** (off by default)
- `/ggc hitch` reports any frame that takes longer than 250 ms (`/ggc hitch 500`
  sets a different limit, `/ggc hitch 0` turns it off). Each report says
  whether a garbage collection happened in that frame and whose it was:
  GentleGC's (with how long it took), the game's automatic one or another
  addon's, or none at all. It also gives how much Lua memory was allocated
  during the freeze and which window was under the mouse.
- `/ggc hitches` lists the last 10 freezes.
- Loading screens are ignored. While on, the detector reads the clock and
  memory counter once per frame and allocates nothing.

The best way to shorten the pauses themselves is still to run less addon memory.
pfQuest, for example, can hold 100 MB while idle.

**Client mods**
- ClassicAPI: supported, as above. Its once-per-frame timer also runs
  GentleGC's background check, in place of a frame OnUpdate.
- SuperWoW and nampower: compatible. Neither offers anything GentleGC needs.
- UnitXP SP3: compatible. A February 2026 build briefly turned garbage
  collection off in combat, and the next build removed that.

**Tests** (`tests/`) run on stock Lua 5.0 with stubbed game functions:
`lua5.0 tests/test_stock.lua GentleGC.lua` (likewise `test_classicapi.lua`,
`test_combat_auto.lua` and `test_hitch.lua`). The game never loads them.

Credits: original by MarcelineVQ (Weird Vibes). Event-driven collection from
jrc13245's fork; separate report timer from TheRealFayz's fork.
