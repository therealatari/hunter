# Profiles

eohunter reads its own profiles from
`data/<game>/<char>/eohunter/profiles/<name>.yaml`, falling back to the
unchanged YAML that bsprofiles writes to
`data/<game>/<char>/bigshot_profiles/<name>.yaml` when no native namesake
exists. The [browser setup guide](setup.md) describes native envelopes,
linked defaults and Combat Plans, and Hunter-owned recovery preferences.
Existing flat profiles remain supported. This page lists the effective
settings the engine honours, how each value is read, its default when
blank, and which behavior uses it. Unknown settings are ignored by the
engine but preserved by the editor.

Values are cleaned the way bigshot's `clean_value` does. A missing or
blank value is the default for legacy value types, booleans included.
The structured `hunting_loadout_sets` and `hunting_loadout_rules` keys are
stricter: omit them or use `{}` / `[]` respectively to disable them. An explicit
YAML null, blank string, or wrong container type is a configuration error.

## Value types

| Type | Reading |
|---|---|
| int, float | `to_i` / `to_f` |
| bool | `true` only for the value `true` or the text "true" |
| string | as text |
| stance | lowercased: offensive, advance, forward, neutral, guarded, defensive |
| room | a Lich room id, or `u<uid>` for a game UID resolved through the map (the first matching Lich id) |
| rooms | a comma-separated list of the above |
| split | comma-separated list |
| split_xx | comma-separated commands, each with an optional repeat: `cmd(x3)` repeats three times, `cmd(xx)` five; `a and b` inside one entry is one line that sends both |
| targets | comma-separated names, each optionally suffixed with a routine letter `(b)` through `(j)`; no letter means routine `a` |
| regex | the text as a case-insensitive pattern |
| seconds | finite nonnegative seconds; invalid values refuse profile loading |
| list | a YAML list or comma-separated text |
| strict_rooms | comma-separated positive room IDs/UIDs; unresolved UIDs refuse loading |

## Rooms and travel

