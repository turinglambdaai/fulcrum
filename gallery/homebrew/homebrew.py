#!/usr/bin/env python3
"""Homebrew — look up formulae and casks for Fulcrum (FPP1).

`brew wget` resolves a package name against formulae.brew.sh. The old
server-side /api/search endpoint was removed in Homebrew 4.1 (July 2023)
and the full /api/formula.json index is ~32 MB — far over the plugin
time budget — so the plugin instead probes the small per-name JSON file
for the query as a formula and as a cask (two parallel requests).
Activating a row opens the package page in the browser.

FPP1 contract: one JSON object per line on stdin, one on stdout.
"""

import json
import socket
import sys
import urllib.error
import urllib.parse
import urllib.request
import webbrowser
from concurrent.futures import ThreadPoolExecutor

API = "https://formulae.brew.sh/api"
TIMEOUT_S = 1.2  # host kills the process at 2 s; probes run in parallel
KINDS = ("formula", "cask")


class ApiError(Exception):
    """Lookup failure carrying a short, user-facing reason."""


class ApiNotFound(ApiError):
    """No formula/cask page exists under that exact name."""


def fetch_json(url):
    request = urllib.request.Request(
        url, headers={"User-Agent": "fulcrum-plugin"})
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT_S) as response:
            return json.loads(response.read().decode("utf-8"))
    except (socket.timeout, TimeoutError) as exc:
        raise ApiError("timed out") from exc
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            raise ApiNotFound(str(exc)) from exc
        if exc.code in (403, 429):
            raise ApiError("rate limited") from exc
        raise ApiError(f"HTTP {exc.code}") from exc
    except urllib.error.URLError as exc:
        raise ApiError("network unreachable") from exc
    except ValueError as exc:  # json.JSONDecodeError
        raise ApiError("invalid response") from exc


def result_row(title, subtitle, arg):
    return {"title": title, "subtitle": subtitle, "arg": arg, "icon": "plugin"}


def truncate(text, limit):
    if len(text) <= limit:
        return text
    return text[: limit - 1].rstrip() + "\u2026"


def lookup(kind, name):
    """Return (kind, desc) for an exact package name, or None if absent."""
    url = f"{API}/{kind}/{urllib.parse.quote(name, safe='')}.json"
    try:
        data = fetch_json(url)
    except ApiNotFound:
        return None
    if not isinstance(data, dict):
        return None
    return kind, str(data.get("desc") or "")


def brew_row(name, kind, desc):
    return result_row(name, f"{kind} \u00b7 {truncate(desc, 70)}",
                      f"https://formulae.brew.sh/{kind}/{name}")


def handle_query(query):
    text = query.strip()
    if not text:
        return [result_row("Search Homebrew formulae and casks",
                           "Example: brew wget", "")]
    found = []
    failure = None
    # Probe formula and cask in parallel: each is a small static JSON file.
    with ThreadPoolExecutor(max_workers=len(KINDS)) as pool:
        futures = [pool.submit(lookup, kind, text) for kind in KINDS]
        for future in futures:
            try:
                hit = future.result()
            except ApiError as exc:
                failure = failure or exc
                continue
            if hit:
                found.append(hit)
    if not found:
        if failure is not None:
            return [result_row("Homebrew search failed", str(failure), "")]
        return [result_row(f"No formula or cask named \u201c{text}\u201d",
                           "Homebrew needs an exact package name", "")]
    return [brew_row(text, kind, desc) for kind, desc in found]


def handle_run(arg):
    if not arg:
        return {"status": "error", "message": "nothing to open"}
    if webbrowser.open(arg):
        return {"status": "ok"}
    return {"status": "error", "message": "could not open a browser"}


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
