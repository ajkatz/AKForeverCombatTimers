# AKForeverCombatTimers

*Called ForeverSwingTimers until v0.3.7 - with the target's casts and your own in the same block,
"swing timers" no longer covered it. `/fst` still works next to `/fct`.*

Swing timers and cast bars for **World of Warcraft: Forever** (Interface `16001`), in one block.

- **Your swings** - main hand, off hand and ranged, each on its own bar, driven by the
  client's own swing API. Replaces Blizzard's built-in timer (and puts it back on request).
- **The enemy's swings** - a bar counting down to the next hit on you, or on the tank your
  target is attacking, or on the friendly you have targeted as a healer.
- **Cast bars** (v0.3) - the target's cast on top of the block, your own cast at the bottom: spell
  icon, name, seconds left. Blizzard's two cast bars are switched off once ours has proven it works.
- **Planned: heal timing** - mark when to start a heal so it lands just after the hit.

Status: **v0.4.1 (2026-09-20)** - renamed from ForeverSwingTimers on 2026-09-20. Confirmed in the game the same day:
*Slice and Dice* stays on the buff bar for its WHOLE duration in a fight (see *The buff bar*). Your own swing bars stand on a verified API and work in the game;
the enemy bar (v0.2 model) replays a real session with a median error of 0.05 s. The cast bars are
new and unproven in the game - see *Cast bars and secret values*.

## The block (v0.3.5)

```
      target cast        ^   the enemy's half grows UP from the seam
      incoming hit       |
 ---- seam --------------+-- what you position; it never moves when rows come and go
      main hand          |
      off hand           |   your half grows DOWN
      ranged             v
      buff (Slice and Dice ...)
      your cast
```

Every bar has a **mode** - `always`, `when used` (+ N seconds after) or `never` - its own **width and
height**, and a place in the **order** of its half. A bar that is `never`, or does not apply to the
character (off hand without an off-hand weapon, a buff bar that tracks nothing), takes no row; every
other bar keeps its row while idle, so nothing ever jumps. Bars **fade** in and out (`/fct fade off`:
they pop). "Used" means: a swing of that type is running / a cast is in progress / an enemy hit is
being timed / the buff is up. Being in combat is not "use".

The block is positioned by its seam: `/fct anchor left|center|right` says which point of it is
pinned (and lines up bars of different widths), `/fct center` centres it on the screen, and a block
dropped within 24 px of the centre line snaps onto it (`/fct snap off`).

Locking no longer decides what is visible. Unlocked only adds a small blue **`timers` tab** next to
the seam (drag it to move the block, click it for the settings window), the seam as a hairline, and
faint corner marks on idle rows. Idle rows are click-through either way.

| | |
|---|---|
| `/fct config` | the settings window: order, mode, seconds, width, height per bar; alignment, centre, snap, fade, lock, test |
| `/fct bar` | list; `/fct bar mh always`, `bar oh never`, `bar rg used 10`, `bar cast width 260`, `bar cast height 18`, `bar cast up` / `down`, `bar reset` |
| `/fct order tcast enemy mh oh rg buff cast` | the whole order at once (each bar stays in its half) |
| `/fct buff` | what the buff bar tracks: `buff add <spell name>`, `buff remove <spell name>`, `buff reset` (rogues start with Slice and Dice) |

**The buff bar.** Out of combat an aura is plainly readable: bar, icon and a countdown. **In a fight an
addon cannot touch your auras at all** - measured on this client (reports of 2026-09-20): a lookup by
spell returns nothing, `UNIT_AURA`'s payload is secret, and even the list of aura instance ids raises
*"Auras cannot be accessed when secret while tainted"*. A Slice and Dice cast in a fight therefore used
to show up only when the fight was over ("just the last 10 seconds").

Since v0.4.1 it runs on **the combo points you spent** instead. Those are secret as well - but
`UnitPowerPercent(unit, powerType, unmodified, curve)` makes the *client* put the secret value through a
curve of ours and hands back the (secret) result. Our curve is "points / 5 -> minus the seconds that many
points buy" (9 / 12 / 15 / 18 / 21), and the result is exactly what a status bar needs as its lower bound:
`SetMinMaxValues(<secret: -duration>, 0)` with `SetValue(-(seconds since the cast))` starts full and is
empty when the buff ends - without a single secret value being read. It is taken when the cast is
**sent** (the points are still there; without that event: the newest snapshot from before the cast).

