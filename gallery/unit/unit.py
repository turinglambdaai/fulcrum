#!/usr/bin/env python3
"""Unit — unit conversions for Fulcrum (FPP1).

`u 5 km in mi` converts between units across length, mass, temperature,
volume, data, time, and speed. Without a target unit the plugin lists
common conversions for the parsed quantity. Activating a row copies the
conversion result to the clipboard.

FPP1 contract: one JSON object per line on stdin, one on stdout.
"""

import json
import shutil
import subprocess
import sys

# Every dimension: name, factor-to-base table (base first), common aliases,
# and the target units suggested when the query omits one.
DIMENSIONS = {
    "length": {
        "base": "m",
        "units": {
            "mm": 0.001, "millimeter": 0.001, "millimeters": 0.001,
            "cm": 0.01, "centimeter": 0.01, "centimeters": 0.01,
            "m": 1.0, "meter": 1.0, "meters": 1.0,
            "km": 1000.0, "kilometer": 1000.0, "kilometers": 1000.0,
            "in": 0.0254, "inch": 0.0254, "inches": 0.0254,
            "ft": 0.3048, "foot": 0.3048, "feet": 0.3048,
            "yd": 0.9144, "yard": 0.9144, "yards": 0.9144,
            "mi": 1609.344, "mile": 1609.344, "miles": 1609.344,
            "nmi": 1852.0, "nauticalmile": 1852.0,
        },
        "suggest": ["mi", "ft", "km", "cm", "in"],
    },
    "mass": {
        "base": "kg",
        "units": {
            "mg": 1e-6, "milligram": 1e-6, "milligrams": 1e-6,
            "g": 0.001, "gram": 0.001, "grams": 0.001,
            "kg": 1.0, "kilogram": 1.0, "kilograms": 1.0,
            "t": 1000.0, "tonne": 1000.0, "tonnes": 1000.0,
            "oz": 0.028349523125, "ounce": 0.028349523125, "ounces": 0.028349523125,
            "lb": 0.45359237, "lbs": 0.45359237, "pound": 0.45359237, "pounds": 0.45359237,
            "st": 6.35029318, "stone": 6.35029318, "stones": 6.35029318,
        },
        "suggest": ["lb", "kg", "g", "oz", "st"],
    },
    "volume": {
        "base": "l",
        "units": {
            "ml": 0.001, "milliliter": 0.001, "milliliters": 0.001,
            "l": 1.0, "liter": 1.0, "liters": 1.0, "litre": 1.0, "litres": 1.0,
            "cup": 0.2365882365, "cups": 0.2365882365,
            "pt": 0.473176473, "pint": 0.473176473, "pints": 0.473176473,
            "qt": 0.946352946, "quart": 0.946352946, "quarts": 0.946352946,
            "gal": 3.785411784, "gallon": 3.785411784, "gallons": 3.785411784,
            "floz": 0.0295735295625, "fluidounce": 0.0295735295625,
        },
        "suggest": ["gal", "l", "ml", "cup", "pt"],
    },
    "data": {
        "base": "mb",
        "units": {
            "b": 1e-6, "byte": 1e-6, "bytes": 1e-6,
            "kb": 0.001, "kilobyte": 0.001, "kilobytes": 0.001,
            "mb": 1.0, "megabyte": 1.0, "megabytes": 1.0,
            "gb": 1000.0, "gigabyte": 1000.0, "gigabytes": 1000.0,
            "tb": 1e6, "terabyte": 1e6, "terabytes": 1e6,
            "kib": 0.001024, "kibibyte": 0.001024,
            "mib": 1.048576, "mebibyte": 1.048576,
            "gib": 1073.741824, "gibibyte": 1073.741824,
        },
        "suggest": ["gb", "mb", "kib", "mib", "gib"],
    },
    "time": {
        "base": "s",
        "units": {
            "ms": 0.001, "millisecond": 0.001, "milliseconds": 0.001,
            "s": 1.0, "sec": 1.0, "second": 1.0, "seconds": 1.0,
            "min": 60.0, "minute": 60.0, "minutes": 60.0,
            "h": 3600.0, "hr": 3600.0, "hour": 3600.0, "hours": 3600.0,
            "d": 86400.0, "day": 86400.0, "days": 86400.0,
            "wk": 604800.0, "week": 604800.0, "weeks": 604800.0,
        },
        "suggest": ["min", "h", "d", "ms", "wk"],
    },
    "speed": {
        "base": "mps",
        "units": {
            "mps": 1.0, "m/s": 1.0,
            "kmh": 0.2777777778, "kph": 0.2777777778, "km/h": 0.2777777778,
            "mph": 0.44704,
            "knot": 0.5144444444, "knots": 0.5144444444, "kn": 0.5144444444,
            "fps": 0.3048, "ft/s": 0.3048,
        },
        "suggest": ["kmh", "mph", "mps", "knot", "fps"],
    },
    "area": {
        "base": "m2",
        "units": {
            "m2": 1.0, "sqm": 1.0,
            "km2": 1e6, "sqkm": 1e6,
            "ft2": 0.09290304, "sqft": 0.09290304,
            "mi2": 2589988.110336, "sqmi": 2589988.110336,
            "acre": 4046.8564224, "acres": 4046.8564224,
            "ha": 10000.0, "hectare": 10000.0, "hectares": 10000.0,
        },
        "suggest": ["sqft", "sqm", "acre", "ha", "sqkm"],
    },
}

