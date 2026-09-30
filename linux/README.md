# Fulcrum Linux host

The Linux first-party UI: a GTK4 floating launcher over one embedded
Racket CS backend, built entirely through Rivet 0.3's official Linux
support — `raco rivet build` compiles this directory, stages
`runtime/*.boot` + `res/core.zo` beside the executable, and
`linux/GeneratedBackend.hpp` is generated from `app/backend.rkt`
(`rivet::linux_runtime` client). Do not edit the generated file by hand.

Launcher-specific parts on top of the official runtime:

- **Global hotkey** — X11 `XGrabKey` on Alt+Space. On Wayland this is a
  protocol limitation, not a bug: the status bar says so and the same
  toggle is available as `fulcrum --toggle` for a compositor keybinding.
- **Overlay chrome** — EWMH properties (`_NET_WM_STATE_ABOVE`,
  `SKIP_TASKBAR`, `WINDOW_TYPE_UTILITY`) set directly on X11; Wayland
  compositors own those decisions.
- **Single instance** — `$XDG_RUNTIME_DIR/fulcrum/host.pid` + `SIGUSR1`,
  so `--toggle` always controls the running launcher.

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
