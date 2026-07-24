# Mori motion system

This document is the G4 integration contract for the independent black and white Mori animation
worktree. It intentionally does not own product inference, notification scheduling, task
completion, memory generation, chat logic, or either app's root navigation.

## Sources of truth

- `characters/penguin-v2` and `characters/polar-bear-v2` remain the approved hatch-pet v2
  foundation: `192x208` cells, `8x11`, nine standard rows, sixteen clockwise look directions,
  `1536x2288`, and `spriteVersionNumber: 2`.
- `characters/motion-catalog.json` is the product motion contract.
- `characters/runtime-state-map.json` is a legacy eight-state export map. It is not authoritative
  for product semantics and must disappear from app runtime use when the new catalog is integrated.

The two Mori variants are separate identities. They share motion IDs and behavior metadata, but
never share recolored, mirrored, warped, or character-substituted production frames.

## Current release scope

The time-boxed G4 handoff ships only the black penguin Mori. Its sixteen product motions, Watch
assets, iPhone assets, Reduce Motion keyframes, previews, and runtime behavior are release
candidates. The white polar-bear Mori remains a future catalog-compatible variant and is not
generated, installed, or claimed as validated in this handoff.

The shared catalog stays in `authoring` state until the polar-bear asset set is independently
authored and reviewed. Integrators must enable the penguin character explicitly instead of treating
catalog membership as proof that every listed character is production-ready.

## Production forms

`unique` motions have a dedicated eight-frame clip for each character unless the catalog explicitly
names an approved hatch-pet foundation row. An alias resolves to another motion or approved
foundation row without manufacturing a second semantic meaning. A pose chooses one reviewed
keyframe or one approved v2 look direction. A policy does not own pixels.

The following are always invalid:

- `idle_lively` using the waving row;
- `touch_body` using the failed row;
- `story_reaction` using the review/processing row;
- a missed task or health event using the failed row;
- the non-directional hatch-pet `running` row being presented as evidence that the user is running.

## Request and arbitration

A runtime request contains:

- a motion or alias ID;
- a stable request identity used for deduplication;
- the selected character ID;
- the surface;
- the request time;
- whether Reduce Motion is active;
- an optional completion deadline.

The catalog priority order is strict:

1. direct touch;
2. a new reality event;
3. conversation or task completion;
4. passive companionship movement;
5. environmental attention;
6. current idle.

A higher-priority request interrupts the current motion. Equal-priority requests follow the
catalog's replacement policy. Lower-priority requests wait only while still relevant; stale queued
requests are discarded instead of replayed later. A duplicate request identity never restarts a
clip.

Foreground loss cancels transient and one-shot playback. Returning to the foreground begins from
the selected current idle rather than resuming a partial clip. A missing catalog entry, missing
frame, unsupported character, unsupported surface, or malformed request resolves to
`idle_neutral`.

## Playback

Every product clip has eight transparent `192x208` frames. Runtime frame names use:

`character_{character}_{motion}_{frame}`

where `frame` is a zero-padded value from `00` through `07`.

The renderer uses nearest-neighbor interpolation, a stable foot anchor, and no baked scenery,
labels, speech bubbles, detached effects, drop shadows, or floor marks. The catalog's playback mode
determines whether the clip loops, plays once, or holds its final frame before settling.

## Reduce Motion and accessibility

Reduce Motion never disables semantic feedback. It renders the catalog's reviewed keyframe with a
short cross-fade and exposes the same visible alternate and VoiceOver localization keys.

Haptics accompany a visible or textual response and never replace it. The motion coordinator emits
a haptic category at most once for an accepted request; platform adapters decide whether haptics
are available and enabled.

Head and body hit regions are character-relative metadata. Empty scenery and inactive character
slots are not interactive. Repeated touch is debounced by the catalog cooldown, and touch playback
never settles tasks, memories, rewards, or health state.

## Asset acceptance

Each enabled character must independently provide:

- every required product clip and its manifest;
- per-clip previews and contact sheets;
- Watch-size previews at the smallest and largest supported layouts;
- a Reduce Motion keyframe sheet;
- deterministic transparency, frame count, dimensions, baseline, and asset-catalog checks;
- independent visual review for identity, intent, cadence, clipping, seams, detached effects,
  apparel occlusion, and interruption safety.

Before the polar-bear variant can be enabled, it must additionally pass a black/white semantic
parity review. Deferring that variant does not permit recoloring or reusing penguin frames.

The approved hatch-pet v2 atlases are not regenerated merely because the product catalog grows.
Any v2 repair still follows the full-row repair and blind direction-review rules from the
`hatch-pet` skill.

Physical-device frame pacing, memory, thermal behavior, energy use, and haptic feel remain
unverified until recorded on actual hardware.

## Independent worktree handoff

This branch must not merge itself into the product branch. The handoff contains commit hashes,
catalog API, generated assets, validation evidence, and known conflicts. Mainline integration is
expected to reconcile later changes to the character catalog, legacy runtime state map,
`WatchScenePresentation`, `CompanionSceneView`, visual validator, and social motion additions such
as `social_leap`.
