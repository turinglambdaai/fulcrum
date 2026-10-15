# Changelog

All notable changes to Fulcrum are documented here. Versions follow
[SemVer](https://semver.org/); the `build` number in `rivet.rktd` increments
independently per platform packaging run.

## [Unreleased]

### Fixed

- **The Linux host is no longer an invisible app.** The panel now opens at
  launch: starting hidden was unworkable on any session where the summon
  path wasn't alive yet — Wayland before the portal consent is granted,
  after a reboot, a rejected grab — so a fresh install looked dead (no
  window, dead hotkey, nothing to click). Esc or focus loss still hides
  the panel immediately.
- **`fulcrum --toggle` with nothing running is a summon, not an error.**
  It used to exit with `no running instance to toggle`, which killed the
  documented compositor-keybinding fallback after every reboot; now it
  starts the launcher and opens the panel.
- The portal hotkey path reports the binding the compositor actually
  chose ("Summon hotkey: Alt+Space") in the status bar instead of
  silence; `linux/README.md` now describes the real portal-first hotkey
  and lease-based single instance (both had drifted).

## [0.11.0] - 2026-10-14

Foundation round — the launcher finally answers "what is this and where
do I report it", on every host, and the Windows and Linux hosts learn to
speak the shared language.

### Added

- **About, on all three hosts.** Query `about` in the launcher and the
  backend ranks one `about.open` row (version, website, feedback,
  license); running it delegates host-native — a native About window on
  macOS, a GTK about dialog on Linux, a ContentDialog on Windows. The
  panel is reachable without the row too: macOS grows an "About Fulcrum"
  menu-bar item and its long-empty Settings scene now shows the About
  panel; Windows gains "About Fulcrum" in the tray menu. Every panel
  carries the version line, the site (fulcrum.jrtx.site), the issue
  tracker and "Business Source License 1.1" (macOS strings ride the
  shared/i18n single source — new `about*` keys, zh and en).
- **The Windows and Linux hosts speak the shared i18n source.** Both
  hardcoded the update/about surface in English; they now load the staged
  `shared/i18n` res JSON (dependency-free line-based loader over an
  embedded fallback table of the same keys) and follow the backend
  `language` setting, applied on the next launch — a missing file
  degrades to correct copy, never to key names.
- **GitHub issue templates** (bug report + feature request) so feedback
  from the About links lands structured: the bug form asks for the
  platform pair, install shape and hotkey setup, and never for an AI key.
- **Websearch commands are unit-tested**: bang routing, RFC 3986
  percent-encoding of query metacharacters (a stray `&` or `=` is a
  query injection into the browser URL), and the fallback contract.

### Fixed

- **The backend's headless version fallback drifted**: the `must track
  rivet.rktd` literal in `app/backend.rkt` still said 0.10.0 after
  0.10.1 shipped, so every headless run (tests, dev loops) believed it
  was outdated. It now tracks the release (0.11.0 as of this release),
  and `check-release-version.sh` grew a fourth gate — VERSION ==
  rivet.rktd == backend fallback == tag — so the literal can never
  drift again.

### Changed

- **Update failure text is selectable** in the macOS update panel's
  failed state, so the exact error can be copied into a bug report
  instead of retyped (Windows' status line already had its copy
  affordance; Linux' status label is selectable).
- **One RIVET_PIN per workflow**: the five literal rivet pins in CI and
  release collapse into `${{ env.RIVET_PIN }}`, so a rivet bump is one
  edit per file, not a grep-replace.
- **Versionless stable aliases ride every release**: the primary
  installers are also uploaded as `fulcrum-macos-arm64.dmg` (etc.), so
  `releases/latest/download/<alias>` stays a permanent URL and the site
  hero CTA points straight at the right download with OS/arch detection.
- **Dead code leaves**: `files.rkt`'s unused `search-command` and
  `plugins.rkt`'s `remember-results!` are gone; the release runbook §2
  now matches reality (the update verification key is committed source,
  not swapped per release).

## [0.10.1] - 2026-10-14

Engineering-alignment patch — no feature changes to the launcher
itself. The hosts consume Rivet as a package library (rivet v0.11.0)
instead of compiling its sources, the update rollout bucket draws from
cryptographic randomness, the website joins the family design system
(dark theme, Chinese default), and the site gains a bilingual user
manual.

### Added

- **User manual at fulcrum.jrtx.site/guide.html** — a bilingual
  (Chinese default, English via the shared nav switcher) web manual
  following the family manual pattern: a five-minute start (install →
  summon → first command/snippet → paste back into the frontmost app),
  the core features (search, clipboard history, snippets, AI key setup,
  window & system commands, hotkey customization), and a FAQ covering
  the real stumbling blocks — macOS Accessibility grants, where data
  lives, accounts, platform differences, language & theme, failed
  updates, uninstall. Illustrated with real screenshots of the macOS
  panel in light and dark themes; the site nav gains a "Manual" entry.

### Changed

- **Rivet is consumed as a package, never as compiled-in sources**
  (project constraint, rivet#238). The Linux host builds via
  `add_subdirectory("${RIVET_ROOT}/platform/linux")` + `rivet::platform`
  instead of hand-copying the platform translation-unit list; the
  Windows host links `rivet-host.vcxproj` through a `ProjectReference`
  (CRT flavor forwarded via `RivetRuntimeLibrary`) instead of
  `ClCompile`-ing four Rivet sources; the macOS host depends on the
  rivet root `Package.swift` (`.package(path: rivetRoot)`, products of
  package "rivet") instead of the platform subpackage. CI and release
  workflows pin Rivet to the `v0.11.0` git tag instead of floating on
  the package catalog, and the `setup-embed-racket` action reference
  moves from `@main` to `@v0.11.0`.
- **Website (fulcrum.jrtx.site)** aligns with the family design system:
  copper accent palette (`#c15f3c` on `#faf7f2`), a complete dark theme
  with a manual toggle (localStorage choice, system-preference fallback,
  anti-flash head script), and `data-i18n` dictionaries with Chinese as
  the default language (`lang="zh-CN"`; title and meta description
  switch with the language). The hardcoded version badge is gone — the
  homepage no longer states a version number.

### Fixed

- **Update rollout buckets are cryptographically random.** The sticky
  0..99 bucket assigned on first update check is now derived from
  `crypto-random-bytes` instead of `random` — racket/base's PRNG has a
  fixed seed, which put every fresh install into the same lockstep
  bucket and would have defeated any staged rollout.

## 0.10.0 — October 13, 2026

Snippet auto-expansion on macOS and Windows — the last core Raycast
base feature — plus the post-0.9.0 base-completeness wave.

### Added (snippet auto-expansion)

- Type a snippet keyword in any app, a word boundary fires, and the
  keyword is replaced with the full snippet text in place. macOS uses a
  CGEventTap with unicode key injection; Windows uses a low-level
  keyboard hook with SendInput repair. Toggle in `settings` →
  `expansion-enabled` (macOS requires the accessibility permission).
  Linux is not supported — Wayland does not allow the required input
  monitoring, documented in the user guide.

### Added (system commands)

- **Toggle Dark Mode** on macOS (System Events appearance), Windows
  (theme registry), and GNOME (color-scheme); **Log Out** and **Empty
  Recycle Bin** on Windows; **Empty Trash** on macOS and GNOME.

### Fixed (file search was dead on large result sets)

- **File search never returned results for common queries**: run-command
  waited for the child process to exit while the child blocked writing
  output larger than the 64 KiB pipe buffer — a mutual deadlock that
  timed out every search whose result set was big ("find README" on a
  dev machine). The stdout drain now runs concurrently with the exit
  wait; a search that used to return zero rows in 1.5 s now answers in
  ~180 ms with results. Regression test included.

### Added (emoji search)

- **Emoji search**: type two letters and matching emoji appear inline
  (Raycast-style) — Enter pastes the character straight into the app you
  came from, ⌘K/Ctrl+K copies it. A curated local dataset of ~300
  popular emoji with English keywords; no network, no name-table
  download.

### Added (Linux Wayland hotkey)

- The Linux host registers its summon shortcut through the
  `org.freedesktop.portal.GlobalShortcuts` portal where available
  (Wayland compositors and modern desktops): the compositor asks for
  consent once and owns the final binding. Sessions without the portal
  keep the X11 grab; older Wayland sessions still bind
  `fulcrum --toggle` in compositor settings.

### Added (Raycast 2.0 parity: the AI memory trio)

- **Persistent AI memory**: the conversation transcript and last answer
  survive restarts (ai-memory.json, local-only, never synced — a
  transcript is sensitive)
- **`ai undo`**: drop the last chat exchange and retry from there — the
  minimal branching primitive
- **`ai persona <text…>`**: persistent personalization, delivered as a
  system message on every request

### Added (polish wave)

- **`ai model <name>`**: set the AI model from the launcher — model names
  are free-form, so a settings cycle does not fit; bare `ai model` shows
  the current value
- **Tab completion** on all three hosts: Tab autocompletes the selected
  row's title into the query field (the Raycast convention for refining a
  fuzzy hit into exact text)

