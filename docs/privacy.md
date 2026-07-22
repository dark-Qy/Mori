# Privacy

## Position

Health context is used to provide a health and fitness companion experience, not for advertising, data brokerage, unrelated profiling, employee monitoring, insurance, or medical diagnosis. The product must remain useful when health access is absent or partial.

This document is an engineering policy, not the final public privacy policy. Store submission requires a reviewed user-facing policy and accurate App Privacy disclosures for every shipped SDK and service.

## Data-flow principles

1. **Purpose limitation:** collect only the types and windows required by an implemented feature.
2. **On-device first:** normalize, deduplicate, derive baselines, and evaluate rules on device when practical.
3. **Bounded context:** send only the relevant raw window, derived features, rule hits, and necessary story state to a remote narrator.
4. **No repeated consent theater:** use clear one-time feature explanation and system permissions, then automate within that scope.
5. **Owner-controlled sharing:** social access is directional and can be revoked independently.
6. **Neutral absence:** never infer denial or poor health from missing data.
7. **No secret clients:** third-party provider credentials stay server-side.

Notification consent is also fail-closed. The proactive-message preference defaults off, stores a
separate consent version when explicitly enabled, and treats older implicit opt-ins as disabled.
Turning it off cancels pending Mori check-ins. A notification tap may navigate to an optional
in-app action, but cannot settle a task or reward.

## Data categories

| Category | Examples | Default location | Remote use |
|---|---|---|---|
| Health samples | sleep stages, workouts, heart rate, steps | device | bounded narration request only after consent and only if needed |
| Derived features | personal baseline, trend, freshness, rule hit | device | limited to current interaction where needed |
| Game state | pet state, growth, inventory, story node | device | optional sync and narration context |
| User settings | quiet hours, permissions, wardrobe | device | optional account sync |
| Social state | friendship, sharing scope, shared story | server when social ships | authoritative access-controlled service |
| Diagnostics | event type, rule ID, error category | device or redacted telemetry | never raw health values or prompts by default |

## HealthKit access

- Ask for HealthKit types at the point their feature is explained, not as an unexplained bulk request.
- Treat authorization status conservatively; the UI must not claim that a user denied read access when Apple does not expose that distinction.
- Store provenance and freshness so mixed sources and stale samples are not misrepresented.
- Do not reconstruct or infer a specific workout label such as soccer from generic activity samples.
- Do not write to HealthKit unless a user-visible feature explicitly requires it.

## AI narration

The narration context builder may automatically select relevant data after informed consent. Automation does not justify sending entire history.

A typical sleep interaction may include last night's relevant sleep samples, a recent summary window, a longer personal baseline, recent compatible context, rule identifiers, and current pet/story state. It should not include unrelated months of heart-rate samples.

The gateway must:

- authenticate the app user separately from the upstream provider;
- obtain its provider credential from environment or a secret manager;
- enforce schema, size, rate, and timeout limits;
- redact request and response bodies from ordinary logs;
- avoid provider training and long retention where a supported contractual setting exists;
- delete transient request content after processing unless a declared purpose requires retention;
- provide deterministic local fallback on the client.

## Social summaries

Friendship does not imply health access. The data owner chooses one directional scope for each friend, with a global default that can be overridden.

- `gameOnly`: no health-derived output.
- `careSummary`: vague, actionable, non-medical support signal without source category or value.
- `limitedHealthSummary`: broad category or trend without precise values by default.

A recipient cannot elevate a scope. Removing the relationship, disabling the feature, or deleting the account revokes future retrieval and notification. Avoid deterministic emission for every health event because timing itself can reveal sensitive information.

## Retention and deletion

Before remote storage ships, define and test category-specific retention. At minimum:

- transient AI request bodies are not retained by the application service by default;
- server state records purpose, creation time, and deletion scope;
- users can delete account, social state, and server-held history;
- local deletion clears caches, queued transfers, and derived state, subject to explicit user confirmation;
- backups, observability, and tombstone retention are documented honestly;
- deletion propagates to processors under applicable agreements.

## Logging and analytics

Allowed examples:

```text
health_sync_completed sample_count=12 source_count=2
rule_evaluated rule_id=recovery.v1 outcome=eligible
narration_failed category=timeout fallback=local_template
```

Disallowed examples:

```text
heart_rate=... user_id=...
prompt="User slept ..."
Authorization: Bearer ...
friend_summary="..."
```

Development diagnostics use synthetic fixtures. Any user-exported support bundle must be explicit, previewable, redacted, and time limited.

## Release checklist

- Review HealthKit usage descriptions against actual behavior.
- Verify the public privacy policy and App Privacy answers.
- Inventory every SDK, endpoint, processor, retention period, and deletion path.
- Confirm upstream AI data-use settings and contractual terms.
- Confirm no provider key exists in an application artifact or repository history.
- Test partial permission, revoked permission, account deletion, friend removal, and sharing-scope downgrade.
