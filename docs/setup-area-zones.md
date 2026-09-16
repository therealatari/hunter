# Map, hunting area, creatures

Development evidence, 2026-09-16. These suggestions are **not field-checked**.

The general setup order is **overall map → particular hunting area → creatures**.
It is not a Rift-only workflow. A classic map is the visual context, not a
promise that every room on that sheet belongs to one hunt. Native creature
habitats supply the areas and occupants. Broad habitats can have explicit
subdivisions in `HunterSetup::AreaZones`; the browser does not need a separate
workflow for each location.

The original explicit subdivisions are The Rift: Planes 1–5 and The Scatter.
The research catalog extends this interface with named geographical footprints,
not just unions of creature spawn rooms. Shared monsters never pull another
plane into a selection, and connector rooms remain even when no selected
creature is recorded there. Scripted exits do not automatically merge areas.
Ordinary, undivided habitats retain the same map/area/creature controls,
restricted to the selected classic map sheet.

Research records are drafts, not field-tested presets. Each carries native UID
membership, source hashes, evidence, limitations and an offline geometry result.
Special-navigation candidates are retained in the research reports rather than
offered as ordinary selectable drafts. Entry swimming, ordinary climbs or
combat hazards alone do not make an internally normal area special. Missing
native data stays a visible gap; it is not invented to complete a catalog.

## Data boundaries

The 2026-09-16 baseline adds 216 draft subdivisions from 64 sheets after research
on all 67 sheets with native creature intersections. Of these drafts, 180 have a
passing offline directed-walk check and 36 are partial. The six pre-existing Rift
choices are preserved independently; Confluence is not newly offered as an
ordinary static area. Counts are snapshot-specific, not a promise of complete
game coverage. Every generated entry remains a draft.

- Native room UIDs describe membership. Room IDs resolve from the installed
  map, not a stored list of local IDs. Coordinates only place the highlights.
- Map names come from native `meta:mapname:` tags, falling back to the installed
  image filename. The UI never derives a plane name from a connected component.
- Membership is explicit catalog data: UID arrays for research areas and compact
  legacy ranges for The Rift. Geography is not inferred from a shared monster.
- Creature selection does not narrow a named area's geographical footprint.
  Flee/ignore target choices do not themselves prohibit entering its rooms.
  Legacy habitats without subdivisions retain creature-derived suggestions.
- Changing map or area replaces the pending preview, not the saved route.
  Changing targets preserves proposal geography. Explicit manual additions must
  belong to the selected map; a user can also exclude rooms and recalculate.
  Only Apply copies the proposed geometry to the draft; Save is
  separate. `area_map`, `area_zone` and `area_provenance` are editor context,
  not new Hunter movement rules. Runtime still uses start and boundary settings.
- The classic map initially focuses on a named subdivision's selected rooms.
  **Show full classic map** restores surrounding context. Neither view creates
  paths or guarantees that a map link can currently be traversed.

## Rift evidence and outstanding checks

### Possible visitors are not habitat membership

The setup lists enormous rift crawlers under **Can also appear here** on
Planes 3 and 5. The installed creature definition records their Plane 4 home;
the [archived GM announcement](https://gswiki.play.net/The_Rift/saved_posts#Preview)
describes burrowing to adjacent planes, and the
[plane research](https://gswiki.play.net/Research%3AThe_Rift_%28planes%29)
identifies those visiting planes. This is documented, not field-checked here.

`AreaZones.visitors` is separate from room membership. It provides the native
creature name, reason, source and verification status. Attributes come from
the installed native template; unavailable attributes stay unknown. A visitor
already in the resident list is not duplicated. Hunt / Do not target / Leave
the room use the same target controls, and a hunted visitor can use any
universal or creature-specific sequence. None of these choices adds its home
plane's rooms or changes the chosen area's boundaries.

No blanket neighboring-area inference is made. Other visitors require their
own evidence-backed encounter records, not expanded creature habitat UIDs.

### Native map evidence

Read-only source inspection used the installed map `map-1788922100.json` and
the plane labels on `imt-rift-1554575848.png`. Creature definitions for aivren,
lost soul and vaespilon corroborate the respective plane UID bands. This is
static evidence, not a movement experiment or a statement of current safety.

| Named area | Explicit UID membership | Resolved room count |
|---|---|---:|
| Plane 1 | 4566001–4566055 | 55 |
| Plane 2 | 4567001–4567055 | 55 |
| Plane 3 | 4568001–4568055 | 55 |
| Plane 4 | 4569001–4569023 | 23 |
| Plane 5 | 4570001–4570014 | 14 |
| The Scatter | 4571001–4571030 | 30 |

All six memberships resolve in this snapshot. That does **not** mean all
entries are reachable or that the creature/room data is exhaustive:

- Plane 5 UID 4570014 resolves to room 33259, which has neither an image nor
  map coordinates. It has an `out` link to 12208, but no incoming link from
  the other selected rooms. The native `Wander::Area` builder, used with the
  read-only map adapter from start 12208 and the calculated perimeter, reaches
  **13 rooms, with no rooms outside the selected plane**, not all 14. Keep the
  missing-artwork and no-mapped-entrance warnings; review/exclude that extra room
  explicitly rather than silently pretending it is reachable. No exit was run.
- Room 2631 has a Plane-1-sheet coordinate but no UID. Its status cannot be
  established from the UID catalog; it was not silently inserted into Plane 1.
- Many scripted cross-plane links generate a large perimeter. This follows the
  existing exterior-neighbor boundary convention; it is not a claim that all
  those links are usable movement choices.
- Weak connectivity is not directed reachability. The one-way-entry diagnostic
  catches rooms with no mapped entrance from peers, not every possible directed
  graph problem or conditional exit. Field verification remains required.

Source SHA256 values:

```text
map-1788922100.json
94220ab8ca6701bba7ffcdd909d84c0c031914304447d847f26e582e01071462
imt-rift-1554575848.png
3de83c6c4c2aaf04a30bc0ced3b7257be862dd2ffae696197369c887adccd3a7
```

Before calling a subdivision verified, check its entrance, directional exits,
conditional transitions, creature distribution and boundary behavior in-game
under an agreed safe-start/safe-return test. Do not turn these static checks
into an automatic hunt or a claim of safe rest locations.

## Regression coverage

Pure geography specs cover selected-map narrowing, all six plane labels,
shared-creature confinement, out-of-plane creature/room rejection, explicit
empty selections, retained unpositioned rooms and missing UID diagnostics.
The real-backend browser fixture walks through map → Plane 5 → shared creature
→ Apply, checks the plane-local geometry, then previews Plane 3 without
replacing the applied route. It also checks the classic-map focus control.
