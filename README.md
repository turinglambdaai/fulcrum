# Fulcrum

One keystroke. Everything within reach. A keyboard-first launcher for macOS, Windows, and Linux — one Racket brain, three first-party native UIs, no WebView anywhere.

[![CI](https://github.com/turinglambdaai/fulcrum/actions/workflows/ci.yml/badge.svg)](https://github.com/turinglambdaai/fulcrum/actions/workflows/ci.yml) ![Windows](https://img.shields.io/badge/Windows-WinUI_3-0078D4?logo=windows11&logoColor=white) ![macOS](https://img.shields.io/badge/macOS-SwiftUI-000000?logo=apple&logoColor=white) ![Linux](https://img.shields.io/badge/Linux-GTK4-F9A03C?logo=linux&logoColor=white) [![License](https://img.shields.io/badge/license-BUSL--1.1-blue)](LICENSE) ![Version](https://img.shields.io/badge/version-0.14.1-C15F3C)

**English** · [中文](README.zh-CN.md)

New to launchers? Start with the **[user guide](docs/user-guide.md)** — it assumes you have never used one. 中文用户请读[用户指南](docs/user-guide.zh-CN.md)。

## Start here

Existing launcher, clipboard, plugins and BYOK features remain free. No Pro checkout is open. Desktop developer previews for macOS, Windows and Linux. Permission and shortcut behavior varies with the OS and Linux display session.

[Installation, first use, privacy, backup and recovery](docs/user-guide.md) · [简体中文](docs/user-guide.zh-CN.md)

## Install on macOS (developer preview)

Choose your Mac build from [GitHub Releases](https://github.com/turinglambdaai/fulcrum/releases/latest):
[Apple Silicon / M-series DMG](https://github.com/turinglambdaai/fulcrum/releases/latest/download/fulcrum-macos-arm64.dmg) or
[Intel DMG](https://github.com/turinglambdaai/fulcrum/releases/latest/download/fulcrum-macos-x64.dmg).
Open the **DMG**, drag **Fulcrum** onto **Applications**, eject the disk image, then launch **Fulcrum from Applications**, not from the mounted installer. The icon on the right in the DMG is an Applications shortcut.

**Signing note:** Current release jobs use development/ad-hoc signing, not an Apple-notarized Developer ID build. Gatekeeper may block the first launch. Verify the download comes from the official release before making any exception; see [Apple's guidance](https://support.apple.com/102445). Do **not** globally disable Gatekeeper or strip quarantine attributes. We are tracking signed/notarized distribution separately. On first use, grant Accessibility permission only when Fulcrum requests it for clipboard paste or snippets. See the [macOS first-run guide](docs/user-guide.md#install-and-first-launch-on-macos).

## What is Fulcrum?

Press one global hotkey and a floating command palette appears:

- **Fuzzy-search everything** — apps, clipboard history, snippets, each with weighted multi-field ranking
- **Paste anywhere** — clipboard rows paste straight into the app you came from; Copy stays one ⌘K away
- **Calculate inline** — exact arithmetic, functions, constants; ↵ copies the answer
- **Clipboard history** — every copy recorded on-device, searchable, pinnable
- **Snippets** — named text expansions with keywords, created from the launcher itself (`add snippet addr 42 Wall Street`)
- **Web-search bangs** — `!g`, `!gh`, `!so`, `!w`, `!yt`, `!m`, `!d`, `!t`
- **Quicklinks** — your own URL templates claimed by a keyword (`yt nature`), created from the launcher itself
- **Window management** — left/right half, maximize, almost-maximize, center, restore, natively on all three platforms
- **File search** — `find <query>` merges a local persistent filename index with Spotlight on macOS, Windows Search on Windows, and `plocate`/`locate` on Linux
- **BYOK AI with streaming** — bring your own OpenAI / Anthropic / Ollama key: `ai summarize`, `ai clean`, `ai translate <lang>`, `ai explain`, `ai chat <msg>`, `ai <question>` — the answer streams into the panel as it is generated and copies to your clipboard when done; the key is used to authenticate requests to your configured provider; it must not be included in sync or diagnostics
- **System commands** — lock, sleep, restart
- **Plugins** — any language that speaks JSON over stdio ([FPP1](docs/plugins.md)), plus twenty-six first-party plugins installed from the launcher itself (query `gallery`)
- **Sync (beta)** — settings and snippets mirrored to any cloud-synced folder; a wiped machine restores from the mirror

Local search (including indexed file names and paths), history and snippets are stored on your device. Plugins, BYOK requests and configured sync have separate network/data destinations.

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
├── gallery/                # 26 first-party FPP1 plugins (installable in-app)
├── tests/                  # backend tests (raco test tests/)
├── docs/                   # user-guide.md, plugins.md, fpp2.md, registry.md
├── site/                   # fulcrum.jrtx.site (GitHub Pages)
└── .github/workflows/      # CI matrix + tag-driven release pipeline
```

## Status (developer preview)

Developer preview. The backend is complete and tested (101 test cases over ranking, stores, plugins, AI, and the signed update pipeline) and ships a twenty-six-plugin first-party gallery (query `gallery` to install) plus a settings/snippets sync beta (`sync-root`). All three hosts track the backend contract: Windows (WinUI 3), macOS (SwiftUI), and Linux (GTK4) — the Linux host builds through the official `raco rivet build` Linux path introduced in [Rivet 0.3](https://github.com/turinglambdaai/rivet). Known platform edges are stated in the [user guide](docs/user-guide.md#troubleshooting) rather than papered over: file search leans on each platform's index (a Windows machine with the index off falls back to a bounded slow scan), and the Linux host wants `wtype` for paste-to-frontmost on Wayland. `raco rivet doctor` / `dev` is the supported developer loop on every platform.

## Development

Prerequisites: [Racket CS](https://racket-lang.org/) 9.3 (stable), a Rivet checkout linked as a package (v0.3.0 or later), and the platform toolchain (Xcode CLT on macOS, VS 2022 Build Tools on Windows, `build-essential cmake pkg-config libgtk-4-dev zlib1g-dev liblz4-dev libncurses-dev libx11-dev libxtst-dev` on Linux — `raco rivet doctor` prints the exact list when something is missing).

```bash
raco pkg install --auto --no-docs --link /path/to/rivet
raco make app/core/*.rkt app/backend.rkt
raco test tests/
raco rivet acceptance --json # packaged product acceptance on this platform
```

Run the launcher through the Rivet toolchain (macOS / Windows):

```bash
raco rivet doctor
raco rivet dev
```

Build a plugin instead? Start with [gallery/epoch](gallery/epoch) and [docs/plugins.md](docs/plugins.md) — Python is enough.

## License

Fulcrum's core is source-available under BUSL-1.1 with a change date to MIT (see [LICENSE](LICENSE)). The plugin protocol ([docs/plugins.md](docs/plugins.md)) and the example plugin are MIT — plugins are your code, and the protocol is open even though the launcher core is not. The business reasoning behind this split is documented in [docs/business.md](docs/business.md).
