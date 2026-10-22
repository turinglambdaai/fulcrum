#!/usr/bin/env bash
# Validate the *real* installed DMG structure, not just its SVG artwork.
# Called on a macOS runner after raco rivet release --development.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
shopt -s nullglob
images=(dist/fulcrum-*-macos.dmg)
if [[ ${#images[@]} -ne 1 ]]; then
  echo "::error::Expected exactly one macOS DMG under dist/" >&2
  exit 1
fi
image="${images[0]}"
mount="$(mktemp -d "${TMPDIR:-/tmp}/fulcrum-dmg-mount.XXXXXX")"
detach() {
  hdiutil detach "$mount" -quiet 2>/dev/null || true
  rmdir "$mount" 2>/dev/null || true
}
trap detach EXIT
hdiutil attach "$image" -readonly -nobrowse -mountpoint "$mount" -quiet
apps=("$mount"/*.app)
if [[ ${#apps[@]} -ne 1 ]]; then
  echo "::error::Expected exactly one installable .app in DMG" >&2
  ls -la "$mount"
  exit 1
fi
test -L "$mount/Applications" || { echo "::error::DMG lacks Applications alias" >&2; exit 1; }
test "$(readlink "$mount/Applications")" = "/Applications" || {
  echo "::error::DMG Applications alias must point to /Applications" >&2; exit 1;
}
test -s "$mount/.background/background.png" || {
  echo "::error::Branded DMG background missing" >&2; exit 1;
}
test -f "$mount/.DS_Store" || {
  echo "::error::DMG lacks Finder icon layout metadata" >&2; exit 1;
}
test -x "${apps[0]}/Contents/MacOS/fulcrum" || {
  echo "::error::Installed app executable missing" >&2; exit 1;
}
# Check the outer app bundle, not only its Mach-O executable: the bundle
# seals embedded frameworks and resources. If verification fails, collect
# nested-code diagnostics but keep the test red (never bypass signature checks).
if ! codesign --verify --strict --verbose=4 "${apps[0]}"; then
  echo "::error::Mounted DMG contains an app with an invalid code signature" >&2
  framework="${apps[0]}/Contents/Frameworks/Racket.framework"
  echo "::group::Nested Racket framework diagnostics" >&2
  ls -la "$framework" "$framework/Versions" || true
  find "$framework" -maxdepth 3 \( -name Info.plist -o -name Racket \) -print || true
  codesign --display --verbose=4 "$framework" 2>&1 || true
  codesign --verify --strict --verbose=4 "$framework" 2>&1 || true
  codesign --verify --strict --verbose=4 "${apps[0]}/Contents/MacOS/fulcrum" 2>&1 || true
  echo "::endgroup::" >&2
  exit 1
fi
echo "Branded Finder DMG has one app, Applications link, wallpaper, icon layout and a strictly verified app signature."
