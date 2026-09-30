# Fulcrum

One keystroke. Everything within reach. A keyboard-first launcher for macOS, Windows, and Linux — one Racket brain, three first-party native UIs, no WebView anywhere.

**English** · [中文](README.zh-CN.md) · [fulcrum.jrtx.site](https://fulcrum.jrtx.site)

[![CI](https://github.com/turinglambdaai/fulcrum/actions/workflows/ci.yml/badge.svg)](https://github.com/turinglambdaai/fulcrum/actions/workflows/ci.yml) ![Windows](https://img.shields.io/badge/Windows-WinUI_3-0078D4?logo=windows11&logoColor=white) ![macOS](https://img.shields.io/badge/macOS-SwiftUI-000000?logo=apple&logoColor=white) ![Linux](https://img.shields.io/badge/Linux-GTK4-F9A03C?logo=linux&logoColor=white) [![License](https://img.shields.io/badge/license-BUSL--1.1-blue)](LICENSE) ![Version](https://img.shields.io/badge/version-0.1.0-C15F3C)

🏠 Product page: **https://fulcrum.jrtx.site**

## What is Fulcrum?

Press one global hotkey and a floating command palette appears:

- **Fuzzy-search everything** — apps, clipboard history, snippets, each with weighted multi-field ranking
- **Calculate inline** — exact arithmetic, functions, constants; ↵ copies the answer
- **Clipboard history** — every copy recorded on-device, searchable, pinnable
- **Snippets** — named text expansions with keywords
- **Web-search bangs** — `!g`, `!gh`, `!so`, `!w`, `!yt`, `!m`, `!d`, `!t`
- **System commands** — lock, sleep, restart
- **Plugins** — any language that speaks JSON over stdio ([FPP1](docs/plugins.md))

Search, history, and snippets never leave your device. There is no telemetry in 0.1.

## Why another launcher?

Because nothing offers Raycast-grade polish on all three desktops with a *native* UI. Fulcrum is built on [Rivet](https://rivet.jrtx.site): one shared Racket backend embedded into each app, with SwiftUI on macOS, WinUI 3 on Windows, and GTK4 on Linux. Not Electron. Not a web wrapper. The Windows app is a Windows app; the macOS app is a macOS app.

| | Fulcrum | Raycast | PowerToys Run | Ulauncher |
|---|---|---|---|---|
| Platforms | macOS + Windows + Linux | macOS (+ Windows beta) | Windows | Linux |
| Native UI | **per-platform first-party** | macOS-native | WinUI (WPF shell) | GTK |
| Backend | one embedded Racket CS | per-platform | C# | Python |
| Plugins | JSON over stdio, any language | TypeScript, in-process | C# | Python |
| Price | free core; Pro planned for 1.0 | free + Pro | free | free |

## Repository layout

```text
fulcrum/
├── rivet.rktd              # release identity, version, deployment targets
├── app/
│   ├── backend.rkt         # the RVT1 wire contract (RPCs, Events, States)
│   ├── update.rkt          # signed-manifest update checks (rivet/distribution)
│   └── core/               # search engine, providers, stores, FPP1 plugins
├── macos-host/             # SwiftUI panel + Carbon global hotkey
├── windows/                # WinUI 3 overlay + RegisterHotKey
├── linux/                  # GTK4 panel + X11 grab (Rivet 0.3 Linux preview)
├── examples/plugins/epoch  # the FPP1 reference plugin
├── tests/                  # 39 backend tests (raco test tests/)
├── docs/                   # plugins.md, release-runbook.md, business plan
├── site/                   # fulcrum.jrtx.site (GitHub Pages)
└── .github/workflows/      # CI matrix + tag-driven release pipeline
```

## Status: v0.1.0 (developer preview)

Developer preview. The backend is complete and tested (39/39). All three hosts are feature-complete against the backend contract: Windows (WinUI 3), macOS (SwiftUI), and Linux (GTK4) — the Linux host now builds through the official `raco rivet build` Linux path introduced in [Rivet 0.3](https://github.com/turinglambdaai/rivet). `raco rivet doctor` / `dev` is the supported developer loop on every platform.

## Development

Prerequisites: [Racket CS](https://racket-lang.org/) 9.3 (stable), a Rivet checkout linked as a package (v0.3.0 or later), and the platform toolchain (Xcode CLT on macOS, VS 2022 Build Tools on Windows, `build-essential cmake pkg-config libgtk-4-dev zlib1g-dev liblz4-dev libncurses-dev` on Linux — `raco rivet doctor` prints the exact list when something is missing).

```bash
raco pkg install --auto --no-docs --link /path/to/rivet
raco make app/core/*.rkt app/backend.rkt
raco test tests/
```

Run the launcher through the Rivet toolchain (macOS / Windows):

```bash
raco rivet doctor
raco rivet dev
```

Build a plugin instead? Start with [examples/plugins/epoch](examples/plugins/epoch) and [docs/plugins.md](docs/plugins.md) — Python is enough.

## License

Fulcrum's core is source-available under BUSL-1.1 with a change date to MIT (see [LICENSE](LICENSE)). The plugin protocol ([docs/plugins.md](docs/plugins.md)) and the example plugin are MIT — plugins are your code, and the protocol is open even though the launcher core is not. The business reasoning behind this split is documented in [docs/business.md](docs/business.md).
