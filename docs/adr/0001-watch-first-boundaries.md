# ADR 0001: Watch-first product and authority boundaries

- Status: Accepted
- Date: 2026-07-23

## Context

The concept began with multiple possible hardware and display surfaces, health interpretation, a virtual pet, proactive AI, and nearby social interaction. Supporting every surface would weaken the primary experience and create technical claims that third-party watchOS applications cannot reliably satisfy.

Health-derived gameplay also requires a strict boundary between deterministic product facts and probabilistic expression. AI-generated text, random timing, and unavailable device capabilities must not corrupt game state, privacy, or user trust.

## Decision

### Product surfaces

Apple Watch is the primary interaction surface for the pet, habits, story, notifications, haptics, and later mutual social interactions. iPhone is a simple companion for settings, privacy, history, collections, and cosmetic wardrobe management.

The product does not include:

- desktop pets or external displays;
- ring integration;
- NFC data exchange;
- a phone-first duplicate game.

### Authority

Deterministic rules and reducers own facts, story transitions, growth, rewards, commitments, eligibility, consent, sharing scopes, quiet hours, and notification limits.

Seeded randomness may select the timing or presence of an eligible optional event. It cannot create eligibility, alter rewards, change the common main story, or bypass safety constraints.

AI may generate bounded expression after an authoritative transition. It cannot modify state, diagnose health, schedule notifications, change permissions, or perform social actions. Invalid or unavailable AI falls back to local templates.

### Health and mocks

Health data is minimized, normalized, and interpreted with provenance, freshness, and uncertainty. Missing data is neutral. Remote narration receives a bounded context rather than entire history.

When Personal Team restrictions, simulator limits, missing devices, or unavailable services prevent a capability, development uses a deterministic mock with persistent visible labeling. No mock result is reported as physical-device verification.

### Social connection

Friendship requires mutual confirmation. Health-sharing scope is directional and controlled by the data owner. Nearby Interaction, if device verified later, supplies proximity evidence only; it does not discover peers, transfer business data, establish identity, or replace consent.

## Consequences

### Positive

- The essential loop can function offline and on the Watch.
- Rules can be replayed, tested, and audited independently of UI and AI.
- Health privacy and degraded behavior are explicit architectural concerns.
- The iPhone app remains useful without displacing the Watch experience.
- Mocks unblock development without overstating hardware capability.

### Costs

- Deterministic state, versioned events, and dependency injection require more initial structure.
- AI text must pass schema and safety validation and may be discarded.
- Some experiences require separate physical-device spikes before release.
- Desktop, ring, NFC, and phone-first opportunities are intentionally declined.

## Replacement criteria

Changing a boundary requires a replacement ADR with:

- a concrete user need that cannot be served inside the accepted surfaces;
- official platform evidence and physical-device validation where applicable;
- privacy and data-flow analysis;
- deterministic fallback behavior;
- migration, test, and maintenance costs.

Convenience, novelty, or the presence of hardware alone is not sufficient.
