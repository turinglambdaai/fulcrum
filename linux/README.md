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
- **Global hotkey, portal-first** — where `org.freedesktop.portal`
  `GlobalShortcuts` exists (GNOME 48+, KDE, recent wlroots compositors),
  the summon shortcut is registered there: the compositor asks for
  consent once and owns the final binding, which the status bar reports.
  When the chosen combo is Alt+Space and GNOME's stock *activate window
  menu* binding still owns it, the host detects the shadowing, says so,
  and grows a **Fix Alt+Space conflict** item in the tray menu (clears
  the stock binding with `gsettings`). Sessions without the portal fall
  back to the X11 `XGrabKey` grab (X11 only, by platform rules); there,
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
