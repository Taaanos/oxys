# Security and privacy

## What Oxys opens, and the risk

Oxys opens every photo in the folder you choose. To show a photo, it uses the image decoders of macOS (ImageIO and Core Image). These are the same decoders that Preview and Finder use. Apple fixes their bugs in macOS updates.

Oxys is not sandboxed. A decoder runs inside the Oxys process, with the same file access as you. This means:

- A photo file that was made to attack a decoder bug could run code with your access. This risk is the same as in other apps that open photos, but Preview and Quick Look run in a sandbox and Oxys does not.
- Open only folders and cards that you trust, and keep macOS up to date. This is the best protection.

We decided to accept this risk for now. A later version may move the decoding into a separate sandboxed process (audit S-4).

## What Oxys writes

Oxys never changes your original photos. It writes only `.xmp` sidecar files next to them, and short-lived hidden temporary files for the same purpose. It does not use the network.

## What Oxys keeps on your Mac

- Your last folder and per-folder state, in `~/Library/Application Support`.
- Thumbnails of the photos you opened, in `~/Library/Caches`. They stay until the cache limit removes them.

## Check the download

Releases are signed. See [Check the download](install.md#check-the-download).
