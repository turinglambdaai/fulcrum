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
assert root.attrib.get("viewBox") == "0 0 660 400"
assert root.attrib.get("width") == "660"
assert root.attrib.get("height") == "400"
assert 'dmg-background . "assets/dmg-background.png"' in RVTD.read_text()

texts = ["".join(el.itertext()).strip()
         for el in root.iter() if el.tag.endswith("}text")]
assert any("Fulcrum" == t for t in texts)
assert any("Drag Fulcrum into Applications" == t for t in texts)
assert any("DRAG TO INSTALL" == t for t in texts)

with PNG.open("rb") as f:
    header = f.read(24)
assert header[:8] == b"\x89PNG\r\n\x1a\n" and header[12:16] == b"IHDR"
assert struct.unpack(">II", header[16:24]) == (660, 400)

# Pinned Rivet installer.rkt positions the app and Applications link at
# (130,160), (450,160) in a 660x400 Finder window, with 80pt icons.
# Validate the arrow cue sits between them on the icon row's center line,
# and that every text element stays inside the canvas.
art = SVG.read_text()
assert 'M 224 214 H 404' in art
assert 'M 392 204 L 404 214 L 392 224' in art
ns = {"svg": "http://www.w3.org/2000/svg"}
for el in ET.parse(SVG).getroot().iter():
    if not el.tag.endswith("}text"):
        continue
    x = float(el.attrib["x"]); y = float(el.attrib["y"])
    assert 0 < x < 660 and 0 < y < 400, f"text outside canvas at ({x},{y})"
print("Fulcrum Finder drag-to-Applications artwork is valid (660x400 @1x).")
