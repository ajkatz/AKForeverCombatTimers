# AKForeverCombatTimers

## 0.5.3

- **A DoT lands on the target it was begun on.** Switch targets while a Corruption or an Immolate is still
  casting and the bar used to be filed under the new target, where no such DoT was. The target is taken
  when the cast begins and kept for that cast, as the game does; an instant goes to the current target,
  as before.

## 0.5.2

- **`/fct grow up` pins the floor, not a mirror.** The 0.5.1 version turned the block upside down - your
  cast bar on top - which kept your bars above a line but not the picture. Now the order is the same as
  ever, cast bar lowest; what changes is what is pinned: the bottom of your half sits where you put the
  block, and rows that come and go push the seam and the enemy's half up. Nothing of yours ever reaches
  below that line. The mirror is its own switch now: **`/fct reverse on`** turns the picture the other way
  up - yours stack up from the seam, cast bar on top, the enemy's hang below - with either pinning. Both
  have a button in the settings window.
- **Bane of Agony gets its bar.** Forever calls Curse of Agony "Bane of Agony" (and Curse of Doom "Bane
  of Doom"); the warlock's default DoTs and the duration table use the new name, and a saved list that
  still says "Curse of Agony" is read as the new one.
- **DoT bars in a fight again.** Client build 70235 (Oct 5 2026) keeps a target's identity secret in a
  fight, and the bars, which filed every DoT under it, went empty exactly where they are wanted. The key is
  now taken when the target is taken and kept until it changes - the identity if the client gives it, a
  stand-in for "this target" if not - so a pull's Corruption and the fight's Immolate share one set of
  bars. A mob you tab back to in a fight gets a fresh stand-in; its bars return with the next cast on it.
  `/fct diag` says whether the key was the identity or a stand-in, and why a cast gave no bar.
- **Corruption and Rend run for less at low ranks.** Corruption lasts 12 seconds at rank 1 and 15 at
  rank 2 (both measured on Forever), 18 from rank 3; Rend 9, 12, 15 and 18 seconds for ranks 1 to 4, 21
  from rank 5. The table used to hold one length per name. A readable aura still teaches the clock, now
  per rank.

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
