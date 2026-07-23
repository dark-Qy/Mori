# Watch Companion visual asset contract

The Watch home is composed from independent layers:

1. an opaque shared scene background;
2. zero or more animated character slots;
3. an optional transparent scene foreground;
4. native SwiftUI status and action controls.

Characters, controls, text, watch bezels, and accessibility labels must never be baked into a
background image. Character animation frames must never contain scenery.

## Scene package

The authoritative catalog is
`Design/WatchCompanionAssets/backgrounds/catalog.json`. It contains exactly ten scenes shared by
both initial characters.

Each scene directory contains:

- `source.png`: the selected full-resolution generated source;
- `background-master.png`: opaque `832x1024` production master;
- `background-small.png`: opaque `352x430` export for small Watch layouts;
- `background-large.png`: opaque `416x496` export for large Watch layouts;
- `foreground-master.png`: optional transparent foreground occlusion layer.

All important scene landmarks must remain outside the catalog's top and bottom UI-safe regions.
The middle/lower staging area must support all three normalized anchors:

- `solo.center`, used by the current single-character home;
- `duo.left`, reserved for the future leading character;
- `duo.right`, reserved for the future trailing character.

The single-character layout does not reuse either duo anchor. Each scene may override the default
anchor positions, scale, facing, and z-index without changing the renderer.

## Character package

The authoritative catalog is
`Design/WatchCompanionAssets/characters/catalog.json`. `penguin` and `polar_bear` are independent
identities, not outfits applied to one shared body.

Each character first completes the hatch-pet v2 source contract:

- `192x208` transparent cells;
- 8 columns by 11 rows;
- nine standard animation rows;
- sixteen clockwise look directions;
- final master atlas `1536x2288`;
- `spriteVersionNumber: 2`;
- deterministic validation, contact sheets, motion previews, direction semantics, and independent
  visual QA.

The Watch runtime exports the following common interaction interface:

- `idle_neutral`
- `idle_resting`
- `idle_curious`
- `idle_lively`
- `touch_head`
- `touch_body`
- `action_success`
- `story_reaction`

`Design/WatchCompanionAssets/characters/runtime-state-map.json` is the machine-readable mapping
from those runtime states to the nine canonical source rows. Every runtime state exports exactly
eight PNG frames at 10 fps; shorter authored rows are deterministically sampled across eight
runtime slots rather than padded with unrelated artwork.

Video may be used as motion reference, but it is not a runtime format. Runtime clips are transparent
PNG frames or atlas pages no larger than `1024x1024`. Every clip uses the same canvas, foot anchor,
character scale, and frame ordering. Pixel art is rendered without smoothing.

## Interaction contract

Touch feedback follows:

`idle -> pressed -> reacting -> settling -> current mood idle`

- Visual feedback begins within 100 ms.
- Only an active character slot is interactive; tapping empty scenery has no side effect.
- Head and body hit regions select different reactions.
- Repeated taps are debounced for 350 ms and do not settle growth or the daily suggested action.
- Transient and one-shot reactions begin at frame zero; one-shots hold their final frame until the
  scene returns to the current mood idle.
- Haptics accompany, but never replace, visual or textual feedback.
- Reduce Motion uses the clip's semantic key frame or a short cross-fade.

## Completion evidence

`Scripts/validate-visual-assets` is the deterministic gate. During production,
`Scripts/validate-visual-assets --allow-pending` validates completed artifacts without pretending
that unfinished characters are ready.

Final visual acceptance additionally requires:

- a ten-scene background contact sheet;
- twenty single-character scene composites;
- ten reserved two-character composites;
- per-row character motion previews;
- normal-size identity, baseline, continuity, and direction review;
- Watch simulator checks for small and large layouts, Reduce Motion, VoiceOver, tapping, offline
  fallback, and scene switching;
- physical-device evidence for frame pacing, memory, energy, and haptics.
