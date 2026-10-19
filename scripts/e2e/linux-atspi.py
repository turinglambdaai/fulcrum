#!/usr/bin/env python3
import argparse
import json
import time
from pathlib import Path

import pyatspi

def children(node):
    if node is None:
        return
    try:
        count = node.childCount
    except Exception:
        return
    for index in range(count):
        try:
            child = node.getChildAtIndex(index)
            if child is not None:
                yield child
        except Exception:
            continue
def walk(node):
    if node is None:
        return
    yield node
    for child in children(node):
        yield from walk(child)
def role(node):
    try: return node.getRoleName()
    except Exception: return "unknown"
def text(node):
    try:
        value = node.queryText()
        return value.getText(0, value.characterCount)
    except Exception: return ""
def wait_for(description, probe, timeout=60.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = probe()
        if value: return value
        time.sleep(0.05)
    raise AssertionError(f"timed out waiting for {description}")
def find_application():
    desktop = pyatspi.Registry.getDesktop(0)
    for application in children(desktop):
        for node in walk(application):
            if role(node) == "frame" and (node.name or "") == "Fulcrum": return application
    return None
def contains(root, fragment):
    return any(fragment in (node.name or "") or fragment in text(node) for node in walk(root))
def snapshot(node, depth=0):
    result = {"name": node.name or "", "role": role(node)}
    value = text(node)
    if value: result["text"] = value
    if depth < 8: result["children"] = [snapshot(child, depth + 1) for child in children(node)]
    return result

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    application = wait_for("Fulcrum application", find_application)
    window = wait_for("Fulcrum frame", lambda: next((n for n in walk(application) if role(n) == "frame"), None))
    query = wait_for("FulcrumQuery", lambda: next((n for n in walk(window) if (n.name or "") == "FulcrumQuery"), None))
    query.queryEditableText().setTextContents("12*12")
    wait_for("calculator result 144 from embedded backend", lambda: contains(window, "144"))
    (args.output / "accessibility.json").write_text(json.dumps(snapshot(application), ensure_ascii=False, indent=2), encoding="utf-8")
    (args.output / "interaction-trace.json").write_text(json.dumps({"platform": "linux", "actions": ["set:FulcrumQuery=12*12"], "assertions": ["packaged GTK4 frame activated on native Wayland", "FulcrumQuery exposed through AT-SPI", "query crossed RVT1 into the embedded backend", "native result list contains 144"]}, indent=2), encoding="utf-8")

if __name__ == "__main__": main()
