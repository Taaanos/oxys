# Contrast of the labels on the photo

Made by `make contrast` (D-01, `scripts/contrast-report.py`). Do not edit it by hand.

**How it is measured.** The `contrast` bench scenario opens each test frame (`scripts/make-contrast-frames.py`) at 1:1 in Loupe and in Compare, with every label on: the info strip at its last level (name, EXIF panel, histogram), and with the strip off (rating corner, truth badge); peaking, clipping and Auto-advance throughout. The overlays are analyzed but not painted, so each label sits on the bare frame. On the split frame the edge between white and black is moved under each label in turn. The window is captured with the labels' text and symbols hidden. Inside each label's shape, inset by 2 pt, the brightest 1% of the pixels (in sRGB) is the worst plate. Each color drawn on the label is composited over it and compared by the WCAG formula.

**Rules.** Text keeps 4.5:1 and a mark (an icon, a star) keeps 3:1, on every frame. A value with `m` is a mark; the others are text. A fail is bold with ✗. Each value is the worst over both layouts, both Compare panes and every edge position. Inks: `secondary` is white at 85%, `star` the system yellow, `warning` `Plate.warning`, `reject` `Plate.reject`, `accent` the accent color, `cyan` the histogram's shadow percent, all as resolved in the dark appearance.

## Dark appearance, Reduce Transparency off, Increase Contrast off

2026-10-03, window 1470 x 923 pt at 2x, 58 captures. **31 of 105 rows fail.**

Inks: white=#FFFFFF  secondary=#FFFFFF@0.85  star=#FFD600  warning=#FF9230  reject=#FF6B66  accent=#007AFF  cyan=#3CD3FE

| Mode | Label | Material | Worst plate (frame) | white | secondary | star | warning | reject | accent | cyan | Result |
| --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| loupe | auto-advance | plate, black 70% | #4C4C4C L 0.072 (white) |  | 6.7 |  |  |  |  |  | pass |
| loupe | clipping | plate, black 70% | #4C4C4C L 0.072 (white) |  | 6.7 |  |  |  |  |  | pass |
| loupe | exif-panel | plate, black 70% | #4C4C4C L 0.072 (white) | 8.5 | 6.7 |  |  |  |  |  | pass |
| loupe | histogram | plate, black 70% | #4C4C4C L 0.072 (white) |  | 6.7 |  | **3.8 ✗** |  |  | 4.8 | fail |
| loupe | info-strip | plate, black 70% | #4C4C4C L 0.072 (white) | 8.5 | 6.7 | 6.0 m | 3.8 m | 3.0 m |  |  | pass |
| loupe | peaking | plate, black 70% | #4C4C4C L 0.072 (white) |  | 6.7 |  |  |  |  |  | pass |
| loupe | rating-corner | glass, regular, black 35% | #7C7C7C L 0.202 (white) |  | **3.5 ✗** | **2.9 m ✗** |  | **1.5 m ✗** |  |  | fail |
| loupe | truth-badge | glass, regular, black 35% | #7D7D7D L 0.205 (white) | **4.1 ✗** |  |  | **1.8 m ✗** |  |  |  | fail |
| compare | auto-advance | plate, black 70% | #4C4C4C L 0.072 (white) |  | 6.7 |  |  |  |  |  | pass |
| compare | clipping | plate, black 70% | #4C4C4C L 0.072 (white) |  | 6.7 |  |  |  |  |  | pass |
| compare | info-strip | plate, black 70% | #4C4C4C L 0.072 (white) | 8.5 | 6.7 | 6.0 m | **3.8 ✗** | 3.0 m |  |  | fail |
| compare | pane-title | plate, black 70% | #4C4C4C L 0.072 (white) | 8.5 | 6.7 m |  |  |  | **2.1 m ✗** |  | fail |
| compare | peaking | plate, black 70% | #4C4C4C L 0.072 (white) |  | 6.7 |  |  |  |  |  | pass |
| compare | rating-corner | glass, regular, black 35% | #7A7A7A L 0.195 (white) |  | **3.6 ✗** | 3.0 m |  | **1.5 m ✗** |  |  | fail |
| compare | truth-badge | glass, regular, black 35% | #7C7C7C L 0.202 (white) | **4.1 ✗** |  |  | **1.8 m ✗** |  |  |  | fail |

<details><summary>Every label on every frame</summary>