| Key | Type | Default | Used by |
|---|---|---|---|
| `hunting_room_id` | room | none | Wander: the area's anchor and the walk out; Rest: the walk back to hunting |
| `hunting_boundaries` | rooms | none | Wander: the rooms that bound the area; Flee: the rooms it may flee into |
| `resting_room_id` | room | none | Rest: where to rest |
| `return_waypoint_ids` | rooms | none | Rest: rooms visited in order on the way home |
| `rallypoint_room_ids` | rooms | none | Rest (group): where the leader gathers followers before hunting |
| `fog_return` | int | 0 | Rest: the fog method on the way home (Lich's Fog methods 1 to 5, or 6 for `custom_fog`) |
| `custom_fog` | split_xx | none | Rest: the commands for fog method 6 |
| `fog_optional` | bool | false | Rest: walk when the fog cannot be cast |
| `fog_rift` | bool | false | Rest: the Rift's second cast |
| `wander_wait` | float | 0.3 | Wander: seconds between steps |
| `ignore_disks` | bool | false | Wander: do not wait for a disk to follow |
| `sneaky_sneaky` | bool | false | Wander and Rest: hide before stepping, `movement autosneak` on trips |

## Resting

`preparations` is an optional structured mapping of named game commands whose
results come from Lich's Combat::Messages definitions. It defaults to `{}`;
explicit null, an unknown field or a malformed entry refuses profile loading.

```yaml
preparations:
  crystal:
    perform: feed my crystal
    result: user_feed_result
    match: { item: crystal }
    expect: { ok: true }
    timeout: 6
resting_room_id: 1234
hunting_prep_commands: prepare crystal
```

Replace the example refuge with your resting room. Install the named message
definition in Lich before using the preparation. Names, event names and payload
keys are lowercase identifiers (`a-z`, digits and underscores, starting with a
letter). `perform` is one nonblank game command, without semicolons or control
characters. `result` is required and must be loaded immediately before sending;
EOHunter reads the current names through World on every attempt. Unknown
preparation names in command lists refuse profile loading.

Optional `match` selects a response by scalar payload values; optional
`expect` checks success after selecting it. Both default to `{}`. Missing fields
never equal null. Numbers compare by value (`6` equals `6.0`); all other values
retain strict types (`"6"` differs from `6`, and `"true"` differs from `true`).
String and symbol keys identify the same payload field. Nested mappings
and arrays are not supported. With no `expect`, any correlated event confirms
success. A correlated event failing `expect` returns `failed/denied`, preserving
the event; silence or only unrelated events returns `timeout/no_confirmation`.
An unloaded result name fails before sending, rather than being treated as denial.
`timeout` defaults to 8 seconds and must be a numeric, finite value greater than
zero and at most 30 seconds. This bounds the confirmation wait after the send;
the existing action roundtime and send ladder retain their own separate bounds.

`prepare NAME` works in hunting routines and in `hunting_prep_commands`,
`resting_commands`, `field_hunting_prep_commands` and `field_rest_commands`.
Both paths call the same action. Routine modifiers remain the scheduling
interface; see [Routines](routines.md). Prep/rest lists take plain `prepare NAME`
words. Existing bare commands, including numeric `prepare 101`, retain their
existing command path.
In prep/rest lists, separate preparation steps with commas; named preparations
inside an `and` array refuse loading so each preparation gets its own tick.
When `preparations` is absent or empty, all existing command words retain their
old meaning, including `prepare spirit warding i`. A nonempty mapping opts into
named `prepare NAME` words; numeric spell preparation remains available, while
other unknown preparation names are configuration errors.

Preparations currently support ordinary solo hunts and require a positive
`resting_room_id`. Group, bounty and controlled LAB profiles reject configured
preparations, including dormant definitions. Their coordinated recovery and
command authority have not been extended by this feature.

A failed or unconfirmed preparation ends the hunt: away from the refuge, the
existing Rest return takes control while urgent survival behaviors remain
available; at the refuge the engine stops. A failed return reports stranded and
stops. Further preparation words are suppressed during that return, and hunting
does not resume automatically. A pre-send transient gate keeps the preparation
pending because nothing was consumed. Inspect the actual item and game result
before restarting; there is no automatic retry of an uncertain consumptive action.

The action arms its listener before sending. This catches immediate replies and
ignores events already delivered before arming, but cannot prove causation if
Lich delivers an older scanned line late. Include useful item/target correlation
fields in the definition and `match`; no regex observers or inferred item-state
latch are added by EOHunter.

`combat_buffs` is an optional structured mapping, disabled by default. It
configures which beneficial spells Maintain must restore and which losses ask
Rest for field/town recovery. See [Combat buff policy](combat-buffs.md) for the
schema, per-spell overrides, safe-departure verification and solo-only scope.

| Key | Type | Default | Used by |
|---|---|---|---|
| `fried` | int | 100 | Rest: mind percent at which to rest |
| `overkill` | int | 0 | Rest: kills past fried before resting |
| `lte_boost` | int | 0 | Rest: `boost longterm` uses per rest |
| `oom` | int | 0 | Rest and Engage: mana below which a spell routine rests |
| `encumbered` | int | 101 | Rest: encumbrance percent at which to rest |
| `encumbrance_grace_seconds` | seconds | 5 | Rest and follower reports: how long overweight must persist after loot releases |
| `wounded_eval` | string | none | Rest: a Ruby expression evaluated in the script; true means rest |
| `creeping_dread`, `crushing_dread` | int | 0 | Rest: the dread stack at which to rest |
| `wot_poison` | bool | false | Rest: rest on Wall of Thorns poison |
| `confusion` | bool | false | Rest: rest when confused |
| `box_in_hand` | bool | false | Read, not honoured: the engine always rests on a box it could not store |
| `rest_till_exp` | int | 0 | Rest: mind percent to rest down to |
| `rest_till_mana`, `rest_till_spirit` | int | 0 | Rest: the value to rest up to |
| `rest_till_percentstamina` | int | 0 | Rest: stamina percent to rest up to |
| `resting_commands` | split_xx | none | Rest: sent at the resting room |
| `resting_scripts` | split | none | Rest: started at the resting room, killed when hunting resumes |
| `use_wracking` | bool | false | Maintain and Engage: Voln's wrack when mana is short |
| `wracking_spirit` | int | 0 | Maintain and Engage: spirit to keep when wracking |
| `final_loot` | bool | false | Rest: a final loot pass before leaving |

### Field Rest and Town Rest (optional)

An ordinary solo hunt can recover near the hunting area, then return to town
only when it needs services. The existing `resting_room_id`, rest scripts,
return waypoints, fog configuration, rally route and hunting prep become the
**Town Rest** settings. Nothing moves or runs merely because a profile is loaded.
Omitting `field_rest_room_id` retains the single-rest cycle.

| Key | Type | Default | Meaning |
|---|---|---|---|
| `field_rest_room_id` | room | none | Safe Field Rest destination; enables two-site routing |
| `field_rest_for` | list | fried, mana | Reasons that can recover at Field Rest |
| `field_rest_commands` | split_xx | none | Commands on field arrival; never inherits town commands |
| `field_rest_scripts` | split | none | Field-only recovery scripts; never inherits town scripts |
| `field_return_waypoint_ids` | strict_rooms | none | Ordered return route to Field Rest |
| `field_rallypoint_room_ids` | strict_rooms | none | Ordered departure route from Field Rest |
| `field_hunting_prep_commands` | split_xx | none | Prep before leaving Field Rest; never inherits town prep |
| `field_rest_timeout_seconds` | seconds | 900 | Escalate unfinished field recovery to town after this interval; 0 disables |
| `town_rest_required_eval` | string | none | Trusted Ruby expression, like wounded_eval, for additional service/supply needs |
| `after_town_rest` | string | resume | `resume` hunts again after recovery; `stop` ends the run there |

All current reasons participate in destination selection: a full mind does not
mask persistent overweight or wounds. Every active reason must be field-eligible
to choose Field Rest. The supported reason keys are `fried`, `mana`, `wounded`,
`creeping_dread`, `crushing_dread`, `poison`, and `confusion`. Only fried/mana
are enabled by default. Opt into another condition only if the field routine
can actually treat it. Persistent encumbrance, failed item storage, an explicit
town-service condition and unknown failures always choose town.

Example (replace these example room IDs and script lists with your own):

```yaml
resting_room_id: 100
resting_scripts: "eherbs, eloot sell, ewaggle"
hunting_prep_commands: "get my staff"
field_rest_room_id: 200
field_rest_for: [fried, mana]
field_rest_scripts: ""
field_hunting_prep_commands: "get my staff"
encumbrance_grace_seconds: 5
after_town_rest: resume
```

Travel uses the existing supervised go2 machinery. Both refuges may be outside
the hunting boundaries. Field travel never inherits town fog/custom-fog commands
or town waypoints. The hunting destination, combat configuration and recovery
thresholds remain shared. Starting at the field room uses its departure prep
and route; other starts retain the existing town-side pre-hunt behavior.

Arrival is checked before location-specific services start. Scripts run in list
order, waiting for each to exit; scripts themselves must support the destination
and restore their equipment/location as required. Script exit is not proof that
selling or healing succeeded: current recovery thresholds must still clear.
An additional `town_rest_required_eval` can hold the character for unresolved
supplies. A missing/unstartable service stops the hunt visibly. Field travel
that exhausts the existing retry policy escalates to town; failed town arrival
does not run town services in the wrong room.

A new town-level need during field recovery or departure escalates to town.
Once selected, town remains selected for that cycle. The field timeout begins
on arrival, not during travel, and ends when departure starts. Escalation waits
for owned loot, travel cleanup and service scripts to finish; it does not kill
them mid-handoff. A hung script therefore still needs operator attention.
Survival, Cleanse and Flee retain their higher priorities throughout.

Two-site profiles currently refuse coordinated `head`/`tail`, ebounty and LAB
controller launches: those protocols promise a single shared/handoff refuge.
Use a separate single-rest profile for those modes. This feature does not add
a GUI or change the loot/selling scripts.

### Brief weight spikes

Rest's overweight timer is nonblocking. While owned loot runs, weight does not
request a return; once it releases, the character must stay at or above
`encumbered` for `encumbrance_grace_seconds` before a return is selected. A
below-threshold observation resets the timer. This covers a heavy box moving
through a hand before disk storage and delayed weight updates after stowing.

The default five-second interval applies to single-rest profiles and follower
reports too. Set it to `0` for the previous immediate threshold behavior. The
grace applies **only to encumbrance**: wounds, hazards and explicit failed-storage
errors are not delayed. Already-resting characters still cannot depart while
overweight; the grace does not relax recovery thresholds.

## Hunting

| Key | Type | Default | Used by |
|---|---|---|---|
| `hunting_prep_commands` | split_xx | none | Rest: sent before walking out |
| `hunting_scripts` | split | none | Rest: started before walking out, stopped at rest |
| `hunting_stance` | stance | defensive | Engage: set before each routine line that needs it |
| `wander_stance` | stance | defensive | Wander, Loot, Rest, Survival: the stance between fights |
| `stand_stance` | stance | defensive | Survival: the stance to stand up in |
| `hunting_right_hand` | string | keep | Loadout: the authoritative right hand between fights |
| `hunting_left_hand` | string | keep | Loadout: the authoritative left hand between fights |
| `hunting_aim` | string | none | Loadout: the body part aimed at once when a loadout is established |
| `hunting_loadout_sets` | mapping | {} | Named right/left/aim overrides of the default hunting hands |
| `hunting_loadout_rules` | list | [] | Ordered target/type selectors for named sets; first match wins |
| `signs` | split | none | Maintain: the signs, spells and symbols to keep up; `650 panther evoke` style entries work |
| `bless` | bool | false | Maintain: Voln's bless on the weapon |
| `check_favor` | bool | false | Maintain: skip a symbol the favor cannot pay for |
| `priority` | bool | false | Engage: the first target in the profile's order rather than the nearest |
| `targets` | targets | none | Targets: what to fight and with which routine |
| `quickhunt_targets` | targets | none | Targets: the quick routine's targets |
| `invalid_targets` | split | none | Targets: never these |
| `boons_ignore` | list | none | Targets: ASSESS abilities that make a creature not worth fighting |
| `boons_flee` | list | none | Flee: ASSESS abilities that mean leave |
| `hunting_commands` and `hunting_commands_b` to `_j` | split_xx | none | Engage: routines a to j; see [Routines](routines.md) |
| `quick_commands` | split_xx | none | Engage: the quick routine (bandit mode) |
| `disable_commands` | split_xx | none | Engage: the routine a fried group member runs |
| `ambush` | split | none | Engage: the body parts for `ambush` lines, in order |
| `archery_aim` | split | none | Engage: the parts for `fire` |
| `aim` | split | none | Engage: the parts for unarmed aiming |
| `tier3` | string | punch | Engage: the unarmed tier-3 attack |
| `uac_smite`, `uac_mstrike` | bool | false | Engage: unarmed extras |
| `mstrike_cooldown`, `mstrike_quickstrike` | bool | false | Engage: mstrike behaviour on cooldown |
| `mstrike_stamina_cooldown`, `mstrike_stamina_quickstrike` | int | none | Engage: stamina floors for the above |
| `mstrike_mob` | int | 2 | Engage: creatures present before mstrike is worth it |
| `ammo_container` | string | none | Engage: where a refused fire stows its ammo; blank means the game's STOW DEFAULT |
| `ammo` | string | none | Maintain: the ammo noun to keep count of |
| `wand` | split | none | Engage: the wand nouns, in order |
| `wand_if_oom` | bool | false | Engage: wave a wand in a spell's place when it is unaffordable |
| `fresh_wand_container`, `dead_wand_container` | string | none | Engage: wandolier's containers |
| `weapon_reaction` | bool | true | Engage: the weapon reaction line |
| `loot_script` | string | none | Loot: a script to loot with, instead of `loot` |
| `delay_loot` | bool | false | Loot: wait fifteen seconds after a kill before looting |
| `loot_stance` | bool | false | Loot: switch to the wander stance to loot |

### Hunting loadout

The two hunting hand fields are optional. Missing, blank, or `keep`
leaves that hand unmanaged, preserving every existing profile. `empty`
requires an empty hand, `ready:<slot>` uses a Lich ReadyList slot such
as `ready:weapon` or `ready:shield`, and any other value is matched as
an item name using Lich's Stash rules.

```yaml
hunting_right_hand: ready:weapon
hunting_left_hand: empty
```

For sword and shield use `ready:weapon` / `ready:shield`; for empty-handed
UAC use `empty` / `empty`.

Ranged weapons care which hand holds them, and the game decides, not Hunter.
Two-handed ranged weapons go in the left hand with the right kept `empty` to
draw ammo. Only the hand crossbow is small enough to use the right hand:

| Weapon | Right | Left |
|---|---|---|
| short, composite, or long bow | `empty` | `ready:ranged_weapon` |
| light or heavy crossbow | `empty` | `ready:ranged_weapon` |
| hand crossbow, one-handed | `empty` | `ready:ranged_weapon` |
| hand crossbow, two-weapon | a second named crossbow | `ready:ranged_weapon` |

Prefer `empty` over `keep` for the free hand. `keep` cannot be reconciled when
the wanted weapon is already sitting in the kept hand, and Stash refuses that
combination rather than swapping, which latches the terminal `loadout_stuck`
path.

### Aim

`hunting_aim` names one body part, sent as a single `AIM` after the hands
verify. Leave it blank and Hunter never touches your aim. It is the ordinary
game-wide AIM setting, so it applies to ambush and unarmed lines exactly as it
applies to archery.

```yaml
hunting_left_hand: ready:ranged_weapon
hunting_right_hand: empty
hunting_aim: right eye
```

This is one command per establish, not a per-shot rotation. The combat routines
own every later change: `archery_aim` for `fire`, `ambush` for ambush lines, and
`aim` for unarmed. If one of those rotates the aim, Hunter does not fight it
back, and does not re-aim until the next time it establishes a loadout. A
refused AIM leaves the verified hands alone and does not stop the hunt.

Loadout is a between-fight baseline, not a competing inventory system.
For solo hunters and group leaders, Rest also checks it after hunting
preparation, before outbound rally travel, and again before travel to
the hunting room. This runs on each departure, not just script startup.
Active go2 travel still owns its hands and destination cleanup. Followers
use the between-fight check; this feature does not add a group-wide
equipment-readiness handshake before the leader moves.
Combat routines retain the hands while continuing against the same target;
a priority or Assist target change requires a new equipment handoff,
and Survival, Cleanse, Flee, Rest, and Loot all take priority. After a
temporary subsystem finishes, EOHunter asks `Lich::Stash.hands` to
restore both configured hands as one transaction and verifies the live
result. Named items are resolved by core on their first reconciliation,
then compared by their current-session IDs. Already-equipped named
items need no movement; ready slots can be checked directly from the
cached list. A missing or inaccessible item produces a specific
`loadout_stuck` error. A solo hunt or group leader returns to its
configured resting room before stopping. A follower reports the failure
through the existing group rest mechanism and stops after the current
return's preparation finishes at the leader's resting room. While
returning, lower-priority combat and wandering stay blocked. Travel
and rest keep their existing retry and failure behavior; a solo profile
without a resting room stops with the diagnostic where it is.
If Rest exhausts its return retries, the hunt stops after stranded
preparation with `loadout_return_failed` and requests manual intervention;
it does not claim that the refuge was reached.

### Named equipment sets

Configure named sets and ordered rules in the same YAML profile. A graphical
editor is not part of this feature. Without these keys, the default hunting
hands above continue to work as before.

```yaml
hunting_right_hand: ready:weapon
hunting_left_hand: empty
hunting_loadout_sets:
  undead:
    right: blessed maul
  spirits:
    right: sanctified maul
  armored:
    right: heavy maul
hunting_loadout_rules:
  - target: armored orc
    set: armored
  - type: noncorporeal
    set: spirits
  - type: undead
    set: undead
```

The item names above are examples, not a claim that Hunter can determine an
item's properties. Choose weapons you have verified suitable for those targets.

Each set accepts `right`, `left` and `aim`, using the same hand references as
the default. Omitted hands inherit the default requirement; explicit `keep`
leaves the hand unmanaged. An omitted `aim` inherits `hunting_aim`; an explicit
empty `aim` means that set sends no AIM at all. Rules require `set` and at least one of `target` or `type`.
When both are present, both must match. The first matching rule wins, so put
specific exceptions before broad categories. A noncorporeal undead target can
match both categories; rule order determines which set wins.

`target` uses the existing target name/noun matching rules (anchored,
case-insensitive patterns, including the regex fragments already supported by
`targets`). `type` accepts `living`, `undead`, or `noncorporeal`. Living requires
positive knowledge from the core creature template; an unknown creature is not
assumed living merely because it lacks an undead tag. Unknown classifications
can still match a name rule, otherwise they use the default.

Rules do not change which monsters Hunter fights. They select equipment for
Engage/Assist's chosen monster, before its routine begins. No match, no eligible
target, and Rest departure preparation use the default hunting hands. A routine
can still intentionally change weapons during that fight; the named set is not
reapplied between its dependent steps. The next target gets a fresh handoff,
including when the previous monster is still alive.

Malformed sets/rules, unknown set references, and invalid target patterns are
rejected during profile loading. Missing required equipment at runtime is an
explicit loadout failure, not permission to attack with a different weapon.

## Fleeing and survival

| Key | Type | Default | Used by |
|---|---|---|---|
| `flee_count` | int | 100 | Flee: creatures present at which to leave |
| `lone_targets_only` | bool | false | Flee: leave when a second creature joins a fight |
| `always_flee_from` | split | none | Flee: names that always mean leave |
| `flee_message` | regex | none | Flee: a game line that means leave |
| `flee_clouds`, `flee_vines`, `flee_webs`, `flee_voids` | bool | false | Flee: hazards that mean leave |
| `pull` | bool | true | Survival: pull a prone group member up |
| `deader` | bool | false | Survival: stop for a dead player in the room during the hunt |
| `dead_man_switch` | bool | false | Survival: quit on death |
| `depart_switch` | bool | false | Survival: depart on death |
| `troubadours_rally` | bool | false | Cleanse: 1040 on ourselves and the group |

## Group hunting

| Key | Type | Default | Used by |
|---|---|---|---|
| `independent_travel` | bool | false | Group: followers walk out on their own |
| `independent_return` | bool | false | Group: followers walk home on their own |
| `group_deader` | bool | false | Group: the leader stops for a dead member |
| `ma_looter` | string | none | Group: who loots |
| `never_loot` | split_xx | none | Group: members who never loot |
| `random_loot` | bool | false | Group: a random looter each fight |
| `quiet_followers` | bool | true | Group: followers do not print the leader's orders |
| `group_fried_trigger` | split | any | Group: `any`, `all`, or names; whose fried brings the group home |
| `group_strict_movement` | bool | false | Experimental same-host named-roster movement acknowledgments; enable on every participant. See [strict movement](strict-group-movement.md) for scope and limits. |

## Cleanse

Cleanse reads `ecleanse.yaml` in the character directory, not the
bigshot profile, with ecleanse's own keys: which afflictions to treat,
which hazards to dispel, disarm recovery, hive traps. ecleanse's setup
window writes that file; eohunter never does.
