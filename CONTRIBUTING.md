# Contributing to Oxys

Thank you for contributing to Oxys.

## Before you change code

1. Read [README.md](README.md) for requirements, build, and test commands.
2. Read [PRD.md](PRD.md) and [AGENTS.md](AGENTS.md) for architecture, invariants, and workflow rules. Oxys never modifies original photos or writes into photo folders except XMP sidecars (and atomic temporary files).
3. Open an issue to discuss behavior changes before you write code.

## Pull request checklist

1. Keep each pull request small and focused on one change.
2. Put testable logic in `Packages/<Module>/` and keep `App/Oxys/` thin.
3. Add or update unit tests (including a seeded property, differential, or simulation test for new package logic).
4. Run `make test` and confirm all package unit tests pass.
5. Run `make build` (Release) and `make check-arch` (must output `arm64`).
6. Include no third-party dependencies without approval, and keep [docs/license-audit.md](docs/license-audit.md) accurate (no GPL-only, AGPL, or LGPL dependencies).

## Security issues

Follow [SECURITY.md](SECURITY.md) to report security bugs privately.

## License

Contributions are licensed under the GNU General Public License, version 3 or any later version. See [LICENSE](LICENSE) for details.
