# Problems and questions

## The keys do nothing

- **A text field has focus.** Bare keys do nothing while you type. Press `Esc` to return to the photo.
- **The key is for another view.** For example, `↑` and `↓` move rows in the Grid. In Loupe, they go through EXIF values. In Compare, they swap or advance. Press `?` to see the keys for the current view.
- **A button has focus.** A focused button takes `Space` and `Return`. Press `Esc` to return to the photo.

## The folder shows no photos

Oxys reads only the folder you open. It does not read subfolders. Open the folder that holds the photos, for example `DCIM/100CANON`. If subfolders hold photos, Oxys tells you.

## A photo looks soft at 1:1

Read the badge. If it says **Preview 1:1, not sensor pixels** or **Preview enlarged**, you see the small preview, made larger. Press `R` to decode the RAW. When the badge says `RAW 1:1`, you see real sensor pixels.

## `R` does nothing

Open **Settings ▸ General ▸ RAW decode**. In Never mode, `R` and `⇧R` are off. A JPEG, HEIC, or TIFF has no RAW to decode.

## My ratings do not show in Lightroom, RawTherapee, or ART

Read [Sidecars and other apps](sidecars.md). These are the usual causes:

- **Lightroom:** you imported from a card, or the photos are in the catalog already. Choose **Metadata ▸ Read Metadata from Files**.
- **Lightroom with JPEG, HEIC, TIFF, or DNG:** Lightroom keeps metadata inside these files. It can ignore the sidecar.
- **RawTherapee:** turn on the XMP sidecar setting. Make the sidecar style match Oxys.
- **A rejected photo:** RawTherapee ignores a rating of -1.
- **Different names:** Oxys and the other program must use the same name style: `name.xmp` or `name.ext.xmp`.

## A banner says Oxys did not save

The folder is read-only, the card is locked or removed, or the disk is full. You can continue to cull. Oxys keeps your choices in memory. Fix the problem and choose Retry. Or use **Save Decisions To…** to write the sidecars to another folder. See [If Oxys cannot save](sidecars.md#if-oxys-cannot-save).

## "N new files, reload"

Photos came into the folder after you opened it. Press `⌥⌘R`.

## Are my originals safe?

Yes. Oxys never writes to a RAW or JPEG file. In your folders, it makes only `.xmp` sidecars. It also makes a hidden temporary file for a short time while it writes a sidecar.

## Where do rejected photos go?

They stay where they are. A reject is a mark in the sidecar (rating -1). Oxys does not move or delete files. Press `⌥⌘X` to hide rejected photos or to show only them. Move or delete the files yourself in Finder.

## What is not available yet

These features are planned. They are **not** in the app now:

- **RAW+JPEG pairs as one photo.** A RAW and a JPEG with the same name show as two photos.
- **Auto-advance after each rating.** Hold `⇧` with a cull key.
- **Return to your place** when you open a folder again.
- **Burst stacks, a focus-point overlay, lights out, a 3-up or 4-up view, progress statistics, a rejects folder, and a hot folder.**

## Report a problem

Tell us:

- The file type.
- The keys you pressed.
- What you expected.
- What happened.

For problems with another program, send a copy of the sidecar. Do not send photos that you want to keep private.
