# Marketplace listing text (copy / paste)

**Name:** AKForeverCombatTimers
**Category:** Combat
**Game version:** World of Warcraft: Forever (1.60.1)
**License:** MIT
**Summary (one line):** Swing, cast, DoT, buff and incoming-hit timers in one block, built for Forever's secret values - what the client will show, and no guessing.

## Description

*Part of a small family of addons built for the WoW: Forever game mode, with one mission: minimalistic UI additions that bring out the utility
Blizzard's UI does not give - minimal in nature, no Lua errors, always smooth.*

Combat timers for World of Warcraft: Forever (Interface 16001), in one block: the target's cast and the next enemy hit
grow up from a seam; your swings, a buff, your DoTs, the reactive windows and your own cast grow down from it. Every bar
can be set to always / when used / never, sized and reordered; the block is dragged by its tab while unlocked, and
locked with a button.

### The bars

- **Your swings** - main hand, off hand and ranged, each on its own bar, driven by the client's own swing events.
  Replaces Blizzard's built-in timer (and puts it back on request).
- **The next enemy hit** - a bar counting down to the next hit on you, on the tank your target is attacking, or on the
  friendly you have targeted as a healer. Learned from the hits that land, with a confidence that dims the bar when the
  rhythm is irregular.
- **Cast bars** for the target and for you: icon, name, seconds left. A target's cast is secret on this client; the bar
  still runs, through the display paths the client allows, with the seconds counted by the client itself. Blizzard's
  two cast bars are switched off once ours has proven it works (`/fct casts blizzard show` puts them back).
- **A buff bar** - first of all a rogue's Slice and Dice. In a fight your auras cannot be read on this client, so the
  bar is estimated from the combo points you spent, through a curve the client evaluates: the right length, no numbers.
- **DoT bars** (`/fct dot`) - one bar per tracked damage-over-time spell (Corruption, Immolate, Bane of Agony, Flame
  Shock, Serpent Sting, Shadow Word: Pain, Rupture, Rip, Rend ...), up to four, kept per enemy and shown for your current
  target. Your own casts are never secret, so these count real seconds in a fight - the length by rank where ranks
  differ (Corruption, Rend) - and a readable aura corrects them. A DoT lands on the target it was begun on, a mob that
  dies loses its bars at once.
- **Reactive windows** (`/fct react`) - Overpower, Revenge, Mongoose Bite, Counterattack, Riposte: the five seconds
  after a dodge, parry or block.
- **The Plainsrunning ramp** for tauren: gaining and losing on two separate clocks (`/fct plains`).

### The block

The seam is what you position; it never moves when rows come and go. `/fct grow up` pins the floor instead: the same
picture, the same order, but the bottom of your bars sits where you put the block and rows that come push everything up
- for a block that sits low on the screen. `/fct reverse on` turns the picture the other way up: your bars stack up from
the seam with your cast bar on top, the enemy's hang below - with either pinning.

### Commands

| | |
|---|---|
| `/fct unlock` / `/fct lock` | move the block (drag the tab) / fix it in place - or the lock button under the tab |
| `/fct config` | the settings window: order, mode, seconds, width, height per bar; alignment, centre, snap, fade, grow, reverse, test |
| `/fct bar mh always`, `bar oh never`, `bar rg used 10`, `bar cast width 260`, `bar cast up` ... | one bar at a time |
| `/fct order tcast enemy mh oh rg buff cast` | the whole order at once (each bar stays in its half) |
| `/fct show always\|used` | every bar that is not switched off |
| `/fct anchor left\|center\|right`, `/fct center`, `/fct snap on\|off` | which point of the block is pinned; centre it; snap to the centre line |
| `/fct grow down\|up`, `/fct reverse on\|off` | the seam or the floor pinned; the picture the other way up |
| `/fct fade on\|off` | bars fade in and out, or pop |
| `/fct dot add Flame Shock`, `/fct dot remove ...`, `/fct dot reset` | which DoTs get a bar (defaults per class) |
| `/fct react add Overpower`, `/fct react reset` | which reactive abilities get a bar |
| `/fct buff add <spell>`, `/fct buff reset` | what the buff bar tracks |
| `/fct enemy`, `/fct watch auto\|focus\|party2` | the incoming-hit bar, and whose hits to time |
| `/fct casts on\|off`, `/fct casts player\|target on\|off`, `/fct blizzard hide\|show` | the cast bars; Blizzard's own swing timer |
| `/fct plains` | the Plainsrunning readout |
| `/fct test`, `/fct reset` | 15 seconds of moving test bars; the block back at its default place |
| `/fct diag` | a report into the settings file for bug reports (then `/reload`); `/fct castlog`, `/fct casttime <spell>`, `/fct auras`, `/fct cpu` help with one |

`/fct` on its own lists everything (`/fst` still works, from the days it was only swing timers).

### Secret values

Forever hides most combat numbers from addons. This addon never reads a secret value: every bar has a display path for
what the client will only show, and a bar with nothing it may show stays silent rather than guessing.

### Source and bug reports

MIT licensed. Code, issues and the changelog: https://github.com/ajkatz/AKForeverCombatTimers

## Logo and screenshots

Logo (400 x 400): `..\ForeverBranding\out\AKForeverCombatTimers\logo-400.png` (master: `logo-1024.png`).
Screenshots to take in game: the block in a fight with a cast on top and a DoT running; the settings window.