* no countdown text in a fight: nothing can count down from a number we may not read. When the fight
  ends the real aura takes over, with its numbers; an estimate whose buff is gone by then is dropped;
* *Improved Slice and Dice* stretches the table: the factor is learned from the first real, readable
  aura (its duration is one of `seconds x factor`) and remembered per character;
* if this client turns out to let us read the value, plain numbers and a countdown are used instead.

`/fct diag` -> `buffs.bar` says how each bar came about, `buffs.estimates` what the curve route did.

**Item icons.** A cast that comes from an item (sharpening stone, bandage, hearthstone, a trinket)
shows the item's own icon instead of the spell's placeholder: your casts are readable, so the spell
id is matched against the "use" spells of what you carry and wear.

## Using it

On first login the bars are unlocked: drag the blue area, then `/fct lock`.

| Command | |
|---|---|
| `/fct unlock` / `/fct lock` | move the bars / fix them in place |
| `/fct test` | 15 seconds of moving test bars |
| `/fct show always` / `combat` | when the bars are visible (default: in combat or while a swing runs) |
| `/fct enemy` | toggle the incoming-hit bar |
| `/fct watch auto` / `focus` / `party2` ... | whose incoming hits to time (default: auto) |
| `/fct casts on` / `off`, `casts player on|off`, `casts target on|off` | the cast bars (default: both on) |
| `/fct casts blizzard show` / `hide` | Blizzard's own cast bars (default: hidden once ours has shown a cast; `show` puts them straight back) |
| `/fct blizzard hide` / `show` | Blizzard's own swing timer (default: hidden, via the `showSwingTimer` CVar) |
| `/fct diag` | snapshot everything measured into SavedVariables, then `/reload` |

## Cast bars and secret values

Block order, top to bottom: **target cast | incoming hit | main hand | off hand | ranged | your
cast** - the enemy above, you below. Idle cast bars keep their (invisible) slot, so the swing bars
never jump when somebody starts casting; out of combat your cast shows without the swing bars.
While the block is **unlocked**, only the swing bars carry the blue tint and can be grabbed; an idle
cast slot is empty, click-through space with four faint corner marks where the bar will appear
(locked: nothing at all).

On this client cast information is `SecretWhenUnitSpellCastRestricted`: `UnitCastingInfo` may answer
with values an addon can pass on but not read. Whether that restriction is ever active in Forever is
not known yet, so the bars handle both, and `/fct diag` records per cast what was secret and which
display path the client accepted (`casts.samples[].path`):

| path | when | what you get |
|---|---|---|
| `numbers` | times readable | own arithmetic: spark, seconds left, pushback, channels drain |
| `SetTimerDuration` | times secret | `UnitCastingDuration(unit)` handed to `StatusBar:SetTimerDuration` - the client animates the bar. **Measured 2026-09-19: this is what every target cast uses** - enemy casts are secret in and out of combat (Blizzard: "secret if the unit ... is not the player or their pet"), your own are always readable |
| `SetMinMaxValues` | ... and the timer refuses addons | the secret start / end become the bar's bounds (documented `AllowedWhenTainted`), we feed it `GetTime()*1000` |
| `refused` | nothing accepted | a full bar with a plain "Casting" - and Blizzard's bar for that unit is left on |

**Seconds left on a secret cast** (v0.3.4) come from the same duration object: a *duration text
binding* (`C_DurationUtil.CreateDurationTextBinding` + a `C_StringUtil.CreateNumericRuleFormatter`
with `{ threshold = 0, step = 0.1, format = "%.1f" }`) lets the client itself keep writing the
countdown into our font string; if it refuses, `duration:FormatRemainingDuration(formatter)` is
written every frame (a secret string, straight into `SetText`); else no seconds. `/fct diag` records
which one was used (`casts.samples[].seconds`: `numbers` | `binding` | `format` | `none`).