| Mode | Label | Frame | Plate | L | white | secondary | star | warning | reject | accent | cyan | Result |
| --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| loupe | auto-advance | white | #4C4C4C | 0.0723 |  | 6.7 |  |  |  |  |  | pass |
| loupe | auto-advance | black | #000000 | 0.0000 |  | 14.8 |  |  |  |  |  | pass |
| loupe | auto-advance | gray18 | #232323 | 0.0168 |  | 11.6 |  |  |  |  |  | pass |
| loupe | auto-advance | yellow | #4C410B | 0.0534 |  | 7.8 |  |  |  |  |  | pass |
| loupe | auto-advance | red | #4D0806 | 0.0176 |  | 11.3 |  |  |  |  |  | pass |
| loupe | auto-advance | checker | #4C4C4C | 0.0723 |  | 6.7 |  |  |  |  |  | pass |
| loupe | auto-advance | split | #000000 | 0.0000 |  | 14.8 |  |  |  |  |  | pass |
| loupe | clipping | white | #4C4C4C | 0.0723 |  | 6.7 |  |  |  |  |  | pass |
| loupe | clipping | black | #000000 | 0.0000 |  | 14.8 |  |  |  |  |  | pass |
| loupe | clipping | gray18 | #232323 | 0.0168 |  | 11.6 |  |  |  |  |  | pass |
| loupe | clipping | yellow | #4C410B | 0.0534 |  | 7.8 |  |  |  |  |  | pass |
| loupe | clipping | red | #4D0806 | 0.0176 |  | 11.3 |  |  |  |  |  | pass |
| loupe | clipping | checker | #4C4C4C | 0.0723 |  | 6.7 |  |  |  |  |  | pass |
| loupe | clipping | split | #4C4C4C | 0.0723 |  | 6.7 |  |  |  |  |  | pass |
| loupe | exif-panel | white | #4C4C4C | 0.0723 | 8.5 | 6.7 |  |  |  |  |  | pass |
| loupe | exif-panel | black | #000000 | 0.0000 | 21.0 | 14.8 |  |  |  |  |  | pass |
| loupe | exif-panel | gray18 | #232323 | 0.0168 | 15.7 | 11.6 |  |  |  |  |  | pass |
| loupe | exif-panel | yellow | #4C410B | 0.0534 | 10.1 | 7.8 |  |  |  |  |  | pass |
| loupe | exif-panel | red | #4D0806 | 0.0176 | 15.5 | 11.3 |  |  |  |  |  | pass |
| loupe | exif-panel | checker | #4C4C4C | 0.0723 | 8.5 | 6.7 |  |  |  |  |  | pass |
| loupe | exif-panel | split | #4C4C4C | 0.0723 | 8.5 | 6.7 |  |  |  |  |  | pass |
| loupe | histogram | white | #4C4C4C | 0.0723 |  | 6.7 |  | **3.8 ✗** |  |  | 4.8 | fail |
| loupe | histogram | black | #000000 | 0.0000 |  | 14.8 |  | 9.4 |  |  | 11.9 | pass |
| loupe | histogram | gray18 | #232323 | 0.0168 |  | 11.6 |  | 7.0 |  |  | 8.9 | pass |
| loupe | histogram | yellow | #4C410B | 0.0534 |  | 7.8 |  | 4.5 |  |  | 5.7 | pass |
| loupe | histogram | red | #4D0806 | 0.0176 |  | 11.3 |  | 6.9 |  |  | 8.8 | pass |
| loupe | histogram | checker | #4C4C4C | 0.0723 |  | 6.7 |  | **3.8 ✗** |  |  | 4.8 | fail |
| loupe | histogram | split | #4C4C4C | 0.0723 |  | 6.7 |  | **3.8 ✗** |  |  | 4.8 | fail |
| loupe | info-strip | white | #4C4C4C | 0.0723 | 8.5 | 6.7 | 6.0 m | 3.8 m | 3.0 m |  |  | pass |
| loupe | info-strip | black | #000000 | 0.0000 | 21.0 | 14.8 | 14.8 m | 9.4 m | 7.5 m |  |  | pass |
| loupe | info-strip | gray18 | #232323 | 0.0168 | 15.7 | 11.6 | 11.1 m | 7.0 m | 5.6 m |  |  | pass |
| loupe | info-strip | yellow | #4C410B | 0.0534 | 10.1 | 7.8 | 7.1 m | 4.5 m | 3.6 m |  |  | pass |
| loupe | info-strip | red | #4D0806 | 0.0176 | 15.5 | 11.3 | 10.9 m | 6.9 m | 5.5 m |  |  | pass |
| loupe | info-strip | checker | #4C4C4C | 0.0723 | 8.5 | 6.7 | 6.0 m | 3.8 m | 3.0 m |  |  | pass |
| loupe | info-strip | split | #4C4C4C | 0.0723 | 8.5 | 6.7 | 6.0 m | 3.8 m | 3.0 m |  |  | pass |
| loupe | peaking | white | #4C4C4C | 0.0723 |  | 6.7 |  |  |  |  |  | pass |
| loupe | peaking | black | #000000 | 0.0000 |  | 14.8 |  |  |  |  |  | pass |
| loupe | peaking | gray18 | #232323 | 0.0168 |  | 11.6 |  |  |  |  |  | pass |
| loupe | peaking | yellow | #4C410B | 0.0534 |  | 7.8 |  |  |  |  |  | pass |
| loupe | peaking | red | #4D0806 | 0.0176 |  | 11.3 |  |  |  |  |  | pass |
| loupe | peaking | checker | #4C4C4C | 0.0723 |  | 6.7 |  |  |  |  |  | pass |
| loupe | peaking | split | #4C4C4C | 0.0723 |  | 6.7 |  |  |  |  |  | pass |
| loupe | rating-corner | white | #7C7C7C | 0.2016 |  | **3.5 ✗** | **2.9 m ✗** |  | **1.5 m ✗** |  |  | fail |
| loupe | rating-corner | black | #1B1B1B | 0.0110 |  | 12.6 | 12.2 m |  | 6.1 m |  |  | pass |
| loupe | rating-corner | gray18 | #575757 | 0.0953 |  | 5.7 | 5.1 m |  | **2.6 m ✗** |  |  | fail |
| loupe | rating-corner | yellow | #8E7600 | 0.1871 |  | **3.6 ✗** | 3.1 m |  | **1.5 m ✗** |  |  | fail |
| loupe | rating-corner | red | #C51610 | 0.1248 |  | 4.6 | 4.2 m |  | **2.1 m ✗** |  |  | fail |
| loupe | rating-corner | checker | #5B5B5B | 0.1046 |  | 5.4 | 4.8 m |  | **2.4 m ✗** |  |  | fail |
| loupe | rating-corner | split | #7C7C7C | 0.2016 |  | **3.5 ✗** | **2.9 m ✗** |  | **1.5 m ✗** |  |  | fail |
| loupe | truth-badge | white | #7D7D7D | 0.2051 | **4.1 ✗** |  |  | **1.8 m ✗** |  |  |  | fail |
| loupe | truth-badge | black | #1B1B1B | 0.0110 | 17.2 |  |  | 7.7 m |  |  |  | pass |
| loupe | truth-badge | gray18 | #585858 | 0.0976 | 7.1 |  |  | 3.1 m |  |  |  | pass |
| loupe | truth-badge | yellow | #907700 | 0.1912 | **4.3 ✗** |  |  | **1.9 m ✗** |  |  |  | fail |
| loupe | truth-badge | red | #C51910 | 0.1260 | 5.9 |  |  | **2.6 m ✗** |  |  |  | fail |
| loupe | truth-badge | checker | #5C5C5C | 0.1070 | 6.6 |  |  | 3.0 m |  |  |  | fail |
| loupe | truth-badge | split | #1B1B1B | 0.0110 | 17.2 |  |  | 7.7 m |  |  |  | pass |
| compare | auto-advance | white | #4C4C4C | 0.0723 |  | 6.7 |  |  |  |  |  | pass |
| compare | auto-advance | black | #000000 | 0.0000 |  | 14.8 |  |  |  |  |  | pass |
| compare | auto-advance | gray18 | #232323 | 0.0168 |  | 11.6 |  |  |  |  |  | pass |
| compare | auto-advance | yellow | #4C410B | 0.0534 |  | 7.8 |  |  |  |  |  | pass |
| compare | auto-advance | red | #4D0806 | 0.0176 |  | 11.3 |  |  |  |  |  | pass |
| compare | auto-advance | checker | #4C4C4C | 0.0723 |  | 6.7 |  |  |  |  |  | pass |
| compare | auto-advance | split | #4C4C4C | 0.0723 |  | 6.7 |  |  |  |  |  | pass |
| compare | clipping | white | #4C4C4C | 0.0723 |  | 6.7 |  |  |  |  |  | pass |
| compare | clipping | black | #000000 | 0.0000 |  | 14.8 |  |  |  |  |  | pass |
| compare | clipping | gray18 | #232323 | 0.0168 |  | 11.6 |  |  |  |  |  | pass |
| compare | clipping | yellow | #4C410B | 0.0534 |  | 7.8 |  |  |  |  |  | pass |
| compare | clipping | red | #4D0806 | 0.0176 |  | 11.3 |  |  |  |  |  | pass |
| compare | clipping | checker | #4C4C4C | 0.0723 |  | 6.7 |  |  |  |  |  | pass |
| compare | clipping | split | #4C4C4C | 0.0723 |  | 6.7 |  |  |  |  |  | pass |
| compare | info-strip | white | #4C4C4C | 0.0723 | 8.5 | 6.7 | 6.0 m | **3.8 ✗** | 3.0 m |  |  | fail |
| compare | info-strip | black | #000000 | 0.0000 | 21.0 | 14.8 | 14.8 m | 9.4 | 7.5 m |  |  | pass |
| compare | info-strip | gray18 | #232323 | 0.0168 | 15.7 | 11.6 | 11.1 m | 7.0 | 5.6 m |  |  | pass |
| compare | info-strip | yellow | #4C410B | 0.0534 | 10.1 | 7.8 | 7.1 m | 4.5 | 3.6 m |  |  | pass |
| compare | info-strip | red | #4D0806 | 0.0176 | 15.5 | 11.3 | 10.9 m | 6.9 | 5.5 m |  |  | pass |
| compare | info-strip | checker | #4C4C4C | 0.0723 | 8.5 | 6.7 | 6.0 m | **3.8 ✗** | 3.0 m |  |  | fail |
| compare | info-strip | split | #4C4C4C | 0.0723 | 8.5 | 6.7 | 6.0 m | **3.8 ✗** | 3.0 m |  |  | fail |
| compare | pane-title | white | #4C4C4C | 0.0723 | 8.5 | 6.7 m |  |  |  | **2.1 m ✗** |  | fail |
| compare | pane-title | black | #000000 | 0.0000 | 21.0 | 14.8 m |  |  |  | 5.2 m |  | pass |
| compare | pane-title | gray18 | #232323 | 0.0168 | 15.7 | 11.6 m |  |  |  | 3.9 m |  | pass |
| compare | pane-title | yellow | #4C410B | 0.0534 | 10.1 | 7.8 m |  |  |  | **2.5 m ✗** |  | fail |
| compare | pane-title | red | #4D0806 | 0.0176 | 15.5 | 11.3 m |  |  |  | 3.8 m |  | pass |
| compare | pane-title | checker | #4C4C4C | 0.0723 | 8.5 | 6.7 m |  |  |  | **2.1 m ✗** |  | fail |
| compare | pane-title | split | #4C4C4C | 0.0723 | 8.5 | 6.7 m |  |  |  | **2.1 m ✗** |  | fail |
| compare | peaking | white | #4C4C4C | 0.0723 |  | 6.7 |  |  |  |  |  | pass |
| compare | peaking | black | #000000 | 0.0000 |  | 14.8 |  |  |  |  |  | pass |
| compare | peaking | gray18 | #232323 | 0.0168 |  | 11.6 |  |  |  |  |  | pass |
| compare | peaking | yellow | #4C410B | 0.0534 |  | 7.8 |  |  |  |  |  | pass |
| compare | peaking | red | #4D0806 | 0.0176 |  | 11.3 |  |  |  |  |  | pass |
| compare | peaking | checker | #4C4C4C | 0.0723 |  | 6.7 |  |  |  |  |  | pass |
| compare | peaking | split | #4C4C4C | 0.0723 |  | 6.7 |  |  |  |  |  | pass |
| compare | rating-corner | white | #7A7A7A | 0.1946 |  | **3.6 ✗** | 3.0 m |  | **1.5 m ✗** |  |  | fail |
| compare | rating-corner | black | #1C1C1C | 0.0116 |  | 12.5 | 12.0 m |  | 6.1 m |  |  | pass |
| compare | rating-corner | gray18 | #545454 | 0.0887 |  | 6.0 | 5.3 m |  | **2.7 m ✗** |  |  | fail |
| compare | rating-corner | yellow | #8A7300 | 0.1766 |  | **3.8 ✗** | 3.2 m |  | **1.6 m ✗** |  |  | fail |
| compare | rating-corner | red | #C41A15 | 0.1253 |  | 4.6 | 4.2 m |  | **2.1 m ✗** |  |  | fail |
| compare | rating-corner | checker | #585858 | 0.0976 |  | 5.7 | 5.0 m |  | **2.5 m ✗** |  |  | fail |
| compare | rating-corner | split | #7A7A7A | 0.1946 |  | **3.6 ✗** | 3.0 m |  | **1.5 m ✗** |  |  | fail |
| compare | truth-badge | white | #7C7C7C | 0.2016 | **4.1 ✗** |  |  | **1.8 m ✗** |  |  |  | fail |
| compare | truth-badge | black | #1B1B1B | 0.0110 | 17.2 |  |  | 7.7 m |  |  |  | pass |
| compare | truth-badge | gray18 | #585858 | 0.0976 | 7.1 |  |  | 3.1 m |  |  |  | pass |
| compare | truth-badge | yellow | #8E7600 | 0.1871 | **4.4 ✗** |  |  | **1.9 m ✗** |  |  |  | fail |
| compare | truth-badge | red | #C51913 | 0.1261 | 5.9 |  |  | **2.6 m ✗** |  |  |  | fail |
| compare | truth-badge | checker | #5C5C5C | 0.1070 | 6.6 |  |  | 3.0 m |  |  |  | fail |
| compare | truth-badge | split | #7C7C7C | 0.2016 | **4.1 ✗** |  |  | **1.8 m ✗** |  |  |  | fail |

</details>
