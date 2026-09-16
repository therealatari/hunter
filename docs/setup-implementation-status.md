# Browser setup implementation status

**WORK IN PROGRESS / DISCUSSION PROTOTYPE. Not ready for formal review or merge.**
This is a shareable development snapshot for the EO/Hunter team to try and
discuss. It is not a completed implementation or a request for approval.
The MA startup prerequisite is kept in a separate commit from browser setup;
before promoting this draft, settle that dependency and split runtime changes
such as `untildead` into the agreed review scope. No reviewers are requested.

Development preview, 2026-09-16. Branch: `feat/web-setup`.
Baseline: `Nisugi/hunter` main at
`c964f0995bb05739fe122f1e0699316b7ced9219`.

This is the first integrated implementation of the revision-2 setup proposal,
not a claim that every proposed workflow is complete. No production profiles
were changed and no game commands were sent during implementation. An initial
standalone editor was installed for user feedback; the installed custom hunter
was deliberately retained because it includes local group functionality absent
from this branch. That describes the initial prototype stage; later integration
is published as draft PR #117. The verification entries below distinguish
local follow-ups from installed builds.

## Implemented

- A local browser editor launched through `;eohunter setup`, with bundled
  assets, searchable sidebar, contextual help and a guided path sharing one
  draft with the normal editor. No GTK, remote CDN or player Node dependency.
- Native-only profile/default/Combat Plan storage, read-only Bigshot import,
  unknown-key preservation, explicit inheritance and routine resolution,
  optimistic revision checks and atomic file replacement.
- Native launch support for the new profiles, including read-only recovery
  compatibility fallback and explicit Hunter-owned recovery preferences.
- Creature/area selection from native templates and map data, directed
  perimeter computation, missing-map/ambiguous/opaque-edge diagnostics,
  hunt/ignore/flee choices and deliberately unverified area suggestions.
- Creature-filtered room unions, explicit section/room narrowing and recomputed
  perimeter approval. Region names are not treated as verified subzones.
- A general map → hunting area → creatures picker, using native map labels and
  habitats plus explicit UID-based subdivisions where necessary. The Rift has
  named planes and The Scatter, with shared creatures kept inside the selected
  plane. Other complex-area subdivisions remain an evidence-gathering task.
- Persistent profile-map editing for start, individual boundaries, town rest
  and field rest, preserving existing routes independently of creature proposals.
  Click/keyboard controls, undo, other map sheets, search and zoom share the draft.
  Uses installed classic map artwork with native-coordinate highlight overlays.
  Missing images/coordinates are explicitly reported; room lists remain usable,
  with no generated diagram substituted.
- Native policy validation and provenance/effective-settings review, plus
  narrowly scoped advisory hazard checks. No claim of complete hazard coverage.
- Loopback-only, token-protected transport with exact Host/Origin checks and
  configuration-only operations. No command execution endpoint.
- Standalone setup-script packaging, active-engine coexistence checks,
  Ruby specs and browser regressions against both fake responses and the real
  Ruby backend with temporary fixture data.

## September 16 action, rest-map and buffs polish

The source build now includes spell-delivery/ranged/stealth/stance action
controls, native opt-in `untildead` support, an independent classic-map rest
picker, learned society-upkeep checkboxes using native readers, and guided
injury-return presets with adjustable thresholds and native action checks. No live
deployment was performed during the user's ongoing editor walkthrough.

Pre-reconciliation verification: 1,323 Ruby examples, zero failures, 34 pending;
35/35 real-backend browser checks; mock browser regressions and four responsive
layout checks; routine/injury codec tests; 30 setup/touched files clean under RuboCop.
Hunter and setup builds pass. Live society metadata and a bounded combat trial
remain to be checked after deploying both packages into a fresh session.

## September 16 MA compatibility reconciliation

The initial setup candidate would have dropped the locally installed MA
startup integration. Reconciled the existing `99e7966` startup patch onto this
checkout, retaining setup work and the upstream coordination changes already
in `c964f09`. The installed older MA library and managed module matched the
local startup sources; this was reuse, not a second startup implementation.

Both startup paths now share native/legacy profile selection and composition.
Managed recovery pins resolved input, and the GUI exposes the leader roster
without enabling follower participation. The build/release output includes
the receiver and group library alongside Hunter, setup and coordination.

Final combined verification: **1,422 examples, zero failures, one pending**
with installed native Lich readers/guards and coordination integration enabled.
The pending case requires actual Windows PowerShell/NTFS ACLs. Separate-process
MA contracts ran; this was not a live hunt. **35/35 browser checks passed**.
All five distributable scripts passed Ruby syntax checks. Focused lint:
11 files, no offenses. No remote Windows CI result is claimed.

Installed all five artifacts and available source maps after backup to
`Lich5/backup/eohunter-setup-ma-20260916-F8efXE`, with byte-for-byte verification
against `dist`. No character configuration, enrollment or game state changed.
Fresh-session GUI and bounded live MA smoke testing remain outstanding.
Those locally installed bundles were built from an uncommitted integration;
their base SHA alone does not identify the combined source. The local deployment
record, not included in this repository, retains the artifact hashes.

## September 16 guided feature-gap follow-up (local, not deployed)

