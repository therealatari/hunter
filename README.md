# eohunter

> **Development prototype — not ready for formal review or merge.**
> This branch is shared for visibility and discussion, not production release.
> Interfaces, profile format and area data may still change.
> See [prototype status and open work](docs/setup-implementation-status.md).

A hunting script for Gemstone IV on Lich 5, built as an engine of small
behaviors rather than one long loop. It reads bigshot profiles unchanged,
so an existing profile runs here without edits, and it folds ecleanse in
as one of its behaviors.

## Running it

The development browser editor is available through `;eohunter setup`.
See [Browser setup](docs/guides/setup.md) for installation, native profile
storage, compatibility behavior and current preview limitations. It never
starts a hunt or edits Bigshot/ecleanse files.

```
;eohunter setup                        open the local browser editor
;eohunter <profile>                    hunt with a native profile, falling back to bigshot_profiles
;eohunter <profile> dry                load the profile, report the policies, do not run
;eohunter <profile> bandits            hunt bandits (also on in bounty mode when the bounty says so)
;eohunter <profile> track <creature>   Rangers: TRACK toward the creature before each step
;eohunter <profile> head <count>       lead a group: wait for <count> followers, then hunt
;eohunter <profile> head <name> ...    lead a group of these characters
;eohunter <profile> tail [uri]         follow a leader (the rally whisper names the uri)
;eohunter bounty [<creature>]          ebounty's hunt child, in place of "bigshot bounty"
```

`scripts/eohunter.lic` needs a Lich with the nine open lich-5 pull
requests it consumes (#1578 Stance, #1579 Stash, #1580 Mana.pulse, #1581
Bank, #1583 the PSM readers, #1584 Fog, #1585 the spell refresh, #1586
Combat::Messages, #1587 bounded fput). Until they merge that is the
eohunter test package at github.com/Nisugi/lich-5/releases: Lich 5.20.1
with the nine merged, the script, and an effect-list that marks Briar
Betrayer refreshable. The script refuses to start on a Lich without them.
Cleanse accepts Hunter-owned `recovery` settings, with read-only fallback to
`data/<game>/<char>/ecleanse.yaml`, which ecleanse's own setup window writes.
A profile's `troubadours_rally`, `signs` entries such as
`650 panther evoke`, and `quick_commands` (used by bandit mode) all work
as they do in bigshot.

Bandit mode narrows the target list to the bandit nouns on the quick
routine (list a when there are no quick commands), never switches
target, and does not flee past `always_flee_from`. It is also switched on
by a bounty that says "suppress bandit activity"; bounty completion is
still ebounty's job, which runs alongside.

Group hunting is bigshot's head and tail. The leader groups everyone in
the game, runs `head` with the follower count or their names, and
whispers a rally address to the group; each follower runs `tail` and
joins. The leader's profile decides the rooms, the looter (`ma_looter`,
`never_loot`, `random_loot`), `quiet_followers`, `independent_travel`,
`independent_return`, `group_deader`, and `group_fried_trigger`; each follower's own profile
decides its routines, prep commands and scripts. A follower that stops
answering is reported and no longer waited for; a follower whose leader
stops answering stops. Before each between-room move, the leader orders
followers to stand down and waits for every live follower to leave
roundtime and acknowledge readiness. A split follower continuously
refreshes the leader's room, travels back, and rejoins automatically.
`group_fried_trigger` defaults to `any`, so any live member reaching
their own configured `fried` threshold brings the group home. Set it to
`all` to wait for every live member, or give one or more names such as
`Testfollower` or `Testfollower, Testleader`. Named matching is case-insensitive.
Non-mind rest reasons still return immediately regardless of this setting.

The `deader` setting stops for dead players during the hunting phase. Unrelated
corpses do not stop preparation, travel to/from the hunt, or resting; this lets
a hunter depart from a town square where players are being raised. The separate
`group_deader` setting still stops the leader for a dead group member during
those phases.

## LAB-controlled trial campaigns

