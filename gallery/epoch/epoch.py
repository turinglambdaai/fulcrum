#!/usr/bin/env python3
"""Epoch — the reference Fulcrum plugin (FPP1).

Converts between Unix timestamps and human-readable dates, and prints the
current time. Implements the protocol exactly as docs/plugins.md specifies:
one JSON object per line on stdin, one JSON object per line on stdout.

manifest.json:
{
  "id": "epoch",
  "name": "Epoch",
  "version": "1.0.0",
  "description": "Unix timestamp ↔ date conversions",
  "icon": "plugin",
  "entry": {"exec": ["python3", "epoch.py"]},
  "commands": [
    {"id": "convert", "name": "Convert timestamp", "keyword": "ts"}
  ]
}

Install: copy this directory into Fulcrum's plugins directory
(Settings → Plugins → Open Directory) and run "Reload plugins".
"""

import datetime
import json
import sys
from datetime import timezone


def result_row(title, subtitle, arg):
    return {"title": title, "subtitle": subtitle, "arg": arg, "icon": "plugin"}


def handle_query(query):
    """Return rows for the given query text (text after the `ts` keyword)."""
    text = query.strip()
    rows = []
    if text:
        try:
            stamp = int(text)
            dt = datetime.datetime.fromtimestamp(stamp, tz=timezone.utc)
            rows.append(result_row(
                dt.strftime("%Y-%m-%d %H:%M:%S UTC"),
                f"{stamp} → UTC", text))
            local = dt.astimezone()
            rows.append(result_row(
                local.strftime("%Y-%m-%d %H:%M:%S %Z"),
                f"{stamp} → local", text))
        except (ValueError, OverflowError, OSError):
            # Not an integer timestamp: parse as a date instead.
            for fmt in ("%Y-%m-%d", "%Y-%m-%d %H:%M", "%Y-%m-%d %H:%M:%S"):
                try:
                    dt = datetime.datetime.strptime(text, fmt).replace(tzinfo=timezone.utc)
                    rows.append(result_row(
                        str(int(dt.timestamp())),
                        f"{text} → Unix seconds", text))
                    break
                except ValueError:
                    continue
    else:
        now = int(datetime.datetime.now(tz=timezone.utc).timestamp())
        rows.append(result_row(str(now), "Current Unix timestamp (↵ to copy)", str(now)))
    if not rows:
        rows.append(result_row(
            "No conversion",
            "Enter a Unix timestamp or a YYYY-MM-DD date", text))
    return rows


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
        except json.JSONDecodeError:
            continue
        request_id = request.get("request_id", 0)
        op = request.get("op")
        if op == "query":
            response = {"request_id": request_id,
                        "results": handle_query(str(request.get("query", "")))}
        elif op == "run":
            arg = str(request.get("arg", ""))
            print(arg, file=sys.stderr)  # visible only in plugin logs
            response = {"request_id": request_id, "status": "ok"}
        else:
            response = {"request_id": request_id, "status": "error",
                        "message": f"unknown op {op!r}"}
        sys.stdout.write(json.dumps(response) + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    main()
