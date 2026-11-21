# Security Policy

## Supported versions

Only the latest release receives security fixes.

## Report a vulnerability

Do not open a public GitHub issue for a security vulnerability.

1. Open the repository **Security** tab on GitHub.
2. Select **Report a vulnerability** to open a private report.
3. Include the Oxys version, macOS version, steps to reproduce, and affected files or paths.

## Security guarantees and threat model

Oxys is a local-only macOS app.
It makes no network requests and collects no telemetry.
It never modifies original photos and only writes `.xmp` sidecar files (via short-lived hidden temporary files) into photo folders.

Its security model, accepted risks (including non-sandboxed system image decoders), and audit history are documented in [security.md](docs/guide/security.md) and [security-audit.md](docs/security-audit.md).
