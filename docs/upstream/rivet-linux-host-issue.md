# Upstream proposal: Linux host for Rivet

> Draft GitHub issue for [turinglambdaai/rivet](https://github.com/turinglambdaai/rivet).
> Paste as-is when opening the issue; the PR (if wanted) references it.
> Status of evidence below: every claim was exercised while building
> [Fulcrum](https://github.com/turinglambdaai/fulcrum), whose Linux host is
> the working prototype this proposal points at.

---

## Title

Linux host: a working GTK4 + embedded-Racket-CS prototype — should this become `platform/linux/`?

## Body

Rivet's README states Linux is not a target today because Rivet follows
first-party platform UI stacks. We believe GTK4 **is** the first-party
Linux stack (GNOME's supported toolkit, same role WinUI 3 and SwiftUI play
on Windows/macOS), so the scope argument that excludes Linux may not apply.
This issue proposes `platform/linux/` and offers a validated prototype.

**Prototype:** [`turinglambdaai/fulcrum` → `linux-host/`](https://github.com/turinglambdaai/fulcrum/tree/main/linux-host) — built for
Fulcrum (a Rivet application), compiles as a CI smoke, runs headless under
Xvfb; not yet wired into `raco rivet build`.

### What the prototype validates

| Concern | Windows path | Linux prototype | Shared? |
|---|---|---|---|
| RVT1 codec | `runtime/src/protocol.cpp` | same files, reused unmodified | ✅ |
| Racket CS embedding | `racket_boot` / `racket_embedded_load_file` / `racket_dynamic_require` / `racket_apply` | identical C API via `libracketcs` | ✅ same symbols |
| Transport | Win32 named pipes (`win32_pipe_transport`) | one `socketpair`, both fds handed to `serve-fds` | app-side, ~100 LOC |
| Request/Event plumbing | `platform/windows/runtime/backend.cpp` | mirrored contract (`request_async`, `set_event_handler`, cancel) | app-side |
| UI | WinUI 3 | GTK4 (`GtkApplicationWindow`, type hint UTILITY, keep-above) | new |
| Global hotkey | `RegisterHotKey` | X11 `XGrabKey`; Wayland: honest message + `fulcrum --toggle` for compositor keybinding | new |
| Runtime staging | `runtime/*.boot` + `res/core.zo` | identical layout, `raco ctool --mods` output consumed as-is | ✅ |

Verified end-to-end on Racket CS 9.3 / Debian-family Linux:

- `raco ctool --mods` produces the `core.zo` the host loads (19 MB with app
  + Rivet collections) — the packaging path needs no Linux-specific changes.
- `raco rivet doctor --json` already degrades correctly (`"ui":
  "unsupported"`, exit 0); `raco rivet new` scaffolds cleanly.
- The backend `serve-fds` contract works unchanged when the two fds are a
  connected socketpair.

### Honest gaps (stated in the prototype's README too)

- Wayland global hotkeys are a protocol limitation, not an implementation
  gap. Options: document the compositor-binding pattern (prototype's
  choice), gtk4-layer-shell (optional dep), or DBusActivate.
- `raco rivet build` / `package` / `verify` have no Linux path yet: that
  wiring (plus `doctor` probes for GTK4/`libracketcs`) is most of the PR.
- The prototype ships its own `posix_backend.cpp`; if upstreamed it should
  move under `platform/linux/runtime/` next to the Windows runtime.

### Questions for the maintainers

1. Is GTK4 acceptable as the "first-party" Linux stack, or does the Linux
   split (X11/Wayland) violate the one-UI-stack-per-platform principle?
2. Preferred transport for the Linux backend: socketpair (prototype) vs
   pipes to match Win32 semantics?
3. Should Linux packaging target tar.gz/AppImage/deb — and does the
   no-silent-installer-fallback rule apply the same way?

If the direction is agreed, we can split the work: (a) `platform/linux/`
runtime + host from the prototype, (b) `raco rivet build` Linux wiring,
(c) `doctor` probes, (d) scaffold template + docs. (a) is ready to move;
(b)–(d) follow the existing Windows implementation pattern.

---

## Notes for opening (not part of the issue)

- File the issue **before** any PR: this is a scope decision, and the
  maintainer's own AGENTS-style docs say platform scope is deliberate.
- PR split if approved: keep `runtime/` untouched (codec already shared);
  add `platform/linux/{runtime,host}/` mirroring `platform/windows/`.
- Reference commits: Fulcrum `linux-host/src/posix_backend.cpp` (embedding
  + RVT1), `linux-host/src/main.cpp` (GTK4 + hotkey), `linux-host/README.md`
  (build + Wayland honesty).
