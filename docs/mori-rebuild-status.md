# Mori Rebuild Status

## Current Goal

| Field | Value |
| --- | --- |
| Branch | `codex/mori-product-rebuild` |
| Base revision | `51b9a58` |
| Active goal | G0 — Product, Design, And Baseline Contract |
| Goal state | Contract ready |
| Implementation | In progress |
| Simulator validation | Not started |
| Device validation | UNVERIFIED |

## Goal Ledger

| Goal | State | Revision | Evidence | Blocker / next action |
| --- | --- | --- | --- | --- |
| G0 Product and baseline contract | Implementing | working tree | PRODUCT, DESIGN, goal plan; static and visual baseline | Fix Release fixture identifier exposure, finish complete baseline |
| G1 Authoritative product domain | Pending | — | — | Depends on G0 |
| G2 Evidence and profile runtime | Pending | — | — | Depends on G1 |
| G3 Sync, reminder, daily memory | Pending | — | — | Depends on G1 |
| G4 Mori motion system | Pending | — | Existing asset baseline only | Depends on G0 |
| G5 Watch experience | Pending | — | — | Depends on G2, G3, G4 |
| G6 iPhone experience | Pending | — | — | Depends on G2, G3, G4 |
| G7 Mori conversation | Pending | — | — | Depends on G1, G3 |
| G8 End-to-end product loops | Pending | — | — | Depends on G5, G6, G7 |
| G9 Release and open-source quality | Pending | — | — | Depends on G8 |

## Baseline Evidence

### PASS

| Check | Revision / tree | Result |
| --- | --- | --- |
| `Scripts/bootstrap` | `51b9a58` plus planning docs | Local Swift and Python tooling resolved |
| `Scripts/check` | `51b9a58` plus planning docs | PASS |
| `Scripts/validate-visual-assets --allow-pending` | `51b9a58` plus planning docs | PASS: 10 scenes, 2 characters, 256 runtime frames, 20 solo composites, 10 duo composites |

### FAIL

| Check | Evidence | Required action |
| --- | --- | --- |
| `Scripts/test-release-boundaries` | `error: Release executable exposes fixture identifier: mock1` | Remove product-enum/fixture-token collision from the Release executable, then rerun |

### NOT RUN

- `Scripts/test`
- `Scripts/test-e2e`
- `Scripts/test-accessibility`
- Computer Use iPhone review
- Computer Use Watch review

### UNVERIFIED

- Physical HealthKit and background delivery
- Physical location and motion background behavior
- Focus and notification timing
- Wrist activation behavior
- Haptic feel and suppression
- Paired-device disconnect and reconciliation
- Frame pacing, decoded memory, thermal behavior, and battery
- Second-device Touch Exchange

## Review Record

| Review | Revision | Result | Disposition |
| --- | --- | --- | --- |
| Initial UI/runtime read-only audit | `51b9a58` | Identified legacy UI, missing experience-event sync, and profile isolation gaps | Incorporated into Goal plan |
| Independent Goal-plan review | planning working tree | 6 P0, 10 P1, quality recommendations | First revision completed; follow-up review found namespace and offline-disable gaps |
| Final Goal-plan P0 review | planning working tree | PASS | No document-level P0 blocks the first commit |

## Recovery Rule

On a resumed task, read this file, verify the branch and current revision, then
continue the first Goal whose state is not `Committed`. Never infer PASS from an
older revision or from Simulator evidence for a physical-device capability.
