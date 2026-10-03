# Contrast of the labels on the photo

Made by `make contrast` (D-01, `scripts/contrast-report.py`). Do not edit it by hand.

**How it is measured.** The `contrast` bench scenario opens each test frame (`scripts/make-contrast-frames.py`) at 1:1 in Loupe and in Compare, with every label on: the info strip at its last level (name, EXIF panel, histogram), and with the strip off (rating corner, truth badge); peaking, clipping and Auto-advance throughout. The overlays are analyzed but not painted, so each label sits on the bare frame. On the split frame the edge between white and black is moved under each label in turn. The window is captured with the labels' text and symbols hidden. Inside each label's shape, inset by 2 pt, the brightest 1% of the pixels (in sRGB) is the worst plate. Each color drawn on the label is composited over it and compared by the WCAG formula.

**Rules.** Text keeps 4.5:1 and a mark (an icon, a star) keeps 3:1, on every frame. A value with `m` is a mark; the others are text. A fail is bold with ✗. Each value is the worst over both layouts, both Compare panes and every edge position. Inks: `secondary` is white at 85%, `star` the system yellow, `warning` `Plate.warning`, `reject` `Plate.reject`, `accent` the accent color, `cyan` the histogram's shadow percent, all as resolved in the dark appearance.

## Dark appearance, Reduce Transparency off, Increase Contrast off

2026-10-03, window 1470 x 923 pt at 2x, 58 captures. All 105 rows pass.

Inks: white=#FFFFFF  secondary=#FFFFFF@0.85  star=#FFD600  warning=#FFAD33  reject=#FF9E99  accent=#007AFF  cyan=#3CD3FE

| Mode | Label | Material | Worst plate (frame) | white | secondary | star | warning | reject | accent | cyan | Result |
| --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| loupe | auto-advance | glass, regular, black 50% | #616161 L 0.119 (white) |  | 5.0 |  |  |  |  |  | pass |
| loupe | clipping | glass, regular, black 50% | #616161 L 0.119 (white) |  | 5.0 |  |  |  |  |  | pass |
| loupe | exif-panel | plate, black 70% | #4C4C4C L 0.072 (white) | 8.5 | 6.7 |  |  |  |  |  | pass |
| loupe | histogram | plate, black 70% | #4C4C4C L 0.072 (white) |  | 6.7 |  | 4.6 |  |  | 4.8 | pass |
| loupe | info-strip | plate, black 70% | #4C4C4C L 0.072 (white) | 8.5 | 6.7 | 6.0 m | 4.6 m | 4.3 m |  |  | pass |
| loupe | peaking | glass, regular, black 50% | #616161 L 0.119 (white) |  | 5.0 |  |  |  |  |  | pass |
| loupe | rating-corner | glass, regular, black 50% | #616161 L 0.119 (white) |  | 5.0 | 4.3 m |  | 3.1 m |  |  | pass |
| loupe | truth-badge | glass, regular, black 50% | #616161 L 0.119 (white) | 6.1 |  |  | 3.3 m |  |  |  | pass |
| compare | auto-advance | glass, regular, black 50% | #616161 L 0.119 (white) |  | 5.0 |  |  |  |  |  | pass |
| compare | clipping | glass, regular, black 50% | #616161 L 0.119 (white) |  | 5.0 |  |  |  |  |  | pass |
| compare | info-strip | plate, black 70% | #4C4C4C L 0.072 (white) | 8.5 | 6.7 | 6.0 m | 4.6 | 4.3 m |  |  | pass |
| compare | pane-title | glass, regular, black 50% | #606060 L 0.117 (white) | 6.2 | 5.0 m |  |  |  |  |  | pass |
| compare | peaking | glass, regular, black 50% | #616161 L 0.119 (white) |  | 5.0 |  |  |  |  |  | pass |
| compare | rating-corner | glass, regular, black 50% | #5F5F5F L 0.114 (white) |  | 5.1 | 4.5 m |  | 3.2 m |  |  | pass |
| compare | truth-badge | glass, regular, black 50% | #606060 L 0.117 (white) | 6.2 |  |  | 3.3 m |  |  |  | pass |

<details><summary>Every label on every frame</summary>

