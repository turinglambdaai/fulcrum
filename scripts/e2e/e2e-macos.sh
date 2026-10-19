#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd)"
output="$repo/.rivet/acceptance/macos"
app="$repo/dist/fulcrum.app/Contents/MacOS/fulcrum"
driver="$output/macos-ax"
home="$output/home-$$"
data="$output/data-$$"
mkdir -p "$output" "$home" "$data"
[[ -x "$app" ]]
swiftc "$repo/scripts/e2e/macos-ax.swift" -o "$driver" -framework AppKit -framework ApplicationServices
HOME="$home" FULCRUM_DATA_DIR="$data" FULCRUM_INSTANCE_ID="site.jrtx.fulcrum.acceptance.$$" FULCRUM_ACCEPTANCE=1 "$app" >"$output/application.log" 2>&1 &
app_pid=$!
stop_bounded() { local pid="$1"; kill -TERM "$pid" 2>/dev/null || true; for _ in $(seq 1 200); do kill -0 "$pid" 2>/dev/null || return 0; sleep 0.05; done; kill -KILL "$pid" 2>/dev/null || true; return 1; }
cleanup() { local status=$?; trap - EXIT; if kill -0 "$app_pid" 2>/dev/null; then stop_bounded "$app_pid" || true; wait "$app_pid" 2>/dev/null || true; fi; exit "$status"; }
trap cleanup EXIT
"$driver" --pid "$app_pid" --output "$output"
for _ in $(seq 1 200); do kill -0 "$app_pid" 2>/dev/null || break; sleep 0.05; done
if kill -0 "$app_pid" 2>/dev/null; then echo "Fulcrum did not exit after native termination" >&2; exit 1; fi
wait "$app_pid"
trap - EXIT