# Temperature is affine, not proportional: value in the unit's own scale.
TEMPERATURE = {
    "c": 0.0, "celsius": 0.0,
    "f": 32.0, "fahrenheit": 32.0,
    "k": 273.15, "kelvin": 273.15,
}
TEMP_SUGGEST = ["c", "f", "k"]


def to_celsius(value, unit):
    if unit in ("c", "celsius"):
        return value
    if unit in ("f", "fahrenheit"):
        return (value - 32.0) * 5.0 / 9.0
    return value - 273.15


def from_celsius(celsius, unit):
    if unit in ("c", "celsius"):
        return celsius
    if unit in ("f", "fahrenheit"):
        return celsius * 9.0 / 5.0 + 32.0
    return celsius + 273.15


def find_unit(token):
    token = token.lower().strip()
    for dimension, spec in DIMENSIONS.items():
        if token in spec["units"]:
            return dimension, token
    if token in TEMPERATURE:
        return "temperature", token
    return None, None


def format_number(value):
    if value == 0:
        return "0"
    if abs(value) >= 1e15 or (abs(value) < 1e-4 and value != 0):
        return f"{value:.6g}"
    if abs(value - round(value)) < 1e-9:
        return str(int(round(value)))
    return f"{value:.4f}".rstrip("0").rstrip(".")


def result_row(title, subtitle, arg):
    return {"title": title, "subtitle": subtitle, "arg": arg, "icon": "plugin"}


def parse_query(text):
    """Return (value, from_unit, to_unit) or None. Accepts
    "5 km in mi", "100kg to lb", "32 f in c", "5 km"."""
    tokens = text.split()
    if not tokens:
        return None
    try:
        value = float(tokens[0].replace(",", ""))
    except ValueError:
        return None
    if len(tokens) < 2:
        return None
    dimension, from_unit = find_unit(tokens[1])
    if from_unit is None:
        return None
    to_unit = None
    if len(tokens) >= 3:
        rest = tokens[2:]
        # Drop a separator token: in / to / -> / → / as.
        if rest and rest[0].lower() in ("in", "to", "->", "→", "as"):
            rest = rest[1:]
        if rest:
            _, to_unit = find_unit(rest[0])
            if to_unit is None:
                return None
    return value, dimension, from_unit, to_unit


def handle_query(query):
    text = query.strip()
    if not text:
        return [result_row(
            "Unit converter",
            "u 5 km in mi · u 100 kg to lb · u 72 f", "")]

    parsed = parse_query(text)
    if parsed is None:
        return [result_row(
            "No conversion found",
            "Try: u 5 km in mi · u 3 lb to kg · u 72 f", "")]

    value, dimension, from_unit, to_unit = parsed

    if dimension == "temperature":
        celsius = to_celsius(value, from_unit)
        targets = [to_unit] if to_unit else [
            u for u in TEMP_SUGGEST if u != from_unit]
        rows = []
        for target in targets:
            converted = from_celsius(celsius, target)
            title = f"{format_number(value)}°{from_unit.upper()[0]} = {format_number(converted)}°{target.upper()[0]}"
            rows.append(result_row(
                title if target != "k" else title.replace("°K", "K"),
                f"Temperature · {from_unit} → {target}",
                format_number(converted)))
        return rows

    spec = DIMENSIONS[dimension]
    base_value = value * spec["units"][from_unit]
    targets = [to_unit] if to_unit else [
        u for u in spec["suggest"] if u != from_unit]
    rows = []
    for target in targets:
        converted = base_value / spec["units"][target]
        rows.append(result_row(
            f"{format_number(value)} {from_unit} = {format_number(converted)} {target}",
            f"{dimension.capitalize()} · {from_unit} → {target}",
            f"{format_number(converted)} {target}"))
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
