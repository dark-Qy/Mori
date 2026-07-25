# Approved Mori rebuild references

These files are the repository-owned copies of the Image2 concepts approved in
the product review that led to the Mori rebuild Goal.

- Approval state: approved as product-direction references
- Approval date: 2026-07-24 repository capture
- Runtime use: reference only; these composites are not shipped as application
  UI or character assets
- Future visual review: use Image2 only, then add the selected output and its
  exact prompt to this directory before implementation

The source PNG files do not embed their original conversation prompts. The
prompts below are therefore canonical regeneration briefs reconstructed from the
approved decisions, not claimed verbatim originals.

## Reference index

| File | SHA-256 | Approved use | Do not copy literally |
| --- | --- | --- | --- |
| `watch-home-data-corners.png` | `80963e9e1c8e1a3a0fd2d3208fac26b6f9abc5e13bec01ac77491aef42cac764` | Full-bleed Watch home, Mori centered, sleep upper-left, steps lower-right | Fixed night/moon scene, decorative frame outside the app |
| `watch-home-companion-settings-approved.png` | `f4670900d7b138c7117e915c886066efc0257108df88d7c576c491db3736bcfc` | Subtle `Mori 随行中` entry and native reminder-mode settings | Card-heavy home, manual sync, ambiguous companion toggle copy |
| `watch-daily-memory.png` | `5d64a21c31e5100c1fa7e968d7076cf53f9ce76359a1f2962d49904ebe3dd4e1` | Best-effort 22:00 notification and immersive daily-memory scene | Treating delivery time as guaranteed, a fitness-report dashboard |
| `watch-event-lifecycle.png` | `56cdda4a4cc5af1fca489fd2330e768cbc7880c957294bd0f8250d158ff3cb23` | Brief foreground speech bubble, expiry, and replacement behavior | A two-minute bubble or queued old reminders |
| `iphone-core-surfaces.png` | `7f9beae475d97f62354909ef8f2c169c6ed37c242445abfd124a50fd60ccf335` | Memory timeline, collection direction, native grouped Settings | The pictured legacy four-tab labels or task-free iPhone scope as final IA |

## Canonical Image2 regeneration brief

Create a high-fidelity Apple Watch and iPhone product-design reference for a
quiet virtual companion named Mori. Use native Apple information architecture,
system typography, controls, lists, navigation, accessibility spacing, and
platform-appropriate safe areas. Avoid stacked dashboard cards, glass effects,
levels, XP, vitality, health scores, streak pressure, manual synchronization,
and visible confidence percentages.

The identity layer is crisp pixel art: a full-bleed natural world with one Mori
character as the primary subject. The Watch home shows only a small sleep fact
at the upper-left, a step fact at the lower-right, and a subtle `Mori 随行中`
entry at the bottom. Mori can look, walk, sit, react, and show one brief compact
speech bubble. Long press opens Today, Mori letters, Touch Exchange, and
Settings. Reminder mode uses a native settings list with `抬腕提醒` and
`轻震提醒`, plus quiet hours.

At night, show a best-effort daily-memory notification followed by an immersive
shared-memory scene with concise prose, step count, and completed sleep
duration. Do not make it a health dashboard.

The iPhone has four tabs: `Mori`, `今天`, `回忆`, and `收藏`; Settings is opened
from a gear. Mori is the conversation home and never contains tasks. Today has
one dominant recommendation and a few compact secondary tasks. Memories form a
chronological story timeline. Collection contains coin balance and cosmetics.
Settings uses native grouped lists and contains permissions, companion sensing,
reminder behavior, data management, and Debug-only Mock profile controls.

Render Simplified Chinese copy legibly. Show light and dark adaptive behavior
where useful. The output is a product reference sheet, not a marketing poster.

## Behavior annotations

### Watch home

- The scene changes with time and context; Mori cannot permanently stare at
  either metric.
- Exact sleep and step facts remain secondary to Mori.
- Tapping `Mori 随行中` opens reminder behavior and quiet hours.
- Tapping Mori gives a small response. Long press has a visible and VoiceOver
  alternative.
- A pending event is eligible for at most two minutes and appears once on the
  next foreground activation. The bubble itself is brief.

### Daily memory

- The iPhone is the only notification-scheduling authority.
- Watch renders the sealed shared record and may transiently show `正在整理`.
- Late evidence does not silently rewrite a sealed memory.
- Notification delivery is best-effort and obeys quiet hours.

### iPhone

- The `Mori` tab is conversation and presence, not a task list.
- `今天` owns the recommendation and manual confirmations.
- Coins appear in collection and task settlement, never on the Watch home.
- Real and Mock profiles are visibly distinguishable in Developer Options and
  never share state.
