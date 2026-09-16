# Browser setup (development preview)

In guided Area & creatures, selecting a map/region immediately shows its
classic map in a right-hand preview. Selecting a hunting area highlights the
proposed rooms in green; switching or clearing it removes the old highlight.
The preview stays beside the controls while scrolling and stacks above them
on narrower screens. Browsing never applies geometry; use the room editor and
Apply controls to change the draft, then Save to persist it.

The combined build preserves the optional multi-account receiver and
`;eohunter <profile> group` entry point. Ordinary and managed launches share
native-profile selection and composition: `eohunter/profiles` takes precedence,
with `bigshot_profiles` as read-only compatibility input. A broken native
profile is an error, not permission to launch an older namesake. Recovery pins
resolved raw settings rather than re-reading editable defaults or combat plans.
The Required multi-account followers field edits the leader roster only;
follower participation and leader approval remain separate local decisions.
See [multi-account startup](multi-account-group.md). Setup never starts a hunt.

Run `;eohunter setup` or `;eohunter-setup`. Setup asks your default browser to
open automatically (Linux `xdg-open`, macOS `open`, or Lich's Windows
`ShellExecute`). Open the local URL printed in the game window if no tab
appears; headless sessions or missing desktop associations may require this.
Stop the editor
with `;kill eohunter-setup`. Closing the browser does not stop the listener.

This is a standalone browser editor, not a GTK window or a claimed native
Vellum WebUI integration. It uses WEBrick, already included in current Lich,
and bundled local assets. Players do not need Node, a web account or internet
access for the editor itself. The listener binds only to loopback and its
session token must not be shared. It is not a sandbox against malicious code
running under your own OS account.

## Editing a hunt

The default visual style is **Field Journal**: a parchment-colored working
surface and a muted green sidebar, with no downloaded fonts or artwork.
Choose **Create with guidance** for five chapters:

1. Your character: name the hunt, optionally link character defaults, and
   choose hand equipment. Solo Hunt, Group Hunt and Multi-Account Team are
   explained separately; selecting a context does not enroll or control peers.
2. Area & creatures: the catalog loads automatically. Choose the overall map,
   then a particular hunting area to preview its creatures. Choose what to hunt, then suggest their hunting
   rooms, narrow the footprint if needed, choose a starting room you have
   checked, and explicitly apply the proposal. Existing profiles also have a
   persistent map editor independent of these suggestions.
3. Combat approach: link a saved plan or add/reorder/remove basic attack and
   spell actions. Custom routine syntax stays intact in its original-text
   editor; the row editor does not attempt to reinterpret it.
4. Rest & recovery: choose destinations, return/resume thresholds and services.
   Advanced emergency and buff policies remain available in the full editor.
5. Review & save: check the effective settings. Missing information has links
   to its settings and is not presented as a successful readiness check.

**Advanced editor** switches to the full section list without copying or
resetting the draft. Search also takes you to the full editor when necessary.
Within Hunting behavior, everyday looting, target-priority and hazard choices
are visible in four named groups: Movement and stance, Choosing fights,
Looting, and When to leave a room. These sections are open by default; their
short descriptions distinguish room fleeing from returning to rest.
The custom flee-message pattern and obsolete box-in-hand
compatibility flag stay under Advanced settings even though they have help text.
Shared defaults and plans can be created from **Reusable settings & current
draft** on the profiles page. Plans open their command editor, not JSON.

Hunter interprets an empty target list as all eligible creatures. The editor
shows this explicitly and asks for a creature selection or acknowledgment;
it never claims an empty list means "hunt nothing." The acknowledgment is
an editor-session check, not a new runtime targeting mode. Drafts with missing
information can still be saved, but the save message marks them unfinished.

### Your profile on the map

The Area & creatures page shows existing profile geometry even without choosing
a creature habitat. Gold/S marks the start, red squares mark boundaries,
blue/T marks town or main rest, and purple/F marks nearby field rest. Multiple
roles retain their letter markers if they share a room. Green rooms show a
potential hunting footprint from the existing Hunter area builder, using only
recorded map links. Executable exits and live passability are **not** evaluated.
A capped preview is incomplete and explicitly warned about.

