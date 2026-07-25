# Mori Conversation G7 Handoff

## Delivered Scope

G7 is a Mock-first conversation checkpoint for the iPhone app. It provides a
deterministic, local-only conversation loop with streaming presentation,
cancellation, retry, bounded persistence, privacy scanning, explicit warning
confirmation, and deterministic failure modes. It cannot make a network
request, mutate a task, grant coins, or present a Mock reply as a production
service.

The production transport remains deliberately unavailable. The real-mode UI
states this directly and does not fall back to the local Mock responder.

## Runtime Boundaries

- Chat V1 is separate from passive Mori narration.
- A repository is bound to one complete `RuntimeProfile`, including profile,
  selection, and deletion epochs.
- Requests capture the profile, conversation clear generation, request and
  client-turn IDs, and relevant consent revisions.
- Recent context is limited to 12 messages; explicit messages, memory excerpts,
  replies, requests, responses, and stored state each have independent bounds.
- The local summary stores roles only, not message text.
- Audit events store request IDs and outcomes only.
- Credentials fail closed. Contact details and precise coordinates require
  explicit confirmation.
- Composer drafts are never persisted by the iPhone UI.

## Mock And Real Isolation

The deterministic transport and its fault selector compile only in Debug.
Mock conversation text is stored in the selected Mock profile namespace. Its
memory-context choice is stored in the same Mock experience generation and is
served by a profile-local authority; it does not mutate global production
consent.

Real mode constructs only `UnavailableRemoteChatTransport`. Enabling a real
provider later requires a separate security and product checkpoint.

## Clear, Reset, And Deletion

- Clearing conversation requires confirmation and preserves shared memories.
- Repository writes use on-disk revision checks. A stale instance refreshes or
  fails closed instead of replacing newer state.
- Artifact retirement is fence-first and does not decode private content.
- A content-free global retirement manifest lives outside `profiles` and
  invalidates active and inactive old conversation writers before namespace
  deletion.
- Resetting the selected Mock waits for its conversation task to stop, removes
  the owned old namespace, advances the Mock profile generation, and starts
  with fresh state.

## Debug Fault Modes

Pass exactly one Debug launch argument:

```text
--chat-behavior=normal
--chat-behavior=offline
--chat-behavior=timedOut
--chat-behavior=rateLimited
--chat-behavior=providerFailure
--chat-behavior=malformedResponse
--chat-behavior=oversizedResponse
--chat-behavior=slowStream
```

Release boundary checks reject this selector.

## Internal Physical-Device AI And Speech Preview

The real provider key never belongs in the app. For an internal Debug build,
configure a separate client-to-gateway token:

1. Set the server's `NARRATION_GATEWAY_ACCESS_TOKEN` to a distinct random value.
2. In the Xcode `WatchCompanion` Run scheme, add the same value under the
   `MORI_WEEKLY_AI_GATEWAY_TOKEN` environment variable.
3. Run the Debug app on the iPhone once from Xcode. The app stores that gateway
   token in a Debug-only, this-device-only Keychain service so later Debug
   launches from the Home Screen do not depend on Xcode's process environment.
4. Enable the remote Chat preview and send a synthetic message. A committed
   Mori reply gives the client a one-time request ID for one best-effort call
   to `/ai/v1/audio/speech`; reply text is not resubmitted by the app. The MP3
   plays only while the iPhone app is active and the Mori tab is visible, and
   respects Silent Mode.

The token in steps 1–3 is not `NARRATION_UPSTREAM_API_KEY`. A provider key that
has appeared in chat, logs, or screenshots must be revoked and replaced before
server testing. UI-test runs keep speech disabled unless
`--enable-chat-tts` is supplied.

Archive/TestFlight/Release remains outside this Debug preview: the remote
conversation transport, stored Debug credential, and TTS transport are
intentionally fenced off.
Production requires per-user or per-device short-lived credentials rather than
shipping the shared development gateway token in the app bundle.

## Required Before A Real Provider

The following are intentionally not claimed by G7:

1. A bounded raw-wire decoder that rejects unknown or oversized fields before
   allocation.
2. An authenticated gateway, provider adapter, retention policy, abuse policy,
   rate and cost controls, and key management.
3. A profile-ledger-owned context builder that validates selected memory and
   approved event IDs by exact ID and revision.
4. An authority-bound final reply commit across consent, memory deletion, and
   repository state.
5. Durable retry journaling for a rare local filesystem cleanup failure.
6. Physical-device, paired-device, background, network, and energy validation.

Do not replace these gates with Mock evidence.
