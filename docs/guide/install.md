# Install Oxys

Oxys needs an Apple silicon Mac with macOS 27 or newer.

The Oxys build is not signed with an Apple Developer ID and Apple has not checked it. This is why macOS shows a warning the first time you open it. Oxys is safe to open if you got it from the Oxys page on GitHub Releases. Do the steps below once.

## Install from GitHub Releases

1. Download `Oxys.zip` from the latest release.
2. Check the download. See [Check the download](#check-the-download). This takes one minute and it is the best protection you have, because Apple does not check Oxys.
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

## Check the download

Each release has a file `Oxys.zip.sig`. It is a signature made with the Oxys release key. If someone changes `Oxys.zip` on GitHub, the signature does not match. Do this before you remove the quarantine mark:

1. Download `Oxys.zip`, `Oxys.zip.sig` and [`release-signers`](https://github.com/Taaanos/oxys/blob/main/docs/release-signers) into one folder.
2. Show the fingerprint of the key:

   ```sh
   ssh-keygen -lf release-signers
   ```

3. Compare it with the fingerprint in the README and in the other places that the README names. Do not trust a fingerprint that only the same download page shows. If they differ, stop and do not open the app.
4. Check the signature:

   ```sh
   ssh-keygen -Y verify -f release-signers -I oxys-release -n oxys-release -s Oxys.zip.sig < Oxys.zip
   ```

   The answer must start with `Good "oxys-release" signature`. Any other answer means: do not open the app.

After the first time, keep the `release-signers` file you checked and use it for later releases. If the file on GitHub is different from yours, the key changed: look for an announcement before you go on.

The `.sha256` file only shows that the download is complete. It does not show who made it.

## Why the warning shows

macOS puts a quarantine mark on each file a browser downloads. For an app that has no Developer ID, Gatekeeper blocks the app while this mark is on it. The `xattr` command removes the mark from the app. It does not change the app.

## Other ways to install

These ways do not set the quarantine mark, so macOS does not show the warning.

- **Download in Terminal.** Files that `curl` downloads have no quarantine mark. Check the signature before you open the app:

  ```sh
  curl -LO https://github.com/Taaanos/oxys/releases/latest/download/Oxys.zip
  curl -LO https://github.com/Taaanos/oxys/releases/latest/download/Oxys.zip.sig
  ssh-keygen -Y verify -f release-signers -I oxys-release -n oxys-release -s Oxys.zip.sig < Oxys.zip
  ditto -x -k Oxys.zip /Applications
  ```

- **Build from source.** An app you build on your Mac is not quarantined. See [Build from source](../../README.md#build-from-source).

## Update or remove

To update, download the new release and do the steps again. To remove Oxys, drag `Oxys.app` to the Trash. Your choices stay in the `.xmp` files next to your photos.
