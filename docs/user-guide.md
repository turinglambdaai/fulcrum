# Fulcrum User Guide

Press one key. Everything on your computer is within reach.

[中文版](user-guide.zh-CN.md)

---

## Install and first launch on macOS

1. Download the **.dmg installer**, not the portable **.zip** (the ZIP is primarily for the signed in-app update feed). Select `arm64` for Apple Silicon M-series Macs and `x64` for Intel Macs. Only use the [official releases page](https://github.com/turinglambdaai/fulcrum/releases/latest).
2. Double-click the DMG, then **drag Fulcrum.app onto the Applications icon** in the Finder window. If prompted to replace an earlier copy, close that copy first. Wait for copying to finish and eject the DMG.
3. Launch **Applications → Fulcrum**. It runs from the menu bar even when its search panel is hidden; summon it with <kbd>⌥</kbd>+<kbd>Space</kbd> or the fallback configured hotkey.
4. If a feature needs Accessibility (for example paste into the previous app), macOS may ask you to enable Fulcrum in **System Settings → Privacy & Security → Accessibility**. Grant the permission only when you intend to use that feature.

**About Gatekeeper:** Current developer-preview builds are ad-hoc signed, not Developer ID notarized. If macOS refuses to launch the app, first make sure the downloaded file came from the official release. Apple's [security guidance](https://support.apple.com/102445) explains the optional, narrowly scoped **Open Anyway** exception under **Privacy & Security**. Don't disable Gatekeeper system-wide or remove quarantine flags. Fully signed, notarized builds are a separate release requirement.

**If the installer shows only a single app:** you likely have an older release. The drag-to-Applications Finder layout will appear in a new release after the installer-artwork change lands; existing downloaded DMGs cannot change retroactively.

---

## Your first minute

1. Press <kbd>Alt</kbd>+<kbd>Space</kbd> (macOS: <kbd>⌥</kbd>+<kbd>Space</kbd>). A panel appears.
2. Type `calc`. Your calculator app appears. Press <kbd>Enter</kbd>. It opens.
3. Press the hotkey again. Type `128*768`. The answer appears. Press <kbd>Enter</kbd>. It is copied.
4. Press the hotkey again. You already know how to use Fulcrum.

That's the whole product: **one key → type → Enter**. Everything below
is detail.

---

## What you can do

### Launch apps

Type any part of an app's name — `firefox`, `term`, `calc`. Fulcrum
matches loosely: `ffx` finds Firefox, typos tolerated. Frequently
launched apps rank higher over time. Chinese names also match offline by
tone-free full pinyin or initials: `weixin` and `wx` both find `微信`,
while the literal Chinese name remains the strongest match.

### Paste anything, anywhere

Every piece of text you copy is remembered. Type `clip` or any word
from what you copied, then press <kbd>Enter</kbd> — the text is pasted
directly into the app you were just using. No window switch, no
<kbd>Ctrl</kbd>+<kbd>V</kbd>.

> macOS asks for the Accessibility permission on first use. Grant it
> once and paste-to-frontmost works everywhere.

### Calculate inline

Type an expression where you would type a search: `128*768`, `(2+3)^4`,
`sqrt(2)`, `sin(pi/4)`. The answer appears as the top result.
<kbd>Enter</kbd> copies it.

The calculator also answers dates and conversions inline — no keyword
needed:

- **Dates.** `next friday`, `in 3 weeks`, `in 2 months`,
  `2026-10-20 + 14d`, `days until 2027-01-01`, `days since 2026-01-01`.
- **Units.** `32f to c`, `100c to k`, `5 km in mi`, `26.2 mi to km`,
  `10 kg to lb`, `12 mm to cm` — temperature, length, and weight across
  a fixed unit set.
- **Currency.** `100 usd to eur`, `1 eur to jpy`, `100$ to €` — from a
  rate table cached on this machine and refreshed quietly in the
  background (at most once an hour). Offline answers use the last
  cache; before the first successful refresh there is no currency row
  yet. ¥ converts as CNY; for Japanese yen, type `jpy`.

The `u` (units) and `cur` (currency) plugins remain available for the
long tail — their rows appear alongside these.

### Expand snippets as you type

Store a piece of text under a keyword, then type that keyword in any
app and Fulcrum replaces it with the full text — automatically, in
place:

```
add snippet addr 42 Wall Street, New York
```

Now typing `addr` + space in your email client becomes `42 Wall
Street, New York`. No shortcuts to remember. Toggle this in
`settings` → `expansion-enabled` (macOS and Windows only; Linux
compositors do not allow the required input monitoring).

To back up or move your snippets without enabling sync, use the launcher:

```text
export snippets /path/to/fulcrum-snippets.json
import snippets /path/to/fulcrum-snippets.json
```

Both commands require an explicit local file path. Export creates a
versioned JSON bundle and refuses to overwrite an existing file. Import
validates the whole bundle before merging by snippet ID, preserves original
IDs and timestamps, and rejects conflicting keywords without changing
existing snippets. Keep exports private: the JSON contains your snippet text.
Portable import/export is available on all three platforms; automatic
expansion still requires macOS or Windows.

Snippets also sync across machines via the [Sync beta](#sync-beta).

### Search the web

| Type | Opens |
|---|---|
| `!g rockets` | Google |
| `!d rockets` | DuckDuckGo |
| `!gh rivet` | GitHub |
| `!so segfault` | Stack Overflow |
| `!w saturn` | Wikipedia |
| `!yt lofi` | YouTube |
| `!m Eiffel Tower` | Google Maps |
| `!t fulcrum` | X/Twitter |

Anything not matched elsewhere gets a general web search as the last
result.

### Create quicklinks

Save a URL template with a keyword:

```
add link yt https://youtube.com/search?q={query}
```

Now `yt lofi` opens YouTube search. `{query}` is replaced by what you
type after the keyword. Query `quicklinks` to manage them.

### Manage windows

Type `window` or parts of a command name. **Left Half**, **Right
Half**, **Maximize**, **Almost Maximize**, **Center**, **Restore** —
applied to whatever window was in front before you summoned Fulcrum.

### Find files

`find invoice` searches file names using the platform index: Spotlight
on macOS, Windows Search on Windows (with a bounded slow scan as fallback
when the index is off), and `plocate`/`locate` on Linux. Results also seed
Fulcrum's local persistent filename index. The first file query starts a
background catalog of Desktop, Documents and Downloads; Windows OneDrive,
macOS iCloud Drive and localized Linux XDG user folders are included when
present. Dependency/cache trees such as `.git`, `node_modules` and `.cache`
are skipped. The platform index answers while that catalog is still building.
Later exact and prefix queries can therefore return common files even if the
platform search times out or is temporarily unavailable. Install `plocate`
on Linux for fast broad searches; with neither platform results nor a known
local match, Fulcrum says so honestly.

Type `file index` to see whether the local catalog is idle, scanning, ready,
partially ready because a folder was unreadable, or failed. A partial scan
preserves older entries instead of treating an access denial as deletion.
Chinese basenames in the local catalog are searchable by tone-free full
pinyin and initials as well as their original characters.

### System commands

`lock`, `sleep`, `restart`, `shut down`, `log out`, `toggle dark mode`,
`empty trash` — Fulcrum offers only the commands that exist on your
platform.

### Search emoji

Type two or more letters of an emoji's English name — `grin`, `fire`,
`heart` — and matching emoji appear inline. <kbd>Enter</kbd> pastes the
character directly into the app you came from.
<kbd>Ctrl</kbd>+<kbd>K</kbd> copies it instead.

---

## AI (bring your own key)

Fulcrum's AI uses your own API key from OpenAI, Anthropic, or a local
Ollama. Fulcrum does not charge for BYOK. The key is stored locally in ai-keys.json and used for provider authentication; conversation history can persist locally. Your prompts only
leave your machine when you run an AI command.

### Setup (once)

1. Type `settings`, run the `ai-provider` row until it shows your
   provider.
2. Type `ai key sk-…` with your actual key and press Enter.
3. Ollama needs no key — just have `ollama serve` running.

### Using AI

| Type | What happens |
|---|---|
| `ai summarize` | Summarizes your clipboard |
| `ai clean` | Fixes grammar and spelling of clipboard text |
| `ai translate zh` | Translates clipboard into Chinese (or any language) |
| `ai explain` | Explains the clipboard content |
| `ai chat explain X` | A question that remembers previous exchanges |
| `what is entropy?` | Any question ending in `?` gets an AI row automatically |

Answers **stream into the panel as they are generated** — you can read
while the model thinks — and land on your clipboard when done.

### Memory and control

Your conversation history **survives restarts** (stored locally,
never synced). The AI remembers context across sessions within the
same provider.

- `ai undo` — drop the last exchange and try a different direction
- `ai reset` — clear the conversation and start fresh
- `ai persona you are a concise technical writer` — persistent
  personality, applied to every request
- `ai model gpt-4o` — switch models without leaving the launcher

---

## Plugins

Plugins extend Fulcrum in any language that can print JSON. The
bundled gallery ships twenty-six:

| Plugin | Keyword | What it does |
|---|---|---|
| Epoch | `ts` | Unix timestamp ↔ date |
| Unit | `u` | Unit conversion (length, weight, temp…) |
| Regex | `re` | Regular expression testing |
| Timezone | `tz` | Timezone conversion |
| GitHub | `gh` | Repository search |
| Cargo | `crate` | crates.io package search |
| Homebrew | `brew` | Formula search |
| Docker | `dk` | Container and image search |
| winget | `winget` | Windows package search |
| Bitwarden | `bw` | Password vault items |
| Currency | `cur` | Exchange rate conversion |
| Number Base | `base` | Decimal, hex, octal and binary forms of a number |
| Base64 | `b64` | Base64 encode / decode text |
| Case Converter | `case` | UPPER, Title, camelCase, snake_case, kebab-case… all at once |
| Color | `color` | HEX / RGB / HSL forms of a color |
| Dictionary | `define` | English definitions, phonetics, examples |
| Hash | `hash` | MD5 / SHA-1 / SHA-256 / SHA-512 digests |
| Hacker News | `hn` | Front page and story search |
| IP Address | `ip` | Local and public IP, hostname, interfaces |
| Lorem Ipsum | `lorem` | Lorem ipsum by paragraph, word or sentence count |
| npm Search | `npm` | npm registry package search |
| Password Generator | `pw` | Strong random passwords and passphrases |
| UUID | `uuid` | Random v4 UUIDs |
| Weather | `wx` | Current conditions and forecast (wttr.in) |
| Wikipedia | `wiki` | English Wikipedia search |
| Word Count | `wc` | Words, characters, lines, reading time |

- Query `gallery` to see everything; Enter installs or uninstalls.
- Query `plugins` to toggle each one on/off.
- Query `plugins <name>` for the detail page.
- `install plugin /path/to/folder` installs from any directory.
- `plugin set <id> <pref> <value>` configures plugin preferences.

Write your own plugin: one manifest + one script. See
[docs/plugins.md](plugins.md) — Python is enough.

---

## Settings

On **Windows**, the tray menu's **Check for Updates** opens a visible
`update` view rather than reporting into a hidden footer. The list refreshes
after checking: choose **Download** to fetch and verify the signed MSI, wait
for the progress to finish, then choose **Quit and install** to upgrade and
relaunch. Keep the installer window open if Windows requests elevation. If the
check or installation fails, the original app remains available with an
explicit error; you can also open the downloaded MSI folder from the same
update results. The installation handoff requires an MSI-installed copy; a
portable ZIP isn't upgraded in place by an MSI.

On **Windows and macOS**, open **Settings** from the tray/menu bar or launcher,
then choose **General**, **Features**, **AI**, **Commands**, or **Sync & Updates**
from the left sidebar. Select the hotkey field in General and press your desired
modifier plus a key (Esc cancels); Windows now records it instead of requiring
you to type `alt+space`. Under **Commands**, configure each command's alias
and keyboard shortcut. Windows uses native WinUI controls and shows the Fulcrum
app icon in its Settings title bar; macOS uses native AppKit/SwiftUI window
chrome. Linux currently offers a grouped scrollable GTK settings form, without
the separate Commands page.

Query `settings` and run a row to change it:

| Setting | What it does |
|---|---|
| language | UI language (zh / en) |
| theme | system / light / dark — applies instantly |
| hotkey | Cycles: `alt+space` → `ctrl+alt+space` → `ctrl+shift+space` → `alt+shift+space` |
| max-results | Rows shown (5–25) |
| clipboard-enabled | Clipboard history on/off |
| expansion-enabled | Snippet auto-expansion on/off |
| web-search-enabled | Web search rows on/off |
| plugins-enabled | Plugin loading on/off |
| ai-provider | OpenAI / Anthropic / Ollama / off |

For custom values (hotkey, model, sync root), type them directly:

```
plugin set docker host tcp://192.168.1.20:2375
ai model gpt-4o
```

Or edit `settings.json` in the data directory.

---

## Updates

Query `update` → **Check for updates now**. Downloads run in the
background; macOS swaps itself and relaunches. Updates are Ed25519
signed — a failed verification is refused, never installed.

---

## Sync beta

Point `sync-root` (in `settings.json`, or `FULCRUM_SYNC_DIR`) at a
folder inside iCloud Drive, Dropbox, Syncthing, or any sync service.
Settings and snippets mirror there; a new machine restores itself on
first launch. Clipboard history and AI keys deliberately do **not**
sync.

---

## Privacy

Local files include clipboard/snippet data, AI history, ai-keys.json, and a rebuildable index of file names and paths previously returned by file search. AI requests send selected context and authenticate with the configured provider; plugins and currency refreshes can also make network requests. Folder sync sends its selected records through your chosen sync service; the file index is never included. Review the data and recovery guidance below.

---

## Keyboard reference

| Key | Context | Action |
|---|---|---|
| `Alt+Space` | Everywhere | Show / hide panel |
| type | Panel | Search everything |
| `↑` `↓` | Panel | Move selection |
| `Enter` | Result selected | Run it (clipboard = paste; emoji = insert; file = open) |
| `Ctrl+K` / `⌘K` | Result selected | Show secondary actions |
| `Tab` | Result selected | Autocomplete title into query |
| `Esc` | Panel | Dismiss: actions → detail → AI → query text → hide |

---

## Coming from Raycast?

Here is what transfers, what is different, and why:

**The same:** the hotkey → type → Enter loop. App launching. Clipboard
history. Snippets. Quicklinks. Calculator. Window management. File
search (macOS). Web search. System commands. Extensions (plugins).
Themes. Dark mode.

**Different by design:**

- **Free, no account.** No login, no account system, no telemetry.
  The entire local product — everything on this page — is free. New multi-step workflow Pro is planned but not on sale; existing BYOK, plugins and BYO-folder sync stay free.
- **Cross-platform, equally.** macOS, Windows, and Linux get the same
  features, same keyboard, same native UI. Not one first-class platform
  and two afterthoughts.
- **BYOK AI, no subscription.** Use your own API key. No monthly fee,
  no per-query cost, no data through Fulcrum's servers.
- **Local-first.** Your data never leaves your device unless you
  explicitly ask it to (AI prompt, web search). No cloud account
  required for sync — use any folder-syncing service you already have.
- **Plugins in any language.** Raycast requires TypeScript. Fulcrum
  accepts any program that reads stdin and writes JSON — Python, Go,
  Rust, a shell script.
- **Focused, not bloated.** Fulcrum does launcher things well and
  doesn't try to be a window manager, a note-taking app, or an AI
  chatbot. When we add AI features, they solve launcher problems.

**Not yet (honest list):** the extension ecosystem is young (26
first-party plugins vs. Raycast's 2,500+ store extensions); clipboard
history is text only (no images); snippet
auto-expansion does not work on Linux.

---

## Troubleshooting

- **The hotkey does nothing.** Another app owns that combo. Fulcrum
  falls back to `Ctrl+Alt+Space` and tells you. You can also open
  Fulcrum from the tray icon (Windows), the menu bar (macOS), or
  `fulcrum --toggle` (Linux). On GNOME specifically, the stock
  *Activate Window Menu* keybinding owns `Alt+Space` and the compositor
  swallows the press before the portal shortcut fires: Fulcrum detects
  this at launch and grows a **Fix Alt+Space conflict** item in its tray
  menu (it clears the stock binding). To fix it by hand:
  `gsettings set org.gnome.desktop.wm.keybindings activate-window-menu "[]"`.

- **Paste-to-frontmost does nothing on macOS.** Grant Accessibility:
  System Settings → Privacy & Security → Accessibility → enable
  Fulcrum.

- **Paste-to-frontmost on Linux.** X11 works out of the box. On
  Wayland, install `wtype`.

- **The AI says "no API key".** Run `ai key <secret>` after picking
  the provider. Ollama needs no key, just `ollama serve` running.

- **The hotkey combo I want is taken.** Cycle through presets in
  `settings` → `hotkey`, or edit `settings.json` — Fulcrum accepts any
  `mod+key` spec.

- **Where is my data?** One directory (`FULCRUM_DATA_DIR`): stores as
  JSON, keys in `ai-keys.json`, and the rebuildable local file-name/path
  cache in `file-index.sqlite3`. Delete it and Fulcrum starts clean.

---

## Why Fulcrum?

A launcher is a tool you use hundreds of times a day. It should be
fast, private, and yours.

Fulcrum is built on [Rivet](https://rivet.jrtx.site): one Racket brain
embedded in each platform's native UI — SwiftUI on macOS, WinUI 3 on
Windows, GTK4 on Linux. Not Electron. Not a web wrapper. The Windows
app is a Windows app; the macOS app is a macOS app.

We are a latecomer. That means we studied what Raycast users complain
about — AI features prioritised over core stability, complexity
creep, Pro-tier gating — and made different choices. Fulcrum
prioritises fundamentals: fast search, reliable actions, honest
errors, and your data staying on your machine.

Source-available (BUSL-1.1, MIT after the change date). Plugin
protocol MIT. No telemetry. No account. No cloud.

## Availability

Existing launcher, clipboard, plugins and BYOK features remain free. No Pro checkout is open.

## Platforms and installation

Desktop developer previews for macOS, Windows and Linux. Permission and shortcut behavior varies with the OS and Linux display session.

Use [official Releases](https://github.com/turinglambdaai/fulcrum/releases), select an explicitly listed OS/architecture asset, read its release notes and check supplied checksums. An absent asset/platform is not a delivery promise. Preview builds may lack publisher signing or notarization; do not disable system-wide security protections to install them.

## Your first successful session

1. Open Fulcrum and use the configured global shortcut to summon the window. Resolve shortcut conflicts in Settings.
2. Enter 12*12 and confirm 144; then search for an installed application and launch it.
3. Enable clipboard history, plugins and AI separately, only after reviewing the data and permissions each needs.

## Data, backup and recovery

Back up the configured application-data directory after quitting Fulcrum. Clipboard history, snippets, plugin settings, AI history and the local filename/path index may be sensitive. `file-index.sqlite3` is a rebuildable cache and does not need to be restored or synced. Test recovery on a copy; do not publish a full diagnostic directory as a bug attachment.

## Network, keys and privacy

Local search does not require a commercial account. Installed plugins can run code and access network services. BYOK requests send the chosen prompt/context to your configured provider, which bills you separately.

## Known limits

This is a developer preview. New multi-step workflow automation is planned and is not an available paid feature. AI lifecycle extraction is tracked in #89.

## Updates and removal

Back up data and read the destination release notes first. An in-app update check does not necessarily install an update for your channel; follow the manual for portable, installer and source paths. Never bypass a failed signature check or replace the program with an untrusted artifact. On failure, preserve data and the error, then recover with a trusted release. Removing the program does not necessarily erase its separate data directory; verify your backup before deleting personal data.

## Get help

Report problems in [GitHub Issues](https://github.com/turinglambdaai/fulcrum/issues), in English or Chinese. Include the version, OS/architecture, installation channel, steps, expected result and actual result. Reproduce with synthetic input first; do not attach keys, credentials, databases, private source documents or complete logs. Public support has no guaranteed response time.

For sensitive vulnerabilities, follow the private process in [SECURITY.md](../SECURITY.md).
