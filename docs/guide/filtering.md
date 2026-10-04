# Filter, sort, and send photos on

You often cull in more than one pass. First reject the clear misses. Then keep 3 stars or more. Then keep 4 stars or more. Filters make this fast. Oxys saves every choice at once, so you do not export anything between passes.

## The filter bar

Press `\` (backslash) to show or hide the filter bar. You can filter by stars, color, and reject state. You can also sort. The toolbar has a button for the filter bar.

| Key | Action |
| --- | --- |
| `\` | Show or hide the filter bar. |
| `⌘L` | Turn filtering on or off. Your settings stay. |
| `⌘F` | Find by file name. |
| `⌥⌘0` | Any rating. |
| `⌥⌘1` to `⌥⌘5` | At least this number of stars. `⌥⌘5` shows only 5 stars. |
| `⌥⌘6` `⌥⌘7` `⌥⌘8` `⌥⌘9` | Show red, yellow, green, or blue. Each key is on or off. |
| `⌥⌘X` | Go through: show rejected, hide rejected, only rejected. |

The **Filter** menu has the same commands. It also has the purple label and **Clear Filter**.

The window subtitle shows how many photos you see, for example "312 of 1,204 shown". The filter works in the Grid, in Loupe, and in Compare. In Loupe, the arrow keys go through the photos that pass the filter.

## Sort

Sort by **capture time** (default) or by **file name**. Choose ascending or descending order. Use the filter bar or the Filter menu.

## A second pass

1. Press `⌥⌘3` to show 3 stars or more.
2. Look at each photo in Loupe or Compare. Change the ratings.
3. Press `⌥⌘4` to be more strict.
4. Press `⌘L` to see all photos. Press `⌘L` again to return.

If a change makes a photo leave the filter, the photo stays on screen until you move away.

## Show photos in Finder

1. Show the photos you want.
2. Press `⌘A` to select them.
3. Press `⌘R`.

Finder opens one window. It selects exactly those files. If you select nothing, `⌘R` shows the active photo.

You can then drag the files to your editor. The `.xmp` sidecars stay next to the photos. Your ratings stay with them. See [Sidecars and other apps](sidecars.md).

## Open photos in an editor

1. Select the photos, or leave nothing selected to use the active photo.
2. Press `⌘E` to open them in your default editor. Press `⌥⌘E` to choose an editor. In the list, use `↑` `↓` and `Return`, or press a number. Press `Esc` to close the list.

The Photo menu also has an Edit In submenu. A RAW with a JPEG of the same name opens as the RAW. Oxys saves your choices to the sidecars first, so the editor reads the newest ratings. Add or remove editors in [Settings](settings.md#editors).

## Export photos

Oxys can save your photos as JPEG or HEIC files. You can share them without a RAW converter. There are three formats:

- **Embedded JPEG:** each RAW file has a JPEG inside it. Oxys saves it as a separate file. The image data does not change.
- **Developed JPEG:** Oxys develops the RAW to a full-size picture and saves it as an 8-bit sRGB JPEG. Every viewer shows its colors in the same way.
- **Developed HEIC:** the same picture, saved as a 10-bit Display P3 HEIC. It has more colors and smoother gradients. At the default quality the file is about as big as the JPEG. Oxys shows this choice only if your Mac can write HEIC.

1. Select the photos, or leave nothing selected to use the active photo.
2. Press `⇧⌘E`. Choose a folder. Make a new one if you need to. Do not choose a folder that holds the photos: Oxys refuses it, because it writes only sidecars into those folders.
3. Choose the format in the `Format` menu below the folder list. Oxys remembers your choice.
4. Optional: turn on `Remove location and serial numbers` (see below). It is off the first time, and Oxys remembers your choice.
5. Press `Export`. Oxys works in the background. A box at the bottom left shows progress. You can keep working. Press `Cancel` or `⌘.` to stop. The file in progress is finished, the next one is not started, and no partial file stays.
6. When it ends, the box shows a summary. It lists the photos that have no embedded JPEG, the RAW files that Oxys could not develop, the files that are not RAW (JPEG and HEIC are skipped), the files that failed, and the files that got a new name. Press `Show in Finder` to see the files. Press `Close` or `⌘.` to close the box.

What you get, for all three formats:

- The file is `name.jpg` or `name.heic`. The name is the RAW's name.
- The file keeps the metadata of the RAW:
  - **EXIF:** camera, lens, exposure, ISO, capture time and time zone, GPS, copyright, artist and serial number. The picture size is the size of the file, and the orientation is correct for the picture. Data that only describes the RAW itself is not copied (RAW size, color matrices, Sony SR2 data, DNG private blocks).
  - **Maker note** (the camera's own data, such as Sony or Canon focus data): JPEG files keep it. A HEIC file cannot hold it. The summary says this once.
  - **XMP:** your rating and color label from the Oxys sidecar (`name.xmp`). If a DNG holds its own XMP and has no sidecar, that XMP is used. Lightroom and other apps read the stars from the file. The editing settings of a RAW editor are not copied to a developed file, because the picture is already developed.
  - **File attributes:** the creation date, the modification date, the permissions, and all extended attributes (Finder tags, Finder comments, "where from", and others). The file has the same dates as the RAW.
- Oxys never replaces a file. If `name.jpg` is there already, the new file is `name-1.jpg`, then `name-2.jpg`. The summary lists these names.
- Oxys reads your RAW files and writes only into the folder you chose.

About an embedded JPEG:

- It is the largest JPEG inside the RAW. Oxys does not decode it or compress it again.
- If it has its own XMP, Oxys keeps it. If it has its own EXIF, the RAW's EXIF replaces it. Oxys keeps the orientation of the embedded JPEG.
- If a maker note cannot be moved safely into the JPEG, Oxys leaves that one note out and lists the file in the summary. Oxys also lists a file whose attributes it could not copy.
- To get exactly the embedded bytes, with no EXIF or XMP from the RAW, quit Oxys and run `defaults write com.thanosam.Oxys extractExactBytes -bool YES`. This has no switch in Settings. The file attributes are still copied.

About a developed file:

- Oxys uses the decoder of macOS with its default settings: the white balance of the camera, the default tone, and the normal sharpening, noise reduction and lens correction. Oxys makes no other changes. This is not the neutral picture that `R` shows in the viewer.
- The work takes about half a second for a 48 MP photo on an Apple silicon Mac. A big job uses a lot of memory and processor time.
- The panel's caption says what each format keeps. All three keep the GPS position unless you turn on the switch above.
- GPS in a HEIC can move by about 10 cm, because the format stores it as degrees, minutes and seconds.
- To change the quality, quit Oxys and run `defaults write com.thanosam.Oxys exportJPEGQuality -float 0.9` (or `exportHEICQuality`). The value is between 0.05 and 1. The defaults are 0.92 for JPEG and 0.8 for HEIC.

### Remove location and serial numbers

By default an export is a faithful copy: it keeps the GPS position of the photo. If you share the files on the web, the position can show where you were. Turn on `Remove location and serial numbers` in the export panel to take it out. The switch is off until you turn it on. It works in the same way for all three formats.

The switch removes:

- **EXIF:** the whole GPS block, the camera owner name, the camera and lens serial numbers and the image unique ID.
- **Maker note:** all of it, because it holds serial numbers in a form that is different for each brand. The camera's own data in the maker note, such as focus data, is lost too.
- **XMP:** every GPS value, the owner name and the serial numbers, the drone maker's block of a drone photo (it holds position, altitude and the drone's serial number), and the city, state and country fields.
- **IPTC:** the city, state, country and place fields, and the creator's contact details.

The switch keeps the camera and lens model, the exposure, the capture time, and the artist and copyright text (they are the credit you chose to publish). It keeps your rating and label in the XMP of a developed file. For the embedded JPEG, it removes the JPEG's own XMP too, so the file has no rating and label. This also holds when you choose the exact embedded bytes (`extractExactBytes`): the image data does not change, but the EXIF, XMP and IPTC of the preview are cleaned.

If Oxys cannot read an XMP packet, it leaves that XMP out and lists the file in the summary. Oxys never copies an XMP that it could not clean. The sidecar next to your RAW is not changed, because it is not an export. The capture time and the file dates still show when the photo was taken. The picture itself can also show a place, for example a street sign.

## Reload the folder

Oxys does not add new photos while the folder is open. If photos arrive, the window subtitle says "N new files, reload with ⌥⌘R". Press `⌥⌘R` to load them. Oxys removes photos from the view when they leave the folder.
