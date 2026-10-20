# Fulcrum User Guide

Press one key. Everything on your computer is within reach.

[中文版](user-guide.zh-CN.md)

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
launched apps rank higher over time.

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

`find invoice` searches file names through Spotlight (macOS). On
Windows and Linux this honestly reports that it needs the platform
search index.

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
Ollama. Fulcrum charges nothing, sees nothing, and stores nothing —
the key stays in a local file that is never synced. Your prompts only
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

| Data | Where it lives | Leaves your device? |
|---|---|---|
| Search history | Never stored | Never |
| Clipboard history | Local JSON file | Never |
| Snippets | Local JSON file (+ sync mirror if configured) | Only to your own cloud folder |
| AI prompts | Nowhere (in-transit only) | Only to the AI provider you chose |
| AI conversation | Local JSON file | Never |
| API keys | Local file | Never |
| Telemetry | None | Nothing to send |

Fulcrum makes exactly three kinds of network requests: update checks
(signed, throttled), web searches you explicitly run, and AI prompts
you explicitly run.

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
  The entire local product — everything on this page — is free. A Pro
  tier is planned for 1.0 and will sit only on services that cost us
  money (sync, bundled AI, themes); the local feature set stays free.
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
history is text only (no images); file search is macOS only; snippet
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
  JSON, keys in `ai-keys.json`. Delete it and Fulcrum starts clean.

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
