# AKForeverCombatTimers

## 0.6.0

- **DoT bars: two mobs of one name no longer share their bars.** In a fight the game hides who the target
  is, and the nameplate lookup the addon leaned on gives nothing for "target" on this client - so the name
  was all it had, and a swap between two Kobold Miners showed the first one's DoTs on the second. Now
  every nameplate that comes up is followed, and the target is matched to its plate: by the client saying
  so; else because it is the only plate of that name; else by the first hit that lands on the target and
  on one plate in the same instant - until then the bars show what you cast on this target and nothing of
  another mob's. Needs enemy nameplates on; without them, mobs of one name still share. `/fct diag` records
  how each swap was placed (`dots.targets`).
- **Nightfall has a bar, like Overpower.** A warlock's Nightfall proc (Shadow Trance: the next Shadow Bolt
  is instant) shows on a reactive bar for as long as it is there, and goes when the Shadow Bolt is cast.
  The buff cannot be read in a fight, so the bar opens when Shadow Bolt's cast time reads zero and counts
  ten seconds from there; out of a fight the buff's real end and length are read and kept. A warlock has
  it from the start; `/fct react remove Nightfall` takes it off.
- **Reactive bars land with a flash and breathe.** Overpower, Revenge, Riposte, Mongoose Bite,
  Counterattack and Nightfall are press-it-now moments: the bar now lands with a white burst that settles
  onto it from a quarter larger, and its glow breathes while the window is open - faster in the last three
  seconds. Only light is added: no row moves or changes size.
- **The sleeping bag: a step is getting up.** The Well Rested count-up now ends the moment you start to
  move, instead of waiting for the game's resting flag or the 75 seconds: before the first stack the bar
  goes; with a stack or two the buff stays and the count-up to the next stack stops, until the next stack
  lands or you lie down again; the minute toward a refresh at 3/3 is dropped. Walking into an inn or a city
  no longer asks "Sleeping bag?" - you are moving, so it is no bag. (A step in the first two seconds after
  lying down is taken for the lying down itself.)

## 0.5.6

- **A count-up for buff food.** Eating food that makes you Well Fed, a bar fills over the seconds the food
  names ("at least 10 seconds eating"; else the time measured the last time, else 10) - "0:07" - and shows
  "Well Fed" full a moment when the buff lands, or is refreshed if you were Well Fed already. Stop eating
  first and it goes; plain food gets no bar. Its own row ("Well Fed", `/fct bar fed ...` like any other bar).
  Which food is buff food: its words (the eating buff's or the item's use spell's) naming Well Fed, or the
  food having made you well fed before - remembered for all your characters. Food it cannot tell yet gets the
  count-up as a guess; no Well Fed three seconds past the mark takes the bar away and remembers the food as
  plain. `/fct food` says what the last meal was taken for and why.

- **`/fct rested probe`** lists what came and went in the last ten minutes - buffs and debuffs, your casts and
  channels, the resting flag - to find what the game shows before the first Well Rested stack.

- **A count-up for the Cozy Sleeping Bag.** From the moment you lie down ("You feel rested" - your bag or somebody else's), a bar fills
  over each minute toward the next stack - "0/3  0:41" before the first, then "1/3", "2/3" - and shows 3/3
  when you have them all. Lying down already at 3/3 counts the minute up too ("3/3  0:41") toward the
  refresh, which fills the bar - then it lets go; nothing is tracked past that first refresh. When resting comes on with
  no other sign, the bar asks "Sleeping bag?": the check keeps it, the X drops it, no answer keeps it counting
  (it goes by itself if no stack comes). Logging in, a hearth, a portal or a flight into a city asks nothing. Get up before the next stack and it goes
  away. Its own row ("Well Rested"), set like any other bar; `/fct rested` says what it sees. From level 60
  on all of it is off - no bar, no question, nothing read or kept: the bag's bonus is to experience, and
  there is none left to earn (the level 60 switch is new, and not yet checked in the game).

## 0.5.5

- **An interrupt you can see** (new, not yet checked in the game). When somebody stops a cast - your target's,
  or a mob stops yours - the cast bar no longer just vanishes: it holds for a second and a half, full and red,
  the spell's icon gone grey. A white flash; "INTERRUPTED" slams down from twice its size and shakes; who did
  it stands on the right in their class colour. The client keeps the interrupter of an enemy's cast secret in a
  fight: its name goes onto the bar as the client hands it over, never read. A cast its own caster stopped (a
  step, Escape), a cast nobody stopped and the cast of a mob that died just end, as before; a new cast ends the
  hold at once. `/fct interrupts on|off` (on by default), `/fct interrupts test` shows one on the target's bar.
  `/fct diag` keeps the last few interrupts heard: shown or why not, and whether the interrupter was secret.

## 0.5.4

- **The hunter's aim on the ranged bar.** A bow, gun, crossbow or thrown weapon spends the last half
  second of every cycle aiming, and the shot waits if you move then. The ranged bar now runs in two
  phases: the wait (the cycle less the aim) fills it as a swing does, then the aim fills it again as a
  quick red cast of half a second labelled "Aim". The wait is yours for a cast or a step. The weapon in
  the ranged slot decides; a wand winds up the same half second before each shot, shown as a red
  "Wind-up" (measured: a wand's first shot comes 0.63 s after the switch-on, a gun's 0.63 s). The first
  shot of an engagement has no swing event before it, so its aim runs from the moment Auto Shot is switched
  on. Switched off, the bar goes down while the game's cooldown runs on; switched on again, the bar picks
  the cycle up where it stands - the half second never runs before the cooldown is up, nor before the
  switch-on. The aim follows your feet: it runs only while you stand still, a step restarts it, and once
  aimed the bar holds "aimed" until the shot's own event (the feet heard through the client's movement
  events, since the speed is a secret in a fight). Checked in the game on a gun and a wand.
- **A resisted DoT draws no bar** (new, and not yet checked in the game). A Flame Shock the mob resisted
  still started a twelve-second bar, since the cast itself had succeeded. Now the target's own word is
  waited for: within a second of the cast - or half a second before its success - a resist, immunity or
  miss in the spell's school (UNIT_COMBAT, the one combat event this client leaves to addons, under
  whatever unit token names the mob) takes the bar down again, and damage of that school marks it landed.
  A swing or another school at the same moment says nothing, and a word a second late is some other
  spell's. Bleeds (Rend, Rupture, Rip) are left as they were: physical, like a white swing, so their miss
  cannot be told apart. `/fct diag` counts landed, not landed and unknown, and keeps the words it weighed.
- **Tab away and back in a fight, and the bars are there.** The client keeps a target's identity secret in a
  fight, and 0.5.3 answered with a stand-in that could not recognise a mob you came back to. Now a mob is
  known by its nameplate while the plate is up (the frame outlives the switch), failing that by its name
  and level, and only without either by a stand-in. A DoT cast at the pull is found again in the fight.
  A plate that goes takes its bars with it. `/fct diag` says which of the four kinds of key was in use.

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
