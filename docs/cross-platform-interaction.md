# Cross-platform interaction contract

Fulcrum has one product interaction grammar rendered by three native hosts.
AppKit, WinUI and GTK may use their platform materials and system integration,
but those mechanisms must not change what the launcher does.

## Required launcher behavior

| Interaction | macOS | Windows | Linux |
| --- | --- | --- | --- |
| Summon | Global hotkey; fall back to Control+Option+Space when occupied | Global hotkey; fall back to Ctrl+Alt+Space when occupied | X11 native grab with Ctrl+Alt+Space fallback; Wayland portal with visible recovery instructions |
| Focus after summon | Panel stays visible through the compositor handoff; query receives typing | Same | Same |
| Focus after first activation | Hide when focus leaves Fulcrum, except while an owned dialog is active | Same | Same, with a short pointer/WM handoff debounce |
| Pointer on result | One click selects; double click executes | Same | Same |
| Keyboard on result | Up/Down select, Enter executes, Tab completes, Command/Ctrl+K opens actions | Same, using Ctrl | Same, using Ctrl |
| Escape ladder | actions → detail → AI → clear query → hide | Same | Same |

The pre-activation distinction is deliberate: a freshly presented panel may be
visible before GNOME grants it focus. Focus-loss dismissal is armed only after
the panel has been active once, otherwise the summon operation can erase itself.

## Shared visual and language grammar

- The panel is 680×460, uses amber `#D97706`, 44-point result rows, an inset
  rounded selection, a leading semantic icon and a trailing badge/Enter chip.
- Application rows should use the real application icon when the platform can
  resolve it. Other kinds use distinct semantic icons; Calculator and AI must
  never share a glyph.
- The query placeholder, status/phase labels, detail heading, footer hints,
  settings labels, common Open/Settings/Updates/About/Quit entries and recovery
  messages come from `shared/i18n/{zh,en}.json`. Changing the language must
  update already-open surfaces without restarting.
- Platform-specific diagnostic entries are allowed only when the mechanism is
  platform-specific. The GNOME Alt+Space repair action is one such exception.
- Search glyph and placeholder must share a single horizontal centerline on
  all hosts. Linux uses a native, centered GtkImage beside GtkEntry rather
  than GtkSearchEntry's independently padded built-in search icon.
- A resident-ready status is **not** a visible launcher row when the launcher
  is already open. Host startup failures, update progress/errors, and
  platform-specific hotkey recovery remain visible and actionable when needed.

## Entry and settings parity

Every host exposes Open, Settings, Check for Updates, About and Quit through its
native resident surface (menu bar or tray) and exposes Settings/About/Update as
searchable launcher rows. Keep the launcher search field free of app-lifecycle
buttons: a Linux-only Restart/Quit button beside the query duplicates the tray
and makes a transient search surface behave unlike macOS/Windows. Restart is
not a primary search action; Quit stays available in the tray, as on Windows.
Platform-specific hotkey recovery remains available when GNOME owns Alt+Space. Linux shows snippet expansion in Settings as disabled
with an explicit unsupported note until its expansion engine exists; hiding the
feature would incorrectly suggest a different product model.

Settings and snippets remain backend-owned. Hosts may render different native
form layouts, but keys, values, descriptions and availability must agree.

### Settings information architecture (Windows / macOS)

Windows and macOS must expose the same five settings areas: General, Features,
AI, Commands, and Sync & Updates. Both use a fixed category sidebar and a
single current section (native NavigationView + Mica/cards on WinUI, native
sidebar + grouped Form on SwiftUI). The shared Racket backend owns validation,
command alias/global bindings, AI key storage and updates; hosts must not
silently omit the Commands editor on Windows. The summon hotkey and command
bindings use native in-window key recording, without exposing canonical
`mod+key` grammar in the default flow. Windows regular titled windows must
show the product icon from the packaged numeric icon resource; borderless
launcher windows do not need a fake titlebar or caption icon. macOS follows
AppKit window decoration, not Win32 caption-icon conventions.

Linux now uses a GTK StackSidebar + five scrollable native content pages
(General, Features, AI, Commands, Sync & Updates). Its Commands editor uses
the same backend validation API for aliases/shortcuts as WinUI and SwiftUI;
Linux now captures shortcut combinations in GTK's key-pressed controller,
translates them to the same canonical backend grammar, and validates them
through the common bindings RPC; GTK's native control styling still differs
from AppKit/WinUI. The GTK widget and packaged Wayland acceptance suites
must pass.

Start at login is a **per-device opt-in** in General on all three hosts, not
a synced Racket setting: macOS uses SMAppService and system approval, Windows
uses HKCU Run, and Linux writes its own XDG autostart .desktop entry. An OS
login launches a resident *hidden* host; an ordinary interactive launch keeps
the existing summon behavior. Background login for an already running host
must never toggle its visible panel.

## Acceptance contract

Each packaged-host acceptance suite exercises the same observable sequence:

1. start hidden and traverse the host's summon activation handoff;
2. after one second, assert the panel is visible and the query owns focus;
3. type `12*12` through the native keyboard path and observe result `144`;
4. execute the selected row and verify the native side effect;
5. cover the Escape ladder and post-activation focus-loss policy in host tests;
6. switch language and assert visible launcher chrome changes immediately.

Mechanism-specific tests supplement this sequence: X11 tests inject the real
chord on a private X server; Wayland acceptance calls the exact activation
handler used by the portal because compositors intentionally prohibit synthetic
global input.

## 当前交付优先级（2026-10-23）

先收敛交互与真实更新/签名门禁，再做窄范围的新增工作流 Pro。保留已有免费能力，平台机制遵循原生惯例。

执行场景与完成标准见[本仓审查 issue](https://github.com/turinglambdaai/fulcrum/issues/88)及家族[交付标准](https://github.com/turinglambdaai/turinglambdaai.github.io/blob/master/docs/PRODUCT-STANDARD.md)。未完成的跨平台、硬件或真实支付验证仍是显式门禁；本节不表示这些验证已通过。后续一次认领一个切片，证据回填本文件与 issue。
