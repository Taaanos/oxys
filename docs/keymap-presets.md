# Key preset: Photo Mechanic (V-14, part 2)

**Status: approved by you on 4 Oct 2026 ("ok sounds good"), and built.** The data file is `Packages/Commands/Sources/Commands/Presets/photomechanic.json`. All decisions D1 to D7 are as proposed. This page stays as the record of the sources and of what is not mapped.

A preset is a data file in the same format as `Keymap.json`. It sits between the Default keys and your own changes. This page is the plan for the one file.

**Decided by you (4 Oct 2026):** there is no FastRawViewer preset. The Default keys already match FastRawViewer for the cull loop: ratings, labels, `X`, `Z`, `G`, 1:1 and Fit.

## How the preset is built

1. The preset lists only the commands whose keys change. Every other command keeps its Default key.
2. For a command that Photo Mechanic also has, its key comes **first**. The menu shows the first key.
3. The Default keys of that command stay as extra keys, unless they clash with another key of the preset. A person who changes between apps keeps both sets.
4. When a preset key clashes with a Default key of another command in the same modes, the preset key wins. The other command loses that key. Every such case would be listed here. There are none in this preset.
5. A command is mapped only when Photo Mechanic has a command with the same job. When the jobs differ, nothing is mapped.
6. I use only keys that Photo Mechanic documents. A row that I could not confirm says **not verified**, and it is not in the preset.

I ran the draft through the real keymap code (`Keymap.resolve` and the conflict check from part 1). It resolves with no problems and no clashes.

## Naming

The preset is called "Photo Mechanic" in the picker, in plain text. The guide adds one line: "Photo Mechanic is a trademark of Camera Bits, Inc. Oxys is not affiliated with Camera Bits." No logo, no Photo Mechanic text is copied, and the file holds only command names and keys. The name appears only where a person chooses the preset.

## Sources