**Left-click always includes or excludes a room. Right-click opens room actions:**
Hunting room, Boundary room, Starting room, Field rest, and Town rest. Each role
has a checkbox showing whether it is active on that room. Select an active role
again to remove it. Removing field or town rest leaves hunting membership, the
start and the other rest role unchanged. Clearing the start requires choosing
another before applying a proposed area. In a proposed area, turning off a
calculated boundary includes that room in the hunt, so recalculation does not
silently bring the boundary back. A new start
replaces the previous start and removes a conflicting boundary. Existing-profile
room toggles recalculate the perimeter with native map geometry; edits that
disconnect the hunt are refused with an explanation. Move the start before
excluding it from an existing route. No click saves or moves a character.
**Undo map edit** restores the previous geometry. Broken or ambiguous room references block map
editing until corrected in the manual fields, rather than silently dropping
them. Untouched UID boundary references remain UIDs when another is toggled.

The display uses the **original illustrated maps installed in Lich's MAP_DIR**,
with translucent highlights over each room's native rectangle coordinates.
Original labels, paths and landmarks are preserved; no synthetic map or links
are drawn. Separate sheets show distant rest sites, and **Show another map
sheet** allows choosing a destination outside the current hunt. Zoom and scroll
larger maps; zoom/scroll survive room edits. Keyboard users can focus a room and
press Enter or Space to toggle it, or Shift+F10 for room actions. Escape closes
the menu without editing. The visible tools act on the last clicked or focused
room, and the searchable list also opens room actions when artwork is missing.
Rest markers are user choices, not verified safe rooms. Colored letter badges
remain separate when several roles share a room; the legend never relies on
color alone. Bounded near-box clicks help with small rooms at fit-to-width zoom.

Missing images or invalid coordinates produce a notice, never a made-up room
position. The searchable room-name/number list remains usable. Retry after
installing missing artwork through your normal map tools; this editor does not
download it. It reads only native-listed PNG/JPEG/GIF/WebP files inside MAP_DIR
through the authenticated API, with a size limit and no arbitrary file endpoint.

### Map, hunting area, then creatures

A named place is not necessarily one hunting zone. First select **Map / region**,
then **Hunting area**, then choose the creatures in that area. The Rift offers
Planes 1–5 and The Scatter; shared monsters do not pull another plane into your
selection. Simple places use the same controls with their native habitat names.
Other complex locations have editable draft subdivisions where native data is
too broad. Drafts show their source and limitations; they are not field-tested
or a promise of safe travel. Missing or unusual areas remain explicit gaps.
See [area data and verification gaps](../setup-area-zones.md).

Selecting a named area previews its geographical rooms, including connectors
where no creature is recorded. Choosing targets does not remove these rooms.
**Reset to suggested area rooms** discards your manual proposal edits and
restores that area's baseline. Legacy habitats without named subdivisions still
derive suggestions from their selected creatures.
Use disconnected-section buttons, a searchable room list, or map clicks to
include/exclude rooms, including explicit additions from the selected map.
**Recalculate** rebuilds the boundary around the remaining
selection. An excluded room becomes a boundary when it adjoins that selection;
an explicitly assigned Boundary room is retained too. Excluding a creature from
targeting does not forbid its rooms. Undo room selection restores the previous
room/start/rest proposal without saving it.

Choose the start and **Apply this hunting footprint** to copy geometry,
source metadata, and any explicitly selected rest spots into the draft.
Existing targets, routines and rest sites you did not edit are preserved.
Field/town rest spots can be outside the hunt; assigning them does not add those
rooms to hunting membership. Changing map or area replaces only the pending preview; changing
targets retains its geographical room selection. Neither changes your approved
route. Manual map edits clear habitat-approval provenance, since
the edited route is no longer the exact approved proposal. Disconnected or
incompletely mapped proposals cannot be automatically applied. Custom target
patterns remain untouched and are not guessed into habitat names.

Named-area map previews focus on the selected rooms using the original artwork.
**Show full classic map** restores context. A room missing artwork stays in the
room list. Rooms without a mapped entrance from the other selected rooms are
flagged for review rather than silently dropped or called reachable.

