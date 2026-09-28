# Fulcrum Linux host

The Linux host is the third first-party UI: GTK4 floating window, embedded
Racket CS (same `runtime/*.boot` + `res/core.zo` layout the macOS and
Windows hosts stage), RVT1 over a socketpair through Rivet's shared C++
codec.

**Status: experimental.** Windows (WinUI 3) and macOS (SwiftUI) hosts build
and run through `raco rivet build` on their platforms. The Linux host is
built by CI as a compile-smoke and exercised headless (Xvfb) but is not yet
wired into `raco rivet build`'s Linux path — Rivet itself does not ship a
Linux host template yet. Build it manually until then.

## Build

Debian/Ubuntu dependencies:

```bash
sudo apt install build-essential cmake pkg-config \
  libgtk-4-dev libpango1.0-dev libx11-dev
```

Then, from a Rivet checkout next to this repository:

```bash
export RIVET_ROOT=/path/to/rivet
export RIVET_RACKET_LIB_DIR=$(dirname $(find $(dirname $(which racket))/.. -name libracketcs.a | head -1))
raco rivet build   # stages runtime/ + res/core.zo into .rivet/build
cmake -S linux-host -B linux-host/build
cmake --build linux-host/build
./linux-host/build/fulcrum
```

## Global hotkey reality

- **X11:** Fulcrum grabs Alt+Space with XGrabKey and toggles on it.
- **Wayland:** compositors do not let clients grab global keys — this is a
  protocol property, not a bug. Fulcrum says so in the status bar; bind
  `fulcrum --toggle` to a key in your compositor settings instead.

Single-instance activation uses `$XDG_RUNTIME_DIR/fulcrum/host.pid` and
`SIGUSR1`, so `--toggle` always controls the running launcher.
