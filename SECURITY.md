# Security Policy

Fulcrum handles sensitive data by design (clipboard history, snippets,
on-device search). Reports are taken seriously and handled quickly.

## Reporting a vulnerability

Email **security@jrtx.site** (or open a GitHub security advisory on this
repository). Include reproduction steps, affected versions, and your
assessment of impact. You will get an acknowledgment within 72 hours.

Please do not open public issues for security problems.

## Scope

In scope:

- The RVT1 transport and embedded-runtime boundary (`app/backend.rkt`,
  Rivet's protocol layer)
- The FPP1 plugin sandbox claims in `docs/plugins.md` — v1 permissions are
  advisory and plugins are trusted code with user-level privileges; claims
  beyond that are bugs in the docs, not just the code
- Update trust: manifest verification, key handling (`app/update.rkt`,
  `rivet/distribution`)
- Local data handling: clipboard/snippet stores, settings, the single
  instance pid file
- The hosts' handling of Events (`open-url` must stay http(s)-only;
  `copy-to-clipboard` must not leak to logs)

Out of scope: social engineering, physical access attacks, and
vulnerabilities in the OS WebView (Fulcrum does not use one).

## Design notes reviewers should know

- The backend binds no network ports; RVT1 runs over inherited fds.
- Plugin processes are spawned per call and killed after the timeout;
  there is deliberately no warm plugin lifecycle in FPP1.
- Update checks require an Ed25519-verified manifest and never install
  anything in 0.1 — they report availability only.
- Clipboard content and snippets are stored as JSON under the platform
  data directory with user-only permissions by directory convention; full
  disk encryption is the at-rest story, as with every local-first tool.

## Supported versions

Security fixes land on `main` first and ship with the next tagged release.
During the 0.x developer preview there is no LTS branch.