EO Hunter has an opt-in native controller for
[Lich Agent Bridge](https://github.com/elanthia-online/lich-agent-bridge). It is
not a second combat engine and it is not enabled by ordinary `;eohunter`
commands. LAB admits an exact, time-bounded launch from a player-reviewed safe
refuge; EO Hunter continues to own travel, target selection, combat, looting,
equipment handling, and return through its existing behaviors.

A campaign selects one existing profile routine per creature—for example,
`a-b-c` tries routine `a` on the first selected creature, `b` on the next, and
`c` on the third. The native runtime records creature/action/resource evidence
at game speed and returns before LAB or its model interprets the results. It
admits at most five creatures, 12 routine actions and 45 seconds per creature.
Target loss or a limit ends the experiment and starts safe return; successful
completion performs the profile's native final loot pass first.

Controlled profiles must have an exact resting room, a hunting room and
boundaries, and must use native commands/looting. Profile child scripts,
logout-on-death, and depart-on-death are refused. Terminal success requires the
same session, survival, a stable monster-free refuge, original hand identities,
and exact owner/child cleanup. Loss of action authority fails closed and sends
no more commands, including return travel.

LAB's public controller registry remains empty. Real character profiles and the
allowed trial sequences are private player configuration; see LAB's synthetic
controller example for registration and operation commands. Direct callers
should not construct the private supervisor flags.

Creature evidence comes from Lich's existing CreatureInstance records; unknown
records remain unknown. Reported resource changes are observed deltas, which may
include regeneration or outside effects, rather than guaranteed spell costs.
Refuge verification checks visible and hidden creatures, stable room identity,
survival, equipment, and owned-child release. A watchdog stop attempts the
existing Rest return under the remaining lease; loss of authority cannot do so.

The controller requires Lich's execution guards and exact child lifecycle in
addition to the normal Hunter dependencies. The rebased implementation is
verified offline; renewed live acceptance against this combination is pending.

Optional cross-process mechanics live in the on-demand
[`libeocoordination`](docs/guides/coordination-library.md) script library rather
than Lich core. Lich owns parser-coherent facts and script execution; the
library owns bounded transport, discovery, operation delivery, and receipts.

## How it works

Each tick, about four times a second, the engine asks every behavior in
priority order whether it wants control, and the most urgent one gets to
run one action. An action is a game command with its preconditions, its
roundtime wait, its send through bigshot's refusal ladder, and its
confirmation on the game's answer, returning a result the caller must
handle. Nothing sends a command and hopes.

Combat routines may use `allycast SPELL NAME` to cast a support spell
on a named player who is both present and in the character's current
game group. A missing ally skips the line without sending a command or
counting as a failed action. Add `(afterattack)` when the spell should
run once initially and then re-arm only after that named ally makes an
observed attack; each allycast line has an independent latch.

| Priority | Behavior | From bigshot / ecleanse |
|---|---|---|
| 0 | Survival | dead, escape rooms, stand, pull, dead players and dead group members |
| 5 | Cleanse | all of ecleanse: afflictions, hazards, disarm recovery, hive traps; Troubadour's Rally for us and the group |
| 10 | Flee | `should_flee?` and the ambusher, one step out per tick |
| 15 | Muster | the leader's holds between fights: a stunned member, a missing follower |
| 20 | Rest / Orders | `ready_to_rest?` with the group's reasons, the final loot, the rest cycle with every follower wait, `ready_to_hunt?`; a follower runs the leader's orders instead |
| 30 | Loot | `need_to_loot?`, the looter, the loot script, the fried bookkeeping |
| 35 | Loadout | restore optional profile-defined hunting hands through Lich::Stash after temporary hand users finish |
| 40 | Maintain | signs including Assume Aspect, bless, wrack |
| 50 | Engage / Assist | the routine language, one line per tick, every command check; a follower takes the leader's target first |
| 60 | Wander / Follow | the hunting area, the claim, hidden creatures, Ranger tracking, one step per tick; a follower goes back to the leader and joins |

Control changes hands between ticks, and a behavior that loses it has
its trip suspended: the go2 script is killed and started again from
wherever we are when the behavior gets control back, so Flee or Cleanse
never issue commands while go2 is still walking.

The parts live in `scripts/eohunter/`, one file each, loaded in order by
`engine.rb`:

- `events.rb`, `world.rb`, `behavior.rb`, `runner.rb`: the control model.
  An event bus, a read-only facade over Lich's game state, the behavior
  contract, the tick loop with its watchdog.
- `loadout.rb`: the optional between-fight right/left-hand policy. It
  compares live state without sending, then delegates one complete
  reconciliation to Lich's Stash API.
- `actions.rb`, `combat.rb`, `maneuvers.rb`, `routines.rb`: the actions.
  fput's bounded ladder and the three confirmation shapes; attack and cast;
  maneuvers on Lich's PSM readers and mstrike; the rest of bigshot's
  routine vocabulary.
- `targets.rb`, `flee.rb`, `rest.rb`, `loot.rb`, `maintain.rb`,
  `survival.rb`, `engage.rb`, `wander.rb`, `cleanse.rb`: the behaviors,
  each with its policy and its predicates.
- `tracking.rb`: bandit mode and Ranger tracking, the policy and the
  three actions Wander uses.
- `group.rb`: the group. A Hub the leader serves over DRb, the leader's
  view of it, the follower's bounded link, and the follower's three
  behaviors (Orders, Assist, Follow) plus the leader's Muster.
- `watch.rb`: the subscription to Lich's parser seam (Combat::Messages,
  the UCS facts, the attack events), each fact renamed onto the bus the
  way the behaviors hear it; a hook only for the profile's own flee text.
