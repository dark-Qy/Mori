# Contributing

Thank you for helping build Watch Companion. Contributions must preserve the product's privacy, safety, determinism, and Watch-first boundaries.

## Before starting

1. Read `PRODUCT.md`, `DESIGN.md`, `docs/mori-rebuild-goal-plan.md`, and the
   relevant ADRs. `docs/product-rules.md` and `docs/architecture.md` describe
   the historical prototype and are migration evidence only.
2. Open or reference an issue that states the user outcome and acceptance criteria.
3. Keep a change focused enough to review, test, and revert independently.
4. For health, location/motion, notification, social, or AI changes, include
   failure and permission-denied behavior in the design.

## Branches and commits

Create a short-lived branch such as `feat/pet-home` or `fix/event-deduplication`. Use Conventional Commits:

```text
feat(rules): add recovery theme selection
fix(store): make event replay idempotent
test(watch): cover notification deep link
docs(privacy): document health retention
```

Do not mix unrelated formatting, generated files, or refactors into a feature commit. Tests and documentation that prove a behavior belong with that behavior.

## Architecture rules

- Keep domain, evidence, policy, profile, synchronization, and conversation
  logic independent of SwiftUI and Apple frameworks.
- Inject time, calendar, randomness, identifiers, storage, health data, notifications, connectivity, and narration.
- Make reducers deterministic. Random behavior must receive a seeded `RandomSource` in tests.
- Normalize external data into versioned domain events before applying rules.
- Treat rules as authoritative. AI output is untrusted presentation data.
- Do not make the iPhone app necessary for moment-to-moment pet play.
- Do not add desktop, external-display, ring, or NFC features without an accepted replacement ADR.

## Privacy and safety checklist

- Request only the HealthKit types needed for a shipped feature.
- Never infer that missing data means poor health or that a user denied permission.
- Do not log raw health samples, prompts containing health data, access tokens, or user messages by default.
- Do not add advertising or behavioral profiling based on health data.
- Keep all health-derived data, memories, and free text out of social output.
  The current Goal permits only the allowlisted public pet card and game-only
  social state.
- Avoid diagnosis, treatment claims, medical labels, and punitive health mechanics.
- Do not put AI provider credentials in Apple application targets.

## Tests required with every change

- Domain changes: unit tests, edge cases, deterministic replay, and migration tests where applicable.
- Adapter changes: contract tests with success, denial, absence, stale data, and failure cases.
- UI changes: UI tests plus a functional and visual pass on every affected form factor.
- State changes: kill/relaunch and idempotent replay coverage.
- Device-only capabilities: evidence in the device runbook; never substitute simulator results.

Use the repository's shared test plan and check scripts when they are available. Do not lower coverage, disable warnings, or skip a flaky test to make a change pass. Fix the test or document and isolate a platform limitation.

## Pull requests

A pull request should include:

- the user-visible outcome;
- design and privacy implications;
- tests run with exact destinations;
- screenshots or recordings for UI work;
- physical-device evidence for HealthKit, location/motion, haptics,
  notifications, and proximity claims;
- fallback behavior for unavailable capabilities;
- documentation or ADR updates.

Reviewers should verify both the happy path and degraded path. Approval is not proof that a device capability works; the device-run evidence is.

## Generated and local files

Never commit secrets, `.env`, signing identities, provisioning profiles, `xcuserdata`, DerivedData, health exports, device logs, recordings containing personal information, or generated build artifacts. Inspect `git diff --cached` before every commit.

By contributing, you agree that your contribution is licensed under Apache-2.0.