**The buff experiment** (v0.3.4, diagnostics only): could a bar show how long *Slice and Dice* still
runs? Aura data is secret "when combat ... restrictions are in effect" unless the spell is flagged
never-secret, and a lookup by spell id returns nothing while it is secret. So when you cast a watched
buff (Slice and Dice, Sprint, Evasion, Lightning Shield) the next `UNIT_AURA` is examined: which
fields were readable, did the event name the aura instance, and can
`C_UnitAuras.GetAuraDuration("player", instanceID)` drive a status bar? Results: `/fct diag` ->
`buffs.samples`.

Name and icon go straight into `FontString:SetText` / `Texture:SetTexture` (both documented
`AllowedWhenTainted`) inside a pcall and are never looked at. One event frame per unit, because even
the unit in a cast event's payload may be secret. `UNIT_SPELLCAST_FAILED` only ends a cast when the
client agrees nothing is being cast (it also fires for a second spell you mash mid-cast).

Blizzard's bars: the player's has no off switch, and the target's `showTargetCastbar` CVar is tested
as `GetCVar(...) and ...` in this build - the string `"0"` is true in Lua, so it shows regardless.
Instead each one is taken off the screen the way ITS code tolerates - plain widget calls only, out
of combat, and only after OUR bar for that unit has displayed a cast; `/fct casts blizzard show`
puts both straight back:

| Blizzard's bar | how | why |
|---|---|---|
| yours (`PlayerCastingBarFrame`) | **parked**: `SetParent` to a frame that is never shown - only while the bar is hidden | its code never asks for its parent; moving it while shown would fire Blizzard's OnHide / OnShow (managed-frame container) from our call |
| the target's (`TargetFrameSpellBar`) | **shrunk** to nothing with `SetScale` | it must keep its parent: `TargetSpellBarMixin:AdjustPosition()` calls `self:GetParent():ShouldAnchorSpellBarToAuraContainer()` at every aura change; Blizzard never sets this bar's scale |

What the game said along the way (2026-09-19):

- v0.3.0 asked `bar:IsEventRegistered(...)`: on Blizzard's cast bars that answers addon code with a
  **secret boolean**, and `if secret then` is a Lua error. Rule since then: whatever a getter on one
  of Blizzard's frames returns goes through `issecretvalue` before it is looked at - and
  `a and b or c` counts as looking. `UnregisterAllEvents()` was dropped with it: the API docs tie it
  to "forbidden aspects" (`EventRegistrations`), a security model we cannot predict.
- v0.3.1 parked the target's bar as well: `TargetFrame.lua:824: attempt to call a nil value` inside
  Blizzard's aura layout - the `GetParent()` call in the table above. Rule: before re-parenting one
  of Blizzard's frames, grep its code for `GetParent()`. The test mock now fails on either mistake. Registering `UNIT_SPELLCAST_*` is safe: unlike
`COMBAT_LOG_EVENT_UNFILTERED` those events carry no `HasRestrictions` flag in the API docs.

## DoT bars

How much longer your damage-over-time spells have left on what you are fighting - Flame Shock, Serpent
Sting, Shadow Word: Pain and so on. One bar each, up to four, ordered and sized like any other bar.

```
/fct dot                     what has a bar, and how long each one is believed to run
/fct dot add Flame Shock     give a spell a bar
/fct dot remove Flame Shock  take it away
/fct dot reset               back to the defaults for your class
```

**These are the one kind of timer that works properly in a fight**, and it is worth saying why. A buff of
yours cannot be found in combat at all on this client - the aura lookup returns nothing and the instance
ids raise - which is why Slice and Dice has to be estimated through a curve and comes out as a bar with
no numbers on it. A DoT needs none of that, because **its duration is a constant we already know** and
**your own casts are never secret**. A cast plus a known duration is a real countdown with real seconds,
whatever the client will or will not say about the aura.

The aura is still read whenever the client allows it, because it is the truth and the above is only
arithmetic. A readable aura corrects the clock *and teaches* how long that spell runs for this character,
which is how ranks, talents and anything else that stretches a DoT get accounted for without a table of
every case. A spell nothing has taught us and that is not in the table gets **no bar** rather than a
confident wrong number.

