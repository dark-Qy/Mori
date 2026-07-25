# Product

## Register

product

## Users

Mori serves people who wear an Apple Watch and want a quiet virtual companion
rather than another fitness dashboard. The primary context is short wrist
glances while moving through daily life. The iPhone is the deeper surface for
conversation, tasks, memories, collection management, permissions, and
development data.

The current audience is the development and evaluation team. Real Apple Health
data and isolated Mock profiles are both first-class inputs during development.

## Product Purpose

Mori turns locally derived activity, sleep, location, and interaction evidence
into small moments of companionship, optional tasks, cosmetic rewards, and
shared memories. Bounded health context, small controllable actions, story
events, and trusted social signals should form a sustainable relationship that
remains useful without AI or network availability.

The product succeeds when Mori feels present without demanding attention:
useful events appear naturally, uncertain inferences remain quiet, health data
does not become a score, and the user can understand or disable every source of
interruption. Memories should make later moments more personal and weekly
reflection should help the person notice their own patterns without diagnosis
or blame.

Mori is not a medical product, a sports tracker, a traditional task manager, or
an RPG progression system.

## Brand Personality

Gentle, intimate, alive, restrained, and quietly adventurous.

Mori speaks with warmth and specific shared context. The voice is observant
without pretending certainty, playful without becoming childish, and supportive
without judging health outcomes. The experience should feel like a well-kept
illustrated field journal shared with a familiar companion.

## Anti-references

- Card-heavy dashboards that shrink an iPhone app onto the Watch.
- Fitness apps centered on rings, trends, health scores, or performance verdicts.
- Traditional to-do lists with many equally prominent tasks.
- RPG interfaces built around levels, XP, vitality, streak pressure, or punishment.
- Constant haptics, noisy alerts, and visible numerical confidence scores.
- Chatbots that invent sensor facts or claim authority over tasks, rewards, or
  permissions.
- Decorative UI that replaces native Apple affordances with unfamiliar controls.
- Generated stories or decorative AI copy that change Mori's identity, invent
  facts, or disconnect from recorded events.
- Guilt, urgency, or pet harm caused by missing data, missed tasks, or health
  outcomes.

## Design Principles

1. **Companion before dashboard.** Mori and the shared world are the primary
   surface; data appears only when it strengthens the relationship.
2. **Watch for presence, iPhone for depth.** Watch interactions stay glanceable
   and passive. Conversation, history, privacy, collections, weekly reflection,
   and management live on iPhone.
3. **Earn every claim.** Exact facts may be stated directly, uncertain
   interpretations use natural tentative language, and low-confidence
   inferences remain silent. Rules and recorded events own observations,
   rewards, memory authority, and safety.
4. **Quiet is a valid behavior.** Reminder mode, quiet hours, expiry, cooldowns,
   and replacement rules outrank the desire to show more content.
5. **Reward controllable actions, never health outcomes.** Tasks may be detected
   or confirmed, but sleep, recovery, or other outcomes never cause punishment.
6. **Local and minimal by default.** Prefer on-device inference and synchronize
   only approved derived experience events, never raw HealthKit payloads or
   precise GPS tracks. A remote conversation necessarily receives the message
   the person explicitly sends and a bounded recent conversation window.
   App-added context is limited to separately consented approved derived facts
   and memory references. When memory context is separately enabled, one
   explicitly selected excerpt of at most 500 Unicode scalars may accompany its
   reference and is invalidated by revocation or memory deletion.
7. **Every memory earns continuity.** A memory must reduce repetition, support
   reflection, or make a later event visibly more personal. Mock weekly reports
   use deterministic reviewed copy and build-time image2 assets.

## Accessibility & Inclusion

- Support VoiceOver, Dynamic Type, increased contrast, Reduce Motion, and
  non-color state cues.
- Long press, touch regions, haptics, and wrist activation must have visible and
  assistive alternatives.
- Watch layouts must remain usable on the smallest supported display.
- Haptics accompany but never replace visual or textual feedback.
- Missing, denied, partial, stale, and unavailable health or location data remain
  neutral.
- Language must avoid medical conclusions, moral judgment, and pressure based on
  health results.
- Essential facts never live only inside generated artwork; every memory remains
  understandable through native text and an accessible description.
