# Fulcrum Linux host

The Linux first-party UI: a GTK4 floating launcher over one embedded
Racket CS backend, built entirely through Rivet 0.3's official Linux
support — `raco rivet build` compiles this directory, stages
`runtime/*.boot` + `res/core.zo` beside the executable, and
`linux/GeneratedBackend.hpp` is generated from `app/backend.rkt`
(`rivet::linux_runtime` client). Do not edit the generated file by hand.

Launcher-specific parts on top of the official runtime:

- **Panel opens on launch** — a launcher that boots hidden is an
  invisible app wherever the summon path isn't alive yet (before the
  portal consent, after a reboot, a rejected grab). Esc or focus loss
  hides it again.
- **Dragging and appearance** — window-manager moves keep the panel open
  while a mouse button is held. Language and explicit light/dark theme
  changes apply to the existing window; System restores the desktop GTK
  theme. The menu beside the search field and the tray both offer Restart
  Fulcrum and Quit Fulcrum. Restart stops the backend and releases the
  single-instance lease before replacing the process image.
- **Global hotkey, portal-first** — where `org.freedesktop.portal`
  `GlobalShortcuts` exists (GNOME 48+, KDE, recent wlroots compositors),
  the summon shortcut is registered there: the compositor asks for
  consent once and owns the final binding, which the status bar reports.
  When the chosen combo is Alt+Space and GNOME's stock *activate window
  menu* binding still owns it, the host detects the shadowing, says so,
  and grows a **Fix Alt+Space conflict** item in the tray menu (clears
  the stock binding with `gsettings`). Sessions without the portal fall
  back to the X11 `XGrabKey` grab (X11 only, by platform rules); the grabbed
  user-event timestamp is forwarded to GTK so Mutter accepts the focus
  request even when another application owns focus. On Wayland,
  `fulcrum --toggle` bound as a compositor keybinding is the documented
  Wayland fallback — and it summons by starting the launcher when
  nothing is running yet.
- **Overlay chrome** — EWMH properties (`_NET_WM_STATE_ABOVE`,
  `SKIP_TASKBAR`, `WINDOW_TYPE_UTILITY`) set directly on X11; Wayland
  compositors own those decisions.
- **Single instance** — Rivet's first-party `SingleInstanceLease`;
  second launches forward `--toggle` to the primary and exit.

## Build

```bash
raco rivet doctor      # prints the exact Linux toolchain list when incomplete
raco rivet build       # backend bundle + codegen + CMake host build, staged
raco rivet dev         # builds and launches
```

Linux toolchain (Debian/Ubuntu):
`build-essential cmake pkg-config libgtk-4-dev zlib1g-dev liblz4-dev
libncurses-dev`, plus an embeddable Racket CS 9.3 build (`libracketcs.a`;
the official recipe builds one from the `racket-minimal` source tarball —
see Rivet's `roundtrip.yml` for the exact steps, and this repository's CI
for a cached version of the same flow).

For fast `find <name>` file search, install `plocate` and build its index
(`sudo apt install plocate`). Fulcrum can fall back to a bounded home-directory
scan, but reports when that unindexed scan exceeds its three-second budget.

## Hotkey regression tests

Run `rtk proxy python3 tests/run-linux-hotkey-tests.py` from the repository
root. Requires a C++20 compiler, `pkg-config`, GLib/X11 development headers,
`libXtst.so.6`, and `xvfb`. Set `XVFB=/path/to/Xvfb` to use a locally extracted
binary without installing it system-wide.

The runner creates a private, authenticated virtual display with TCP disabled;
it never uses the desktop's `DISPLAY`. Tests have a 15-second timeout, CPU and
memory limits, and clean up the server on exit. They exercise the actual X11
listener with ordinary window events, injected key chords, lock keys,
autorepeat, conflicting grabs, rebinding, and shutdown. They do not start the
launcher, access its backend or clipboard, or validate a complete native app.

## Settings preview

The launcher with Chinese labels, a selected setting, and current-value badges
(sample rows rendered by the native widgets; no backend is connected):

![Linux launcher settings](../docs/images/linux-settings-preview.png)

## Widget regression tests

After `rtk proxy raco rivet build`, run:

Requires `xvfb` (including `xvfb-run`), `xauth`, and `dbus-run-session`.

```bash
rtk proxy cmake --build .rivet/build/linux --target fulcrum-ui-test
rtk proxy xvfb-run -a -s "-screen 0 1280x800x24 -nolisten tcp" dbus-run-session -- timeout 30s .rivet/build/linux/fulcrum-ui-test
```

The fixture uses the launcher's real GTK widgets with sample rows. It checks
candidate visibility, setting badges, keyboard scrolling, internal clicks,
temporary focus loss, owned dialogs, and dismissal on sustained external
focus loss. Its executable has no adjacent runtime, so it does not start the
backend or access clipboard history. These checks use a private virtual
display; desktop compositor behavior still needs a real-session check.

The X11 fallback owns a separate connection and grabs the root window so it
works while the launcher is hidden. Do not attach a second event reader to
GDK's connection: unrelated UI events must never toggle the launcher or be
removed from GDK's queue.
