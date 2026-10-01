#!/usr/bin/env python3
"""Bitwarden — vault search for Fulcrum (FPP1).

`bw <query>` searches a Bitwarden vault through the `bw` CLI; an empty
query lists items favorites-first. Locked vaults (no BW_SESSION) get a
single hint row instead of results. Activating a row copies the item's
username to the clipboard.

Privacy note: only the username is ever copied — never the password.
Fulcrum may keep a clipboard history, and a launcher that silently puts
secrets into that history would leak them, so rows carry the username in
their arg and the run path performs no second lookup.

FPP1 contract: one JSON object per line on stdin, one on stdout.
"""

import json
import os
import shutil
import subprocess
import sys

TIMEOUT = 1.5  # every subprocess stays under the host's 2 s kill window
MAX_RESULTS = 8

# bw item "type" codes, used as the subtitle when there is no username.
TYPE_NAMES = {1: "Login", 2: "Secure note", 3: "Card", 4: "Identity"}


def result_row(title, subtitle, arg):
    return {"title": title, "subtitle": subtitle, "arg": arg, "icon": "plugin"}


def bw_output(args):
    """Return stdout of a bw command, or None on any failure (missing
    binary, non-zero exit, timeout)."""
    if shutil.which("bw") is None:
        return None
    try:
        completed = subprocess.run(["bw"] + args, capture_output=True,
                                   timeout=TIMEOUT)
    except (subprocess.SubprocessError, OSError):
        return None
    if completed.returncode != 0:
        return None
    return completed.stdout.decode("utf-8", "replace")


def session_args():
    session = os.environ.get("BW_SESSION", "")
    return ["--session", session] if session else []


def vault_status():
    """Return the vault status string from `bw status`, or None."""
    raw = bw_output(["status"])
    if raw is None:
        return None
    try:
        return str(json.loads(raw).get("status", ""))
    except ValueError:
        return None


def list_items(query):
    """Return item summaries (id/name/username/favorite/kind), favorites
    first, or None when the CLI failed. The full items JSON can be huge,
    so it is reduced to the few fields the rows need immediately."""
    args = ["list", "items"]
    if query:
        args += ["--search", query]
    args += session_args()
    raw = bw_output(args)
    if raw is None:
        return None
    try:
        items = json.loads(raw)
    except ValueError:
        return None
    if not isinstance(items, list):
        return None
    summaries = []
    for item in items:
        if not isinstance(item, dict):
            continue
        login = item.get("login") or {}
        kind = TYPE_NAMES.get(item.get("type"), "Item")
        summaries.append({
            "id": str(item.get("id", "")),
            "name": str(item.get("name") or "(unnamed)"),
            "username": str(login.get("username") or ""),
            "favorite": bool(item.get("favorite")),
            "kind": kind,
        })
    # Stable sort keeps the CLI's relevance order within each group.
    summaries.sort(key=lambda s: not s["favorite"])
    return summaries


def handle_query(query):
    if shutil.which("bw") is None:
        return [result_row("Bitwarden CLI is not installed",
                           "install the `bw` CLI to search your vault", "")]
    status = vault_status()
    if status is None:
        return [result_row("Bitwarden is not available",
                           "`bw status` failed or timed out", "")]
    if status == "locked" and not os.environ.get("BW_SESSION"):
        return [result_row("Vault is locked",
                           "unlock in a terminal, then set BW_SESSION", "")]
    if status == "unauthenticated":
        return [result_row("Not logged in",
                           "run `bw login` in a terminal first", "")]
    summaries = list_items(query.strip())
    if summaries is None:
        return [result_row("Vault search failed",
                           "`bw list items` failed or timed out", "")]
    rows = []
    for item in summaries[:MAX_RESULTS]:
        subtitle = item["username"] or item["kind"]
        rows.append(result_row(item["name"], subtitle,
                               f"username|{item['username']}"))
    if not rows:
        return [result_row("No items found", "try another search", "")]
    return rows


def copy_to_clipboard(text):
    # Same tool ladder as the unit plugin.
    for command in (["pbcopy"], ["wl-copy"],
                    ["xclip", "-selection", "clipboard"], ["clip.exe"]):
        if shutil.which(command[0]):
            try:
                subprocess.run(command, input=text.encode("utf-8"),
                               check=True, timeout=TIMEOUT)
                return True
            except (subprocess.SubprocessError, OSError):
                continue
    return False


def handle_run(arg):
    action, _, username = arg.partition("|")
    username = username.strip()
    if action != "username":
        return {"status": "error", "message": f"unknown action: {action!r}"}
    if not username:
        return {"status": "error", "message": "item has no username"}
    if copy_to_clipboard(username):
        return {"status": "ok", "message": f"{username} copied"}
    return {"status": "error", "message": "no clipboard tool found"}


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
