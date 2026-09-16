# The routine language

`prepare NAME` invokes a named, event-confirmed profile preparation without a
stance change. For example, `prepare crystal(once)` runs once per target and
`prepare crystal(room)` uses the existing room modifier. Definitions and failure
recovery are documented in [Profiles](profiles.md#resting). Unsent action gates
keep this line pending; denied or unconfirmed required preparations end the hunt
through the existing return lifecycle. The named action is also used by prep/rest
lists. Numeric game commands such as `prepare 101` remain ordinary commands.

Use modifiers directly on the word. The `force`, `eachtarget` and spell prefixes
cannot wrap a named preparation: they can perform additional sends or repeat a
consumptive command within the same tick. Such combinations refuse profile loading.

A routine is a list of lines in `hunting_commands` (routine `a`) or
`hunting_commands_b` through `_j`. Engage runs one line per tick, in
order, wrapping around, on the current target. Each line is a word
with arguments and an optional parenthesis of modifiers:

```
702, 720(m40 !stunned), coupdegrace(coupdegrace buff5), attack(x2)
```

`(x2)` and `(xx)` are repeats and expand when the profile loads. `a and
b` inside one entry is one line that sends both. Everything else in the
parenthesis is a modifier, checked before the line runs; if any one of
them says skip, the line is skipped without sending and the routine
moves on. A skipped line is not a failed action.

`untildead` retains the current step after a successful action, once per engine
turn, until the target changes or disappears. Conditions and higher-priority
behaviours still run between attempts; a skip or unsuccessful action advances
normally. Target changes restart the routine. For example,
`719 (once), 711 (x2), 705 (untildead)` stays on successful 705 actions after
the opener rather than cycling back immediately. Do not combine `untildead`
with `once`, `room` or expanded repeats. This modifier requires the updated
engine; older engines may silently ignore unknown modifiers.

Before a line runs Engage also does the standing work: the hunting
stance unless the word is stance-free (a spell number, wait, sleep,
wand, berserk, script, hide, nudgeweapon), the weapon reaction, and the
soothe when the target is calmed.

## Words

### Spells

`702`, `incant 702`, `702 open`, `702 channel`, `702 evoke fire`, `702
closed cast`. The number is Lich's spell; the rest is passed to the
cast. A spell line first goes through the spell gates: known, not on
cooldown, affordable, the out-of-mana rule. An unaffordable spell waves
a wand when `wand_if_oom` is on, wracks when `use_wracking` is on, and
otherwise fails the line and, when the `oom` rule says so, asks for a
rest. Self spells 506, 902 and 411 cast without a target.

`allycast 1109 Skooshii` casts on a named player who is present and in
our group; a missing ally skips the line. With `(afterattack)` the line
runs once and then re-arms only after that ally makes an observed
attack.

### Attacks

`attack`, `kill`, `jab`, `punch`, `kick`, `grapple`, `hurl`. Sent at the
target through the attack action, which knows the game's refusals
(nothing to attack, out of reach, hands full, stunned) and returns them
as reasons.

With a managed hunting loadout, `hurl` and `dhurl` retain ownership through
bounded weapon recovery, even if the throw kills the target. Hunter records
both original hand item IDs, allowing a shield to stay in the other hand, and
uses the existing core return event and `recover hurl` action. Recovery observes
the existing six-second flight window and has a ten-second total budget,
including roundtime waits. Automatic return can finish earlier when the
original items are observed back in hand. Loot and a new equipment set do not
interleave inside this action.

Stop, pause, urgent survival/cleansing/fleeing needs, an active rest return, or
a room change interrupt managed recovery. A missing, ambiguous, or unverified
return enters the existing loadout failure/return path; Hunter does not walk
back into another room to chase a hurled item. An interrupted hunt does not
silently resume combat with unresolved equipment.

This verifies item identity, not every special weapon script. Returns creating
replacement IDs, disappearing generated projectiles, and weapons requiring
custom retrieval commands need separate support/testing. A same-ID name change
is safe. Profiles with no managed default or rule-selected set keep their
existing `hurl`/`dhurl` behavior. Saving unused named sets does not enable
management.

### Maneuvers

Every PSM technique bigshot's routines name, by its bigshot word, sent
through Lich's PSM readers so the command and the result lines are the
core's. The category may be given (`cman bullrush`) or not
(`bullrush`). `all` after the word targets everyone. Coup de grace is
held, not sent, when the target's health is above the skill's threshold.

| Kind | Words |
|---|---|
| assault (weapon) | barrage, flurry, fury, gthrusts, pummel, thrash |
| weapon | charge, clash, cripple, cyclone, dizzyingswing, pindown, pulverize, twinhammer, volley, wblade, whirlwind |
| shield | shield bash, shield charge, shield pin, shield push, shield strike, shield throw, shield trample |
| cman | bullrush, coupdegrace, cpress, dirtkick, disarm, and the rest of bigshot's cmd_cmans list |
| feat, warcry | the words in `Actions::Maneuver::WORDS`; shout, yowlp, holler and the other cries |

The full table is `Actions::Maneuver::WORDS` in maneuvers.rb.

### mstrike

`mstrike` and `mstrike <attack>`, with the profile's cooldown and
quickstrike rules and the `mstrike_mob` floor.

### Other words

| Word | Does |
|---|---|
| `hide`, `hide 5` | hide, up to N attempts (three by default) |
| `weed`, `kweed` | Tangleweed; `k` for the kill form |
| `script name args` | start a script and wait for it |
| `sleep 3`, `sleep 3 nostance` | wait, in the wander stance unless `nostance` |
| `stance offensive` | change stance |
| `wait 5` | hold until the target swings or N seconds pass |
| `ambush`, `ambush head` | the next part from `ambush` in the profile, or the named part |
| `fire` | ranged: aim at the next `archery_aim` part and fire; a refused fire stows the ammo |
| `wand`, `wandolier` | wave the next wand; wandolier manages fresh and dead containers |
| `unarmed <attack> <aim>` | the unarmed machine with its tiers |
| `smite` | Paladin's smite, once per target |
| `caststop 1013`, `unravel`, `barddispel`, `depress`, `resonance 1030 1031` | bard words |
| `curse clumsy` and the other curses, `phase`, `tether`, `efury fire`, `dhurl` | sorcerer and empath words |
| `rapid`, `rapidfire`, `throw`, `dislodge`, `jewel <mnemonic>`, `briar <weapon>`, `assume <aspect>` | the rest of bigshot's cmd_* table |
| `wield <noun> [left]`, `store [left]` | hands, through Lich's Stash |
| `sacrifice`, `stomp`, `leech`, `nudgeweapons`, `berserk` | as in bigshot |
| `force <cmd> until 120` | repeat a command until its endroll reaches the goal |
| `eachtarget <cmd>` | the command once at every valid creature |
| `celerity <cmd>`, `slayer <cmd>`, `tonis <cmd>` (or 506, 240, 1035) | the prefix spell first, then the command |

Anything else is sent as a plain command and its answer returned.

## Modifiers

A modifier in the parenthesis is one of the forms below. A leading `!`
inverts it. Unknown words are reported once and ignored.

### Amounts

`m40` skips the line when mana is below 40. The letter picks the value:

| Letter | Value |
|---|---|
| `m` | mana |
| `s` | stamina |
| `v` | spirit |
| `h` | health percent |
| `e` | encumbrance percent |
| `essence` | shadow essence |
| `mob` | creatures present (skip when fewer than N) |
| `valid` | valid targets present (skip when fewer than N) |
| `tier` | the unarmed tier (skip when below N) |
| `k` | kneeling (no number) |

With `!` the comparison flips: `!m40` skips when mana is 40 or more.

### Buffs and effects

| Form | Skips when |
|---|---|
| `buff5` | the command's own buff is up with more than 5 minutes left (barrage, bearhug, coupdegrace, flurry, fury, garrote, kweed, pummel, shout, thrash, weed, yowlp) |
| `empowered20` | an Empowered buff of +20 or more is up |
| `thp50` | the target's health percent is above 50 |
| `repeatdelay30` | the same line ran within the last 30 seconds |
| `EB"Name"` | the buff is not active (`!EB` when it is) |
| `ES"Name"` | the spell effect is not active |
| `EC"Name"` | the cooldown is not active |
| `ED"Name"` | the debuff is not active |
| a buff word | the named effect is **not** up, so the line that raises it runs once and then stops (`!` skips while it is up): barrage, celerity or 506, coupdegrace, flurry, fury, garrote, holler, momentum, pummel, rapid, rebuke, scourge, shout, tailwind, thrash, vigor, yowlp, animate |

### Words about us and the room

| Word | Skips when |
|---|---|
| `burst`, `surge` | the Enhancive buff is up (with `!`, when the cooldown is active) |
| `bearhug` | an Enh. Strength buff is not up |
| `voidweaver` | no Voidweaver buff |
| `disease`, `poison`, `hidden` | we are not diseased, poisoned, hidden |
| `outside` | the room is not outside |
| `splashy` | the room is tagged splashy |
| `pcs` | no other players in the room outside our group |
| `justice` | Swift Justice is not ready |
| `reflex` | Arcane Reflex is not ready |
| `once` | the line already ran once on this target |
| `room` | the line already ran in this room |
| `tier1`, `tier2`, `tier3` | the unarmed tier is not that one |

### Words about the target

Read from Lich's CreatureInstance, never from the status string:

| Word | Skips when |
|---|---|
| `prone` | the target is not down (sleeping, webbed, stunned, kneeling, sitting, prone, immobilized) |
| `frozen` | the target is not immobilized |
| `rooted` | the target is not rooted |
| `flying` | the target is not flying |
| `calm`, `disoriented`, `hovering`, `immobilized`, `kneeling`, `sitting`, `sleeping`, `stunned`, `webbed` | the target does not have that status |
| `ascended`, `ascension_boss`, `challenging`, `disengaged`, `inferior`, `mini_boss`, `mount`, `rider`, `sympathetic` | the target does not carry that flag |
| `undead`, `noncorporeal` | the target is not that type |
| `ancient` | the name is not grizzled or ancient |
| `wounded` | the target is above 25 percent health |
| `fatalcrit`, `smote` | the target has not taken one |
| `ucsdecent`, `ucsgood`, `ucsexcellent`, `ucstierup` | unarmed position words |

With `!` each of these means the opposite: `!prone` skips when the
target is down.

## What a line returns

Every line is an action and returns a result: success, skipped, or
failed with a reason (`:blocked`, `:no_mana`, `:fizzled`, the refusal
the game gave). A `:blocked` result marks the room as one where combat
is refused and Wander leaves it. Failed results count toward the
watchdog; skipped ones do not.

A line is skipped for either of two reasons: a modifier vetoed it, or
the action's own gate refused before sending. The gates cover the
states a hunter is in all the time, so they must not accumulate: being
stunned or webbed (`:muckled`), a technique still cooling
(`:cooldown`), too little stamina or mana to pay for it
(`:unaffordable`), the target dying while roundtime ran
(`:target_gone`). None of those put a command on the wire, so none of
them is evidence that the engine's model of the world is wrong, which
is what the watchdog exists to catch.
