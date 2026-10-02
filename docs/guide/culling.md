# Cull photos

## The three views

| View | Key | Use it to |
| --- | --- | --- |
| **Grid** | `G` or `Esc` | See many photos. Select a group. Change the thumbnail size. |
| **Loupe** | `E`, `Return`, or `Space` | Look at one photo in large size. |
| **Compare** | `C` | Look at two photos side by side. See [Compare two photos](compare.md). |

You can also use the picker in the toolbar. In the Grid, a double-click on a thumbnail opens Loupe.

## Move

| Key | Action |
| --- | --- |
| `→` `←` | Next photo, previous photo. Hold to move fast. |
| `↑` `↓` | Up one row, down one row (Grid). |
| `Home` `End` | First photo, last photo. |
| `-` `=` | Smaller thumbnails, larger thumbnails (Grid). |

Oxys loads the next photos before you need them.

## Stars, colors, and rejects

| Key | Action |
| --- | --- |
| `1` `2` `3` `4` `5` | Set the stars. |
| `0` | Clear the stars. |
| `[` `]` | One star less, one star more. |
| `X` | Reject. |
| `6` `7` `8` `9` | Red, yellow, green, blue label. |

The keypad number keys work the same way. Purple has no key. Use the Photo menu.

Know these rules:

- A rating key does nothing if the photo already has that rating.
- A label key removes the label if the photo already has it.
- `X` on a rejected photo removes the reject. The photo has no stars. It does not get its old stars back.
- `]` on a rejected photo gives it 1 star.
- `[` on a rejected photo does nothing.
- Each label also shows a letter. You do not need to tell colors apart.
- Cull keys ignore key repeat. If you hold `⇧3`, only one photo changes.

## Apply and go to the next photo

Hold `⇧` and press a rating, label, or reject key. Oxys applies the choice and goes to the next photo.

- `⇧X` rejects and moves on.
- `⇧3` gives 3 stars and moves on.

In Compare, `⇧` moves only the active side. See [Compare two photos](compare.md).

## Undo and redo

- `⌘Z` undoes the last cull action. It also undoes the sidecar on disk.
- `⇧⌘Z` does the action again.

The Edit menu names the action, for example "Undo Set Rating". A change to many photos is one undo step.

## Select many photos

Select photos to change them together.

| Key | Action |
| --- | --- |
| `⇧` + arrow | Add to the selection (Grid). |
| `⌘A` | Select all visible photos. |
| `⇧⌘A` | Select none. |
| `⇧⌘I` | Invert the selection. |
| `/` | Remove the active photo from the selection. |
| `⌥⌘A` | Select by rating or label. |

In the Grid, cull keys change **all selected photos**. In Loupe and Compare, they change only the photo you see.

`⌘A` selects only the photos you can see. If a filter is on, it selects the filtered photos.

## When a choice hides the photo

Sometimes a choice makes a photo leave the filter. For example, you press `2` while you show 3 stars or more. The photo stays on screen until you move away. The view does not jump.

## Typing in a text field

Bare keys do nothing while you type in a text field. Press `Esc` one time to leave the field. Press `Esc` again to go to the Grid.

Shortcuts use key position, not the letter. They work with Greek, Cyrillic, Japanese, and other input sources.

## Accessibility

You can reach every control with the keyboard. VoiceOver reads the state of a photo as one phrase, for example "3 stars, red label". If Full Keyboard Access is on, `⇥` moves between controls. Use `⌥⌘T` to hide the toolbar.