### Fixed

- AI chat memory and the last-answer row lived in Racket parameters,
  which are per-thread — every RVT1 request runs on its own worker
  thread, so both silently reset between requests in production while
  the single-threaded tests stayed green. Both now live in module-level
  boxes and actually persist for the backend session

## 0.9.0 — October 12, 2026

The launch-parity wave: closing the gaps a user touches daily, with the
FPP2 core landing alongside.

### Added (FPP2 wave)

- **Plugin protocol v2** ([docs/fpp2.md](docs/fpp2.md)): daemon-mode
  plugins stay warm across queries (lazy spawn, per-op timeouts, crash
  backoff, LRU cap, rate-limited results-changed push), results can
  declare ⌘K actions and a detail view (native text + metadata panel on
  every host), and manifests can declare preferences the backend stores
  and injects — edited with `plugin set <id> <pref> <value…>` or cycled
  from the plugin detail rows. FPP1 is unchanged and permanent.
- **Live results**: a new `search-revision` State makes all three hosts
  refresh the on-screen rows when a backend daemon pushes updates.
- Conformance kit: `tests/fpp2-test.rkt` drives a real daemon fixture
  through warm queries, interleaved ops, action routing, preference
  injection, nudge rate-limiting, and the crash/backoff/cold-fallback
  path.

