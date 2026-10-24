#!/usr/bin/env bash
# Render the editable Finder DMG SVG to the PNG expected by the pinned
# Rivet branded DMG builder: 660x400 pixels for the 660x400-point Finder
# window. Finder draws the icon-view background at its native pixel size
# (no auto-scaling), so the raster must equal the window exactly.
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
if (width, height) != (660, 400):
    raise SystemExit(f'DMG background must be 660x400, got {width}x{height}')
print('Rendered Finder DMG background at 660x400 (1x).')
PY
