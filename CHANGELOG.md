# AKForeverCombatTimers

## 0.5.1

- **`/fct grow up`**: the block the other way up - your bars stack up from the seam and the enemy's hang
  below it, so the seam is the floor of your bars and nothing of yours ever reaches further down. For a
  block that sits low on the screen; `/fct grow down` (the default) is the old picture. Also a button in
  the settings window.
- **Settings follow the character again.** Client build 1.60.1.70170 (Oct 1 2026) moved a character's
  surname into the realm slot of `UnitName`, so every character started a fresh, empty profile. The profile
  is now keyed by the full name and the realm (`Purrdee Bubson - ClassicBetaPvE`, the spelling the older
  builds saved under) and bound at PLAYER_LOGIN, when the client knows the name for sure, so a cold login no
  longer lands in an `Unknown` profile. Profiles saved under the other spellings are folded into it the
  first time each character logs in: the long-standing profile keeps its values, the others fill its gaps,
  and `/fct diag` says what was adopted.
- The same client build reads saved settings back again, so the saved-settings bridge
  (`tools/Install-SavedStateBridge.ps1`) is no longer needed and `-Remove` takes it out.

## 0.5.0 - first public release

For **World of Warcraft: Forever** (1.60.1, Interface 16001).

Combat timers in one block: the target's cast and the next enemy hit grow up from a seam; your main
hand, off hand and ranged swings, a buff timer, the Plainsrunning ramp and your own cast grow down from
it. Every bar can be set to always / when used / never, sized, and reordered; the block is dragged by
its tab while unlocked, and locked with a button.

- **Swing bars** for main hand, off hand and ranged, on the client's own swing events.
- **The next enemy hit**, learned from the hits landing on whoever the target is attacking - a timer
  per attacker, with a confidence that dims the bar when the rhythm is irregular.
- **Cast bars** for the target and for you. A target's cast is secret on this client; the bar still
  runs, through the display paths the client allows, with the seconds counted by the client itself.
- **A buff bar** - first of all a rogue's Slice and Dice - which in a fight is estimated from the combo
  points spent, through a curve the client evaluates, because the aura itself cannot be found there.
- **The Plainsrunning ramp** for tauren: gaining and losing on two separate clocks.
- **DoT bars** (`/fct dot`): one bar per tracked damage-over-time spell, up to four, kept per enemy and
  shown for the current target. A DoT's length is known and your own casts are never secret, so the bar
  counts real seconds in a fight; a readable aura corrects it and teaches the length. A mob that dies
  loses its bars at once. *New in this release and not yet checked in the game:* the lengths assumed
  for Rupture and Rip - `/fct dot` reports what real auras have shown.
- **Reactive windows** (`/fct react`): Overpower, Revenge, Mongoose Bite, Counterattack, Riposte - the
  five seconds after a dodge, parry or block, from the event the client still sends. Overpower's
  "target dodged" counts as yours when you are alone, and in a group only when it lines up with a swing
  or melee ability of yours. *New in this release and not yet checked in the game.*
- Secret values are never read: every bar has a display path for what the client will only show.
- `/fct` lists the commands; `/fct diag` writes a report for bug reports.
