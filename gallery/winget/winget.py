#!/usr/bin/env python3
"""Winget — package search for Fulcrum (FPP1).

`winget <query>` searches the Windows Package Manager catalog through the
winget CLI. Activating a row copies the matching `winget install` command
to the clipboard (via clip.exe). Windows only — every other platform gets
a single notice row instead of results.

FPP1 contract: one JSON object per line on stdin, one on stdout.
"""

import json
import re
import shutil
import subprocess
import sys

TIMEOUT = 1.5  # every subprocess stays under the host's 2 s kill window
MAX_RESULTS = 8

# winget prints a fixed-width table; columns are separated by runs of 2+
# spaces (ids and names never contain such runs, so this is a safe split).
COLUMN_SPLIT = re.compile(r"\s{2,}")


def result_row(title, subtitle, arg):
    return {"title": title, "subtitle": subtitle, "arg": arg, "icon": "plugin"}


def parse_table(output):
    """Parse winget's table output into (name, id, version) tuples.

    Real data rows start after the dashed separator line under the (possibly
    localized) header, so the separator is the anchor and the header itself
    is skipped without needing to know its text.
    """
    lines = output.splitlines()
    start = -1
    for i, line in enumerate(lines):
        stripped = line.strip()
        if stripped and set(stripped) <= set("-"):
            start = i + 1
            break
    if start < 0:
        return []
    rows = []
    for line in lines[start:]:
        if not line.strip():
            continue
        cells = COLUMN_SPLIT.split(line.strip())
        if len(cells) < 2:
            continue
        name, package_id = cells[0], cells[1]
        version = cells[2] if len(cells) >= 3 else ""
        rows.append((name, package_id, version))
    return rows


def handle_query(query):
    if sys.platform != "win32":
        return [result_row("winget is only available on Windows",
                           "this plugin shells out to the winget CLI", "")]
    text = query.strip()
    if not text:
        return [result_row("Winget package search",
                           "Type to search · ↵ copies the install command",
                           "")]
    if shutil.which("winget") is None:
        return [result_row("winget is not installed",
                           "install the App Installer package from Microsoft",
                           "")]
    try:
        completed = subprocess.run(
            ["winget", "search", "--query", text, "--disable-interactivity"],
            capture_output=True, timeout=TIMEOUT)
    except (subprocess.SubprocessError, OSError):
        return [result_row("winget search failed",
                           "the CLI did not respond in time", "")]

    rows = []
    for name, package_id, version in parse_table(
            completed.stdout.decode("utf-8", "replace"))[:MAX_RESULTS]:
        subtitle = f"{package_id} · {version}" if version else package_id
        rows.append(result_row(name, subtitle, package_id))
    if rows:
        return rows
    if completed.returncode != 0:
        # Surface a short reason from stderr when the CLI itself failed.
        reason = completed.stderr.decode("utf-8", "replace").strip()
        reason = reason.splitlines()[0][:100] if reason else "exit code " \
            f"{completed.returncode}"
        return [result_row("winget search failed", reason, "")]
    return [result_row("No matching packages",
                       f"nothing in the catalog matches {text!r}", "")]


def copy_to_clipboard(text):
    # On Windows clip.exe reads the text from its standard input.
    if shutil.which("clip.exe") is None:
        return False
    try:
        subprocess.run(["clip.exe"], input=text.encode("utf-8"),
                       check=True, timeout=TIMEOUT)
        return True
    except (subprocess.SubprocessError, OSError):
        return False


def handle_run(arg):
    package_id = arg.strip()
    if not package_id:
        return {"status": "error", "message": "no package id given"}
    command = f"winget install --id {package_id} -e"
    if copy_to_clipboard(command):
        return {"status": "ok", "message": command}
    return {"status": "error", "message": "no clipboard tool found (clip.exe)"}


def main():
    try:
        request = json.loads(sys.stdin.readline())
    except (ValueError, json.JSONDecodeError):
        print(json.dumps({"request_id": 0, "status": "error",
                          "message": "invalid request"}))
        return
    request_id = request.get("request_id", 0)
    try:
        if request.get("op") == "query":
            response = {"request_id": request_id,
                        "results": handle_query(request.get("query", ""))}
        elif request.get("op") == "run":
            response = {"request_id": request_id}
            response.update(handle_run(request.get("arg", "")))
        else:
            response = {"request_id": request_id, "status": "error",
                        "message": f"unknown op: {request.get('op')}"}
    except Exception as exc:  # never crash the protocol
        response = {"request_id": request_id, "status": "error",
                    "message": str(exc)}
    print(json.dumps(response))


if __name__ == "__main__":
    main()
