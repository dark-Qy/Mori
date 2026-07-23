# Mori Design System

## Intent

The interface should feel like Mori lives inside an Apple product. Native
navigation, lists, typography, controls, accessibility, and platform behavior
provide familiarity. Pixel-art scenes and character motion provide identity.

Cards are used only when they represent a real bounded object such as one
recommended task. They are not the default layout primitive.

## Platforms

### Apple Watch

- The home is a full-bleed pixel-art world with Mori as the primary subject.
- Sleep appears at the upper left, steps at the lower right, and the subtle
  `Mori 随行中` entry appears at the bottom.
- The home never shows tasks, levels, vitality, XP, health status cards, trends,
  manual synchronization, or coin balance.
- An event remains eligible for the next foreground activation for at most two
  minutes. Once presented, it is consumed and expressed by Mori's motion and one
  brief compact speech bubble over the world, not a modal card.
- Tapping `Mori 随行中` opens reminder behavior and quiet hours.
- Long pressing Mori opens `今天`, `Mori 来信`, `碰一碰`, and `设置`.
- `今天` emphasizes one recommendation and keeps any additional tasks compact.
- The daily memory is an immersive night scene, not a fitness report.
- Settings use native watchOS lists. Companion reminder settings and special
  data settings are separate destinations.

### iPhone

- The primary tab bar is `Mori`, `今天`, `回忆`, and `收藏`.
- Settings opens from a gear action and is not a fifth tab.
- `Mori` is the conversation home and never contains a task list.
- `今天` contains one dominant recommendation, a small number of secondary
  tasks, completion summary, and today's memory.
- `回忆` is a chronological story timeline led by imagery and prose. Step and
  sleep facts remain secondary.
- `收藏` shows the coin balance and cosmetic clothing, accessories, and scenes.
- Settings uses standard pushed pages and grouped lists without decorative
  containers.

## Color

Use adaptive system backgrounds and labels for application chrome. Preserve the
existing semantic accents:

- mint: positive companion state and confirmed selection;
- blue: navigation and informational action;
- gold: coins and cosmetic value only;
- rose: destructive or safety-significant state.

Pixel-art scenes carry most of the palette. Inactive controls remain neutral.
Text contrast must meet 4.5:1 for body text and 3:1 for large text.

## Typography

Use the system font on both platforms. Prefer native text styles and Dynamic
Type over fixed custom sizes. UI labels use one family and a restrained type
scale. Chinese copy must be checked at the largest supported accessibility size
for truncation and reading order.

## Layout And Components

- Prefer full-bleed imagery, native lists, timelines, separators, and inline
  sections over repeated cards.
- Do not nest cards.
- Use a single component vocabulary for task rows, coin rewards, memory facts,
  data-source rows, and error states.
- Footprint icons represent steps only. Every reward uses the gold coin symbol.
- The recommended task may use one bounded elevated surface; secondary tasks are
  rows.
- Loading uses content-shaped placeholders where practical. Empty and denied
  states explain the next safe action.

## Motion

- Character motion communicates presence, attention, inference, interaction,
  task state, reward, reflection, and rest.
- Runtime character clips share stable identity, canvas, scale, baseline, and
  action identifiers across Watch and iPhone.
- Pixel art is rendered without smoothing.
- Product transitions normally complete in 150–250 ms. Character clips may run
  at their authored cadence.
- Reduce Motion selects a semantic key frame or a short cross-fade.
- Haptics are optional and governed by reminder mode and quiet hours.
- No bounce, elastic choreography, detached effects, or decorative page-load
  animation.

## Character Variants

The black penguin Mori and white polar-bear Mori are independent identities.
They share one semantic action catalog and receive complete authored semantic
coverage through validated unique clips, aliases, poses, and policies. One
character is never produced by recoloring or deforming the other.

Every required action defines:

- stable action identifier and product trigger;
- loop or one-shot behavior;
- frame rate and completion behavior;
- Reduce Motion key frame;
- optional haptic policy;
- supported interaction and accessibility alternative.

## Accessibility

- Every interactive element has a stable accessibility identifier, label, hint,
  trait, and adequate hit region.
- Long press has an accessibility action or visible alternate path.
- Speech bubbles expose their text independently of the scene image.
- State does not depend on color, motion, or haptics alone.
- Verify small and large Watch sizes, iPhone light and dark appearance, increased
  contrast, accessibility text sizes, VoiceOver order, and Reduce Motion.

## Prohibited Patterns

- Watch dashboards made from stacked cards.
- Levels, XP, vitality, health scores, or streak pressure.
- Tasks on either Mori home.
- Numerical confidence shown to the user.
- Manual sync, sync testing, or simulated sync-failure controls in product UI.
- Raw GPS tracks or raw HealthKit payloads in memories, chat context, logs, or
  cross-device synchronization.
- Cosmetic items that change health, task, or reward statistics.
