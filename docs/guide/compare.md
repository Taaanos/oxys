# Compare two photos

Compare shows two photos side by side. Use it to choose the better one.

- The left photo is the **select**. It is the best photo so far.
- The right photo is the **candidate**.

One side is **active**. A ring marks it. Every cull key changes the active side.

## Open Compare

Press `C` in the Grid or in Loupe.

- If two photos are selected, Compare shows those two.
- If not, Compare shows the current photo and the next photo. On the last photo, it shows the previous photo.

## Keys

| Key | Action |
| --- | --- |
| `⇥` | Change the active side. |
| `←` `→` | Move the active side to another photo. It skips the photo on the other side. |
| `↓` | Swap the select and the candidate. The ring stays on the same side. |
| `↑` | The candidate becomes the select. The next photo becomes the candidate. |
| `1`–`5`, `0`, `[` `]`, `6`–`9` | Rate or label the active side. |
| `⇧X` or `⇧` + a cull key | Apply to the active side. Move that side to the next photo. |
| `G` or `Esc` | Go to the Grid. |
| `E`, `Return`, or `Space` | Open the active photo in Loupe. |

A common way to work: look at both photos. Press `X` on the weaker one. Press `↑` or `→` to bring in the next candidate.

## Compare sharpness at 1:1

| Key | Action |
| --- | --- |
| `Z` | Zoom both sides to 1:1 at the same point. |
| `⇧Z` | Link or unlink zoom and pan. |
| `R` | Decode the RAW on both sides. |
| `F` `H` `S` | Show peaking and clipping on both sides. |

When the sides are linked, a zoom or pan on one side moves both. Press `⇧Z` to unlink them. Then you can align one side by itself. Press `⇧Z` again to link them. Oxys keeps the offset.

Each side has its own badge and information. Oxys marks each EXIF value that is different between the two photos. You see a change in shutter speed or ISO at once.
