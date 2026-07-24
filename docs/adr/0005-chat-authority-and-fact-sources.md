# ADR 0005: Chat authority and fact sources

- Status: Accepted
- Date: 2026-07-24

## Context

The iPhone app will support multi-turn conversation with Mori. Conversation
should deepen companionship, but a remote model must not invent sensor facts,
diagnose health, change product state, or receive a raw personal timeline.
The existing `/v1/narrations` endpoint is a bounded one-shot memory-writing
contract and is not a multi-turn chat API.

## Decision

Chat is a separately versioned, text-only contract. Its request distinguishes
two sources:

1. `UserConversationContext` is the message the person explicitly sends plus a
   bounded recent window of user and assistant messages. This text may contain
   information the person typed; the UI discloses remote processing before the
   first send. A best-effort local scanner blocks recognized credentials and
   warns on likely contact/location identifiers, but the product does not claim
   perfect DLP.
2. `AppAddedContext` is a strict schema containing current Mori identity,
   user-controlled tone, approved derived companion events, stable memory
   references, and at most one explicitly selected memory excerpt of 500 Unicode
   scalars. It is included only while the corresponding `GlobalConsentState`
   revision permits it.

A local conversation summary supports local search and fallback but is not sent
to the remote Chat service in this Goal. The app never automatically enriches a
message with contacts, precise location, routes, hidden permission state,
internal numeric confidence, raw HealthKit samples, secrets, or unbounded
history.

The model may:

- answer conversationally using supplied facts;
- refer to an approved memory;
- produce a non-authoritative candidate for a Mori task or future expression.

The model may not:

- mutate tasks, coins, collection, memories, permissions, reminders, profiles,
  or synchronization state;
- call state-changing tools;
- diagnose, score, or judge health;
- claim an observation absent from the supplied envelope.

A task candidate is untrusted input. The local rule engine revalidates source
event, confidence, cooldown, visibility capacity, reward, profile, and safety
before it can become a `TaskInstance`. Invalid responses are discarded.

Provider, model, timeout, retry, rate, and cost limits are explicit
configuration. A local template and offline conversation state remain
available when the service is unavailable. Microphone capture, speech
recognition, and audio generation are outside this Goal.

The remote processor, purpose, retention behavior, and applicable no-training
or zero-retention setting are disclosed in the public privacy material before
remote Chat is enabled. Requests use a stateless application gateway with
`no-store` semantics; no server-side conversation history is assumed.

## Retention and deletion

Conversation is stored in the active `ProfileState`. Real and Mock histories are
isolated, and Mock Chat never calls the production remote provider.

Clearing conversation removes messages, the local summary, response cache,
request drafts, and context index. It does not delete memories. Deleting a
memory removes it from the context index and every future prompt; a historical
assistant message that mentioned it remains conversation text until the person
clears conversation. Global deletion follows
`docs/mori-data-deletion-contract.md`, including any enabled processor
acknowledgement. Logs contain request IDs and redacted error classes, not
message bodies or personal context.

## Consequences

Chat cannot be the source of product truth, even when its language sounds
confident. This limits autonomous behavior but preserves deterministic rewards,
privacy, and offline operation.

## Validation

- Contract tests separate explicit user text from app-added context and reject
  forbidden app-context keys, oversized windows, unknown schemas, recognized
  credentials, and state-changing tool requests.
- Adversarial fixtures attempt to invent health facts, grant coins, alter
  permissions, and bypass task cooldowns.
- Timeout, malformed output, rate-limit, and offline tests use local fallback.
- E2E verifies conversation retention, clearing, profile isolation, and
  deletion without sending raw sensor data. It also proves memory-context
  revocation and memory deletion remove future references.