The sidebar and guided setup edit the same draft. Search accepts native keys
and familiar terms such as `fried`, `oom` and `ecleanse`. Common settings have
plain-language labels and help. Less common settings and structured policies
currently use advanced/raw controls; this preview is not the finished set of
specialist visual editors.

The header and draft controls stay anchored. The sidebar and editor content
scroll independently; choosing a page starts that page at the top without
moving the surrounding controls. On small screens navigation opens as an
overlay instead of pushing the form down.

Choose creatures from native data, then preview their rooms and perimeter.
Hunter boundaries
are rooms excluded from the hunt, not the allowed-room list. A start room and
rest destination are explicit choices. Incomplete or disconnected previews
cannot be automatically applied as a complete footprint. Native map coverage
does not prove safe traversal or a safe resting room.

Every suggestion is currently **data-derived, not field-checked**. Initial
hazard advice covers only the documented 719/713 Bowels interactions and 719
in wet Nelemar conditions. Other spells, custom scripts, equipment flares and
live conditions remain unchecked. No warning does not mean no hazard.

Saving never starts a hunt, sends a game command, or changes an active hunt's
captured settings. Missing information can remain in a draft, but malformed
native policies must be corrected. Review the effective configuration before
launching with `;eohunter <name> dry`, then deliberately start a hunt when ready.
This requires the matching native-profile-aware hunter build. An editor-only
preview installed beside an older hunter does not add launch support to it.

## Files and compatibility

The editor writes only beneath:

```text
data/<game>/<character>/eohunter/
  profiles/<name>.yaml
  defaults/<name>.yaml
  plans/<name>.yaml
```

Bigshot profiles remain readable from `bigshot_profiles`. Opening one in setup
and saving creates a Hunter-owned copy. The original file is not changed.
Native profiles take precedence over same-named Bigshot profiles on launch.
Rename a native copy if you want to keep launching its legacy namesake.

Native hunt documents have a versioned envelope:

```yaml
schema_version: 1
defaults: My usual setup
combat_plan: Usual combat
creature_plans:
  particular creature: Disable first
settings:
  hunting_room_id: 123
  resting_room_id: 456
  hunting_boundaries: '122, 124'
  targets: particular creature(a)
  recovery:
    cleanse_poison: false
```

The numbers above are placeholders, not a usable hunting area. Plain raw
profiles remain accepted. Unknown configuration keys are preserved; YAML
formatting/comments are not preserved when importing into the native copy.
Saves compare file revisions and reject stale edits instead of overwriting
another editor's work. Symlinked setup storage is currently refused. Keep
ordinary directories for this preview.

## Character defaults and Combat Plans

**Your combat sequences** is a character-scoped collection, not one universal
routine. Use **Add sequence** to create named alternatives such as Everyday,
No fire, or Tough enemies. **Save a copy as another sequence** preserves the
original. These use existing Combat Plan files; a duplicate name is refused
rather than overwritten. **Save universal sequence** adds it to the collection
without changing any creature's choice or the hunt default. **Save & use as
hunt default** additionally selects it as the fallback. Neither saves or starts
the hunt.

**Combat sequence for each creature** shows every explicit target in the hunt.
Each can use any saved universal sequence, the hunt default, or **Custom for
this creature**. Several creatures can share one universal sequence while
others use different ones. “Universal” means reusable, not guaranteed effective
or safe against every creature. Target exclusions, flee rules and survival
policies still apply. No target list is invented for unrestricted hunting.

Custom creature sequences stay in this hunt's native a-j routine slots; they do
not create or edit a shared Combat Plan. If a routine is shared with another
creature or inherited, editing allocates a separate free slot. An existing
dedicated local slot can be edited in place. If all slots are occupied the edit
is refused rather than overwriting a routine. Switching to a universal sequence
preserves old native routines, including unused ones. Review and save the hunt
to persist its selections; running hunts are not changed.

Character defaults use the same envelope with `settings` and an optional
`combat_plan`. Only explicitly inheritable settings transfer to a hunt;
geometry, target eligibility and destinations remain local. Lists and
structured maps replace as a whole, not a recursive merge. Explicit `false`
and empty values do not mean inherit.

