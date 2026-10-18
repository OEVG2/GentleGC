Gentle Garbage Collection — unified edition (v2.4)
---
For WoW 1.18.1 clients (Lua 5.0).

In Lua 5.0 every garbage collection is a full stop-the-world pause, and the
automatic collector fires whenever addon memory reaches a threshold, which
often happens in the middle of a fight. Stock Lua 5.0 sets that threshold to
twice what was live after the last collection, but the 1.12 client uses its
own rule: live memory plus at least a quarter of it (1.25x or more, varying
with the allocator's state). GentleGC measures the ratio from full
collections and plans with the lowest one it has seen. A
pause can't be made shorter, but it can be moved. GentleGC moves it to
moments you won't notice.

**When it collects**
- Loading screens, logging out, death/release, AFK, flight masters, and when you
  open a merchant, bank, mailbox, auction house or trainer.
- Right after combat ends, if enough garbage built up.
- Out of combat, early, once garbage has filled 70% of the room between live
  memory and the point where the automatic collector would fire, so the next
  pull starts with room to spare. That collection would happen anyway at the
  same cost, so it skips the minimum-garbage check.
- Fallback: every 5 minutes out of combat.
- With the ClassicAPI client mod installed: after you've stood still for
  3 seconds out of combat. When the camera isn't moving, a hitch is much
  harder to notice. GentleGC detects ClassicAPI and works the same without it.

**Careful mode**: when collections average 100 ms or more (large addon
memory without wow_turbo, typically 250-400 ms in raids), a pause is visible
even while standing still. GentleGC then stops collecting while standing
still or idle, and only collects at loading screens, death and release,
taxis, NPC windows (merchant, bank, mail, auction house, trainer), AFK,
after combat, and under pressure. It switches back once collections average
under 75 ms. `/ggc slow <ms>` sets the limit; `/ggc slow 0` turns it off.

**When it doesn't**
- Never in combat. On entering combat it also raises the automatic-GC
  threshold (32 MB of extra room by default), so that collection is pushed past
  the end of the fight where possible, and restores the threshold afterwards.
- It skips collections that would free little: less than 4 MB, or less than
  15% of live memory (lowered automatically when the collector's threshold
  leaves less room than that). A pause costs about the same whether it frees
  1 MB or 50 MB, because scanning live data is most of the work.

**Commands**
- `/ggc`: status: how many *automatic* (unscheduled) collections happened,
  which are the ones that cause stutter; collections run by other addons, by
  name; the collector's measured threshold ratio; how long collections take
  and whether careful mode is on; and how fast garbage is being created.
- `/ggc debug 1`: chat summary every 5 minutes. `/ggc debug 2` also prints each collection. `/ggc debug 0` turns it off.
- `/ggc now`: collect immediately.
- `/ggc interval|maxinterval|report <sec>`, `/ggc garbage|headroom <mb>`,
  `/ggc garbagepct <%>`, `/ggc pressure <%>` (share of the room, default 70),
  `/ggc slow <ms>` (careful mode, default 100), `/ggc allocwarn <MB/s>`
  (garbage-rate warning, default 10, 0 turns it off), `/ggc still <sec>` (0 turns stand-still
  collection off), `/ggc reset`.
- The old `/run ggc_debug = 1` still works.

**Freeze detector** (off by default)
- `/ggc hitch` reports any frame that takes longer than 250 ms (`/ggc hitch 500`
  sets a different limit, `/ggc hitch 0` turns it off). Each report says
  whether a garbage collection happened in that frame and whose it was:
  GentleGC's (with how long it took), the game's automatic one or another
  addon's, or none at all. It also gives how much Lua memory was allocated
  during the freeze and which window was under the mouse.
- It also lists the game events that fired during the freeze, and where the
  time went: the longest gap between them (for example "longest gap 0.50s
  after CHAT_MSG_ADDON (BigWigs)") and the event the biggest memory jump
  followed. A long gap after an event usually means one of its handlers was
  slow; a gap before the first event points at rendering, an addon's
  OnUpdate, or the engine.
- `/ggc hitches` lists the last 10 freezes.
- Loading screens are ignored. While on, the detector records each event
  into a fixed 64-slot buffer and reads the clock and memory counter once
  per frame, allocating nothing until it has a freeze to report.

**Other addons' collections**: GentleGC wraps the global `collectgarbage`,
so when another addon runs a collection (for example a "free memory after
fights" option), it's timed, counted under that addon's name, and doesn't
throw off GentleGC's estimates. An addon that kept its own copy of
`collectgarbage` from before GentleGC loaded can't be wrapped; its
collections are still detected, because the game's collector can't fire
while memory is well below the threshold, and are listed as "unknown addon".
Calls that only query memory or set the threshold pass straight through.

**Garbage rate**: `/ggc` and the periodic summary show how fast garbage is
being created (MB/s). Above 10 MB/s (30 s average) you get a warning, at most
every 10 minutes: at that rate no schedule can avoid frequent collections,
and the fix is finding the addon that creates it (`/ggc hitch` shows which
events the memory jumps follow).

The best way to shorten the pauses themselves is still to run less addon memory.
pfQuest, for example, can hold 100 MB while idle.

**Client mods**
- ClassicAPI: supported, as above. Its once-per-frame timer also runs
  GentleGC's background check, in place of a frame OnUpdate.
- SuperWoW and nampower: compatible. Neither offers anything GentleGC needs.
- wow_turbo: compatible, and recommended with a lot of addon memory. It
  keeps the client's threshold rule but makes each collection much faster
  (parallel mark and sweep): about 40 ms instead of 300 ms with 220-330 MB of
  addon memory, which keeps GentleGC out of careful mode.
- UnitXP SP3: compatible. A February 2026 build briefly turned garbage
  collection off in combat, and the next build removed that.

**Tests** (`tests/`) run on stock Lua 5.0 with stubbed game functions:
`lua5.0 tests/test_stock.lua GentleGC.lua` (likewise `test_classicapi.lua`,
`test_combat_auto.lua`, `test_hitch.lua`, `test_factor.lua`, which
simulates the client's 1.25x collector, and `test_raid.lua`, which covers
careful mode, other addons' collections and the garbage rate). The game never loads them.

Credits: original by MarcelineVQ (Weird Vibes). Event-driven collection from
jrc13245's fork; separate report timer from TheRealFayz's fork.