**Rip and Rupture are a case of their own.** Their length is bought with combo points, and the points
are secret - so no table and no remembered value can say how long one is running. Learn sixteen seconds
from a five-point Rupture, cast a two-point one, and the bar would lie with a straight face. So for
these: never a table duration, never a learned one. Out of a fight the aura is readable and the bar is
exact, with numbers. In a fight the buff bar's trick applies unchanged - the client puts the secret
points through a curve of ours and hands back a secret length, which a status bar takes as its lower
bound without anybody reading it. That bar runs the right length with no numbers on it, which is the
honest best this client allows.

Timers are kept per enemy GUID, so a mob you DoTted a minute ago still has its clock when you target it
again; the bars themselves only ever show your current target. Where the client will not give a readable
GUID - an enemy player, most likely - nothing is filed at all, rather than guessing whose DoT it was.

## Reactive windows

How long you still have to press **Overpower, Revenge, Mongoose Bite, Counterattack or Riposte** - the
abilities that only open for a few seconds after a dodge, a parry or a block. One bar each, up to three.

```
/fct react                    what has a bar, and the counts
/fct react add Revenge        give one a bar (only the five above: it has to know what opens it)
/fct react remove Revenge
/fct react reset              back to your class's defaults
```

The combat log is forbidden to addons on this client, but `UNIT_COMBAT` is not - *"this unit was just
hit / dodged / parried / blocked"*, by name, readable in combat (measured: 306 events, none secret). It
names the **victim**, which is exactly right for four of the five: you dodged, you parried, you blocked.
The window is a constant we know (five seconds), so the bar counts real numbers down with nothing secret
anywhere, and it closes the moment you *use* the ability - your own casts are never secret.

**Overpower is the wrinkle.** It opens when the target dodges *your* attack, and "target dodged" cannot
say whose. Alone, it is you. In a group the dodge has to line up with a swing of yours - and this addon
owns the swing timers: `PLAYER_SWING` fires the instant a swing lands, and your melee abilities arrive on
`UNIT_SPELLCAST_SUCCEEDED`. A target dodge within 0.4s of either is yours; anything else is counted as
somebody else's in `/fct react` rather than shown. Nothing else in the game is placed to make that call.

## How it works

```
Core.lua         events, message bus, one account-wide saved table, session log, slash commands
Swings.lua       your swings: PLAYER_SWING(duration, type) + range + attack speed rescaling
Incoming.lua     enemy swings: watched-unit resolution, UNIT_COMBAT hit model, self-scoring
UI/Bars.lua      the bars (plain frames only - nothing protected, nothing blocked in combat)
Blizzard.lua     switches Blizzard's timer off/on through its CVar
Diagnostics.lua  /fct diag -> AKForeverCombatTimersDB.diag (measurements, errors, blocked actions)
```

**Your swings.** Forever ships `C_SwingTimer`: the `PLAYER_SWING` event carries the swing's
duration and type (`Enum.PlayerSwingType`: MainHand / OffHand / Ranged), and
`PLAYER_SWING_RANGE_UPDATE` says when the target is out of reach. Blizzard's own bar is
plain `GetTime()` arithmetic on that event, and so is this one. When `UNIT_ATTACK_SPEED`
fires, the rest of a running swing is rescaled by new/old speed.

**The enemy's swings.** There is no swing API for other units, the combat log is restricted
for addons, and `UnitAttackSpeed(target)` is secret whenever unit stats are restricted. What
the client still announces is `UNIT_COMBAT`: *this unit was hit / dodged / parried / blocked
/ missed*, with the damage school. It names the victim, never the attacker, so the timer
follows **hits landing on one watched unit**:

| You have targeted | Watched unit |
|---|---|
| a hostile | whoever it is attacking - you, your pet, or a group member |
| a friendly | that friendly (healer watching the tank) |
| nothing | you |

The swing interval is the median gap between recent hits (0.7-6s, hits within 0.25s count
as one). Confidence falls as the rhythm gets irregular - several attackers on one victim,
or special attacks mixed in - and the bar dims below 40%. If the target's attack speed *is*
readable it seeds the timer before the second hit.

