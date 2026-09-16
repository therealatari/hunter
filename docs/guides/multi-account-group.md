# Multi-account group startup

This experimental, opt-in feature starts an approved party from one character:

```text
;eohunter Leveling-Trio group
```

Each character keeps its own Lich process and local profile. A persistent
`eohunter-ma-group.lic` receiver handles startup and supervises that character's
hunter. LAB and a particular frontend are not required.

## Installation and dependencies

Build the complete optional package with `bundle exec rake build:group`. Install
these four files from `dist/` into Lich's scripts directory:

- `eohunter.lic`
- `eohunter-ma-group.lic`
- `libeohuntergroup.lic`
- `libeocoordination.lic`

The source checkout keeps the libraries in folders for development. The built
files contain their source parts and work with flat script installers. Keep the
`.map` files when reporting a generated-script line number.

The required native capabilities include ActiveSessions discovery, supervised
Script children and parser hooks with priority support. Library loading alone
does not enable a receiver. The plain version string `5.21.0` does not establish
that all required capabilities are present.

On GemStone, the passive parser projection also respects Lich's existing
`Claim::Lock` while a room arrival is being assembled. A fully parsed network
line is not necessarily a complete room/player list. During that interval
state remains unknown and follow/movement decisions wait for native arrival
completion; no fixed sleep substitutes for it. Changing a loaded library
requires a clean session restart for the new code to take effect.

Native ActiveSessions must be enabled **before login**, using the supported
`--active-session-dir=PATH` launch option or the native `active_sessions_api`
feature flag. Enabling the flag after login permits API calls but does not start
the native lifecycle/heartbeat that was skipped at boot. Relog those sessions;
do not manufacture connected records in the group library. Receivers should
discover native session names, game instances and connected state before launch.

