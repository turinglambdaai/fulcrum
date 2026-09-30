# Changelog

All notable changes to Fulcrum are documented here. Versions follow
[SemVer](https://semver.org/); the `build` number in `rivet.rktd` increments
independently per platform packaging run.

## 0.1.0

### Changed

- Migrate the Linux host onto Rivet 0.3's official Linux support: the project now uses the standard `linux/` host directory, codegen emits the `rivet::linux_runtime` client for the Linux host, and CI builds through `raco rivet build` with an embeddable Racket CS 9.3 — replacing the hand-rolled CMake bridge. Launcher specifics (X11 global hotkey, EWMH overlay chrome, single-instance `--toggle`) ride on top of the official runtime and startup model.

### Added

- Shared Racket backend (`app/backend.rkt`) over RVT1: `search`,
  `run-action`, `index-rebuild`, `clipboard-record/history/clear`,
  `snippet-list/save/delete`, `settings-list/set`, `plugins-list/reload`,
  `update-check`; States `theme`, `hotkey`, `version`; Events
  `copy-to-clipboard`, `open-url`, `notify`, `update-available`.
- Search engine (`app/core/engine.rkt`) with weighted multi-field fuzzy
  ranking (app metadata, snippet names/keywords/text, clipboard content),
  recents boost with persistence, and a single 8-column result row contract
  shared by every host.
- Calculator provider: self-contained recursive-descent parser — no `eval`
  — with exact arithmetic, right-associative `^`, postfix factorial,
  scientific notation, 18 functions, 4 constants, and every failure
  converted to a one-line `exn:calc`.
- Application discovery per platform: `.app` bundles (macOS, CFBundleName
  via plutil), XDG `.desktop` entries with NoDisplay/Hidden/Type filtering
  (Linux), Start Menu `.lnk/.url/.exe` (Windows).
- Clipboard history store: dedupe-by-content move-to-front, pinning that
  survives the size limit, atomic JSON persistence, bounded entries.
- Snippets store: CRUD by id, keyword lookup, fuzzy search, atomic
  persistence.
- Web-search provider: 8 bangs plus a default-engine fallback row; strict
  RFC 3986 percent-encoding; host-side open restricted to http(s).
- System commands: lock/sleep/restart per platform with availability
  probes.
- **FPP1 plugin protocol** (`app/core/plugins.rkt`, spec in
  `docs/plugins.md`): external process per query/run, one JSON object per
  line, per-call timeout, manifest validation, relative-path entry
  resolution, load-error surfacing. Reference plugin
  `examples/plugins/epoch` (Python).
- Settings manager over `rivet/system`: 10 typed keys, stale-value
  fallback, loud invalid writes.
- Update wiring over `rivet/distribution`: Ed25519-verified channel
  manifest checks; developer builds honestly report "updates unavailable"
  until a key is embedded (runbook §2).
- macOS host: SwiftUI floating panel, nonactivating `NSPanel`, Carbon
  global hotkey (⌥Space with ⌃⌥Space fallback), pasteboard watcher,
  debounced generation-guarded search.
- Windows host: WinUI 3 topmost overlay, `RegisterHotKey` (Alt+Space with
  Ctrl+Alt+Space fallback), `WM_CLIPBOARDUPDATE` watcher, window-subclass
  message pump, stale-completion-guarded search.
- Linux host (experimental): GTK4 panel, X11 `XGrabKey` hotkey with an
  honest Wayland message (`fulcrum --toggle` for compositor keybindings),
  embedded Racket CS over a socketpair through Rivet's shared RVT1 codec.
- CI matrix (backend tests on all three OSes, host compile smokes, FPP1
  fixture end-to-end) and a tag-driven release pipeline with
  tag/version/changelog validation, dev/production packaging, Ed25519
  update-manifest signing, and draft GitHub releases.
- Product site (`site/`, fulcrum.jrtx.site, bilingual), business plan
  (`docs/business.md` + 中文), release runbook, BUSL-1.1 licensing with an
  MIT plugin protocol.

### Tests

- 39 backend tests: fuzzy ranking anchors, calculator surface and hostile
  input, clipboard dedupe/pin/limit/persistence, snippet CRUD, FPP1
  end-to-end with real subprocesses (including a hanging-plugin timeout
  case), desktop-entry parsing, engine ranking/actions/events, settings
  round-trips and stale-value fallback.
