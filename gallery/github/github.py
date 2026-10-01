#!/usr/bin/env python3
"""GitHub — search issues and pull requests for Fulcrum (FPP1).

`gh memory leak repo:rust-lang/rust` queries the GitHub search API
(search/issues) and lists the top issues and PRs. Activating a row opens
the issue or PR in the browser. Set GITHUB_TOKEN in the host environment
to raise the API rate limit.

FPP1 contract: one JSON object per line on stdin, one on stdout.
"""

import json
import os
import socket
import sys
import urllib.error
import urllib.parse
import urllib.request
import webbrowser

API = "https://api.github.com/search/issues"
TIMEOUT_S = 1.5  # host kills the process at 2 s
REPO_PREFIX = "https://api.github.com/repos/"


class ApiError(Exception):
    """Search failure carrying a short, user-facing reason."""


def fetch_json(url, headers):
    request = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT_S) as response:
            return json.loads(response.read().decode("utf-8"))
    except (socket.timeout, TimeoutError) as exc:
        raise ApiError("timed out") from exc
    except urllib.error.HTTPError as exc:
        if exc.code in (403, 429):
            raise ApiError("rate limited — set GITHUB_TOKEN") from exc
        raise ApiError(f"HTTP {exc.code}") from exc
    except urllib.error.URLError as exc:
        raise ApiError("network unreachable") from exc
    except ValueError as exc:  # json.JSONDecodeError
        raise ApiError("invalid response") from exc


def result_row(title, subtitle, arg):
    return {"title": title, "subtitle": subtitle, "arg": arg, "icon": "plugin"}


def search_headers():
    headers = {"Accept": "application/vnd.github+json",
               "User-Agent": "fulcrum-plugin"}
    token = os.environ.get("GITHUB_TOKEN", "").strip()
    if token:
        headers["Authorization"] = f"Bearer {token}"
    return headers


def issue_row(item):
    title = f"{item.get('title', '')} #{item.get('number', '?')}"
    repo = item.get("repository_url", "")
    if repo.startswith(REPO_PREFIX):
        repo = repo[len(REPO_PREFIX):]
    # A pull_request key means the item is a PR, not a plain issue.
    prefix = "PR · " if item.get("pull_request") else ""
    user = (item.get("user") or {}).get("login", "unknown")
    subtitle = f"{prefix}{repo} · {item.get('state', 'unknown')} · {user}"
    return result_row(title, subtitle, item.get("html_url", ""))


def handle_query(query):
    text = query.strip()
    if not text:
        return [result_row("Search GitHub issues and PRs",
                           "Example: gh memory leak repo:rust-lang/rust", "")]
    q = urllib.parse.quote(text, safe="")
    url = f"{API}?q={q}&per_page=8"
    try:
        payload = fetch_json(url, search_headers())
    except ApiError as exc:
        return [result_row("GitHub search failed", str(exc), "")]
    items = payload.get("items", []) if isinstance(payload, dict) else []
    rows = [issue_row(item) for item in items if isinstance(item, dict)]
    if not rows:
        return [result_row("No results",
                           f"No issues or PRs match \u201c{text}\u201d", "")]
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