Every prediction is scored against the hit that actually arrives; `/fct diag` reports the
mean error. That number, not opinion, decides how the model changes.

## Measured so far (rogue, open world, 2026-09-19, 306 UNIT_COMBAT events)

| Question | Answer |
|---|---|
| Does `PLAYER_SWING` fire per swing? | Yes (105 swings). Our timer ends within **41 ms** of the next swing on average, never more than 100 ms. The event's duration (1.60) is 0.1 s shorter than `UnitAttackSpeed` (1.70). |
| Is `UNIT_COMBAT` readable in combat? | **Yes**, none of 306 events were secret (outdoors). It also fires for the `targettarget` and `nameplateN` tokens - we match the watched token exactly, so nothing is counted twice. |
| Is the target's attack speed readable? | **Out of combat yes, in combat secret.** So it is noted before the pull and kept. |
| Is the combat log available? | No - registering for it is a forbidden action (see below). |

Replaying that session's real hits (`lua tests/replay.lua tests/sample-session-2026-09-19.lua 2.0`):

| Model | median error | within 0.25 s | within 0.5 s | worst |
|---|---|---|---|---|
| v0.1: one rhythm per victim | 0.084 s | 16 / 27 | 18 / 27 | several seconds |
| v0.2: one track per attacker, speed unknown | 0.066 s | 17 / 21 | 19 / 21 | 2.99 s |
| v0.2 with the mob's speed kept from before the pull | **0.045 s** | 16 / 20 | **19 / 20** | **0.63 s** |

Small sample (29 hits), and the same data motivated the redesign - the next session is the real
test. v0.2 scores fewer hits because a new attacker's first hit is counted as *unannounced*
rather than as a prediction; `/fct diag` reports predicted / late / new-attacker counts.

Still open: dungeons and raids ("restricted maps"), haste/slow effects on your own swings, reading
your own cast (for heal timing).

## The experiment

Fight a few things, then `/fct diag`, `/reload`, and read
`WTF/Account/<account>/SavedVariables/AKForeverCombatTimers.lua` (`AKForeverCombatTimersDB.diag`).

1. `player.swings` / log `swing` entries: does `PLAYER_SWING` fire per swing, for each hand?
   What is the logged `drift` (how far off the previous timer was when the next swing came)?
2. After a haste proc or slow: does the client re-send `PLAYER_SWING`, or is our
   `swing_rescaled` the only correction? Compare the two in the log.
3. `enemy.rawSamples`: does `UNIT_COMBAT` arrive readable **in combat**? **Inside a dungeon?**
   Which `action` / `school` values do melee swings, avoided swings and specials carry?
4. `enemy.unitCombatSecretEvents`: ever above zero? Where?
5. `enemy.meanAbsErrorSeconds` on a single mob, on a pack, on a boss.
6. `enemy.prior` / log `target_attack_speed`: is a hostile's attack speed ever readable?
7. ~~Does the combat log reach addons anywhere?~~ **No.** Merely registering
   `COMBAT_LOG_EVENT_UNFILTERED` is a forbidden action in the Forever client: v0.1.0's probe
   raised the "blocked from an action only available to the Blizzard UI" dialog (2026-09-18).
   The probe is gone, the test mock now refuses that registration the way the client does,
   and `diag.blockedActions` names the function if anything is ever blocked again.
8. `cast`: is your own cast readable (needed for heal timing)?

## Saved settings on the Forever beta

The 1.60.1 client writes SavedVariables on logout but never reads them back.
`tools/Install-SavedStateBridge.ps1` installs a companion addon that loads the saved file as
code before this addon starts (`-Remove` takes it out again). All data, per-character
included, lives in the one account-wide table so a single junction covers it. Never delete
the companion folder with `Remove-Item -Recurse` in Windows PowerShell 5.1: it follows the
junction into the real SavedVariables folder.

## Tests

```powershell
lua tests/run.lua
```

`tests/wowmock.lua` is a strict stand-in for the client (unknown widget methods fail, any
addon error fails the scenario). It encodes our assumptions about the API; passing tests
prove the logic, the experiment above proves the assumptions.
