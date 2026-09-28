# Contributing to Fulcrum

Thank you for looking under the hood. Fulcrum is source-available
(BUSL-1.1, see [LICENSE](LICENSE)), and contributions are welcome under the
same terms: by submitting a pull request you agree your contribution is
licensed under BUSL-1.1, with the same MIT change date as the rest of the
Work.

## Ground rules

1. **The wire contract is cross-platform.** `app/backend.rkt` declares the
   RPC/Event/State surface and the 8-column result row. Changing any of it
   is a three-platform release, not a local edit — state the impact in your
   PR description and update the checked-in generated clients
   (`windows/GeneratedBackend.hpp`, `macos-host/Sources/RivetHost/GeneratedBackend.swift`)
   in the same commit.
2. **Fail honestly.** Missing runtimes, bad plugin manifests, unavailable
   hotkeys: report what failed and what to do next. No silent fallbacks.
3. **Privacy is a feature.** No network calls from the backend except the
   update check. No telemetry. New storage stays under the platform data
   directory with atomic writes.
4. **Tests pin contracts.** If you change behavior a test covers, change
   the test in the same commit and say why.

## Before you push

```bash
raco make app/core/*.rkt app/backend.rkt
raco test tests/
```

Platform hosts additionally compile in their CI jobs; if you touch
`windows/` or `macos-host/`, say whether you were able to build locally.

## Areas that especially want help

- Linux host polish (GTK4 + embedded Racket CS — see
  [linux-host/README.md](linux-host/README.md))
- Plugins! The protocol is MIT and the reference plugin is 100 lines of
  Python ([docs/plugins.md](docs/plugins.md))
- Documentation translations

## Reporting issues

Include: OS + version, Fulcrum version (`fulcrum --version` from the staged
build, or the version State), steps to reproduce, and — for backend issues
— the log under the platform data directory. Security issues go through
[SECURITY.md](SECURITY.md), not public issues.
