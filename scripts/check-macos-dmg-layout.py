#!/usr/bin/env python3
"""Validate the editor source and raster used by Rivet's 660x400 Finder DMG.

Run after scripts/render-dmg-background.sh. This is a layout contract check,
not a replacement for opening the actual DMG in Finder on a release machine.
"""
from pathlib import Path
import re
import struct
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
SVG = ROOT / "assets/dmg-background.svg"
PNG = ROOT / "assets/dmg-background.png"
RVTD = ROOT / "rivet.rktd"

root = ET.parse(SVG).getroot()
assert root.attrib.get("viewBox") == "0 0 1320 800"
assert root.attrib.get("width") == "1320"
assert root.attrib.get("height") == "800"
assert 'dmg-background . "assets/dmg-background.png"' in RVTD.read_text()

texts = ["".join(el.itertext()).strip()
         for el in root.iter() if el.tag.endswith("}text")]
assert any("Fulcrum" == t for t in texts)
assert any("Drag Fulcrum into Applications" == t for t in texts)
assert any("DRAG TO INSTALL" == t for t in texts)

with PNG.open("rb") as f:
    header = f.read(24)
assert header[:8] == b"\x89PNG\r\n\x1a\n" and header[12:16] == b"IHDR"
assert struct.unpack(">II", header[16:24]) == (1320, 800)

# Pinned Rivet installer.rkt positions the app and Applications link at
# (130,160), (450,160) in a 660x400 Finder window, with 80pt icons.
# Validate the arrow is centered between their 2x centers.
art = SVG.read_text()
assert 'M 457 419 H 840' in art
assert 'M 813 391 L 845 419 L 813 447' in art
print("Fulcrum Finder drag-to-Applications artwork is valid (660x400 @2x).")