| Mode | Label | Frame | Plate | L | white | secondary | star | warning | reject | accent | cyan | Result |
| --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| loupe | auto-advance | white | #616161 | 0.1195 |  | 5.0 |  |  |  |  |  | pass |
| loupe | auto-advance | black | #161616 | 0.0080 |  | 13.2 |  |  |  |  |  | pass |
| loupe | auto-advance | gray18 | #444444 | 0.0578 |  | 7.5 |  |  |  |  |  | pass |
| loupe | auto-advance | yellow | #705C00 | 0.1110 |  | 5.2 |  |  |  |  |  | pass |
| loupe | auto-advance | red | #9C1610 | 0.0768 |  | 6.3 |  |  |  |  |  | pass |
| loupe | auto-advance | checker | #484848 | 0.0648 |  | 7.1 |  |  |  |  |  | pass |
| loupe | auto-advance | split | #616161 | 0.1195 |  | 5.0 |  |  |  |  |  | pass |
| loupe | clipping | white | #616161 | 0.1195 |  | 5.0 |  |  |  |  |  | pass |
| loupe | clipping | black | #161616 | 0.0080 |  | 13.2 |  |  |  |  |  | pass |
| loupe | clipping | gray18 | #444444 | 0.0578 |  | 7.5 |  |  |  |  |  | pass |
| loupe | clipping | yellow | #705C00 | 0.1110 |  | 5.2 |  |  |  |  |  | pass |
| loupe | clipping | red | #9C1610 | 0.0768 |  | 6.3 |  |  |  |  |  | pass |
| loupe | clipping | checker | #474747 | 0.0630 |  | 7.2 |  |  |  |  |  | pass |
| loupe | clipping | split | #616161 | 0.1195 |  | 5.0 |  |  |  |  |  | pass |
| loupe | exif-panel | white | #4C4C4C | 0.0723 | 8.5 | 6.7 |  |  |  |  |  | pass |
| loupe | exif-panel | black | #000000 | 0.0000 | 21.0 | 14.8 |  |  |  |  |  | pass |
| loupe | exif-panel | gray18 | #232323 | 0.0168 | 15.7 | 11.6 |  |  |  |  |  | pass |
| loupe | exif-panel | yellow | #4C410B | 0.0534 | 10.1 | 7.8 |  |  |  |  |  | pass |
| loupe | exif-panel | red | #4D0806 | 0.0176 | 15.5 | 11.3 |  |  |  |  |  | pass |
| loupe | exif-panel | checker | #4C4C4C | 0.0723 | 8.5 | 6.7 |  |  |  |  |  | pass |
| loupe | exif-panel | split | #4C4C4C | 0.0723 | 8.5 | 6.7 |  |  |  |  |  | pass |
| loupe | histogram | white | #4C4C4C | 0.0723 |  | 6.7 |  | 4.6 |  |  | 4.8 | pass |
| loupe | histogram | black | #000000 | 0.0000 |  | 14.8 |  | 11.3 |  |  | 11.9 | pass |
| loupe | histogram | gray18 | #232323 | 0.0168 |  | 11.6 |  | 8.4 |  |  | 8.9 | pass |
| loupe | histogram | yellow | #4C410B | 0.0534 |  | 7.8 |  | 5.4 |  |  | 5.7 | pass |
| loupe | histogram | red | #4D0806 | 0.0176 |  | 11.3 |  | 8.3 |  |  | 8.8 | pass |
| loupe | histogram | checker | #4C4C4C | 0.0723 |  | 6.7 |  | 4.6 |  |  | 4.8 | pass |
| loupe | histogram | split | #4C4C4C | 0.0723 |  | 6.7 |  | 4.6 |  |  | 4.8 | pass |
| loupe | info-strip | white | #4C4C4C | 0.0723 | 8.5 | 6.7 | 6.0 m | 4.6 m | 4.3 m |  |  | pass |
| loupe | info-strip | black | #000000 | 0.0000 | 21.0 | 14.8 | 14.8 m | 11.3 m | 10.6 m |  |  | pass |
| loupe | info-strip | gray18 | #232323 | 0.0168 | 15.7 | 11.6 | 11.1 m | 8.4 m | 7.9 m |  |  | pass |
| loupe | info-strip | yellow | #4C410B | 0.0534 | 10.1 | 7.8 | 7.1 m | 5.4 m | 5.1 m |  |  | pass |
| loupe | info-strip | red | #4D0806 | 0.0176 | 15.5 | 11.3 | 10.9 m | 8.3 m | 7.8 m |  |  | pass |
| loupe | info-strip | checker | #4C4C4C | 0.0723 | 8.5 | 6.7 | 6.0 m | 4.6 m | 4.3 m |  |  | pass |
| loupe | info-strip | split | #4C4C4C | 0.0723 | 8.5 | 6.7 | 6.0 m | 4.6 m | 4.3 m |  |  | pass |
| loupe | peaking | white | #616161 | 0.1195 |  | 5.0 |  |  |  |  |  | pass |
| loupe | peaking | black | #161616 | 0.0080 |  | 13.2 |  |  |  |  |  | pass |
| loupe | peaking | gray18 | #444444 | 0.0578 |  | 7.5 |  |  |  |  |  | pass |
| loupe | peaking | yellow | #705C00 | 0.1110 |  | 5.2 |  |  |  |  |  | pass |
| loupe | peaking | red | #9C1610 | 0.0768 |  | 6.3 |  |  |  |  |  | pass |
| loupe | peaking | checker | #484848 | 0.0648 |  | 7.1 |  |  |  |  |  | pass |
| loupe | peaking | split | #616161 | 0.1195 |  | 5.0 |  |  |  |  |  | pass |
| loupe | rating-corner | white | #616161 | 0.1195 |  | 5.0 | 4.3 m |  | 3.1 m |  |  | pass |
| loupe | rating-corner | black | #161616 | 0.0080 |  | 13.2 | 12.8 m |  | 9.1 m |  |  | pass |
| loupe | rating-corner | gray18 | #444444 | 0.0578 |  | 7.5 | 6.9 m |  | 4.9 m |  |  | pass |
| loupe | rating-corner | yellow | #705C00 | 0.1110 |  | 5.2 | 4.6 m |  | 3.3 m |  |  | pass |
| loupe | rating-corner | red | #9C1610 | 0.0768 |  | 6.3 | 5.8 m |  | 4.1 m |  |  | pass |
| loupe | rating-corner | checker | #484848 | 0.0648 |  | 7.1 | 6.4 m |  | 4.6 m |  |  | pass |
| loupe | rating-corner | split | #616161 | 0.1195 |  | 5.0 | 4.3 m |  | 3.1 m |  |  | pass |
| loupe | truth-badge | white | #616161 | 0.1195 | 6.1 |  |  | 3.3 m |  |  |  | pass |
| loupe | truth-badge | black | #161616 | 0.0080 | 18.1 |  |  | 9.7 m |  |  |  | pass |
| loupe | truth-badge | gray18 | #454545 | 0.0595 | 9.5 |  |  | 5.1 m |  |  |  | pass |
| loupe | truth-badge | yellow | #705C00 | 0.1110 | 6.5 |  |  | 3.5 m |  |  |  | pass |
| loupe | truth-badge | red | #9C1610 | 0.0768 | 8.2 |  |  | 4.4 m |  |  |  | pass |
| loupe | truth-badge | checker | #484848 | 0.0648 | 9.1 |  |  | 4.9 m |  |  |  | pass |
| loupe | truth-badge | split | #616161 | 0.1195 | 6.1 |  |  | 3.3 m |  |  |  | pass |
| compare | auto-advance | white | #616161 | 0.1195 |  | 5.0 |  |  |  |  |  | pass |
| compare | auto-advance | black | #171717 | 0.0086 |  | 13.1 |  |  |  |  |  | pass |
| compare | auto-advance | gray18 | #444444 | 0.0578 |  | 7.5 |  |  |  |  |  | pass |
| compare | auto-advance | yellow | #705C00 | 0.1110 |  | 5.2 |  |  |  |  |  | pass |
| compare | auto-advance | red | #9C1612 | 0.0769 |  | 6.3 |  |  |  |  |  | pass |
| compare | auto-advance | checker | #484848 | 0.0648 |  | 7.1 |  |  |  |  |  | pass |
| compare | auto-advance | split | #616161 | 0.1195 |  | 5.0 |  |  |  |  |  | pass |
| compare | clipping | white | #616161 | 0.1195 |  | 5.0 |  |  |  |  |  | pass |
| compare | clipping | black | #161616 | 0.0080 |  | 13.2 |  |  |  |  |  | pass |
| compare | clipping | gray18 | #444444 | 0.0578 |  | 7.5 |  |  |  |  |  | pass |
| compare | clipping | yellow | #705C00 | 0.1110 |  | 5.2 |  |  |  |  |  | pass |
| compare | clipping | red | #9C1610 | 0.0768 |  | 6.3 |  |  |  |  |  | pass |
| compare | clipping | checker | #474747 | 0.0630 |  | 7.2 |  |  |  |  |  | pass |
| compare | clipping | split | #616161 | 0.1195 |  | 5.0 |  |  |  |  |  | pass |
| compare | info-strip | white | #4C4C4C | 0.0723 | 8.5 | 6.7 | 6.0 m | 4.6 | 4.3 m |  |  | pass |
| compare | info-strip | black | #000000 | 0.0000 | 21.0 | 14.8 | 14.8 m | 11.3 | 10.6 m |  |  | pass |
| compare | info-strip | gray18 | #232323 | 0.0168 | 15.7 | 11.6 | 11.1 m | 8.4 | 7.9 m |  |  | pass |
| compare | info-strip | yellow | #4C410B | 0.0534 | 10.1 | 7.8 | 7.1 m | 5.4 | 5.1 m |  |  | pass |
| compare | info-strip | red | #4D0806 | 0.0176 | 15.5 | 11.3 | 10.9 m | 8.3 | 7.8 m |  |  | pass |
| compare | info-strip | checker | #4C4C4C | 0.0723 | 8.5 | 6.7 | 6.0 m | 4.6 | 4.3 m |  |  | pass |
| compare | info-strip | split | #4C4C4C | 0.0723 | 8.5 | 6.7 | 6.0 m | 4.6 | 4.3 m |  |  | pass |
| compare | pane-title | white | #606060 | 0.1170 | 6.2 | 5.0 m |  |  |  |  |  | pass |
| compare | pane-title | black | #171717 | 0.0086 | 17.9 | 13.1 m |  |  |  |  |  | pass |
| compare | pane-title | gray18 | #444444 | 0.0578 | 9.7 | 7.5 m |  |  |  |  |  | pass |
| compare | pane-title | yellow | #6F5B00 | 0.1086 | 6.6 | 5.3 m |  |  |  |  |  | pass |
| compare | pane-title | red | #9C1612 | 0.0769 | 8.2 | 6.3 m |  |  |  |  |  | pass |
| compare | pane-title | checker | #474747 | 0.0630 | 9.2 | 7.2 m |  |  |  |  |  | pass |
| compare | pane-title | split | #606060 | 0.1170 | 6.2 | 5.0 m |  |  |  |  |  | pass |
| compare | peaking | white | #616161 | 0.1195 |  | 5.0 |  |  |  |  |  | pass |
| compare | peaking | black | #161616 | 0.0080 |  | 13.2 |  |  |  |  |  | pass |
| compare | peaking | gray18 | #444444 | 0.0578 |  | 7.5 |  |  |  |  |  | pass |
| compare | peaking | yellow | #705C00 | 0.1110 |  | 5.2 |  |  |  |  |  | pass |
| compare | peaking | red | #9C1610 | 0.0768 |  | 6.3 |  |  |  |  |  | pass |
| compare | peaking | checker | #484848 | 0.0648 |  | 7.1 |  |  |  |  |  | pass |
| compare | peaking | split | #616161 | 0.1195 |  | 5.0 |  |  |  |  |  | pass |
| compare | rating-corner | white | #5F5F5F | 0.1144 |  | 5.1 | 4.5 m |  | 3.2 m |  |  | pass |
| compare | rating-corner | black | #171717 | 0.0086 |  | 13.1 | 12.7 m |  | 9.0 m |  |  | pass |
| compare | rating-corner | gray18 | #434343 | 0.0561 |  | 7.6 | 7.0 m |  | 5.0 m |  |  | pass |
| compare | rating-corner | yellow | #6E5A00 | 0.1063 |  | 5.3 | 4.7 m |  | 3.3 m |  |  | pass |
| compare | rating-corner | red | #9C1612 | 0.0769 |  | 6.3 | 5.8 m |  | 4.1 m |  |  | pass |
| compare | rating-corner | checker | #464646 | 0.0612 |  | 7.3 | 6.6 m |  | 4.7 m |  |  | pass |
| compare | rating-corner | split | #5F5F5F | 0.1144 |  | 5.1 | 4.5 m |  | 3.2 m |  |  | pass |
| compare | truth-badge | white | #606060 | 0.1170 | 6.2 |  |  | 3.3 m |  |  |  | pass |
| compare | truth-badge | black | #161616 | 0.0080 | 18.1 |  |  | 9.7 m |  |  |  | pass |
| compare | truth-badge | gray18 | #454545 | 0.0595 | 9.5 |  |  | 5.1 m |  |  |  | pass |
| compare | truth-badge | yellow | #6F5B00 | 0.1086 | 6.6 |  |  | 3.5 m |  |  |  | pass |
| compare | truth-badge | red | #9C1612 | 0.0769 | 8.2 |  |  | 4.4 m |  |  |  | pass |
| compare | truth-badge | checker | #484848 | 0.0648 | 9.1 |  |  | 4.9 m |  |  |  | pass |
| compare | truth-badge | split | #606060 | 0.1170 | 6.2 |  |  | 3.3 m |  |  |  | pass |

</details>
