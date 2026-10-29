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

1. validates the tag against `VERSION`, `rivet.rktd` and the changelog
   after the main-branch `VERSION` workflow has verified stable release
   authorization, required credentials and exact-SHA CI/Product Acceptance;
2. provisions platform signing credentials from the repository secret store;
3. runs `raco rivet release` with production-signing and verification
   when publisher credentials are provisioned, or the separately approved
   and explicitly labelled unsigned desktop channel (Linux artifact and
   update-feed signatures remain mandatory), to build the installers,
   update manifest, CycloneDX SBOM and third-party notices;
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
  and publication still requires the independent
  `FULCRUM_STABLE_RELEASE_APPROVED=true` gate. The unsigned-channel variable
  selects the distribution **signing posture**, not permission to publish;
  both approvals must be explicit for an unsigned stable release.
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

## 3b. Ubuntu 26.04 GNOME 50 Wayland release-quality gate (v0.14.1)

Issue [#111](https://github.com/turinglambdaai/fulcrum/issues/111)
reported that the stock GNOME 50 session rejects the global summon hotkey's
`GlobalShortcuts.CreateSession` with `An app id is required`. The v0.14.1
candidate registers the reverse-DNS `site.jrtx.fulcrum` app ID with the
host portal over a retained D-Bus peer and sets the matching installed
`site.jrtx.fulcrum.desktop` identity. A compiled fixture or nested Weston
acceptance run **does not** prove that GNOME 50's real portal consent and
shortcut activation work.

Before authorizing the v0.14.1 stable release, use an actual Ubuntu 26.04
GNOME 50 Wayland desktop (physical or a genuine GNOME VM, not just nested
Weston) to record the following for each Linux installer kind claimed as
supported. Keep exact artifact names, SHA-256, desktop ID and installed
version in the evidence. Do not silently substitute source builds.

For pre-release manual diagnosis on **Ubuntu x86_64**, download the
`fulcrum-0.14.1-gnome50-qa-UNSIGNED` artifact from the **Linux packaged
GTK4 acceptance** job attached to PR #104's latest **successful SHA**.
It contains a v0.14.1 DEB, AppImage, SHA256SUMS and an explicit QA-only
warning. Check the artifact's workflow commit SHA, then use
`sha256sum -c gnome50-qa-only-SHA256SUMS` before installation. These
are short-lived **development/unsigned test packages**, not a Github
Release and never part of the stable update feed. A successful test of a
QA package must still be reconciled with the eventual distribution build;
no signed-production, GNOME-permission or global hotkey conclusion follows
from artifact creation alone. Production release secrets are not used for
these QA packages.

After installing each exact candidate artifact on that desktop, run the
**environment preflight** from the release branch:

```bash
bash scripts/acceptance/gnome50-portal-preflight.sh --kind deb
bash scripts/acceptance/gnome50-portal-preflight.sh --kind appimage
```

Run the appropriate command separately for the actual installed DEB and
AppImage cases. Capture and redact its output before attaching it to #111.
Its exit status checks only the host OS/session, portal Registry interface,
installed desktop identity and, for DEB, package version. It **cannot**
assert that the running Fulcrum process registered successfully, obtained
GNOME consent or received an `Activated` signal. These remain operator
checks below. CI runs only the script syntax and a deliberately failing
non-Wayland guard test; that CI result is not GNOME 50 acceptance.

1. Capture `echo "$XDG_SESSION_TYPE"`, `gnome-shell --version`,
   `dpkg-query -W xdg-desktop-portal xdg-desktop-portal-gnome` (or the
   matching package-manager query), and the installed
   `site.jrtx.fulcrum.desktop` file's `Exec` and `Name` fields.
2. Install the candidate **DEB** and launch through GNOME Activities, then
   separately via `gtk-launch site.jrtx.fulcrum`. Verify that the portal
   consent dialog appears, approval succeeds, and the configured shortcut
   activates Fulcrum from another focused application repeatedly (summon,
   hide, summon). Record the actual `Registry.Register`,
   `CreateSession`, `BindShortcuts` and `Activated` outcomes, not only
   that the Settings UI renders.
3. Quit completely; test opt-in **Start at Login**, a logout/login round
   trip and shortcut activation without a visible startup launcher.
   Change the hotkey through native Settings and verify the new key and
   persisted consent after relaunch.
4. Reject portal consent, then verify the launcher keeps an actionable
   hotkey failure visible after backend readiness and that the documented
   desktop shortcut pointing at `fulcrum --toggle` really works. Restore
   the original desktop bindings and consent after the test.
5. Repeat the applicable checks for the **AppImage** installation form,
   distinguishing an integrated desktop-file install from an unintegrated
   portable copy. Record unsupported cases honestly in the release notes.

For debugging, `busctl --user monitor org.freedesktop.portal.Desktop` and
`journalctl --user -b -u xdg-desktop-portal.service` may help explain
identity and authorization failures. Portal bus traffic can contain data
from unrelated applications: capture locally, restrict file permissions,
review and redact before sharing; never auto-upload full logs.

**Decision:** Attach the real desktop results to #111 and the v0.14.1 PR.
If there is no passing GNOME 50 evidence, keep #111 open; do not mark it
fixed or claim global-hotkey parity. A release with the limitation is only
permissible if the release owner explicitly accepts that known defect and
publishes the exact unsupported scenario and documented fallback in the
release notes. CI success alone cannot make that decision.

## 4. Publish checklist

- [ ] Draft release notes link the changelog section.
- [ ] `manifest.json` verifies against the embedded **Ed25519 feed
      public key**; `raco rivet verify --production` is a separate
      platform-package/signature verification, not a manifest verifier.
- [ ] For a **production-signed release**, both macOS DMGs/installed apps
      pass Developer ID, Gatekeeper, notarization and stapling checks, and
      Windows MSI/EXE pass Authenticode verification. For an **explicitly
      approved unsigned release**, macOS ad-hoc and Windows unsigned status
      is disclosed in release notes and install guidance, not represented
      as production-signed. Both Linux tarballs keep verified detached
      Ed25519 signatures in either channel.
- [ ] Install the **actual release artifact** on a clean VM for each OS; run one
      search, one clipboard copy, one plugin query, one update check.
- [ ] In-app update check reports the new version on the previous release.
- [ ] Site pricing/download links still match reality.

## 5. Rollback

If a release must be pulled: publish a new patch version and point
`stable/manifest.json` at it (signed, with `rollback` metadata referencing
the pulled version). Never re-upload an artifact under an existing version
URL — hashes are pinned by the signed manifest.
