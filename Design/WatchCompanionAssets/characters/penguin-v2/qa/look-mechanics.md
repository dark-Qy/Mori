# Penguin look-direction mechanics

The sixteen v2 look directions are a clock-face sweep used for attention cues, not locomotion.

- Keep the feet and lower body on the same baseline in every direction.
- Lead with the blue-gray eyes, then add a restrained head, neck, and upper-body turn.
- Preserve the face opening, navy penguin hood, white hood eyes, yellow beak, black bob, blunt bangs,
  turquoise X hair clip, patterned neck bow/scarf, white belly, flipper sleeves, and yellow feet.
- Keep silhouette width, overall height, head-to-body ratio, and costume volume stable.
- The hair clip remains on the character's left side and must not mirror between directions.
- Do not rotate or warp the entire sprite, move the feet, introduce scenery, add detached effects, or
  bake direction labels into a runtime frame.
- Adjacent directions must read as one smooth clockwise sweep at normal Watch display size.

Clockwise order:

1. `down`
2. `down-right`
3. `right`
4. `up-right`
5. `up`
6. `up-left`
7. `left`
8. `down-left`
9. `down-slight-right`
10. `right-slight-down`
11. `right-slight-up`
12. `up-slight-right`
13. `up-slight-left`
14. `left-slight-up`
15. `left-slight-down`
16. `down-slight-left`
