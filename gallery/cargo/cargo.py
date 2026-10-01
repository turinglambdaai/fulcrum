#!/usr/bin/env python3
"""cargo — search crates on crates.io for Fulcrum (FPP1).

`crate serde` queries the crates.io API and lists the top crates with
their latest version and download count. Activating a row opens the
crate page on crates.io in the browser.

FPP1 contract: one JSON object per line on stdin, one on stdout.
"""

import json
import socket
import sys
import urllib.error
import urllib.parse
import urllib.request
import webbrowser

API = "https://crates.io/api/v1/crates"
TIMEOUT_S = 1.5  # host kills the process at 2 s
# crates.io rejects requests without a descriptive User-Agent.
USER_AGENT = "fulcrum-plugin (plugins@fulcrum.dev)"


class ApiError(Exception):
    """Search failure carrying a short, user-facing reason."""


def fetch_json(url):
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT_S) as response:
            return json.loads(response.read().decode("utf-8"))
    except (socket.timeout, TimeoutError) as exc:
        raise ApiError("timed out") from exc
    except urllib.error.HTTPError as exc:
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


def crate_row(crate):
    name = crate.get("name", "")
    version = crate.get("max_version") or "?"
    downloads = crate.get("downloads") or 0
    description = truncate(str(crate.get("description") or ""), 60)
    return result_row(f"{name} {version}",
                      f"{downloads} downloads \u00b7 {description}",
                      f"https://crates.io/crates/{name}")


def handle_query(query):
    text = query.strip()
    if not text:
        return [result_row("Search crates.io",
                           "Example: crate serde", "")]
    q = urllib.parse.quote(text, safe="")
    url = f"{API}?q={q}&per_page=8"
    try:
        payload = fetch_json(url)
    except ApiError as exc:
        return [result_row("crates.io search failed", str(exc), "")]
    crates = payload.get("crates", []) if isinstance(payload, dict) else []
    rows = [crate_row(c) for c in crates if isinstance(c, dict)]
    if not rows:
        return [result_row("No results",
                           f"No crates match \u201c{text}\u201d", "")]
    return rows


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