Named Combat Plans contain `commands: 'incant 711, incant 705'`, for example.
The resolver allocates native a-j routine slots for creature exceptions and
reports overflow rather than dropping a sequence. Existing routine slots are
preserved. A local raw default routine overrides an inherited named plan; an
explicitly selected local plan takes precedence and reports a conflict warning.

The native reader resolves a launch snapshot. A running hunt is not silently
updated when a shared plan changes. Shared-impact previews and advanced plan
editing are still being refined; review linked hunts before changing defaults.

## Recovery and buff policies

`settings.recovery` overrides integrated Cleanse preferences. Missing keys use
the existing read-only `ecleanse.yaml`/CharSettings fallback. Explicit `false`
disables a supported preference. The legacy profile `troubadours_rally` rule
still applies before explicit native recovery overrides. The review shows
the effective recovery policy separately from raw compatibility fallback.
Standalone ecleanse settings are never modified.

Existing `combat_buffs` can be configured through the advanced editor. New
dispel-specific immediate/post-combat choices and configurable MANA SPELLUP
thresholds are a separate engine feature, not implemented by this GUI. Native
mode restrictions continue to apply to buffs, preparations and field rest.

## Groups

Group Hunt describes your character's participation with other players.
Multi-Account Team settings describe supported local coordination behavior.
Neither editing nor saving enrolls peers, authorizes remote control or starts
another character. The mode selector validates a profile for solo/head/tail;
it does not persist or issue a group launch command. Use existing participant
setup and launch mechanisms separately. A richer multi-character setup flow
remains follow-up work.

## Build and offline verification

`bundle exec rake build` creates the standalone `dist/eohunter.lic`,
`dist/eohunter-setup.lic`, and coordination library, with source maps. Install
both Hunter and its setup script together for native profile support. Source
checkouts must include the entire `scripts/eohunter/setup` directory and assets.

The standalone setup build reuses an already loaded engine's policy classes
and does not reload or replace an active hunt. Setup-only starts load policy
definitions without installing hooks or starting the game loop.

After installing an updated standalone editor in a session that already
loaded setup, safely log out and back in before opening it again. Shared
definitions and bundled assets are guarded process constants; stopping and
restarting the script alone is not a guaranteed code refresh. Do not reload
the hunt engine just to refresh the editor.

Tests:

```sh
bundle exec rspec
bundle exec rubocop
bundle exec rake build
bundle exec ruby tools/setup_fixture.rb
```

The last command starts an **offline fake-data fixture** in a temporary
directory, not an actual character session. Stop it with Ctrl-C.
Browser acceptance uses development-only Playwright:

```sh
npm install --prefix /tmp/hunter-setup-browser playwright@1.63.0
PLAYWRIGHT_MODULE=/tmp/hunter-setup-browser/node_modules/playwright \
  node tools/setup_ui_acceptance.mjs
```

Set `BROWSER_PATH` to an installed Chromium-family browser, or install the
Playwright Chromium test browser. `RUBY` can select the test Ruby executable.
The acceptance driver owns its temporary fixture and closes it afterward.

### Conditions and repetition on combat actions

Expand **Conditions & repetition** below an action. The same editor is used
for the hunt default, reusable Combat Plans, and creature-specific sequences.
You can change the action, move it up/down, choose repeats per sequence pass,
or limit it to once per target/room. Add resource thresholds, target or room
states, named effects, or a minimum delay between uses. Each condition is
shown in plain language with its native token, and can be removed separately.
Edits change the draft only; Save remains a separate step.

Conditions are ANDed. A failed condition **skips**, rather than waits on, the
action. The engine checks conditions again for each expanded repeat. Mana,
stamina and spirit thresholds use **points**, while health and encumbrance
use percentages. Effect names are matched as escaped literal name fragments;
existing custom regex patterns remain available in original routine text.

For example, the controls can produce:

```text
incant 719 (once), incant 711 (m40 !stunned)(x2), incant 705
```

That attempts 719 once per target in the room, then up to two 711 actions per
pass when mana is at least 40 points and the target is not stunned, then 705.
The sequence loops. It does **not** mean 711 twice in total then only 705 for
the rest of the fight. Identical native lines share once/delay tracking;
the editor disallows combining its once control with multiple repeats.

