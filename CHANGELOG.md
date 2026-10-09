# Changelog

All notable changes to Fulcrum are documented here. Versions follow
[SemVer](https://semver.org/); the `build` number in `rivet.rktd` increments
independently per platform packaging run.

## 0.4.2

### Changed

- **Releases now ship one human installer per platform instead of bare
  archives**: `fulcrum-macos.dmg`, `fulcrum-windows-x64.msi` (Start-menu and
  desktop shortcuts included), and `fulcrum-linux-x64.tar.gz`. The release
  pipeline runs `raco rivet release`, and the signed channel manifest pins
  those installers — no more unpacking a WinUI runtime directory to hunt
  for `RivetHost.exe`.
- **The app has a brand icon on all three platforms.** One amber
  lever-on-pivot mark (matching the site palette) ships as the Windows
  executable icon, the macOS `.icns`, and a full hicolor set plus a menu
  entry for Linux.
- **Linux installs like a native package**: the release adds
  `fulcrum_<version>_amd64.deb` — `/opt/fulcrum`, a `/usr/bin/fulcrum`
  command, a desktop entry, and icons — alongside the tarball, and the
  Linux binary is named `fulcrum` (not the scaffold's `RivetHost`) to
  match the docs and the compositor keybinding.
- Every release now publishes `SHA256SUMS.txt` and renders its changelog
  section plus per-platform install instructions into the release notes.

### Fixed

- The update check now actually ships the redirect-following fetch:
  0.4.1 announced this fix but its release pin predated rivet#153, so
  0.4.1 binaries still failed every in-app update check at signature
  verification. 0.4.2 builds on the commit that carries the fix.
- SIGTERM/SIGINT now stop the whole app: the Linux host installs Rivet's
  shutdown hook, so a termination signal runs the same orderly backend
  stop as the GTK shutdown signal and then exits. Previously the backend
  died on the signal while the panel stayed up, half-dead; only SIGKILL
  removed it.

## 0.4.1

### Fixed

- The update check follows HTTP redirects (rivet#153): GitHub release
  assets answer with a 302 to their CDN, and the previous fetch verified
  an empty redirect body — every in-app update check failed at signature
  verification. No app changes; rebuilt on the fixed rivet.

## 0.4.0

### Added

- **Online updates go live**: the update channel now serves the signed
  channel manifest straight from GitHub Releases
  (`releases/latest/download/manifest.json`) — no separate downloads origin
  to operate. The default `update-base-url` setting points there, and the
  updater fetches `/manifest.json` under whichever base is configured.
  Checks stay signature-verified (Ed25519, key `fulcrum-2026-10`) and
  honest: a developer build reports "developer build", a failed origin
  reports the error verbatim.

## 0.3.0

### Added

- **First-party plugin gallery** — ten plugins built into the app, listed
  by querying `gallery` or `plugins`, installed and uninstalled from the
  launcher itself (each install row is an engine action; no new UI surface
  on any host, and installed plugins are queryable without a restart).
  Fuzzy queries suggest installs for missing plugins the way apps are
  suggested. The gallery can only remove plugins it installed (a marker
  file guards user-installed ones), and wire-supplied plugin ids are
  validated against a strict pattern before touching the filesystem.
  The opening roster: Epoch (`ts`), Unit Converter (`u`), Regex (`re`),
  Timezone (`tz`), GitHub (`gh`), Cargo (`crate`), Homebrew (`brew`),
  Docker (`dk`), winget (`winget`), Bitwarden (`bw`) — every tool-backed
  plugin degrades to a single explanatory row when its CLI or network is
  unavailable.
- **Sync beta** for settings and snippets: point the new `sync-root`
  setting (or the `FULCRUM_SYNC_DIR` environment variable, which also
  bootstraps a wiped machine) at any directory a file sync service
  replicates; every write mirrors there and a newer mirror restores the
  local file at startup — that is the whole wipe-and-restore story.
  Conflict policy is newest-file-wins by mtime; clipboard history and
  recents are deliberately not synced.
- **Currency plugin** (the eleventh first-party) — `cur 100 usd in eur`
  against the keyless open.er-api.com daily feed, with the usual
  graceful-degradation row when the network is down.
- **Quicklinks** — user-defined URL templates claimed by a keyword, the
  cheap half of Raycast's quicklinks: `yt nature` opens the YouTube
  search for "nature"; a URL without `{query}` is a plain bookmark.
  Created from the launcher itself with a one-line grammar
  (`add link yt https://youtube.com/?q={query} YouTube`), listed and
  deleted under `quicklinks`, and synced with settings and snippets.
- **Window management** — Left Half, Right Half, Maximize, Almost
  Maximize, Center and Restore for the frontmost window. The engine
  ranks the rows; each host executes natively (Accessibility API on
  macOS, which honestly reports the missing permission until granted;
  `SetWindowPos` on Windows; EWMH `_NET_MOVERESIZE_WINDOW` on
  Linux/X11, compile-tested like the rest of that host). A new
  `delegated` action status carries the backend's verdict to the host.
- **BYOK AI** (the roadmap's phase-1 shape: the user's key, our cost
  zero): `ai summarize`, `ai clean`, `ai translate <lang>`, `ai explain`,
  and bare `ai <question>` — with the clipboard attached as context where
  it makes sense. Rows appear instantly in search; running one calls the
  provider (OpenAI, Anthropic, or a local Ollama endpoint) and the answer
  copies to the clipboard, so a slow model never traps the user in the
  panel. The API key lives in `ai-keys.json` inside the data directory
  and is deliberately excluded from sync; `ai key <secret>` saves it from
  the launcher, `settings → ai-provider` (now a cycle in the settings
  rows) picks openai / anthropic / ollama. Unconfigured installs show
  honest setup rows instead of pretending.
  AI is a first-class citizen now: **`ai chat <msg>` holds a
  conversation** (session history threaded into every request, capped at
  eight exchanges, `ai chat reset` clears), **any typed question** —
  `what is entropy?`-style, configured installs only — offers an
  "Ask AI" row without the prefix, and the **last answer stays visible**
  under `ai` as a one-keystroke copy instead of vanishing into the
  clipboard.
- **File search** — `find <query>` over Spotlight (`mdfind -name`,
  deduped, capped at 8 rows); a result opens with the platform opener.
  Linux and Windows get one honest row instead of a pretend search until
  their index providers land.
- **Settings in the launcher** — the hosts have no settings window, so
  the launcher is the settings UI: query `settings` lists theme,
  max-results and the clipboard/web/plugin toggles with their current
  values as badges; running a row cycles or toggles the value and
  notifies the new one.
- **Plugin center** — the launcher is the management surface: query
  `plugins` for every installed plugin with an Enabled/Disabled toggle
  (persisted, honored by the loader on reload), a row that reveals the
  plugins directory, and the gallery's install/uninstall rows underneath.
  `install plugin <path>` copies a third-party plugin folder into place —
  the destination comes from the folder's manifest id (never the folder
  name, so a spoofed name cannot escape the plugins directory) — and
  `plugins.uninstall` removes any plugin, gallery-owned or user-installed.
- **Marketplace-grade plugin center** — first-party manifests now carry
  author, category, and per-command usage examples. `plugins <name>`
  expands a detail view: every command with a **copyable example**
  (select → the example sits on the clipboard, paste into a fresh query
  to try it), the declared permissions by name (or an honest "none
  declared"), and the category. The **update flow** exists at last: when
  the app ships newer plugin code than an installed copy, the listing
  offers "Update <name> → v<new>" and overwrites in place (gallery-owned
  plugins only; user data never lives in plugin directories).
- Gallery, sync, quicklinks, AI, file search and the plugin center carry
  21 new backend tests (69 total).

### Changed

- The epoch reference plugin moved from `examples/plugins/` to
  `gallery/epoch` — the gallery is now the single home of first-party
  plugins, and `scripts/gen-gallery.rkt` embeds their files into the
  compiled backend (CI regenerates and fails on drift).
- The backend now reads its version from the staged
  `rivet-app-info.rktd` (`rivet/app-info`) instead of a hardcoded string,
  with the rivet.rktd version as the headless fallback. 0.2.0 shipped
  reporting "0.1.0", which would have made every install believe an
  update was available once the channel manifest went live.

### Changed

- **Menu bar / tray presence** (the discoverable way in, and the only
  quit affordance since Esc just hides): macOS installs the first-party
  rivet menu bar with "Open Fulcrum" and "Quit Fulcrum"; Windows rides
  the first-party Shell_NotifyIcon tray surface with the same two
  actions (left click toggles the launcher, right click opens the
  menu). Linux is deferred honestly — the rivet tray contract is
  deliberately absent there (StatusNotifierItem, upstream #118).
- All hosts: **⌘K action panel** — Ctrl+K (Win/Linux) and ⌘K (macOS)
  open the selected row's secondary actions: Reveal in Finder and Copy
  path for apps, Pin/Unpin and Delete for clipboard entries, Delete for
  snippets, Copy URL/path for links, files and web rows. Esc walks back
  to the live search; mutating actions keep the launcher open instead of
  dismissing it.
- All hosts: **Esc follows the Alfred/Raycast convention** — it clears
  the query first and hides the panel only when the query is already
  empty, so a stray Esc never throws away typed text. The app itself
  never quits: the panel hides, the single instance (and the clipboard
  watcher) stay resident.

### Fixed

- macOS host: result row identity was `(action id, arg)` — unique for
  engine providers, but FPP1 plugins legitimately return several rows
  sharing one arg (Epoch renders a timestamp as UTC *and* local). SwiftUI
  collapsed them to one row; the row title now participates in the
  identity. Found on the first real-machine gallery smoke.

## 0.2.0

### Changed

- macOS host: Raycast-grade panel — under-window vibrancy with rounded
  corners and a hairline edge, real dock icons for application rows (tuned
  SF Symbols for calculator/clipboard/snippet/web/plugin/system rows),
  inset amber selection highlight with a ↵ affordance chip on the selected
  row, and tightened typography and spacing. The brand amber (#D97706)
  matches the product site; both appearance modes verified on screen.
- All hosts: single-instance activation now rides Rivet's first-party
  system services — `RivetSingleInstance` on macOS, `SingleInstanceLease`
  on Windows and Linux — replacing the hand-rolled pid-file + SIGUSR1
  scheme on Linux (the `fulcrum --toggle` contract is unchanged; the
  activation handler hops to the GTK main loop) and adding the previously
  missing guard on macOS and Windows, where a second launch silently grew
  a second panel.
- Plugins: the FPP1 spawn path resolves interpreter names on PATH like a
  shell would. A manifest entry of `"python3"` forked a doomed child
  (Racket's `subprocess` does no PATH lookup), the failure vanished into
  an empty result list, and the reference plugin never appeared in
  searches. Spawn failures now surface as plugin errors instead.

### Fixed

- End-to-end verification on macOS surfaced launch-blocking backend bugs
  that CI never reached, because every discovery-path test exercised only
  the Linux branch:
  - `macos-apps-from-dirs` passed a `#:stop` keyword to `in-directory`,
    which takes its descend? predicate positionally — the backend died
    during `engine-rebuild-index!` on every real launch.
  - `application-id-from-path` formatted a hash in base 36;
    `number->string` accepts only 2/8/10/16, so macOS and Windows
    discovery crashed the same way.
  - `spawn-command`/`run-command` passed bare program names to Racket's
    `subprocess`, which performs no PATH lookup: the child forked, exec
    failed, and the helper reported success. Launching applications
    (`open`) and the `plutil` bundle-name probe never actually worked;
    the probe was masked by the directory-name fallback. Program names
    are now resolved on PATH (or rejected) in `app/core/proc.rkt`.
- macOS host: result rows carried the *action* id (`app.launch`) as their
  SwiftUI identity, so the panel rendered one row a dozen times. Row
  identity is now `(action id, arg)`, unique per row; the action id still
  drives `run-action`.
- macOS host: backend events were parsed as lists, but RVT1 event frames
  hand the host a bare string payload — copy-to-clipboard, open-url and
  notify were silent no-ops. The calculator's ↵-to-copy now works.
- macOS host: the Esc/↑↓ key handler was a background view outside the
  field editor's responder chain and never fired; replaced with a window
  local `NSEvent` monitor.
- Windows and Linux hosts: the same event-payload bug as the macOS host —
  they parsed event values as lists, but the runtime delivers the bare
  string after unwrapping the RVT1 `[name, value]` frame, so
  copy-to-clipboard, open-url and update-available were silent no-ops.
- Linux host: search completions carried no generation guard (both other
  hosts have one), so two overlapping searches could let a stale result
  set overwrite the newer one.
- macOS (Rivet): `raco rivet build` staging invalidated the embedded
  framework's signature via `install_name_tool` and never re-signed it,
  so AMFI killed every `raco rivet dev` launch with "Code Signature
  Invalid". Staging now ad-hoc re-signs the inner dylib and the wrapper;
  `package` re-signs with the release identity as before.

### Tests

- 39 → 43 backend tests: macOS and Windows application discovery from
  fixture directories (plist bundle name with graceful fallback, no
  descent into nested `.app`, shortcut file filtering), and PATH
  resolution plus missing-binary behavior for
  `run-command`/`spawn-command`.

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
