# Watch Companion

Watch Companion is a Watch-first companion game that turns health context, small habits, stories, and trusted social signals into a sustainable relationship with a virtual pet.

The Apple Watch is the primary product surface. A lightweight iPhone companion provides account and privacy management, history, collections, and cosmetic wardrobe controls. Desktop clients, external displays, rings, NFC exchange, and phone-first gameplay are intentionally out of scope.

> Project status: early development. Health, alarm, haptic, and proximity behavior must not be considered verified until the corresponding physical-device checks in `docs/device-runbook.md` pass.

## Product principles

- The pet is the interface; the Watch home is not a health dashboard.
- Rules own facts, eligibility, rewards, safety boundaries, and notification budgets.
- Seeded randomness may choose when an eligible interaction appears.
- AI may express and dramatize approved state, but it cannot change state or make health diagnoses.
- Missing or denied health data is neutral, never a negative health result.
- Health outcomes are not moral failures. Only explicit, controllable commitments may have recoverable story consequences.
- Mock data is welcome in development and must always be visibly labeled.

The complete product rules live in [`docs/product-rules.md`](docs/product-rules.md).

## Intended architecture

```text
HealthKit / mock events / user actions
                  |
          normalized event ledger
                  |
      deterministic rules and reducers
                  |
     pet, growth, quest, and story state
                  |
      context builder (bounded windows)
                  |
   local templates or AI narration provider
                  |
        Watch UI + iPhone management UI
```

Domain rules are designed as a pure Swift package. Framework-specific adapters for HealthKit, notifications, persistence, connectivity, and AI sit outside the domain and are injected behind protocols. See [`docs/architecture.md`](docs/architecture.md).

## Planned repository layout

```text
Apps/                    iPhone and watchOS application targets and UI tests
Packages/CompanionCore/  Pure domain, rules, story, growth, and mock utilities
Services/                Optional server-side services such as narration gateway
Fixtures/                Synthetic health, story, timeline, and AI fixtures
TestPlans/               Shared Xcode test plans
Scripts/                 Reproducible developer checks
docs/                    Architecture, privacy, testing, and operating decisions
```

Directories are added only when their implementation begins; this document does not imply every planned component already exists.

The selective Phase 2 narration service is documented in
[`Services/NarrationGateway/README.md`](Services/NarrationGateway/README.md). It is optional: a
missing provider key produces a deterministic local fallback and never blocks the core Watch loop.

## Development phases

### Phase 0: prove foundations and device capabilities

- Establish deterministic domain state, versioned events, fixtures, and test gates.
- Validate HealthKit ingestion and permissions on physical devices.
- Validate smart-alarm scheduling and fallback behavior on a physical Apple Watch.
- Treat Nearby Interaction as a separate capability spike, not a Phase 1 dependency.

### Phase 1: complete the single-user loop

- Show a living pet, one relevant action, and an explainable data source on Watch.
- Deliver a seven-day common main story with recovery and activity themes.
- Support vitality growth, daily habits, a soccer-triggered random side story, local notifications, persistence, and deterministic offline templates.
- Provide a simple iPhone management and cosmetic wardrobe experience.

### Selected Phase 2 foundations

- Bond growth, explicit commitments, and repairable consequences.
- Bounded stochastic initiative with quiet hours and notification budgets.
- A privacy-aware context builder and optional server-side AI narration gateway.

AI and network access are enhancements. The core pet loop must remain functional with local templates and mocks.

## Secrets and local configuration

Never put provider secrets in the iPhone or Watch application bundle. Copy the narration service's `.env.example` to its local `.env` only for server-side development, then supply a newly issued key through your secret manager or shell environment. Do not reuse keys posted in chat, logs, issues, or screenshots.

```sh
cp Services/NarrationGateway/.env.example Services/NarrationGateway/.env
```

The real `.env` must remain untracked. Before every commit, inspect the staged diff and run a secret scan.

## Local validation

Bootstrap resolves Swift packages and creates an ignored Python environment for the optional
narration gateway. The same commands are used in CI:

```sh
Scripts/bootstrap
Scripts/check
Scripts/test
Scripts/test-e2e
```

## Contributing

Read [`CONTRIBUTING.md`](CONTRIBUTING.md), [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md), and [`SECURITY.md`](SECURITY.md) before contributing. Every behavior change requires tests and documentation in the same change. UI changes require both automated coverage and a visual/functional pass on the relevant simulator or device.

## License

Licensed under the Apache License 2.0. See [`LICENSE`](LICENSE).
