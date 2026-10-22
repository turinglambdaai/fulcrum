#!/usr/bin/env bash
# Static guard against accidentally shipping unsigned stable release assets.
# PR CI never needs publisher credentials; only the tagged release does.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
release="$ROOT/.github/workflows/release.yml"
require() {
  grep -Fq -- "$1" "$release" || {
    echo "release-safety: required production gate missing: $1" >&2
    exit 1
  }
}
# CI's `release --development` smoke is intentional; release.yml is different.
if grep -Eq '^[[:space:]]+raco rivet release --development([[:space:]]|$)' "$release"; then
  echo "release-safety: stable release may not use --development" >&2
  exit 1
fi
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
require 'needs: github-release'
require 'Verify installers and signed feed exist before publishing'
require "prerelease: \${{ contains(github.ref_name, '-rc.') }}"
require "make_latest: \${{ contains(github.ref_name, '-rc.') && 'false' || 'true' }}"
require "if: \${{ !contains(github.ref_name, '-rc.') }}"
echo 'release-safety: stable production-signing gates present'
