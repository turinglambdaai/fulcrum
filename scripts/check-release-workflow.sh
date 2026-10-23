#!/usr/bin/env bash
# Static guard against accidentally shipping unsigned stable release assets.
# PR CI never needs publisher credentials; only the tagged release does.
#
# Two explicitly approved signing postures exist:
#   * production (default)  — every platform credential required;
#   * unsigned channel      — FULCRUM_UNSIGNED_RELEASE_APPROVED=true ships
#     ad-hoc-macOS / unsigned-Windows packages with a prominent release-notes
#     banner; the Ed25519 update feed and Linux artifact signatures stay on.
# A stable release with missing credentials and neither approval still fails
# closed: `raco rivet release --development` may only appear inside a step
# gated on the unsigned-approval variable.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
release="$ROOT/.github/workflows/release.yml"
require() {
  grep -Fq -- "$1" "$release" || {
    echo "release-safety: required production gate missing: $1" >&2
    exit 1
  }
}
unsigned_uses="$(grep -c 'FULCRUM_UNSIGNED_RELEASE_APPROVED' "$release" || true)"
if [[ "$unsigned_uses" -lt 4 ]]; then
  echo "release-safety: the unsigned channel must gate identity setup, the release step, and publishing (found $unsigned_uses uses of FULCRUM_UNSIGNED_RELEASE_APPROVED)" >&2
  exit 1
fi
# `raco rivet release --development` is legal only inside the unsigned step;
# that step must be gated on the approval variable, never on a bare platform
# or unconditional condition.
if ! grep -B40 'raco rivet release --development' "$release" | grep -Fq 'FULCRUM_UNSIGNED_RELEASE_APPROVED'; then
  echo "release-safety: --development packaging must sit inside a FULCRUM_UNSIGNED_RELEASE_APPROVED-gated step" >&2
  exit 1
fi
# The production path stays the default and must remain intact.
require 'raco rivet release'
require 'raco rivet verify --production'
require 'Configure macOS Developer ID and notary profile'
require 'xcrun notarytool store-credentials'
require 'MACOS_CERTIFICATE_P12'
require 'Configure Windows Authenticode identity'
require 'WINDOWS_CERTIFICATE_PFX'
require 'RIVET_WINDOWS_TIMESTAMP_URL'
require 'Configure Linux Ed25519 artifact signing'
require 'RIVET_LINUX_SIGN_PRIVATE_KEY'
require '.tar.gz.sig'
require 'RIVET_UPDATE_PRIVATE_KEY_PEM'
require 'RIVET_UPDATE_KEY_ID'
require 'FULCRUM_STABLE_RELEASE_APPROVED'
require 'Release (unsigned, honestly labeled)'
require 'Banner unsigned releases before they go public'
require 'Unsigned release.** Publisher accounts are not provisioned yet'
require 'needs: github-release'
require 'Verify installers and signed feed exist before publishing'
require 'Require green CI and Product Acceptance for tagged commit'
require 'head_sha=$GITHUB_SHA'
require 'actions: read'
require "prerelease: \${{ contains(github.ref_name, '-rc.') }}"
require "make_latest: \${{ contains(github.ref_name, '-rc.') && 'false' || 'true' }}"
require "if: \${{ !contains(github.ref_name, '-rc.') }}"
echo 'release-safety: stable production-signing gates present (explicit unsigned channel verified)'
