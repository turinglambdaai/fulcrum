# The Fulcrum Plugin Registry (`fulcrum-gallery`) — Design Draft

**Status: draft.** The public plugin registry, built entirely on GitHub
— no servers, no accounts, no cost. The pattern is deliberate: it is the
Raycast model (`raycast/extensions` is a GitHub repo; submissions are
PRs) running on infrastructure this family already operates for app
updates (signed manifests served from GitHub Releases).

**Status of scope:** curated, human-reviewed, free plugins. The paid
store with revenue share stays gated per [docs/business.md](business.md)
§7 and needs billing rails — that is the one thing GitHub cannot host.

## Principles

1. **Zero servers.** Everything is a public GitHub repo: code, index,
   artifacts, and the submission pipeline. Free tier covers it (public
   repos get unlimited Actions minutes; plugin zips are tens of KB
   against a 2 GB per-file ceiling).
2. **Same trust pattern as app updates.** The index is an Ed25519-signed
   artifact served from `releases/latest/download/` — the exact path the
   updater already uses (GitHub 302 → objects CDN). Transport is GitHub's
   problem; integrity is ours.
3. **The embedded gallery stays.** The twenty-six first-party plugins
   remain built into the app (`gen-gallery.rkt`). That is the offline baseline,
   the fresh-install experience, and the trust anchor: a plugin source
   review always has a canonical copy.
4. **Curated means curated.** No self-publishing, no accounts — a PR and
   a human review. This is a feature at this stage: the review bar is
   the ecosystem's quality and safety story until automated enforcement
   exists (FPP2 staged permissions, [docs/fpp2.md](fpp2.md)).

## Repository layout (`turinglambdaai/fulcrum-gallery`)

```text
fulcrum-gallery/
├── plugins/
│   └── <id>/                 # one directory per plugin, FPP layout
│       ├── manifest.json     # "protocol": 1 or 2
│       └── …                 # source files, LICENSE
├── scripts/
│   ├── build-index.rkt       # plugins/ → index.json (the only writer)
│   └── validate-plugin.rkt   # the CI gate, also runnable locally
├── index.json                # GENERATED — never hand-edited
└── .github/workflows/
    ├── validate.yml          # on every PR
    └── publish.yml           # on merge to main
```

Plugin sources live **in the registry repo** (not fork-external), so the
reviewed artifact and the reviewed source are one commit. Authors may
mirror elsewhere; `source` in the index points at their upstream.

## The index

`index.json` is generated from `plugins/` and attached, signed, to a
release. The client never parses anything humans edit.

```json
{
  "schema": "fulcrum-gallery-index/1",
  "generated-at": "2026-10-12T03:00:00Z",
  "revision": 42,
  "plugins": [
    {
      "id": "epoch",
      "name": "Epoch",
      "version": "1.2.0",
      "description": "Unix timestamp ↔ date conversions",
      "author": "turinglambdaai",
      "category": "Developer",
      "icon": "plugin",
      "protocol": 1,
      "permissions": [],
      "min-app-version": "0.8.0",
      "homepage": "https://github.com/turinglambdaai/fulcrum-gallery/tree/main/plugins/epoch",
      "changelog": "https://github.com/turinglambdaai/fulcrum-gallery/blob/main/plugins/epoch/CHANGELOG.md",
      "artifact": {
        "url": "https://github.com/turinglambdaai/fulcrum-gallery/releases/download/g-2026-10-12/epoch-1.2.0.zip",
        "sha256": "…",
        "size-bytes": 8123
      }
    }
  ]
}
```

| Field | Notes |
|---|---|
| `schema` | Index format version. A breaking change bumps it and the client keeps parsing the old one for one transition release. |
| `revision` | Monotonic; lets the client short-circuit "nothing changed". |
| `id` | Must match the manifest's `id` exactly, `^[a-z0-9][a-z0-9-]*$` (the client's path-traversal rule — the registry does not get to weaken it). |
| `protocol` | 1 or 2. The client hides `detail`/`preferences` affordances for protocol-1 plugins. |
| `min-app-version` | SemVer floor; the client hides entries its version cannot run instead of installing something that half-works. |
| `artifact.sha256` | Over the zip bytes. The client verifies before staging — same discipline as update artifacts. |
| `permissions` | Copied from the manifest; shown at install; advisory (FPP2 staged enforcement). |

