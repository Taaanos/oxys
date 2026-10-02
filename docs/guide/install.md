# Install Oxys

Oxys needs an Apple silicon Mac with macOS 27 or newer.

The Oxys build is not signed with an Apple Developer ID and Apple has not checked it. This is why macOS shows a warning the first time you open it. Oxys is safe to open if you got it from the Oxys page on GitHub Releases. Do the steps below once.

## Install from GitHub Releases

1. Download `Oxys.zip` from the latest release.
2. Optional: check the file. In Terminal, run `shasum -a 256 Oxys.zip`. The result must be the same as the text in the `.sha256` file of the release.
3. Double-click the zip. Move `Oxys.app` to `/Applications`.
4. Remove the quarantine mark. Choose one method:

   **Method A: Terminal (one command)**

   ```sh
   xattr -dr com.apple.quarantine /Applications/Oxys.app
   ```

   Then open Oxys as usual.

   **Method B: System Settings**

   1. Open Oxys. macOS shows a message that it cannot check the app. Click **Done**.
   2. Open **System Settings → Privacy & Security**.
   3. Scroll down to the message about Oxys. Click **Open Anyway**.
   4. Enter your password. Click **Open Anyway** again.

You do this one time. Oxys opens normally after that.

## Why the warning shows

macOS puts a quarantine mark on each file a browser downloads. For an app that has no Developer ID, Gatekeeper blocks the app while this mark is on it. The `xattr` command removes the mark from the app. It does not change the app.

## Other ways to install

These ways do not set the quarantine mark, so macOS does not show the warning.

- **Download in Terminal.** Files that `curl` downloads have no quarantine mark:

  ```sh
  curl -LO https://github.com/Taaanos/oxys/releases/latest/download/Oxys.zip
  ditto -x -k Oxys.zip /Applications
  ```

- **Build from source.** An app you build on your Mac is not quarantined. See [Build from source](../../README.md#build-from-source).

## Update or remove

To update, download the new release and do the steps again. To remove Oxys, drag `Oxys.app` to the Trash. Your choices stay in the `.xmp` files next to your photos.
