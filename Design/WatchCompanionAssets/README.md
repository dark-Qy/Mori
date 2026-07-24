# Watch Companion visual assets

This directory separates reusable scenes, character identities, production exports, and review
evidence. Scene art never contains a character, and character art never contains scenery.

## Where to look

- `backgrounds/catalog.json` is the source of truth for the ten shared backgrounds.
- `backgrounds/<scene-id>/` contains the master PNG and Watch-sized exports for one scene.
- `characters/catalog.json` is the source of truth for the two initial characters.
- `characters/runtime-state-map.json` maps product interactions to animation rows.
- `social_leap` is an eight-frame Watch runtime supplement (ready, compression, push-off, rise,
  apex, descent, landing, recovery). It stays outside the standard 8×11 v2 package atlas.
- `characters/<character-id>/final/` contains the approved v2 atlas and package manifest.
- `characters/<character-id>/qa/` contains the retained acceptance evidence and runtime source
  frames.
- `qa/composites/` contains single-character and reserved two-character scene composites.
- `references/` contains the original character reference and shared generation references.

## Generation workspace

The following folders are authoring inputs or reproducible intermediates, not app runtime assets:

- `decoded/`
- `frames/`
- `prompts/`
- `references/`
- `imagegen-jobs.json`

Keep canonical approved files in these folders because the deterministic validator and asset
installer use them. Temporary alternatives must include `candidate` in the filename; they are
ignored by Git and should be removed after a selection is approved.

## Runtime exports

The app consumes generated files under:

- `Apps/Apple/WatchApp/Assets.xcassets/Scenes`
- `Apps/Apple/WatchApp/Assets.xcassets/Characters`
- `Apps/Apple/iPhoneApp/Assets.xcassets/Scenes`
- `Apps/Apple/iPhoneApp/Assets.xcassets/Characters`

These exports are derived from the catalogs above. Do not edit individual runtime PNGs by hand.
Use `Scripts/prepare-visual-assets`, then run `Scripts/validate-visual-assets`.
After regenerating the supplemental row, bind an independent reviewer decision to the canonical and
source-strip SHA-256 values in each row's `identity-review.json`, then run
`Tools/VisualAssets/validate_social_leap_frames.py`. The validator rejects missing, stale, or failed
identity evidence and renders contact sheets plus GIF previews.
