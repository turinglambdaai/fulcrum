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

## Entry and settings parity

Every host exposes Open, Settings, Check for Updates, About and Quit through its
native resident surface (menu bar or tray) and exposes Settings/About/Update as
searchable launcher rows. Linux shows snippet expansion in Settings as disabled
with an explicit unsupported note until its expansion engine exists; hiding the
feature would incorrectly suggest a different product model.

Settings and snippets remain backend-owned. Hosts may render different native
form layouts, but keys, values, descriptions and availability must agree.

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
