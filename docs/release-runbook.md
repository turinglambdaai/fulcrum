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

All release identity lives in `rivet.rktd`: bump `version` (SemVer) and
`build` (integer, never reuse per platform). Update `CHANGELOG.md` with a
section named exactly after the new version — the tag validator rejects a
tag whose version has no matching changelog section.

For the developer preview on the `main` branch this is enough; production
steps continue below.

## 2. Update key embedding (release builds only)

`app/update.rkt` carries `current-update-public-key-hex`. For release
builds, replace it with the hex of `update-public.der`:

```bash
openssl pkey -inform DER -in update-public.der -outform DER -out /dev/null 2>/dev/null
xxd -p update-public.der | tr -d '\n'   # → current-update-public-key-hex
```

Set `current-update-key-id` to the same key id used when signing the
manifest (e.g. `release-2026`). Developer builds keep `#f` — update checks
then honestly report "developer build" instead of pretending.

Key rotation: generate a new pair, ship a client trusting the **next**
public key first, then sign releases exclusively with it. The `key_id`
field is what makes the overlap safe.

## 3. Tagged pipeline

```bash
git tag -s v0.1.0 -m "Fulcrum 0.1.0"
git push origin v0.1.0
```

`.github/workflows/release.yml` then, per platform matrix:

1. validates the tag against `rivet.rktd` and the changelog;
2. `raco rivet build` + `raco rivet package --production` (platform
   signing from secrets);
3. `raco rivet release` — installer (DMG / MSI), Ed25519-signed update
   manifest, CycloneDX SBOM, third-party notices;
4. uploads artifacts to the draft GitHub release, including the
   `manifest.json` signed channel manifest; the app fetches it from
   `RIVET_UPDATE_BASE_URL` (default
   `https://github.com/turinglambdaai/fulcrum/releases/latest/download`),
   so publishing the draft puts the update feed live.

Required secrets: `MACOS_CERTIFICATE_P12`, `MACOS_CERTIFICATE_PASSWORD`,
`MACOS_NOTARY_PROFILE`, `APPLE_ID`/`APPLE_TEAM_ID` (notarytool),
`WINDOWS_CERTIFICATE_PFX`, `WINDOWS_CERTIFICATE_PASSWORD`,
`RIVET_UPDATE_PRIVATE_KEY` (the DER file, PEM-wrapped), `RIVET_UPDATE_KEY_ID`,
`RIVET_UPDATE_BASE_URL`.

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