At the time of implementation, development used the integrated Lich revision
`4ccdfb7dbeade96d73e2680e8a8e27c86c924f57`, including the existing discovery
cleanup work in [Lich #1612](https://github.com/elanthia-online/lich-5/pull/1612)
and hook-priority work in [Lich #1621](https://github.com/elanthia-online/lich-5/pull/1621).
The coordination-library and consumer branches are separate dependencies.
This is a tested-development-baseline statement, not a released-version claim.

## Participation and profiles

Allowing automatic startup is a character preference. It is not inherited by
downloading or selecting a hunting profile. The receiver reads that preference
from the fixed `eohunter` settings namespace using the native character scope.

For each allowed leader and group, the character chooses a local profile,
refuge and whether joining at the rally is allowed. An allowed leader cannot
send an arbitrary script, Ruby expression, command sequence or profile path.
The local profile contains the character's existing combat and equipment
configuration.

The leader profile uses `group_members` for its explicit roster. Existing
`resting_room_id`, group fried policy, loot assignments and combat routines
retain their meanings. There is no separate `striker` role configuration.

To share kills between learners, set `group_fried_trigger: all` on the leader
and give each learner a nonattacking routine using the existing profile key:

```yaml
fried: 100
hunting_commands: attack target
disable_commands: stance defensive, sleep 1 nostance
```

When that character reaches its own `fried` threshold, it uses
`disable_commands` while continuing to follow and obey loot/movement orders.
The routine is re-evaluated between actions, even on the same target; an action
already sent is not cancelled. If experience drains below the threshold, normal
attacks resume to keep the learner topped up. This is current-state behavior,
not a permanent "was fried once" latch. Empty `disable_commands` preserves the
existing attack behavior. Safety and resource return reasons still override
the all-fried experience rule. A support-only leader can use `fried: 0` to
satisfy its own part of the all-members rule without needing experience.

All required members must already be at the common safe refuge. An opted-in,
ungrouped member may join the leader there if its local mapping permits it.
A member already in a conflicting party is refused. Rendezvous from distant
rooms is not included.

Existing solo and manual `head` / `tail` commands remain available. An unrelated
active hunter or travel owner makes the character busy; automatic startup
must not take over that work.

### One-time local setup

For example, on each follower (substitute the exact game instance and that
character's existing local profile):

```text
;eohunter-ma-group allow Testleader GSIV Leveling-Trio Group-Follower 324 join
;force eohunter-ma-group enable
;force eohunter-ma-group status
```

`allow` takes **leader, game, leader's group/profile name, local profile name,
refuge room ID**, and optional `join`. Without `join`, the character must already
be in the correct physical party. `enable` saves participation and installs the
receiver in that character's existing autostart configuration. This example
does not create or replace a hunting profile. Names must match the actual
character, instance, and profile; quote profile names containing spaces.

Once the receiver is running, use Lich's `;force eohunter-ma-group <command>`
form for subsequent local controls. Lich normally rejects a duplicate script
before its body runs. The forced invocation only queues its command into the
existing receiver and exits; the library mutex keeps a single runtime/owner.
This does not force hunter admission or bypass readiness checks.

On the leader, put the exact required followers in the existing profile's
`group_members`, set its `resting_room_id` to the same refuge, and run:

```text
;eohunter Leveling-Trio group
```

The leader command starts its receiver if necessary. There is no need to start
three hunters manually. `;eohunter-ma-group start Leveling-Trio` is the equivalent
local receiver control.

If passive tools such as LAB are intentionally running, approve their exact
script names locally, for example:

```text
;force eohunter-ma-group background lab lab-bridge
```

This **replaces** the background approval list; `background` with no names
clears it. It does not make those scripts harmless or grant them permission to
compete for movement or equipment. Keep LAB from issuing conflicting game
commands during an outing. Unknown active scripts still block startup.

## Startup and readiness

The leader's local supervisor publishes an exact startup intent. Each permitted
follower supplies a grant for that leader/run through a private local
credential exchange. Discovery contains only token-free metadata. The intended
trust model is cooperating processes on one host under the same OS user.

Startup has two barriers:

1. Every local hunter finishes preparation and reports current readiness.
2. Every local hunter acknowledges commitment to that same run.

Only then is hunting released. Registration with the group hub is not evidence
that preparation finished. Roundtime, restraints, equipment and cleanup are
checked locally; a later state change can withdraw readiness. The existing
strict movement mechanism continues to check hunting-room departures.

The local supervisor uses exact native child handles and waits for their
teardown. It never substitutes a script with the same name for the child it
actually started. Repeated transport requests retain their request identities.

## Stopping and recovery

A cooperative stop closes hunting admission, allows necessary owned hand/loot
cleanup, and uses existing recovery/travel actions to return. Each character
has a local recovery path even if the leader's endpoint becomes unavailable.
Native survival behavior can override normal cleanup waiting in an emergency.

Arrival alone is insufficient. A successful local handoff also needs appropriate
equipment and completed child cleanup. A failed or unreachable member is
reported as unresolved. Killing a Lich process cannot make its character
return; surviving peers must not claim that it did.

An unresolved-run record prevents automatic restart after an unconfirmed
handoff. Operator reconciliation must check the character's current state;
removing a file is not proof of safe recovery. Prefer the cooperative receiver
controls over force-killing the hunter or its supervisor.

Disabling participation prevents new automatic starts. Accepted recovery is
still owned locally until it completes or is explicitly reported unresolved.

```text
;force eohunter-ma-group status
;force eohunter-ma-group stop
;force eohunter-ma-group disable
```

Use `stop` on the leader for a party-wide cooperative return. A follower's local
`stop` starts its own return; the leader then observes that member withdrawing
and returns the remaining group. `disable` removes the receiver's autostart
entry and closes new admission; it does not silently abandon accepted work.

After a receiver/process restart, `;eohunter-ma-group recover Group-Follower`
can attempt only the unresolved run's pinned local profile. Recovery requires
the saved profile snapshot and original hand evidence, followed by fresh local
safety checks and native teardown. Missing or invalid evidence leaves the run
unresolved for manual reconciliation; it is not an invitation to guess the
previous equipment. The private journal is stored under
`DATA_DIR/eohunter-group-private`, separately from ordinary hunting profiles.

## Current scope

- One host, one shared local Lich installation, explicitly named participants.
- A common safe rally/refuge; no automatic cross-area gathering.
- The current supported group profiles. Existing refusals for grouped
  Field/Town Rest and grouped combat-buff policies still apply.
- Hunting-room readiness is not a guarantee that every go2 special transition
  or emergency movement moves the party atomically.
- CLI settings first. A future setup GUI must call the same settings and
  control interfaces and explain every field with a tooltip.

## Verification

Use `bundle exec rspec` for the complete suite and `bundle exec rake build:group`
for the distributable package. The multi-account workflow runs portable
contract tests and artifact checks on Linux and Windows. A workflow file alone
does not establish a successful Windows run.

Live acceptance begins and ends at a designated safe refuge. It covers a full
startup, busy/missing members, delayed RT and cleanup, ordinary rest cycling,
cooperative stop, and controlled peer loss. If a live test fails, initiate
recovery immediately and confirm each available character before investigating.