**Repeat on this target until it dies or leaves** uses native `untildead`.
After a successful action, Hunter keeps that step for its next combat turn.
Conditions and higher-priority safety behaviours still run between actions;
a skipped or unsuccessful action advances to the next step. A target change
restarts the sequence. This is not a blocking loop or a guarantee to kill.
For example, `719 (once), 711 (x2), 705 (untildead)` normally stays on 705 after
the opening actions succeed. If 705 fails or its conditions stop matching,
the sequence advances instead. Setup offers this only when the loaded engine
advertises support; deploy the updated Hunter and setup packages together.

Compatibility limits remain explicit: `(xx)` expands to five actions; it is not
an until-death instruction. Mana-percentage conditions and exact N-total uses
per target still need a separate native engine contract. Special native tokens such as
`buffN`, ambiguous legacy conditions, extension words, compound `and` actions
and structured arrays are preserved rather than silently translated. Unknown
modifiers may be ignored by the runtime: retention is not validation.

The editor adds no combat interpreter and sends no game commands. Its pure
codec lives in `assets/routine-editor.js`, with native-parser contract coverage
and browser save/reopen checks. Run `node tools/setup_routine_editor_test.cjs`
for the development-only codec tests.

### Action types and automatic combat settings

Each step has an action editor for spell delivery (incant, native default,
cast, channel or evoke), optional spell variants, ranged fire, hide, ambush,
unarmed attacks, aimed hurling, stance, waits and native maneuvers. Spell
variants must actually be supported by the spell; a dropdown does not make
every combination valid. Maneuver choices come from Hunter's native table,
not a claim that your character has learned them.

Ranged aiming, ammunition stow containers, weapon hands, hiding before movement
and automatic stances are hunt-level settings below the sequence editor.
`fire` has no invented per-step aim argument. `ambush` can become an open
attack if hiding failed; add the **hidden** condition when that is unwanted.
Hide-before-moving is not stalking a moving target. Explicit stance steps do
not disable Hunter's automatic attack, spell or movement stance policies.
Unsupported imported syntax stays in the original routine text.

### Rest rooms on another map

Use **Choose field rest on another map** or **Choose town rest on another map**
beside the rest fields or map controls. The separate pane searches all native
map sheets, including maps with no hunting creatures. Click a room on the
classic artwork (or use the searchable room list), then confirm. Cancel/Escape
discards the tentative choice. Field rest is purple **F**, town rest blue **T**.
Choosing a rest room never includes it in the hunting footprint or changes
targets, start or boundaries. Choices made in an area proposal still require
Apply; direct profile choices still require Save. No travel is performed and
the map does not certify that the room is safe.

### Society upkeep

The Buffs page lists learned Council of Light Signs, Order of Voln Symbols and
Guardians of Sunfist Sigils from Lich's native society readers. Check supported
tracked buffs to keep them active using Hunter's existing `signs` policy.
Names, descriptions and costs come from native metadata; dissipating spirit
costs are labelled. Nothing is selected automatically. Other learned powers
remain visible but are not offered as indefinite upkeep without a supported
tracked buff; use the appropriate combat, recovery or emergency policy.

This is a startup snapshot, not a live character monitor. Reopen setup after
learning abilities. Missing reader data is reported, not treated as proof of
no membership. Original/custom entries and entries from other societies are
preserved when selecting checkboxes. Mana recovery, blessings and monitored
missing-spell policies remain separate controls; selection never enables them.

### Injury return rules without writing Ruby

In guided **Rest & recovery** or advanced **Monitoring & limits**, choose a
starting preset under **When am I too injured to continue?**:

- General hunting: health at or below 70%, or any rank 2+ wound.
- Cautious: health at or below 85%, any wound, or bleeding.
- Spellcaster: health at or below 70%, bleeding, or injuries preventing casting.
- Ranged hunter: health at or below 70%, bleeding, or injuries preventing ranged attacks.