[Keyboard Shortcuts: macOS](https://docs.camerabits.com/support/solutions/articles/48000317772), and the pages [Star Ratings](https://docs.camerabits.com/support/solutions/articles/48001143067), [Color Class Ratings](https://docs.camerabits.com/support/solutions/articles/48001142942) and [Custom Keyboard Shortcuts](https://docs.camerabits.com/en/support/solutions/articles/48001271746).

I have no copy of the app, so I did not test a key in Photo Mechanic. The table is from the documents only.

Photo Mechanic is a contact sheet, ingest and metadata tool. Its keys are mostly for jobs that Oxys does not do. Only about 15 commands map, so this preset is small.

---

## Keys that change

| Oxys command | Oxys Default | Photo Mechanic | Preset keys | Source |
| --- | --- | --- | --- | --- |
| 0 to 5 stars | `0`–`5`, keypad | `⌃1`–`⌃5` and `⌃0`; single keys `0`–`5` if you set them in Preferences > Accessibility | `⌃0`–`⌃5`, `0`–`5`, keypad | Keyboard Shortcuts: macOS (Contact Sheet and footnote); Star Ratings |
| Zoom In | `=` `⌘=` `⇧⌘=` | `+` increases zoom (Preview) | `+` `=` `⌘=` `⇧⌘=` | Preview window |
| Highlight Clipping | `H` | Toggle highlights `B` (Preview) | `B` `H` | Preview window |
| Shadow Clipping | `S` | Toggle shadows `N` (Preview) | `N` `S` | Preview window |
| Compare | `C` | 2-up view (landscape) `V` (Preview) | `V` `C` | Preview window |
| Link Zoom and Pan | `⇧Z` | Link 2 previews `L` (Preview) | `L` `⇧Z` | Preview window |
| Deselect Active Photo | `/` | Deselect `D` (Preview) | `/` `D` | Preview window |
| Select None | `⇧⌘A` | Deselect all `⌘D` (Edit menu) | `⌘D` `⇧⌘A` | Edit menu |
| Invert Selection | `⇧⌘I` | Select others `⇧⌘O` (Edit menu) | `⇧⌘O` `⇧⌘I` | Edit menu |
| Reload Folder | `⌥⌘R` | Refresh `F5` (View menu) | `F5` `⌥⌘R` | View menu |

The `⇧` twins of the rating keys follow the new keys, as they do in the Default keys (for example `⇧⌃3`). No Default key moves away in this preset.

## Keys that are the same in both apps (no change)

`←` `→` next and previous, `Home` `End`, `Space` preview, `Esc` close preview, `Z` toggle zoom, `⌥`-arrows pan, `⇧⌥`-arrows pan a view, `⌘Z` and `⇧⌘Z`, `⌘A`, `⌘O`, `⌘F` find, `⌘E` edit, `-` zoom out.

## Not mapped, and why

| Photo Mechanic key | Why it is not in the preset |
| --- | --- |
| `⌘1`–`⌘8` set a color class, `⌘0` removes it | **Not verified.** Photo Mechanic has 8 classes, and their colors depend on one of six label schemes. Its pages do not give the default colors. Oxys has 5 labels. Any mapping would be a guess. `⌘1` and `⌘0` are also Oxys's 1:1 and Fit keys. |
| `Delete`, `⌫` delete the item | Oxys never deletes a file. A reject key on `⌫` would look like a delete. See D2. |
| `T`, `+`, `-`, `⌘T` tag | Tagging is Photo Mechanic's way to mark photos for later. The nearest Oxys idea is the selection, which has other keys. |
| `[` `]` rotate | These are Oxys's rating down and up. Oxys does not rotate. |
| `F` full screen | `F` is Oxys's focus peaking. See D1. |
| `⇥` switch pane in 2-up | `⇥` is Focus Mode in every mode. The keymap cannot give `⇥` to one mode only without taking it from Focus Mode. |
| `G` or `/` swap items in 2-up | `G` is Show Grid and `/` is Deselect. Same reason. |
| `⌘R` preview | `⌘R` is Reveal in Finder. |
| `E` edit (bare) | `E` is Open in Loupe. `⌘E` is already the same in both apps. |
| `X` crop | `X` is Reject. |
| `⌘⇧F1`–`F5` show images by star rating, `⌘⌃F1`–`F8` by color | **Not verified.** I cannot tell if "show by rating" means exactly N stars or N stars and more. Oxys has both kinds. |
| `I`, `⌘I` metadata (IPTC), `Q`, `Y`, `U`, `S`, `M`, `⌘G` ingest and the rest | No Oxys command. |

---

## Decisions for you

| # | Question | Proposed |
| --- | --- | --- |
| D1 | `F` stays focus peaking, so full screen keeps `⌃⌘F`. | Yes. Peaking is a core key of Oxys. |
| D2 | `⌫` is not a reject key. | Keep it unmapped. |
| D3 | Color classes are not mapped until someone confirms the number of each color. | Keep them unmapped. |
| D4 | Stars on `⌃1`–`⌃5`. If you turn on "Switch to Desktop 1–5" in System Settings, macOS takes these keys before Oxys sees them. The bare digits stay as second keys, so ratings still work. | Yes. |
| D5 | Switching to the preset removes your own key changes after a confirmation that shows the count and offers Export first. (Same as Q10 of V-14.) | Yes. |
| D6 | With one preset, keep the picker (Default, Photo Mechanic)? | Yes. The preset format and loader exist from part 1. The picker is one control. |
| D7 | The naming in "Naming" above (plain text name, one trademark line in the guide, no logo). | Yes. |

## Risks

- The menu bar may not draw a key that is an F-key (`F5`). The cheat sheet and the Keys tab draw it. This is the same open check as in part 1.
- Photo Mechanic can change these keys in a later version. The page says which document I used. The preset is a plain file, so a later change is a small edit.

## What was done after you approved

1. Wrote `Presets/photomechanic.json` in `Packages/Commands` (and remove `Presets/.gitkeep`).
2. Added the key-set picker to the Keys tab, with the confirmation of D5, and the trademark line to the guide.
3. Added the tests: the preset resolves with no problems, no unknown command, no clashes; the order Default, preset, your file is right; a switch removes your changes.
4. Updated the guide (Settings > Keys), the changelog and V-14, and committed as `V-14 (part): key preset: Photo Mechanic`.
