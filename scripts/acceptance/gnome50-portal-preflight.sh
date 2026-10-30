#!/usr/bin/env bash
# Environment preflight only for Fulcrum Issue #111 on a real GNOME 50 Wayland desktop.
# This cannot assert CreateSession, permission consent or Activated.
set -euo pipefail

usage() {
  cat <<'HELP'
Usage: bash scripts/acceptance/gnome50-portal-preflight.sh --kind deb|appimage

Run on the actual Ubuntu 26.04 GNOME 50 Wayland desktop after installing the
v0.14.1 candidate. Capture stdout/stderr locally and redact before sharing.

This checks system identity, portal interface availability and desktop entry
integration. EXIT 0 MEANS ONLY THAT ENVIRONMENT PREFLIGHT PASSED.
It does NOT verify Fulcrum's GlobalShortcuts.CreateSession or Activated events;
the manual checks printed at the end are mandatory release evidence.
HELP
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi
if [[ "${1:-}" != "--kind" || $# -ne 2 ||
      ( "$2" != "deb" && "$2" != "appimage" ) ]]; then
  usage >&2
  exit 2
fi
kind="$2"
failures=0
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  failures=$((failures + 1))
}
note() { printf 'INFO: %s\n' "$*"; }

note "Fulcrum GNOME 50 portal *environment preflight*; artifact kind: $kind"
note "This is not an automated GNOME GlobalShortcuts acceptance test."
if [[ ! -r /etc/os-release ]]; then
  fail "/etc/os-release not readable"
else
  # shellcheck source=/etc/os-release
  . /etc/os-release
  note "Operating system: ${PRETTY_NAME:-unknown}"
  [[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "26.04" ]] ||
    fail "Expected Ubuntu 26.04 (not a CI Ubuntu runner or nested Weston)"
fi

note "XDG_SESSION_TYPE=${XDG_SESSION_TYPE:-unset}"
[[ "${XDG_SESSION_TYPE:-}" == "wayland" && -n "${WAYLAND_DISPLAY:-}" ]] ||
  fail "Expected a genuine Wayland desktop session with WAYLAND_DISPLAY"
if ! command -v gnome-shell >/dev/null 2>&1; then
  fail "gnome-shell not installed"
else
  gnome_version="$(gnome-shell --version 2>&1 || true)"
  note "GNOME version: $gnome_version"
  [[ "$gnome_version" =~ [[:space:]]50([.]|$) ]] ||
    fail "Expected GNOME Shell major version 50"
fi

if command -v dpkg-query >/dev/null 2>&1; then
  for package in xdg-desktop-portal xdg-desktop-portal-gnome; do
    installed_version="$(dpkg-query -W -f='${Version}' "$package" 2>/dev/null || true)"
    if [[ -z "$installed_version" ]]; then
      fail "Package not installed: $package"
    else
      note "$package version: $installed_version"
    fi
  done
fi
if ! command -v gdbus >/dev/null 2>&1; then
  fail "gdbus not on PATH (required to check host portal interface)"
elif ! timeout 8s gdbus introspect --session \
    --dest org.freedesktop.portal.Desktop \
    --object-path /org/freedesktop/portal/desktop 2>/dev/null |
    grep -F "org.freedesktop.host.portal.Registry" >/dev/null; then
  fail "Host portal Registry is unavailable on the user session bus"
else
  note "Host portal Registry interface advertised (not proof of registration)"
fi

desktop_id="site.jrtx.fulcrum"
desktop_file=""
for root in "${XDG_DATA_HOME:-$HOME/.local/share}" /usr/local/share /usr/share; do
  if [[ -f "$root/applications/$desktop_id.desktop" ]]; then
    desktop_file="$root/applications/$desktop_id.desktop"
    break
  fi
done
if [[ -z "$desktop_file" ]]; then
  if [[ "$kind" == "deb" ]]; then
    fail "Installed $desktop_id.desktop not found in standard XDG application directories"
  else
    note "AppImage desktop integration absent; unintegrated AppImage has an explicit portal limitation"
  fi
else
  note "Installed desktop identity: $desktop_file"
  exec_line="$(grep -m1 '^Exec=' "$desktop_file" || true)"
  if [[ -z "$exec_line" ]]; then
    fail "Installed desktop file has no Exec= line"
  else
    note "$exec_line"
  fi
  if command -v desktop-file-validate >/dev/null 2>&1; then
    desktop-file-validate "$desktop_file" ||
      fail "desktop-file-validate rejected installed entry"
  fi
fi

if [[ "$kind" == "deb" ]] && command -v dpkg-query >/dev/null 2>&1; then
  package_version="$(dpkg-query -W -f='${Version}' fulcrum 2>/dev/null || true)"
  if [[ -n "$package_version" ]]; then
    note "Installed DEB version: $package_version"
    [[ "$package_version" == 0.14.1* ]] ||
      fail "Expected a v0.14.1 candidate package, not $package_version"
  else
    fail "Cannot find installed fulcrum DEB package"
  fi
fi

if (( failures > 0 )); then
  printf 'PREFLIGHT FAILED: %d environment issue(s); no release acceptance.\n' "$failures" >&2
  exit 1
fi
cat <<'NEXT'

ENVIRONMENT PREFLIGHT PASSED — THIS IS NOT A GLOBAL HOTKEY PASS.

On this same real GNOME 50 Wayland desktop, still record manually:
1. Launch Fulcrum through Activities and gtk-launch site.jrtx.fulcrum.
2. Capture Registry.Register and GlobalShortcuts.CreateSession/BindShortcuts
   responses on Fulcrum's sender; observe the real GNOME consent dialog.
3. Accept consent; from a different foreground app, press the configured
   hotkey repeatedly and prove the launcher toggles via Activated.
4. Restart/login with Start at Login enabled, re-test summon and custom chord.
5. Deny consent; confirm the actionable failure persists after backend ready.
6. Verify the documented fulcrum --toggle desktop-shortcut fallback.
7. Repeat the relevant matrix for the actual AppImage and document any
   unintegrated desktop-file limitation.

Record artifact name/hash, exact OS and portal versions, consent/outcomes,
and tester/date in Issue #111. Redact unrelated D-Bus data before posting.
DO NOT close #111 or approve a stable release on preflight alone.
NEXT