### Fixed

- Update-check results no longer hide the panel before they can be
  read; the status line is copyable on all three platforms.

The launch-parity wave plus the FPP2 core: closing the gaps a user
touches daily, then the plugin protocol upgrade. The wire contract
moved once; all three hosts ride together.

### Added

- **Paste to frontmost**: clipboard rows now paste straight into the app
  the user came from (Enter pastes; Copy stays in the ⌘K panel), snippets
  and the AI last-answer get a "Paste to frontmost" action. Hosts write
  the pasteboard, hide the panel, and synthesize the platform paste
  keystroke — Accessibility on macOS, SendInput on Windows, XTEST on X11
  and `wtype` on Wayland on Linux
- **Streaming AI**: AI answers stream into the panel as they are
  generated (new `AiStream` State, phases running → done|error) and land
  on the clipboard when finished; running an AI row no longer blocks the
  panel for the whole model call
- **Snippet one-liner creation**: `add snippet <keyword> <text…>` saves a
  snippet from the launcher, mirroring `add link`; query `snippets`
  lists the store
- **Host-rendered hotkey and theme**: the launcher hotkey and UI theme
  settings now reach all three hosts — hosts pull them on startup, follow
  live `$state` pushes (the Carbon/Win32/X11 grab re-binds, the panel
  switches appearance), the settings row cycles through four presets,
  and a taken combo falls back with a status note instead of stranding
  the launcher
- **Linux clipboard capture**: the GTK host records clipboard changes
  (1 s poll), so clipboard history finally exists on Linux
- **User guide**: `docs/user-guide.md` (+ `user-guide.zh-CN.md`),
  written for people who have never used a launcher
- **Design drafts for the next wave**: `docs/fpp2.md` (plugin protocol
  v2 — daemon mode, detail view, result actions, preferences, the
  staged permissions ladder) and `docs/registry.md` (the GitHub-only
  curated plugin registry: signed index on Releases, PR-based
  submission, embedded gallery as the offline baseline)

## 0.8.0

Packaging parity release: the release asset set now matches the family
benchmark (taskly) format-for-format on every platform it ships, and the
update feed moves to the family-standard file name.

### Added

- **Linux arm64 joins the matrix**: the Linux job is a two-architecture
  matrix on native `ubuntu-24.04-arm` runners — tar.gz, deb, rpm, AppImage,
  and portable zip, same recipe as x64
- **Portable zips for Linux and Windows** (`fulcrum-<version>-linux-<arch>.zip`,
  `fulcrum-<version>-windows-x64.zip`): rivet release already produced them
  with their own `.sha256` sidecars; the workflow now hoists them into the
  release instead of dropping them (the duplicate rivet macOS zip is
  discarded — the hand-built zip stays)

### Changed

- The signed update feed is now published as `update-manifest.json` (family
  convention) and carries a Linux arm64 tar.gz entry; a byte-identical
  `manifest.json` rides along so pre-0.8.0 clients polling the old name
  keep updating — the alias will be dropped once 0.7.x installs are gone
  from the field (same transition policy payback used)
- The site version badge tracks the release again (it had drifted at v0.5.0)

## 0.7.0

### Added

- **Native Linux packages**: `raco rivet release` now produces deb, rpm, and
  AppImage beside the signed tar.gz on x64 — the family rivet 0.6.1
  linux-formats mechanism, previously opted out on this line. The deb
  installs `/opt/fulcrum` with a desktop entry and pixmaps icon
  (`Depends: libgtk-4-1`); the rpm builds through rpmbuild
  (`Requires: gtk4`); the AppImage bundles its own GTK4 dependency closure
  with the 512 px brand icon (`assets/fulcrum-icon-512.png`, rendered from
  the site favicon SVG) as the top-level AppDir icon. The update feed
  contract is unchanged: the signed channel manifest still pins the four
  portable artifacts, and Linux updates still flow through the tar.gz —
  the new formats ship as GitHub release assets only.

