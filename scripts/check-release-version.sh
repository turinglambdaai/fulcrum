#!/usr/bin/env bash
# Release preflight: VERSION == rivet.rktd == the backend's headless
# fallback literal == tag. Runs in CI (no argument) and in every release
# packaging job (tag as $1). rivet.rktd is the version source the signed
# channel manifest (.github/sign-manifest.rkt) reads, so this gate pins
# all four to one value.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
TAG="${1:-}"

fail() {
  echo "release preflight: $*" >&2
  exit 1
}

[[ -n "$VERSION" ]] || fail "VERSION is empty"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]] || \
  fail "VERSION '$VERSION' is not a supported semantic version"

if [[ -n "$TAG" ]]; then
  TAG_VERSION="${TAG#v}"
  VERSION_PATTERN="${VERSION//./\\.}"
  [[ "$TAG_VERSION" == "$VERSION" ||
     "$TAG_VERSION" =~ ^${VERSION_PATTERN}-rc\.[1-9][0-9]*$ ]] || \
    fail "tag '$TAG' must be v$VERSION or v$VERSION-rc.N"
fi

# The Rivet app manifest carries the product version on this tree.
RIVET_RKTD_VERSION="$(grep -o '"[0-9]*\.[0-9]*\.[0-9]*"' "$ROOT/rivet.rktd" | head -n1 | tr -d '"')"
[[ "$RIVET_RKTD_VERSION" == "$VERSION" ]] || \
  fail "rivet.rktd version '$RIVET_RKTD_VERSION' does not match VERSION '$VERSION'"

# The backend's headless fallback literal (must track rivet.rktd; it feeds
# the update check when rivet-app-info.rktd is absent — drift here means
# every headless run believes it is outdated).
grep -qF "(lambda (_) \"$VERSION\")" "$ROOT/app/backend.rkt" || \
  fail "app/backend.rkt fallback version does not match VERSION '$VERSION'"

if [[ -n "$TAG" ]]; then
  echo "release preflight: version $VERSION is aligned (VERSION == rivet.rktd == backend fallback == tag)"
else
  echo "release preflight: version $VERSION is aligned (VERSION == rivet.rktd == backend fallback)"
fi
