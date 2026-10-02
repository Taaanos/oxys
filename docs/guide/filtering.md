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

## Extract embedded JPEGs

Each RAW file has a JPEG inside it. Oxys can save these JPEGs as separate files. You can share them without a RAW converter.

1. Select the photos, or leave nothing selected to use the active photo.
2. Press `⇧⌘E`. Choose a folder. Make a new one if you need to.
3. Oxys works in the background. A box at the bottom left shows progress. You can keep working. Press `Cancel` or `⌘.` to stop. The file in progress is finished, the next one is not started, and no partial file stays.
4. When it ends, the box shows a summary. It lists the photos that have no embedded JPEG, the files that are not RAW (JPEG and HEIC are skipped), the files that failed, and the files that got a new name. Press `Show in Finder` to see the JPEGs. Press `Close` or `⌘.` to close the box.

What you get:

- The file is `name.jpg`. The name is the RAW's name. It is the largest JPEG inside the RAW. Oxys does not decode it or compress it again. The image data does not change.
- The JPEG keeps the metadata of the RAW:
  - **EXIF:** camera, lens, exposure, ISO, capture time and time zone, GPS, copyright, artist, serial number, and the maker note (the camera's own data, such as Sony or Canon focus data). The picture size is the size of the JPEG, and the orientation is the one the JPEG needs. Data that only describes the RAW itself is not copied (RAW size, color matrices, Sony SR2 data, DNG private blocks).
  - **XMP:** your rating and color label from the Oxys sidecar (`name.xmp`). If a DNG holds its own XMP and has no sidecar, that XMP is used. Lightroom and other apps read the stars from the JPEG.
  - **File attributes:** the creation date, the modification date, the permissions, and all extended attributes (Finder tags, Finder comments, "where from", and others). The copy has the same dates as the RAW.
- If the embedded JPEG has its own XMP, Oxys keeps it. If the embedded JPEG has its own EXIF, the RAW's EXIF replaces it. Oxys keeps the orientation of the embedded JPEG.
- If a maker note cannot be moved safely into the JPEG, Oxys leaves that one note out and lists the file in the summary. Oxys also lists a file whose attributes it could not copy.
- To get exactly the embedded bytes, with no EXIF or XMP from the RAW, quit Oxys and run `defaults write dev.oxys.Oxys extractExactBytes -bool YES`. This has no switch in Settings. The file attributes are still copied.
- Oxys never replaces a file. If `name.jpg` is there already, the new file is `name-1.jpg`, then `name-2.jpg`. The summary lists these names.
- Oxys reads your RAW files and writes only into the folder you chose. Do not choose the folder that holds your photos if you want to keep it clean.

## Reload the folder

Oxys does not add new photos while the folder is open. If photos arrive, the window subtitle says "N new files, reload with ⌥⌘R". Press `⌥⌘R` to load them. Oxys removes photos from the view when they leave the folder.
