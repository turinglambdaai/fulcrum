#!/usr/bin/env python3
"""Currency — live exchange-rate conversion for Fulcrum (FPP1).

`cur 100 usd in eur` converts across ~160 currencies using the free,
keyless open.er-api.com daily feed. Rates are fetched per query with a
1.5 s budget (the host's default plugin timeout is 2 s); a network failure
degrades to one explanatory row. Activating a row copies the result.

FPP1 contract: one JSON object per line on stdin, one on stdout.
"""

import json
import shutil
import subprocess
import sys
import urllib.request

API = "https://open.er-api.com/v6/latest/USD"
NETWORK_TIMEOUT = 1.5


def result_row(title, subtitle, arg):
    return {"title": title, "subtitle": subtitle, "arg": arg, "icon": "plugin"}


def fetch_rates():
    request = urllib.request.Request(
        API, headers={"User-Agent": "fulcrum-plugin"})
    with urllib.request.urlopen(request, timeout=NETWORK_TIMEOUT) as response:
        payload = json.loads(response.read().decode("utf-8"))
    if payload.get("result") != "success":
        raise ValueError(payload.get("error", "feed error"))
    return payload["rates"]


def parse_query(text):
    """Return (amount, from_code, to_code) or None. Accepts
    "100 usd in eur", "100usd to eur", "100 usd eur"."""
    tokens = text.replace(",", " ").split()
    if not tokens:
        return None
    try:
        amount = float(tokens[0])
    except ValueError:
        return None
    rest = [t.upper().lstrip(":") for t in tokens[1:]]
    rest = [t for t in rest if t not in ("IN", "TO", "->", "→", "AS")]
    if len(rest) < 2:
        return None
    from_code, to_code = rest[0], rest[1]
    if len(from_code) != 3 or len(to_code) != 3:
        return None
    return amount, from_code, to_code


def format_number(value):
    if value == 0:
        return "0"
    if value >= 1 or value <= -1:
        return f"{value:,.2f}"
    return f"{value:.6f}".rstrip("0").rstrip(".")


def handle_query(query):
    text = query.strip()
    if not text:
        return [result_row(
            "Currency converter",
            "cur 100 usd in eur · live daily rates from open.er-api.com", "")]

    parsed = parse_query(text)
    if parsed is None:
        return [result_row(
            "No conversion found",
            "Try: cur 100 usd in eur · cur 250 jpy to cny", "")]

    amount, from_code, to_code = parsed
    try:
        rates = fetch_rates()
    except Exception:
        return [result_row(
            "Currency feed unreachable",
            "Check your network; rates come from open.er-api.com", "")]

    from_rate = rates.get(from_code)
    to_rate = rates.get(to_code)
    if from_rate is None or to_rate is None:
        unknown = from_code if from_rate is None else to_code
        return [result_row(f"Unknown currency code: {unknown}",
                           "Use a 3-letter ISO code like USD, EUR, CNY", "")]

    usd_amount = amount / from_rate
    converted = usd_amount * to_rate
    unit_rate = to_rate / from_rate
    rows = [result_row(
        f"{format_number(amount)} {from_code} = {format_number(converted)} {to_code}",
        f"1 {from_code} = {unit_rate:.4f} {to_code} · ↵ copies",
        f"{format_number(converted)} {to_code}")]
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
