# Settings

Press `⌘,` to open Settings. It has eight tabs: General, Keys, RAW, Memory, Editors, Peaking, Clipping, and Sidecars. The keys in this guide are the Default keys. Change them in the Keys tab.

## General

- **Advance after rating, label or reject:** off by default. When it is on, hold `⇧` with a key to apply it and stay on the photo. `A` switches it on and off.
- **Show a RAW and its JPEG as one photo:** on by default. A RAW and a JPEG or HEIC with the same name in the same folder become one photo. You see the camera JPEG, and a rating goes to both files. Reveal in Finder selects both files. Switching this changes the open folder at once.

## Keys

The Keys tab lists every command with its keys. Use it to change the keys, add more keys, or remove keys. Oxys saves each change at once. The menus and the cheat sheet (`?`) show the new keys at once. You do not need to restart.

| To do this | Do this |
| --- | --- |
| Find a command | Type a command name, a mode, or a key in the search field. |
| Change a key | Click the key. Choose **Change Key…**. Press the new key. |
| Add a key | Click `+` next to the command. Press the key. A command can have more than one key. |
| Remove a key | Click the key. Choose **Remove Key**. The command stays in the menu. |
| Stop recording | Press `Esc` while Oxys waits for a key. |
| Go back to the Default keys | Click the arrow next to a changed command. For all commands, choose **Reset All…** in the **Keymap file** menu. |

A command that works in some modes only shows them under its name. The same key can do different things in different modes. For example, `↑` moves up a row in Grid, and walks the EXIF values in Loupe.

**A key that is already in use.** Oxys shows which command has the key, and in which modes. Nothing changes until you choose **Reassign**. Then the other command loses the key. Choose **Cancel** to keep both commands as they are.

**Keys you cannot use.** Oxys shows the reason and waits for another key.

- `⌘Q`, `⌘W`, `⌘H`, `⌥⌘H`, `⌘M`, `⌘,`, `⇧⌘/`, and ``⌘` `` belong to macOS and to the app menu.
- `Space` in Loupe: holding it lets you drag the photo.
- `Esc` cannot be recorded, because it stops recording. To take `Esc` away from a command, use **Remove Key**.
- A `⇧` key that is the "apply and go on" twin of a cull key. For example, `⇧X` goes with `X`. Change the key of the cull command first.

**Cull keys.** When you give a rating, label or reject command a new key, `⇧` with that key applies it and goes to the next photo, as before.

**Function keys.** You can use `F1` to `F12`, `Page Up`, `Page Down`, and forward delete. On a MacBook, hold `fn` with an `F` key, unless you changed this in System Settings.

**The keymap file.** Oxys saves your changes in `~/Library/Application Support/Oxys/Keymap.json`. The file lists only the commands that you changed. If you did not change any, the file does not exist. The **Keymap file** menu has these items:

- **Export…** saves a copy of your keys.
- **Import…** uses the keys of another file. Oxys shows how many of your changes it replaces, and which entries of the file it ignores. Then you choose **Import** or **Cancel**.
- **Show File in Finder**.

You can also edit the file in a text editor. Oxys reads it again when you come back to the app. If an entry is wrong, Oxys ignores that entry and tells you in the Keys tab. If Oxys cannot read the file at all, it uses the Default keys and shows the reason. **Start Over** moves the file to `Keymap.json.bak` and goes back to the Default keys.

```json
{
  "version": 1,
  "bindings": {
    "cull.reject": [ { "position": "q" } ],
    "zoom.in": [ { "character": "=", "modifiers": ["command"] } ]
  }
}
```

A command that is in the file gets exactly the keys that the file lists. An empty list (`[]`) removes all keys of the command. `position` names a key by where it sits, so it works with any input source. `character` names a punctuation key by the character that it types. `modifiers` are `shift`, `control`, `option` and `command`.

FastRawViewer and Photo Mechanic key presets are planned.

## RAW

**RAW decode** sets when Oxys decodes the full RAW. Without decoding, Oxys shows the preview.

| Mode | What happens |
| --- | --- |
| Never | Oxys shows previews only. |
| On demand (default) | `R` decodes one photo. `⇧R` switches to Always until you quit. |
| Always | Oxys decodes every RAW. It also decodes nearby photos in the background. |

**Automatic RAW at 1:1** is on by default. It works in On demand mode. When you zoom to 1:1 and the preview has fewer pixels than the sensor, Oxys decodes the RAW. Then 1:1 shows real sensor detail.

**Lens correction for RAW** is off by default. When it is on, the system decoder corrects the lens geometry in the decoded RAW, as the camera's own preview and most editors do. Applies only to cameras that the system decoder supports. Other cameras are not changed. With the correction on, 1:1 is resampled and does not show sensor pixels. When you change this setting, Oxys decodes the RAW on screen again. To see the result for the photo on screen, look at the **Lens correction** row in the inspector (`⌥⌘I`).

## Memory

**Frame cache** is the memory Oxys uses to keep decoded photos ready. Choose Automatic or Custom. Automatic is 2 GB, or one quarter of your RAM if that is less. On a Mac with little memory, choose a smaller size.

**Cached RAW frames** is how many developed RAWs stay in memory. Choose Automatic (5) or Custom (1 to 1000). The frame cache size is the higher limit: if the frames do not fit in it, the oldest ones go first, whatever the number is.

## Editors

This list holds the apps that `⌘E` and `⌥⌘E` can open photos in. Lightroom Classic, RawTherapee, and ART are in it already. Choose the default editor, add other apps, or remove the ones you added. An app that is not installed stays in the list but is dimmed. If you choose no default, `⌘E` uses the first installed editor.

## Peaking

- **Mode:** Edges or Fine detail. In Loupe, `⇧F` changes it.
- **Color:** magenta by default.
- **Sensitivity:** from Strict to Loose. Strict marks only the strongest edges. Loose also marks faint edges.

## Clipping

- The highlight percentage and the shadow percentage. The defaults are 98% and 2%. `⌥H` opens the same values.
- **Stripes instead of solid color:** Oxys draws the marks as stripes. You can see the photo through them.

Each of these two tabs has a **Reset to Defaults** button.

## Sidecars

**Sidecar name** sets the sidecar file name: `name.xmp` (Lightroom, FastRawViewer) or `name.ext.xmp` (darktable style). Set the XMP sidecar style in RawTherapee to match. See [Sidecars and other apps](sidecars.md).

## Appearance

The window follows the light or dark appearance of your Mac. The photo always has a neutral dark gray surround. The surround does not change how you see the exposure.