## Trust and signing

- **Separate key from app updates** (`fulcrum-gallery-<date>`): a
  compromised registry key must not be able to sign app update
  manifests, and vice versa. Public key embedded in the client; private
  key in Sync/Keys + the GitHub secret, same triple as every product.
- The publish job computes `index.json`, signs the exact bytes with
  detached Ed25519, and attaches both `index.json` and
  `index.json.sig`. The client verifies before parsing plugin entries.
- Rotation follows the family's update-key practice: new key gets its
  own release note; the client carries the current key one release
  before the registry switches.

## Publishing flow

`publish.yml` on merge to main:

1. `build-index.rkt` regenerates `index.json` from `plugins/` (CI fails
   on drift — the same freshness discipline as the embedded gallery).
2. Each changed plugin is zipped (deterministic: fixed timestamps, LF
   endings), sha256 recorded.
3. Index is signed; a release tagged `g-<UTC-date>` (or `g-<date>-2`
   same-day) is created with `index.json`, `index.json.sig`, and every
   current plugin zip attached.
4. The `stable` tag is force-moved to that release, so
   `releases/latest/download/index.json` always resolves to the current
   signed index — the updater's URL pattern, reused verbatim.

## Client behavior

One new surface in the launcher, built from parts that already exist:

- **Fetch cadence:** at most once per 24 h, throttled backend-side via a
  `registry-last-check` settings key (the `update-last-check` pattern).
  Manual refresh: query `plugins`, run the "Refresh the plugin
  registry" row.
- **Pipeline:** fetch `index.json` over HTTPS → verify Ed25519 →
  per-plugin version compare against installed → download changed
  artifacts → verify sha256 → stage into the plugins directory through
  the existing atomic staging path → `plugin-manager-reload!`. Installed
  registry plugins get the `.fulcrum-gallery` marker variant
  (`.fulcrum-registry`), so provenance is visible and uninstall rules
  stay strict.
- **Rows, not silos:** registry results render as ordinary gallery rows
  (the "Install <name>" / "Update <name> → v<new>" rows the launcher
  already has), so the three hosts need zero new UI. The embedded
  catalog and the registry merge into one list, embedded rows first.
- **Failure is honest and bounded:** unreachable index, bad signature,
  or a failed hash = a status line, never a partial install. Offline,
  the embedded catalog still lists and installs everything first-party.
- **No GitHub API.** Raw/release-redirect URLs only — anonymous API
  limits (60/h) are irrelevant at one fetch per day, and the objects CDN
  path is the one the mainland-tested updater already uses.

## Submission pipeline

A PR adding `plugins/<id>/` runs `validate.yml`:

1. Manifest schema (FPP1/FPP2 by declared protocol), id regex, ≤ 32
   commands, ≤ 64 KiB manifest, preferences schema well-formed.
2. FPP smoke: the plugin's first command answers a real `query` within
   the default timeout with well-formed JSON (the CI fixture pattern the
   app repo already runs).
3. `build-index.rkt --check` — the author's hand-added index entry (if
   any) matches what the generator would produce.
4. License: an OSI-compatible LICENSE in the plugin directory (plugins
   are the author's code; the registry only requires the right to
   redistribute, which the index's download link exercises).
5. Permission sanity for protocol-2 manifests: observed `network:` /
   `exec:` use in a smoke run must be a subset of the declaration
   (best-effort, platform-dependent — the review-tooling stage of the
   FPP2 permissions ladder).

A maintainer reviews the source (the actual safety mechanism) and
merges; `publish.yml` does everything else. The PR template carries the
checklist so review starts from "verified", not "what is this".

## What this deliberately does not do

- **No accounts, no self-publish, no analytics, no download counts**
  (clone counts exist if ever wanted; nothing user-facing depends on
  them).
- **No update push.** The client polls on its 24 h throttle; there is no
  notification channel from GitHub to installed apps, and we do not want
  one.
- **No paid distribution.** Business-plan gated; needs billing rails and
  the enforcement ladder completed first.
- **No hosting of secrets or tokens.** Plugins that need credentials use
  FPP2 preferences (`secret` type, local-only, never synced) — the
  registry never touches user credentials.