- `travel.rb`: the go2 script supervised a tick at a time, with one
  trip owning go2 and suspension on preemption.
- `profile.rb`: a bigshot profile YAML into the behaviors' policies.
- `controller.rb`: exact-session LAB supervision, bounded profile-routine
  trials, structured evidence, and verified refuge/equipment handoff.

Every rule was read from bigshot 5.16 and ecleanse 2.3.6 with the line
references written into `docs/hunting-engine-plan.md`, one section per
step of the build. When the engine and bigshot disagree, that document
says which line of bigshot the engine is following and why.

## Tests

The engine loads outside Lich, so the specs run without a game:

```
bundle install
bundle exec rspec
bundle exec rubocop
```

Each spec fakes the world with plain structs and stubs the send seams, so
a test says what the game answered and checks what the engine sent.

Bounties are ebounty's. It stays the driver for every bounty type and
runs eohunter as the hunt child where it ran bigshot: `;eohunter bounty`
reads the profile ebounty loaded, evaluates ebounty's completion rule,
rests when it says done, and exits at the resting room for ebounty to
carry on. In a group the leader's child ends the hunt when every member
is done, or at once when one stops answering.

## API documentation

The engine's YARD docs are published from `main` to
https://nisugi.github.io/hunter/ by the `docs` workflow. To build them
locally:

```
bundle exec rake doc          # writes doc/, open doc/index.html
bundle exec rake doc:stats    # coverage, listing what is undocumented
```

`.yardopts` names the sources: the script, the engine parts, the
builder, the guides below and the three documents under `docs/` as
extra pages. `doc/` and `.yardoc/` are not committed. A `@bigshot` tag
on a method or class names the bigshot rule it came from, with the
line reference.

## Guides

- [Getting started](docs/guides/getting-started.md): install, the dry run, the modes, how it stops
- [Profiles](docs/guides/profiles.md): every bigshot profile key the engine honours, its type, default and reader
- [Combat buff policy](docs/guides/combat-buffs.md): opt-in native restoration, safe recovery, and verified departure requirements
- [Multi-account group startup](docs/guides/multi-account-group.md): opt-in followers, one-command party startup, local supervision, and safe return
- [The routine language](docs/guides/routines.md): the words, the spell syntax, the maneuvers, every modifier
- [Architecture](docs/guides/architecture.md): the pieces, the tick, actions, World, events, travel, groups, the watchdogs
- [Extending the engine](docs/guides/extending.md): adding an action, a routine word, a behavior, a World reader
- [Troubleshooting](docs/guides/troubleshooting.md): the lines, the stops, common causes, what to report
- [Contributing](docs/guides/contributing.md): the flow, the conventions, review
- [Core dependencies](docs/guides/core-dependencies.md): the lich-5 PRs, what each provides, the test package

## Building the single-file scripts

The engine is developed and tested as parts under `scripts/eohunter/`,
but Lich's installers cannot place a directory: `;repo` fetches one
script file and jinx installs assets flat. So distribution uses an
`eohunter.lic` with the engine parts inlined and a self-contained
`libeocoordination.lic` with the coordination parts inlined:

```
bundle exec rake build      # writes both .lic files and their line maps
```

The EOHunter builder (`tools/build.rb`) takes `scripts/eohunter.lic`, replaces its
one `load` line with `engine.rb` and every part in `PARTS` order, each
behind a `# ==== eohunter/<part>.rb ====` marker, and turns `load_parts`
into a no-op. `EO::Engine::BUILT_FROM` records the commit. The map lists
each part's first and last line in the built file, so a line number in
a Lich error traces back to the part. `dist/` is not committed; the
parts stay the source of truth and the specs never load the built file.
`tools/build_coordination.rb` similarly inlines `scripts/eocoordination/*.rb`
in dependency order and removes only their internal `require_relative` lines;
the built library retains its inert load behavior and public version check.

CI builds both files on every push and keeps them as a workflow artifact. A tag
`v<version>` matching `EO::Engine::VERSION` builds them again, runs the
specs, and attaches both scripts and maps to a GitHub release of that
tag. Where the built files go from there, the scripts repo for
`;repo` and the standard jinx manifest or a manifest of this repo's own,
is not decided yet.

Editing `dist/eohunter.lic` in place is the one thing not to do: the
next build overwrites it. Edit the part and rebuild.

## What is not there yet

ebounty's side of the above: the setting to run eohunter instead of
bigshot, and group bounties with follower town phases. A routine word
outside the table is sent bare, as bigshot sends it.

## In-game runs so far

Solo on a Ranger profile, 2026-09-10: the routine language, hides and
fires, coup de grace with its health and Empowered gates, Assume Aspect
from the signs box, rests to the resting room and back, and the go2
supervision. Bandit mode, Ranger tracking and group hunting have not had
a live run yet.
