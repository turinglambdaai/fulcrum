#!/usr/bin/env python3
"""Regex — live regular-expression matching for Fulcrum (FPP1).

`re <pattern> <text>` matches the Python regular expression `<pattern>`
against `<text>` and lists every match with its groups. Activating a row
copies the matched text. The pattern is the first whitespace-delimited
token; everything after it is the subject text.

FPP1 contract: one JSON object per line on stdin, one on stdout.
"""

import json
import re
import shutil
import subprocess
import sys

MAX_ROWS = 10
MAX_TEXT = 100000


def result_row(title, subtitle, arg):
    return {"title": title, "subtitle": subtitle, "arg": arg, "icon": "plugin"}


def split_pattern(text):
    """First token is the pattern, the rest is the subject. Returns
    (pattern, subject) or (None, None)."""
    stripped = text.strip()
    if not stripped:
        return None, None
    parts = stripped.split(None, 1)
    if len(parts) == 1:
        return parts[0], None
    return parts[0], parts[1]


def handle_query(query):
    pattern_source, subject = split_pattern(query)
    if not pattern_source:
        return [result_row(
            "Regex tester",
            "re \\w+@\\w+\\.com <text> · first token is the pattern", "")]
    if subject is None:
        return [result_row(
            f"Pattern {pattern_source}",
            "Add text to match against: re <pattern> <text>", "")]

    if len(subject) > MAX_TEXT:
        subject = subject[:MAX_TEXT]

    try:
        pattern = re.compile(pattern_source)
    except re.error as exc:
        return [result_row(f"Invalid pattern: {exc}", "", "")]

    matches = list(pattern.finditer(subject))[:MAX_ROWS]
    if not matches:
        return [result_row("No matches",
                           f"{pattern_source} against "
                           f"{subject[:60]}{'…' if len(subject) > 60 else ''}",
                           "")]

    rows = []
    for index, match in enumerate(matches, 1):
        groups = [g if g is not None else "" for g in match.groups()]
        named = {k: v for k, v in (match.groupdict() or {}).items()
                 if v is not None}
        subtitle_bits = [f"match {index} · span {match.start()}–{match.end()}"]
        if groups:
            subtitle_bits.append("groups: " + ", ".join(
                repr(g) for g in groups[:4]))
        elif named:
            subtitle_bits.append(" · ".join(
                f"{k}={v!r}" for k, v in list(named.items())[:4]))
        rows.append(result_row(match.group(0) or "(empty match)",
                               " · ".join(subtitle_bits)[:160],
                               match.group(0) or ""))
    return rows


def copy_to_clipboard(text):
    for command in (["pbcopy"], ["wl-copy"], ["xclip", "-selection", "clipboard"],
                    ["clip.exe"]):
        if shutil.which(command[0]):
            try:
                subprocess.run(command, input=text.encode("utf-8"),
                               check=True, timeout=5)
                return True
            except (subprocess.SubprocessError, OSError):
                continue
    return False


def handle_run(arg):
    if not arg:
        return {"status": "error", "message": "nothing to copy"}
    if copy_to_clipboard(arg):
        return {"status": "ok", "message": arg}
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