## 0.6.0

### Added

- **Updater 0.2 — download and install** (family pattern, taskly parity):
  the backend now owns the whole verify-download pipeline. `update-check`
  (manual and silent variants) returns a typed `UpdateCheck` record
  (status/version/build/published-at/installer/size-bytes); `update-download`
  streams the signed artifact to `<data-dir>/updates/` on a background
  thread with progress in a state box; `update-state` reports phase
  (idle | checking | downloading | downloaded | error), percent and the
  verified file path. The 4-hour silent-check throttle is backend-owned
  (settings key `update-last-check`) so all three hosts share it, and the
  staged-rollout bucket persists sticky as `update-rollout-bucket`.
- **Launcher update rows**: query `update` on every platform surfaces the
  one row the current phase wants — check, download (version + size),
  live progress, then "Quit and install" (macOS) or "Open the updates
  folder" with honest manual-install guidance (Windows: the downloaded
  .msi; Linux: the .tar.gz). Windows and Linux hosts additionally poll
  download progress into the status line and run the throttled silent
  check at launch.
- **macOS update window + in-place install**: a menu-bar "Check for
  Updates…" item opens an update panel (available → confirm version + size
  → download progress → quit-and-install). Installation swaps the verified
  bundle atomically (unzip → ditto → keep the old bundle as `.old` until
  the relaunch succeeds, taskly's proven swap script) and relaunches.
- **i18n for the update flow**: `shared/i18n/{zh,en}.json` ship as staged
  resources (`resources` clause in rivet.rktd) and the macOS host renders
  the update panel in the configured language (`language` setting, zh
  default, toggle via the launcher settings rows).

### Fixed

- The updater no longer draws a fresh rollout bucket per check; the bucket
  is drawn once and persisted, matching the family update contract.

## 0.5.0

### Changed

- **Release artifacts now carry the full version and architecture in their
  names** — `fulcrum-0.5.0-macos-arm64.dmg`, `fulcrum-0.5.0-macos-arm64.zip`,
  `fulcrum-0.5.0-windows-x64.msi`, `fulcrum-0.5.0-linux-x64.tar.gz` — instead
  of the fixed `fulcrum-macos.dmg`-style names. Every artifact ships with a
  `.sha256` sidecar, and the publish job assembles them into a combined
  `SHA256SUMS` (family packaging standard).

### Added

- **macOS Intel build**: releases now include an x64 DMG and zip alongside
  the Apple-silicon ones (the taskly-style mac matrix), plus a portable
  `fulcrum-<version>-macos-<arch>.zip` per architecture — the zip is also
  what the signed update feed serves macOS clients.
- **Release version gate**: a `VERSION` file at the repo root and
  `scripts/check-release-version.sh` (VERSION == rivet.rktd == tag) run in
  CI and in every release packaging job.

### Fixed

- The update check actually verifies now: the embedded public key is
  decoded into a key object (`bytes->ed25519-public-key`, evaluated at
  check time — FFI at module-import time kills embedded apps at startup)
  before reaching the manifest verifier. 0.4.x passed raw DER bytes, so
  every update check died on an `ed25519-verify` contract violation and
  surfaced as "update check failed". The release pin moved to the rivet
  snapshot that carries the bytes key parser (2e1924c).
- The update manifest architecture labels now match what the in-app updater
  sends (`arm64`/`x64`, the rivet family vocabulary). The old manifest wrote
  `arm64`/`x64` while the updater sent `aarch64`/`x86_64`, and
  `select-update` matches with `eq?` — so no client ever matched an artifact
  and every update check reported "up to date" even when a newer version had
  shipped. Manifest URLs are also tag-pinned now
  (`releases/download/<tag>/<artifact>`) instead of riding
  `releases/latest/download/`.

## 0.4.2

### Changed

- **Releases now ship one human installer per platform instead of bare
  archives**: `fulcrum-macos.dmg`, `fulcrum-windows-x64.msi` (Start-menu and
  desktop shortcuts included), and `fulcrum-linux-x64.tar.gz`. The release
  pipeline runs `raco rivet release`, and the signed channel manifest pins
  those installers — no more unpacking a WinUI runtime directory to hunt
  for `RivetHost.exe`.

### Fixed

- The update check now actually ships the redirect-following fetch:
  0.4.1 announced this fix but its release pin predated rivet#153, so
  0.4.1 binaries still failed every in-app update check at signature
  verification. 0.4.2 builds on the commit that carries the fix.

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
