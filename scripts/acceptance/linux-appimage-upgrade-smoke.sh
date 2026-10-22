#!/usr/bin/env bash
set -euo pipefail

arch="\${1:?usage: linux-appimage-upgrade-smoke.sh x64|arm64}"
case "$arch" in
  x64) suffix="linux-x86_64.AppImage" ;;
  arm64) suffix="linux-aarch64.AppImage" ;;
  *) echo "unsupported AppImage architecture: $arch" >&2; exit 2 ;;
esac

old_version="0.13.1"
new_version="0.13.2"
work="$(mktemp -d "\${RUNNER_TEMP:-/tmp}/fulcrum-appimage-e2e.XXXXXX")"
trap 'rm -rf "$work"' EXIT

fetch_release() {
  local version="$1"
  local filename="fulcrum-\${version}-\${suffix}"
  local base="https://github.com/turinglambdaai/fulcrum/releases/download/v\${version}"
  curl --fail --location --silent --show-error --retry 4 \
    --connect-timeout 15 --max-time 300 "$base/$filename" -o "$work/$filename"
  curl --fail --location --silent --show-error --retry 4 \
    --connect-timeout 15 --max-time 60 "$base/$filename.sha256" -o "$work/$filename.sha256"
  local expected actual
  expected="$(awk 'NR == 1 { print $1 }' "$work/$filename.sha256")"
  if [[ ! "$expected" =~ ^[[:xdigit:]]{64}$ ]]; then
    echo "invalid official SHA-256 sidecar for $filename" >&2
    exit 1
  fi
  actual="$(sha256sum "$work/$filename" | awk '{ print $1 }')"
  if [[ "\${actual,,}" != "\${expected,,}" ]]; then
    echo "SHA-256 mismatch for official release $filename" >&2
    exit 1
  fi
  chmod 755 "$work/$filename"
  printf '%s\n' "$work/$filename"
}

old_app="$(fetch_release "$old_version")"
new_app="$(fetch_release "$new_version")"
new_filename="fulcrum-\${new_version}-\${suffix}"
new_sha="$(awk 'NR == 1 { print $1 }' "$work/$new_filename.sha256")"

# Run the real AppImage runtime in extraction mode so hosted CI does not need
# FUSE privileges. xvfb + a private D-Bus session let the new GTK application
# start and survive Rivet's health window; the harness then cleans it up.
APPIMAGE_EXTRACT_AND_RUN=1 xvfb-run -a \
  -s "-screen 0 1280x800x24 -nolisten tcp" \
  dbus-run-session -- timeout 120s \
  .rivet/build/linux/fulcrum-appimage-real-upgrade-test \
  --real-upgrade "$old_app" "$new_app" "$new_sha" "$new_version"
