#!/usr/bin/env bash
# Render the editable Finder DMG SVG to the 2x PNG expected by the pinned
# Rivet v0.12.0 branded DMG builder (660x400 Finder view).
#
# Developers: brew install librsvg; bash scripts/render-dmg-background.sh
# CI release runners do the same before invoking raco rivet release.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
svg="$root/assets/dmg-background.svg"
png="$root/assets/dmg-background.png"
if ! command -v rsvg-convert >/dev/null 2>&1; then
  echo "Missing rsvg-convert; on macOS run: brew install librsvg" >&2
  exit 1
fi
rsvg-convert --format png --output "$png" "$svg"
python3 - "$png" <<'PY'
import struct
import sys

with open(sys.argv[1], 'rb') as stream:
    header = stream.read(24)
if header[:8] != b'\x89PNG\r\n\x1a\n' or header[12:16] != b'IHDR':
    raise SystemExit('Invalid DMG PNG')
width, height = struct.unpack('>II', header[16:24])
if (width, height) != (1320, 800):
    raise SystemExit(f'DMG background must be 1320x800, got {width}x{height}')
print('Rendered Finder DMG background at 1320x800 (2x).')
PY
