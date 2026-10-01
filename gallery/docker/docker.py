#!/usr/bin/env python3
"""Docker — container control for Fulcrum (FPP1).

`dk` lists Docker containers via `docker ps -a`. With an empty query only
running containers are shown; typing filters all containers by a
case-insensitive substring match on name, image, state, and status.
Activating a row toggles the container: start a stopped one, stop a
running one.

FPP1 contract: one JSON object per line on stdin, one on stdout.

Timeout note: Fulcrum kills this plugin at its ~2 s host timeout, so a
long `docker stop` may cut the CLI process off mid-call — but the Docker
daemon has already accepted the stop request and finishes it on its own.
That is why a stop timeout is still reported as success below.
"""

import json
import shutil
import subprocess
import sys

TIMEOUT = 1.5  # every subprocess stays under the host's 2 s kill window

PS_FORMAT = "{{.Names}}\t{{.Image}}\t{{.State}}\t{{.Status}}"
MAX_ROWS = 10


def result_row(title, subtitle, arg):
    return {"title": title, "subtitle": subtitle, "arg": arg, "icon": "plugin"}


def unavailable_row():
    """Single graceful row when docker or its daemon cannot be reached."""
    if shutil.which("docker") is None:
        return result_row("Docker is not available",
                          "the docker CLI was not found in PATH", "")
    return result_row("Docker is not available",
                      "docker did not respond — is the daemon running?", "")


def docker_output(args):
    """Return stdout of a docker command, or None when the CLI is missing,
    the daemon is unreachable, or the call exceeded the timeout."""
    if shutil.which("docker") is None:
        return None
    try:
        completed = subprocess.run(["docker"] + args, capture_output=True,
                                   timeout=TIMEOUT)
    except (subprocess.SubprocessError, OSError):
        return None
    if completed.returncode != 0:
        return None
    return completed.stdout.decode("utf-8", "replace")


def handle_query(query):
    text = query.strip()
    lines = docker_output(["ps", "-a", "--format", PS_FORMAT])
    if lines is None:
        return [unavailable_row()]

    rows = []
    if not text:
        # Empty query: a hint row first, then only running containers.
        rows.append(result_row("Docker containers",
                               "Type to filter · ↵ to start/stop", ""))
    for line in lines.splitlines():
        parts = line.split("\t", 3)
        if len(parts) < 4:
            continue
        name, image, state, status = parts
        if not text:
            if state != "running":
                continue
        elif not any(text.lower() in field.lower() for field in parts):
            continue
        action = "stop" if state == "running" else "start"
        rows.append(result_row(name, f"{image} · {status}",
                               f"{action}:{name}"))
        if len(rows) >= MAX_ROWS:
            break
    if not rows:
        rows.append(result_row("No matching containers",
                               "no container matches the filter", ""))
    return rows


def handle_run(arg):
    if shutil.which("docker") is None:
        return {"status": "error", "message": "docker CLI not found"}
    action, _, name = arg.partition(":")
    name = name.strip()
    if action not in ("start", "stop") or not name:
        return {"status": "error", "message": f"unknown action: {arg!r}"}

    if action == "start":
        try:
            completed = subprocess.run(["docker", "start", name],
                                       capture_output=True, timeout=TIMEOUT)
        except subprocess.TimeoutExpired:
            return {"status": "error", "message": f"start of {name} timed out"}
        except OSError:
            return {"status": "error", "message": f"failed to start {name}"}
        if completed.returncode == 0:
            return {"status": "ok", "message": f"started {name}"}
        return {"status": "error", "message": f"failed to start {name}"}

    # Stop: give the container 5 s to exit gracefully. The host may kill
    # this plugin before the CLI returns — the daemon still completes the
    # stop, so a timeout counts as "stop sent" (see module docstring).
    try:
        completed = subprocess.run(["docker", "stop", "-t", "5", name],
                                   capture_output=True, timeout=TIMEOUT)
    except subprocess.TimeoutExpired:
        return {"status": "ok", "message": f"stop sent to {name}"}
    except OSError:
        return {"status": "error", "message": f"failed to stop {name}"}
    if completed.returncode == 0:
        return {"status": "ok", "message": f"stopped {name}"}
    return {"status": "error", "message": f"failed to stop {name}"}


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
