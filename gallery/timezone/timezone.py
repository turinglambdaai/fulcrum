#!/usr/bin/env python3
"""Timezone — convert times across zones for Fulcrum (FPP1).

`tz 14:30 Tokyo` converts a wall-clock time into the target zone, your
local zone, and UTC. Without a time the plugin shows the current time in
the named zone. Without any argument it lists a few major zones as a
starting point. Activating a row copies the converted time.

Zone data comes from the IANA database via Python's stdlib `zoneinfo`
(Python 3.9+). Windows Python needs the `tzdata` package for zone lookups;
the plugin degrades to an explanatory row when a zone cannot be loaded.

FPP1 contract: one JSON object per line on stdin, one on stdout.
"""

import json
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

DEFAULT_ZONES = ["America/Los_Angeles", "America/New_York", "Europe/London",
                 "Europe/Berlin", "Asia/Shanghai", "Asia/Tokyo",
                 "Asia/Kolkata", "Australia/Sydney"]

TIME_FORMATS = ("%H:%M", "%H%M", "%I:%M%p", "%I%p")


def result_row(title, subtitle, arg):
    return {"title": title, "subtitle": subtitle, "arg": arg, "icon": "plugin"}


def zone_for(name):
    """Resolve a zone by IANA name, or by a bare city token
    ("tokyo" → Asia/Tokyo)."""
    try:
        return ZoneInfo(name)
    except (ZoneInfoNotFoundError, ValueError):
        pass
    token = name.strip().lower().replace(" ", "_")
    for candidate in DEFAULT_ZONES:
        if candidate.rsplit("/", 1)[1].lower() == token:
            try:
                return ZoneInfo(candidate)
            except ZoneInfoNotFoundError:
                pass
    return None


def parse_time(text):
    """Parse "14:30", "1430", "2:30pm" into (hour, minute) or None."""
    text = text.strip().lower()
    for fmt in TIME_FORMATS:
        try:
            parsed = datetime.strptime(text, fmt)
            return parsed.hour, parsed.minute
        except ValueError:
            continue
    return None


def split_query(text):
    """Return (time-or-None, zone-name-or-None). The zone is the trailing
    token(s); everything before the first zone-looking token is the time."""
    tokens = text.split()
    if not tokens:
        return None, None
    # Zone names contain "/" or are the trailing token(s): try the last
    # token first, then the last two joined ("new york").
    for take in (1, 2):
        if len(tokens) < take:
            break
        candidate = " ".join(tokens[-take:])
        if take == 2:
            candidate = candidate.replace(" ", "_")
        if zone_for(candidate) is not None:
            rest = tokens[:-take]
            time_part = parse_time(" ".join(rest)) if rest else None
            if rest and time_part is None:
                return None, None  # junk before the zone
            return time_part, candidate
    return None, None


def handle_query(query):
    text = query.strip()
    if not text:
        rows = [result_row("Timezone converter",
                           "tz 14:30 Tokyo · tz 9am New York · tz <zone> for now",
                           "")]
        rows.extend(now_rows(datetime.now(timezone.utc), DEFAULT_ZONES[:5]))
        return rows

    time_part, zone_name = split_query(text)
    if zone_name is None:
        return [result_row(
            "Unknown zone or time",
            "Try: tz 14:30 Tokyo · tz 2026-10-01 09:00 America/New_York", "")]

    zone = zone_for(zone_name)
    if zone is None:  # pragma: no cover - split_query already checked
        return [result_row(f"Zone not found: {zone_name}", "", "")]
    display_name = zone_name.replace("_", " ")

    if time_part is not None:
        now = datetime.now(timezone.utc)
        target = now.astimezone(zone).replace(
            hour=time_part[0], minute=time_part[1], second=0, microsecond=0)
    else:
        target = datetime.now(zone).replace(second=0, microsecond=0)

    rows = [result_row(
        target.strftime("%Y-%m-%d %H:%M %Z"),
        f"{display_name} · ↵ copies", target.strftime("%Y-%m-%d %H:%M %Z"))]

    local = target.astimezone()
    if local.tzinfo != target.tzinfo:
        rows.append(result_row(
            local.strftime("%Y-%m-%d %H:%M %Z"),
            "your local time", local.strftime("%Y-%m-%d %H:%M %Z")))
    utc = target.astimezone(timezone.utc)
    rows.append(result_row(
        utc.strftime("%Y-%m-%d %H:%M UTC"),
        "UTC", utc.strftime("%Y-%m-%d %H:%M UTC")))
    return rows


def now_rows(now, zones):
    rows = []
    for name in zones:
        zone = zone_for(name)
        if zone is None:
            continue
        local = now.astimezone(zone)
        rows.append(result_row(
            f"{name.rsplit('/', 1)[1].replace('_', ' ')} "
            f"{local.strftime('%H:%M %Z')}",
            local.strftime("%Y-%m-%d"), local.strftime("%Y-%m-%d %H:%M %Z")))
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
