#!/bin/sh
# S-3: signs dist/Oxys.zip with an SSH key kept off GitHub; writes dist/Oxys.zip.sig and checks it at once.
# Usage: OXYS_SIGNING_KEY=<private key file> scripts/sign-release.sh   (run from the repo root)
# The matching public key is in docs/release-signers (see docs/release-signing.md). The key should have a
# passphrase, and ideally live on a hardware key (`ssh-keygen -t ed25519-sk`).
set -eu

key=${OXYS_SIGNING_KEY:?set OXYS_SIGNING_KEY to the private key file}
signers=${OXYS_SIGNERS:-docs/release-signers}
[ -f "$key" ] || { echo "no such key file: $key" >&2; exit 1; }
[ -f "$signers" ] || { echo "no signers file: $signers (see docs/release-signing.md)" >&2; exit 1; }
[ -f dist/Oxys.zip ] || { echo "dist/Oxys.zip is missing: run scripts/package-release.sh first" >&2; exit 1; }

rm -f dist/Oxys.zip.sig
ssh-keygen -Y sign -f "$key" -n oxys-release dist/Oxys.zip
# The check a user will do, so a wrong key is found here and not after the upload.
ssh-keygen -Y verify -f "$signers" -I oxys-release -n oxys-release -s dist/Oxys.zip.sig < dist/Oxys.zip
echo "dist/Oxys.zip.sig"
