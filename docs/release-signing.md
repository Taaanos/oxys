# Release signing

Oxys has no Apple Developer ID (the program costs money, and Oxys is free). Apple does not check the app, so a user needs another way to know that a download is the real one. Each release has a signature, `Oxys.zip.sig`, made with a key that is not on GitHub. The checksum file only shows that a download is complete. The signature shows who made it (audit S-3).

## The key

One key pair, type Ed25519, with a passphrase. The private key stays off GitHub: on a hardware key (best), or in a file on an encrypted disk that is not synced. Nobody else gets it.

Make the key once:

```sh
ssh-keygen -t ed25519 -C "taaanos-release" -f ~/.ssh/taaanos-release        # asks for a passphrase
# Hardware key (best): ssh-keygen -t ed25519-sk -C "taaanos-release" -f ~/.ssh/taaanos-release
echo "taaanos-release $(cut -d' ' -f1,2 ~/.ssh/taaanos-release.pub)" > docs/release-signers
ssh-keygen -lf docs/release-signers                                    # the fingerprint to publish
```

Then:

1. Commit `docs/release-signers` (the public key).
2. Publish the fingerprint in at least two places that are not the Oxys repository: for example your GitHub profile README and your personal website. Add the fingerprint to the README of this repository too. A user compares the three.
3. Turn on two-factor authentication for the GitHub account, and tag protection for `v*` tags in the repository settings.

If the private key is lost or stolen: make a new key, publish the new fingerprint in all places, and say so in the next release notes. Old signatures stay valid for the old key only.

## Each release

```sh
export OXYS_SIGNING_KEY=~/.ssh/taaanos-release
scripts/release.sh 1.0.1          # builds, signs, verifies the signature, uploads Oxys.zip, .sha256 and .sig
scripts/release.sh 1.0.1 --tap ../homebrew-tap   # the same, then writes the Homebrew cask, shows it, asks, and pushes the tap
```

Without `--tap`, Homebrew users stay on the old version until you run `scripts/make-cask.sh 1.0.1 ../homebrew-tap` and push the tap.

`scripts/sign-release.sh` checks the signature against `docs/release-signers` before the upload, so a wrong key stops the release. `--unsigned` skips the signature (test releases only).

## What a user does

See [Check the download](guide/install.md#check-the-download).