Adjust health, wound/scar ranks, bleeding, casting/ranged/hiding injury checks
and popped muscles (**Overexerted**) separately. Conditions are ORed: any one
requests an injury return. Blank health or **Do not check** disables that
individual condition; at least one condition must remain. These defaults are
starting points, not a promise of safety for a particular character or area.

**Apply injury return rule** deliberately replaces `wounded_eval` in the draft;
Save is separate. Merely opening the panel or choosing a preset changes
nothing. Existing custom Ruby remains untouched until Apply, and remains
available under **Original Ruby injury rule (advanced)**. The editor only
recognizes its own exact generated expressions; it never guesses the meaning
of arbitrary Ruby or evaluates it.

Generated rules use the existing runtime evaluation path. Scar thresholds use
Lich's cached injury projection rather than assuming XML exposes scars hidden
under wounds. That reader's native freshness limitations still apply. Casting, ranged and
hiding checks call Lich's `Injured` predicates, reusing its wounds/scars and
Sigil of Determination handling. They check injury restrictions, not mana,
spell knowledge or roundtime. Native injury refreshes may issue `_injury`
during the running hunt; setup never calls those predicates. Missing native
predicates are disabled in the editor. No new injury arithmetic or recovery
engine is introduced, and field/town recovery routing stays with Hunter.

Live area verification and native Windows/macOS acceptance remain separate
gates. Do not infer them from Linux fixtures. Any future in-game trial starts
and ends at an agreed safe location with an explicit stop/return plan.

## Guided configuration coverage update

The development editor now includes the following controls over existing
Hunter settings. Saving these controls never executes a command or starts a hunt.

- **Area & creatures → Boon creatures:** choose Fight, Do not target, or Leave
  the room for each ability in the installed Hunter recognition table. Bulk
  choices affect only the listed abilities; unknown imported names remain intact
  in the original lists. Fight does not override your normal creature selection.
- **Combat → Unarmed combat and MSTRIKE:** choose the excellent-positioning
  attack, aiming, SMITE, multi-target threshold, cooldown and stamina options.
  The legacy `uac_mstrike` flag is inverted: the control is deliberately labelled
  **Disable automatic unarmed MSTRIKE**.
- **Combat / Equipment → Wands and spell fallback:** set fresh/depleted
  containers, wand types and unaffordable-spell fallback together.
- **Rest → How to return:** choose a named native return method, conditional
  fogging, Rift handling and waypoints. Custom return commands have an ordered
  editor. A choice is not proof that the character knows or can afford it.
- **Preparation and rest lists:** add, update, reorder or remove individual
  commands and services. Script-list entries are script names and arguments;
  command-list entries use `script NAME` when calling a script. Existing arrays
  remain arrays. Nested/custom imported structures stay in the raw editor.
- **Combat action rows:** specialized builders cover wandolier, MSTRIKE,
  gemstone mnemonics, curse variants, Earthen Fury, tether, cast-and-stop,
  unravelling, resonance rotations, equipment operations, combat scripts,
  `force`, `eachtarget` and buff prefixes. For a wrapper, open **Choose the inner
  action**, update that action, then add/update the outer step. Modifiers belong
  to the outer step. Unsupported imported arguments remain custom text.
- **Action conditions:** native named-buff checks join the existing resource,
  effect and target choices, along with kneeling and UAC follow-up conditions.
- **Alternative combat sequences:** edit full-mind group and quick-target
  routines separately from the ordinary sequence.
- **Multi-Account Team:** roster/readiness, travel, resting and looting settings
  are grouped by purpose. This is not a receiver-enrollment interface.
- **Your character → Profile notes:** save personal reminders as editor
  metadata, without adding hunting instructions.

### Not claimed by this update

Interaction-alert windows and monitor/safe-string rules still need a separate
runtime design. The GUI labels the existing death switches as **Log out on
death** and **DEPART on death**, not low-health logout or guaranteed automatic
restart. It does not change their implementation.

The native `buffN` duration gate needs a semantic review before adding a
friendly “refresh with N seconds left” control: the current source skips while
the active buff's remaining time is **at or below** `N / 60.0`, which does not
match that label. Existing syntax remains preserved. Other specialized/custom
conditions and compound `and` expressions remain available through original
routine text, not a claim of complete no-code parity.
