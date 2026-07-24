# Watch Companion

Watch Companion is a Watch-first relationship with Mori, a virtual companion
that quietly shares real-world movement, rest, tasks, and memories without
turning health into a score.

Apple Watch is the passive presence surface. iPhone carries conversation,
Today, shared memories, collection, permissions, privacy, and development data
controls. Desktop clients, external displays, rings, NFC exchange, and
phone-first gameplay are intentionally out of scope.

> Project status: early development. HealthKit, location/motion, haptic,
> notification, connectivity, performance, and proximity behavior must not be
> considered device-verified until the corresponding checks in
> `docs/device-runbook.md` pass.

## Product principles

- The pet is the interface; the Watch home is not a health dashboard.
- Rules own facts, eligibility, rewards, safety boundaries, and notification
  budgets.
- Passive inference is on-device first; uncertainty changes Mori's wording or
  keeps Mori silent rather than showing a confidence percentage.
- AI may express approved state and converse, but it cannot create facts, change
  product state, or make health diagnoses.
- Missing or denied health data is neutral, never a negative health result.
- Tasks are occasional and concise. Reliable evidence may complete them
  automatically; otherwise the person confirms explicitly.
- Health outcomes are not moral failures and never lose coins or block access.
- Mock data is development-only, visibly labeled, and isolated from real state.

The current product authority is [`PRODUCT.md`](PRODUCT.md). Visual and
interaction authority is [`DESIGN.md`](DESIGN.md). The executable rebuild
contract and status live in
[`docs/mori-rebuild-goal-plan.md`](docs/mori-rebuild-goal-plan.md) and
[`docs/mori-rebuild-status.md`](docs/mori-rebuild-status.md).
`docs/product-rules.md` is retained only as a historical prototype contract.

## Intended architecture

```text
HealthKit / motion / coarse location / mock evidence / user actions
                  |
     minimized facts and evidence ledger
                  |
  confidence policy + deterministic reducers
                  |
 passive event + optional task + memory eligibility
                  |
 profile-scoped task, coin, collection, memory, and letter ledgers
                  |
 bounded local context + optional remote conversation/narration
                  |
 passive Watch scene + iPhone Mori/Today/Memories/Collection
```

Domain rules are designed as a pure Swift package. Framework-specific adapters for HealthKit, notifications, persistence, connectivity, and AI sit outside the domain and are injected behind protocols. See [`docs/architecture.md`](docs/architecture.md).

That architecture document describes the current prototype for migration
purposes. ADR 0002–0006 and the rebuild Goal plan govern new implementation.

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

## Execution Goals

Work is organized by acceptance Goals rather than dates or legacy phases. See
[`docs/mori-rebuild-goal-plan.md`](docs/mori-rebuild-goal-plan.md). AI and
network access remain enhancements: the passive companion, tasks, memories, and
local conversation fallback must remain coherent offline.

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
