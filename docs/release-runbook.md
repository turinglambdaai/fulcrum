# Release runbook

How a Fulcrum release ships: version bump, update keys, signing, tagged
pipeline. This is the operator document; `docs/release-and-updates.md` in
the Rivet repository explains the trust model this builds on.

## 0. Prerequisites (one-time per machine)

- Racket CS (the version Fulcrum embeds), on PATH as `raco`/`racket`.
- macOS: Xcode command line tools, an Apple Developer ID Application
  certificate, and a `notarytool` keychain profile.
- Windows: Visual Studio 2022 Build Tools (Desktop C++ + WinUI workload),
  an EV or OV Authenticode certificate, `WiX Toolset v4+`.
- An Ed25519 update key pair, generated and stored **outside** any checkout:

  ```bash
  openssl genpkey -algorithm Ed25519 -outform DER -out update-private.der
  openssl pkey -inform DER -in update-private.der -pubout -outform DER -out update-public.der
  ```

## 1. Version bump

Release identity lives in two files that must agree: bump `version` (SemVer)
and `build` (integer, never reuse per platform) in `rivet.rktd`, and set the
repo-root `VERSION` file to the same value. Update `CHANGELOG.md` with a
section named exactly after the new version — the tag validator rejects a
tag whose version has no matching changelog section.
`scripts/check-release-version.sh` (run in CI and every release packaging
job) enforces `VERSION == rivet.rktd == tag`; `.github/sign-manifest.rkt`
reads the version from `rivet.rktd` when composing the channel manifest.

For the developer preview on the `main` branch this is enough; production
steps continue below.

## 2. Update key embedding

The Ed25519 verification key ships as source, not a build-time
substitution: `app/update.rkt` commits `current-update-public-key-hex`
(DER SPKI, hex) and `update-key-id` permanently — the public half only
enables verification, so developer builds and release builds verify
updates identically and there is no key step in packaging. The private
half never enters a checkout: it lives in the keys vault and in the
`RIVET_UPDATE_PRIVATE_KEY` repository secret (PEM; the release pipeline
converts it to DER for `raco rivet release` and for the channel-manifest
signer, which takes the matching `RIVET_UPDATE_KEY_ID`).

Key rotation: generate a new pair (§0), replace the committed hex and key
id —

```bash
xxd -p update-public.der | tr -d '\n'   # → current-update-public-key-hex
```

— ship a client trusting the **next** public key first, then sign
releases exclusively with it. The `key_id` field is what makes the
overlap safe.

## 3. Tagged pipeline

```bash
git tag -s v0.1.0 -m "Fulcrum 0.1.0"
git push origin v0.1.0
```

`.github/workflows/release.yml` then, per platform matrix (macOS arm64 +
x64, Windows x64, Linux x64):

1. validates the tag against `VERSION`, `rivet.rktd` and the changelog;
2. `raco rivet build` + `raco rivet package --production` (platform
   signing from secrets);
3. `raco rivet release` — installer (DMG / MSI), Ed25519-signed update
   manifest, CycloneDX SBOM, third-party notices;
4. renames artifacts to the versioned, architecture-suffixed release names
   (`fulcrum-<version>-macos-<arch>.dmg` / `.zip`,
   `fulcrum-<version>-windows-x64.msi`,
   `fulcrum-<version>-linux-x64.tar.gz`), writes a `.sha256` sidecar per
   artifact, and uploads them;
5. the publish job signs one channel manifest pinning all artifacts
   (macOS clients are served the portable zip for their architecture),
   assembles `SHA256SUMS` from the sidecars, and drafts the GitHub
   release. Manifest URLs are tag-pinned
   (`releases/download/<tag>/<artifact>`) — never re-upload under an
   existing version URL. The app itself fetches `manifest.json` under its
   `update-base-url` setting (default
   `https://github.com/turinglambdaai/fulcrum/releases/latest/download`),
   so publishing the draft puts the update feed live.

Required secrets: `MACOS_CERTIFICATE_P12`, `MACOS_CERTIFICATE_PASSWORD`,
`MACOS_NOTARY_PROFILE`, `APPLE_ID`/`APPLE_TEAM_ID` (notarytool),
`WINDOWS_CERTIFICATE_PFX`, `WINDOWS_CERTIFICATE_PASSWORD`,
`RIVET_UPDATE_PRIVATE_KEY` (the DER file, PEM-wrapped),
`RIVET_UPDATE_KEY_ID`. The manifest base URL is derived from the tag, not
a secret.

## 3a. macOS drag-to-install DMG (Taskly-parity)

Fulcrum now uses the **Rivet v0.12.0 branded Finder DMG** instead of the
default single-folder disk image. `rivet.rktd` declares
`dmg-background = assets/dmg-background.png`; its editable, reviewable
source is `assets/dmg-background.svg`. Finder positions the 80-point app
and Applications-link icons at (130,160) and (450,160) in a 660×400 window.

On each **macOS** tagged-release runner, after installing Rivet but before
`raco rivet release`, run:

```bash
brew install librsvg
bash scripts/render-dmg-background.sh
python3 scripts/check-macos-dmg-layout.py
```

The build fails if the artwork cannot be rendered or is not the expected
1320×800 (2×) PNG; the generated raster is intentionally gitignored.
Both `macos-arm64` and `macos-x64` run this check, and macOS CI
validates the SVG/raster contract as well.

**Release smoke test on a real macOS machine, both architectures:**
mount the actual packaged `.dmg`, check that the Finder window displays
Fulcrum.app and the Applications alias with the correct drag cue, drag the
app to Applications, eject the DMG, launch the installed copy, summon it
with the hotkey and check Accessibility permissions are requested only
when relevant. An app started directly inside a mounted DMG is **not**
the installed copy and must not be used as the updater acceptance path.

**Signing is a separate gate.** The current release workflow explicitly
uses `raco rivet release --development`: this produces an ad-hoc-signed
preview, *not* a Developer ID signed and Apple-notarized public build.
A nicer DMG cannot remove Gatekeeper warnings. Before promising a
warning-free consumer install, wire up Rivet's production signing/
notarization path and test `spctl`, `codesign --verify`, and stapled
DMG validation, using securely provisioned signing credentials.
Do not work around the absence of notarization by clearing quarantine
or disabling Gatekeeper.

---

## 4. Publish checklist

- [ ] Draft release notes link the changelog section.
- [ ] `manifest.json` verifies with the **public** key:
      `raco rivet verify --production` on a machine with only the public key.
- [ ] Install the signed artifact on a clean VM for each OS; run one
      search, one clipboard copy, one plugin query, one update check.
- [ ] In-app update check reports the new version on the previous release.
- [ ] Site pricing/download links still match reality.

## 5. Rollback

If a release must be pulled: publish a new patch version and point
`stable/manifest.json` at it (signed, with `rollback` metadata referencing
the pulled version). Never re-upload an artifact under an existing version
URL — hashes are pinned by the signed manifest.
