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
job) enforces `VERSION == rivet.rktd`; a stable tag is `v<VERSION>`, while a
candidate tag may be `v<VERSION>-rc.N`. `.github/sign-manifest.rkt` reads the
numeric package version from `rivet.rktd` when composing the channel manifest.

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
2. provisions platform signing credentials from the repository secret store;
3. runs `raco rivet release` followed by `raco rivet verify --production`
   to build and verify the signed/notarized installer, update manifest,
   CycloneDX SBOM and third-party notices;
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
   so only publishing a non-prerelease release changes the stable feed.

### The explicitly unsigned channel

When publisher accounts are not provisioned (Apple Developer Program,
Windows Authenticode), setting the repository variable
`FULCRUM_UNSIGNED_RELEASE_APPROVED=true` ships an honestly-labeled
**unsigned** stable release:

- macOS packages are ad-hoc signed; users right-click → Open on first
  launch. Windows packages carry no Authenticode signature; SmartScreen
  warns. The publish job prepends a warning banner to the release notes,
  and the publish approval accepts either this variable or
  `FULCRUM_STABLE_RELEASE_APPROVED=true` — approval is required either way.
- What stays signed: the Ed25519 update feed (in-app updates verify byte
  integrity identically) and the Linux detached artifact signatures — the
  Linux job never enters the unsigned branch.
- The channel is **explicit, never a silent fallback**: without the
  variable, a stable tag with missing credentials still fails closed
  (preflight in `version-release.yml`, the per-platform identity steps,
  and `scripts/check-release-workflow.sh` all enforce this). Set the
  variable back to `false` once the production accounts are provisioned;
  the next release then returns to mandatory Developer ID notarization
  and Authenticode signing.

### Release candidates

An RC tag uses `v<VERSION>-rc.N`, but `VERSION`, `rivet.rktd`, native package
metadata and artifact names keep the numeric `VERSION`. This is intentional:
WiX MSI and RPM package versions cannot safely use a SemVer prerelease suffix.
Create the version bump on a release-candidate branch, let that exact commit
pass CI and Product Acceptance, then tag that commit. Do not merge the numeric
version bump to `main`, because the main-branch version gate would create a
stable tag automatically.

The workflow marks an RC as a GitHub prerelease, never uploads the versionless
stable aliases, and explicitly sets `make_latest=false`. Therefore
`releases/latest/download/update-manifest.json` and all stable download buttons
continue resolving to the last stable release. The RC still carries its own
tag-pinned signed manifest for inspection and manual installation.

Because the installed native package version is numeric, an RC consumes that
number. To test online update from the RC, the next candidate or stable release
must increment the numeric version (for example, candidate package `0.13.3`
updates to stable `0.13.4`); republishing `0.13.3` as stable would correctly be
treated as the same version and would not exercise an update.

Required **GitHub Actions secrets** (configure before creating any signed
stable or RC tag):

- `MACOS_CERTIFICATE_P12`: base64 of the Developer ID Application P12,
  `MACOS_CERTIFICATE_PASSWORD`, `MACOS_SIGN_IDENTITY` (full
  `Developer ID Application: …` name), `APPLE_ID`, `APPLE_TEAM_ID`,
  `MACOS_APP_SPECIFIC_PASSWORD` for `notarytool`. Both architecture jobs
  import into temporary keychains and save a `fulcrum-notary` profile.
- `WINDOWS_CERTIFICATE_PFX`: base64 of an Authenticode code-signing PFX
  and `WINDOWS_CERTIFICATE_PASSWORD`. Set the repository **variable**
  `WINDOWS_TIMESTAMP_URL` to a working RFC 3161 service URL.
  Certificates requiring interactive hardware-backed signing need a
  separately provisioned trusted runner; do not export hardware keys.
- `LINUX_SIGN_PRIVATE_KEY`: PEM-encoded **artifact signing** Ed25519
  private key and `LINUX_SIGN_KEY_ID`. This is separate from the update
  feed signing key. Production Linux release ships the detached signature
  `fulcrum-<version>-linux-<arch>.tar.gz.sig`; DEB/RPM repository metadata
  signing is not implied by this signature.
- `RIVET_UPDATE_PRIVATE_KEY`: PEM Ed25519 feed signing private key, plus
  `RIVET_UPDATE_KEY_ID=fulcrum-2026-10`. The ID and its public key must
  match the trust root embedded in shipped clients.

Before merging any `VERSION` bump, set the repository variable
`FULCRUM_STABLE_RELEASE_APPROVED=true` **only when you intend to ship**.
`version-release.yml` checks this authorization and the presence of all
credentials **before creating the immutable tag**. Set it back to `false`
after publishing. Manually pushed stable tags are also blocked at the draft
promotion step unless this variable is `true`. Without approval, the
version-bump workflow fails and does not create a tag.

Private key files are only materialized under the ephemeral runner temp
directory, never committed. All missing identities/signatures/notary
credentials **fail closed**: a stable tag must never silently fall back to
`release --development`. The manifest base URL is derived from the tag,
not a secret.

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

**Signing is a separate gate.** Stable tagged releases now invoke
`raco rivet release` and `raco rivet verify --production`, after temporary
Developer ID identity and `notarytool` profile setup. The release fails
if its Apple certificate, notary credentials, signed bundle, stapled DMG
or Gatekeeper verification is unavailable. Local CI's
`release --development` is **only** an unsigned installer smoke test;
it is never proof of stable-release trust. Validate the final artifacts
with `codesign --verify --deep --strict`, `spctl --assess`, and
`xcrun stapler validate` on actual installed apps and DMGs.
Do not work around the absence of notarization by clearing quarantine
or disabling Gatekeeper.

---

## 4. Publish checklist

- [ ] Draft release notes link the changelog section.
- [ ] `manifest.json` verifies against the embedded **Ed25519 feed
      public key**; `raco rivet verify --production` is a separate
      platform-package/signature verification, not a manifest verifier.
- [ ] Both macOS DMGs and installed apps pass Developer ID, Gatekeeper,
      notarization and stapling checks; Windows MSI/EXE pass Authenticode
      verification; both Linux tarballs have verified detached signatures.
- [ ] Install the signed artifact on a clean VM for each OS; run one
      search, one clipboard copy, one plugin query, one update check.
- [ ] In-app update check reports the new version on the previous release.
- [ ] Site pricing/download links still match reality.

## 5. Rollback

If a release must be pulled: publish a new patch version and point
`stable/manifest.json` at it (signed, with `rollback` metadata referencing
the pulled version). Never re-upload an artifact under an existing version
URL — hashes are pinned by the signed manifest.
