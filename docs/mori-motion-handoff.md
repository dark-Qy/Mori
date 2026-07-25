# Mori motion G4 handoff

This branch is an independent integration handoff. It must not merge itself into the product
branch.

## Git checkpoints

- `b0917235348e7689b4d859823a5c611fc4680036` — motion catalog contract;
- `b8f87a74917961f9aa206bd6b1160d23f12e16bc` — black Mori production animations;
- `2bf950c61e51802745b7a3f3f15d399cf4115d38` — asset and contract validator;
- `0737676642e29de39bae63e5e4c11c21c5ea65d4` — animation runtime, fallback, and tests.

## Release scope

- Ready candidate: black penguin Mori.
- Deferred: white polar-bear Mori. No production clips were generated, installed, or validated.
- Included: sixteen motion definitions, fifteen dedicated product clips plus the approved v2
  neutral idle, Watch and iPhone assets, Reduce Motion keyframes, a deterministic runtime package,
  previews, and validators.
- Excluded: product inference, notification scheduling, task/reward settlement, memories, chat,
  root navigation, and direct UI integration.

The shared catalog intentionally remains `authoring` because it describes both character IDs.
Product integration must enable `penguin` explicitly; catalog membership is not a readiness flag
for `polar_bear`.

## Integration API

Add `Packages/MoriMotion` as a local Swift package and load:

`Design/WatchCompanionAssets/characters/motion-catalog.json`

The primary API is:

- `MoriMotionCatalog.load` or `MoriMotionCatalogLoader.loadOrFallback`;
- `MoriMotionRequest` for one stable request identity, selected character, surface, deadline, and
  Reduce Motion preference;
- `MoriMotionCoordinator.send(_:now:)` for deterministic state transitions;
- `MoriMotionCoordinator.enabledCharacterIDs`, which defaults to `["penguin"]`; do not enable a
  future character merely because its ID exists in the shared catalog;
- `MoriMotionEffect.transition` to render `MoriMotionPresentation`;
- `MoriMotionEffect.cancel` to stop an interrupted, replaced, expired, backgrounded, or
  missing-asset clip;
- `MoriMotionEffect.haptic` to emit the catalog category at most once per request identity;
- `MoriAssetInventory.available` to require installed frame names before playback;
- `.assetUnavailable(requestIdentity:)` when the renderer discovers a late asset failure.

The renderer owns timers, frame drawing, localization, and platform haptics. It must render frame
names from the presentation in order, use nearest-neighbor interpolation, preserve the catalog
anchor, and send `.playbackCompleted` for one-shot clips. It must send foreground changes to the
coordinator instead of resuming a partial clip.

Current priority is:

1. touch;
2. reality event;
3. conversation or task success;
4. companionship movement;
5. environmental attention;
6. idle.

## Assets

The penguin source manifest is:

`Design/WatchCompanionAssets/characters/penguin-v2/product-motion/final/motion-manifest.json`

Every frame is a transparent `192x208` PNG. Runtime names use:

`character_penguin_{motion}_{00...07}`

The same bytes are installed into both:

- `Apps/Apple/WatchApp/Assets.xcassets/Characters`;
- `Apps/Apple/iPhoneApp/Assets.xcassets/Characters`.

Review evidence lives under:

`Design/WatchCompanionAssets/characters/penguin-v2/product-motion/qa`

## Validation

Run:

```sh
Scripts/validate-mori-motion
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift \
  test --package-path Packages/MoriMotion --disable-sandbox
```

The asset validator checks the exact sixteen-motion contract, aliases, fallback, priority metadata,
touch regions, Reduce Motion and accessibility keys, forbidden mappings, approved v2 atlas hash,
128 source frames, clip uniqueness, and 256 byte-identical installed assets.

Current evidence:

- asset/package validation: 7/7 checks, 0 errors, 1 expected integration warning;
- Swift runtime: 24/24 tests passing;
- independent code review: approved, no remaining P0/P1/P2;
- independent visual review: pass, no blockers;
- structural finalizer: 16 motions, 0 errors, 0 warnings.

The visual review accepts that reflection/reaction poses depend partly on sequence and context,
`sit_down` intentionally changes the grounded silhouette, and reduced-motion keyframes cannot
express full loop cadence. No clipping, external hand, detached effect, material color edge, or
identity/apparel drift was found in the final sheets.

`--strict` intentionally fails while the legacy `runtime-state-map.json` still contains the
forbidden placeholder mappings. The non-strict release-candidate check reports those as integration
warnings because this branch is not authorized to replace the product UI runtime.

## Integration conflicts

The branch started from `92e5486` and does not cherry-pick later mainline work. Integration must
reconcile:

- the later character catalog and `social_leap` addition;
- the legacy runtime state map;
- `WatchScenePresentation`;
- `CompanionSceneView`;
- the main visual validator;
- any later AppRuntime/G2 sensing changes.

Keep `social_leap` as a supplementary motion if still required. Do not restore the forbidden
`idle_lively -> waving`, `touch_body -> failed`, or `story_reaction -> review` placeholders.

## Known limitations

- The runtime is Foundation-only. It does not render, schedule timers, or play real haptics.
- A renderer must provide an asset inventory or report late asset failures.
- Seen request identities are retained for the coordinator lifetime; the host may recreate the
  coordinator at an appropriate session boundary.
- Physical Watch frame pacing, memory, thermal behavior, energy use, and haptic feel are not
  validated in this isolated branch.
- This machine can run Swift package tests with the Xcode toolchain, but the product Watch UI was
  intentionally not modified or launched in this worktree.
- White Mori semantic parity remains unverified and must be completed before enabling that variant.