Added guided controls over existing runtime settings: native boon responses,
UAC/MSTRIKE and wand fallback, named return methods, ordered preparation/rest
lists, alternative combat sequences, specialized action builders and named-buff
conditions. Team settings are grouped by purpose and notes are editor metadata.
Imported custom values remain available without silently rewriting them.
See the [coverage and limitations](guides/setup.md#guided-configuration-coverage-update).

Verification: **1,427 Ruby examples, zero failures, one Windows-only pending**;
**42/42 offline real-backend browser checks**; routine/settings codec assertions;
five distributable builds; focused Ruby lint and whitespace checks. Browser
screenshots were inspected. Tests use temporary profiles, not live characters.
The locked Bundler dependencies are unavailable on this machine, so these checks
used the installed Ruby 4.0.5 tooling, not a fresh lockfile install.

This follow-up does not change combat execution. Interaction alerts, ambiguous
`buffN` duration semantics and remaining custom compound-condition editors are
not claimed as complete. No live installation, game commands or live profile
changes are part of this follow-up.

## Earlier verification completed locally

Guided region preview follow-up: a sticky right-hand classic-map preview now
appears as soon as a map is selected. Hunting-area selection highlights only
its proposed rooms without applying profile geometry. Narrow screens stack
the preview above controls. Reuses the existing profile-map and image readers;
delayed responses cannot resurrect detached views. Browser suite: 37/37 passed,
including selection/clearing, desktop/mobile placement, unchanged draft
geometry and stale-region response rejection. Fixture screenshot inspected.

Legacy-key follow-up: the GUI rejected valid integer spell IDs under
`combat_buffs.spells`. Store now normalizes integer keys to JSON strings,
retaining duplicate-key detection and rejecting boolean/compound keys.
All 16 Calvix legacy profiles passed read-only import reads. Full native-enabled
suite: 1,425 examples, zero failures, one Windows-only pending. The three
affected bundles and maps were backed up and updated on disk; fresh login is
required because the stable shared Store class remains loaded in existing
sessions. No legacy profiles were modified.

- Full Ruby suite: **1,281 examples, 0 failures, 34 pending**. The pending
  cases are opt-in native integration tests; they are not claimed as passes.
- RuboCop: **137 files, no offenses**.
- All three distributable scripts build: hunter, setup and coordination.
- YARD: **100% documented**, with a pre-existing unknown `@ecleanse` tag
  warning and the Ruby 4 IRB dependency warning.
- Focused browser regressions passed: unknown/custom values, search,
  invalid drafts, shared wizard state, target policy, geometry guards,
  inheritance, response races and token transport.
- Real-backend browser acceptance: **14 checks passed**, covering save/reopen,
  inherited values, explicit geometry selection, delayed reads and delayed
  saves, the complete five-chapter guided flow, and empty-target/shared-plan
  presentation, deliberate inherited-sequence overrides and stale area-preview
  rejection, creature-footprint map clicks and persistent profile-map edits
  across start/boundary/both rest sites, stale profile-map responses and stale
  creature-footprint responses, classic image/overlay scaling, and missing-image
  fallback to the room list, and map-first named-plane selection with a shared
  creature confined to that plane. All fixture writes were isolated from character data.
- Offline visual inspection against the installed Mine Road map confirms the
  original artwork and native rectangles align. This is not an in-game route test.
- Read-only Rift map checks resolve all six named memberships. Plane 5 has 14
  recorded UIDs but only 13 rooms reachable from 12208 in the static native area
  builder, with no spill into another plane. The unmapped one-way room remains
  visible for review. See [evidence and limitations](setup-area-zones.md).
- Field Journal layout checks pass for desktop and mobile: fixed header/sidebar,
  independently scrolling form/navigation, search focus and overlay navigation.

## Field Journal usability revision

The selected concept B is now the actual editor theme, not just a mockup.
Guided mode has five sidebar chapters instead of showing the full advanced
menu and a second row of steps. Basic command sequences have ordered rows;
custom routines keep their original text. Missing prerequisites are separated
from malformed configurations, with links to the relevant settings. Area
selection auto-loads and previews, but applying geometry remains explicit.

The first-hunt path is browser-tested, not a substitute for fresh-user usability
testing. Verified safe destinations and richer structured
policy editors remain unfinished. Group/Team terminology explains ownership
without pretending this editor performs enrollment or launches other accounts.

Local verification used Ruby 4.0.5 on Linux and headless Brave with Playwright
1.63.0. Existing CI targets Ruby 3.4. Browser and Windows setup checks have been
added to CI configuration, but their remote results are not yet available.

## Still required before calling the proposal complete

1. Replace advanced JSON controls with specialist visual editors for structured
   policies, ordered routines, equipment rules, item upkeep and group setup.
   The current engine settings remain accessible, but accessibility is not the
   same as the proposed polished non-programmer workflow.
2. Complete richer shared-plan impact/compare workflows, an explicit flattened
   independent-copy operation and multi-character enrollment UX. Saving another
   profile currently retains its shared links and says so.
3. Verify the browser launch and editor lifecycle in actual Lich frontends,
   including Windows/macOS. The current adapter is a standalone browser,
   not an embedded Vellum WebUI integration.
4. Field-check suggested area footprints and routes against actual game data.
   Weak map connectivity is not proof of directed reachability, traversable
   exits, creature safety or safe rest destinations. No field verification has
   been performed here.
5. Implement the separately scoped engine changes for configurable dispel
   recovery timing and MANA SPELLUP thresholds. This editor exposes existing
   policies; it does not pretend that new runtime behavior already exists.

Follow the [setup guide](guides/setup.md) for build and offline preview steps.
Before any live trial, agree on a safe start/end location, deliberately install
the test build and confirm that the character is not hunting. Saving in this
editor never authorizes or starts that trial.
