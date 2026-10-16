Gentle Garbage Collection — unified edition (v2.0)
---
For OctoWoW and other Turtle WoW–based 1.12 clients (Lua 5.0).

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
  `/ggc garbagepct|pressure <%>`, `/ggc reset`.
- The old `/run ggc_debug = 1` still works.

The best way to shorten the pauses themselves is still to run less addon memory.
pfQuest, for example, can hold 100 MB while idle.

Credits: original by MarcelineVQ (Weird Vibes). Event-driven collection from
jrc13245's fork; separate report timer from TheRealFayz's fork.
