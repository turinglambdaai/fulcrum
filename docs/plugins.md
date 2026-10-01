# Fulcrum Plugin Protocol v1 (FPP1)

A Fulcrum plugin is an external process. The backend spawns it per request,
speaks one JSON object per line over stdin/stdout, and kills it after each
call. The process boundary is the isolation story: a hung plugin costs its
own timeout (default 2000 ms, configurable), never the launcher.

Any language that can read stdin, write stdout, and parse JSON can be a
plugin: Python, Go, Rust, Node, a shell script. See
[`gallery/epoch`](../gallery/epoch) for a complete,
tested reference plugin.

## The first-party gallery

Fulcrum ships ten first-party plugins built into the app — query
`gallery` or `plugins` in the launcher to list them; select a row to
install, select an installed row to uninstall. Fuzzy queries also suggest
installs (type `docker` and the install row appears next to your apps).
Installed plugins are queryable immediately, no restart.

| Plugin | Keyword | Needs |
|---|---|---|
| Epoch | `ts` | — |
| Unit Converter | `u` | — |
| Regex | `re` | — |
| Timezone | `tz` | — |
| GitHub | `gh` | network (optional `GITHUB_TOKEN`) |
| Cargo | `crate` | network |
| Homebrew | `brew` | network |
| Docker | `dk` | the `docker` CLI |
| winget | `winget` | Windows |
| Bitwarden | `bw` | the `bw` CLI, unlocked (`BW_SESSION`) |

Every plugin is also a second reference implementation — read
[`gallery/unit/unit.py`](../gallery/unit/unit.py) for the graceful
availability-probe pattern, or
[`gallery/github/github.py`](../gallery/github/github.py) for the
network + open-URL pattern. Their sources live in the repository
[`gallery/`](../gallery) directory; the backend embeds them at build time
via `scripts/gen-gallery.rkt` (CI regenerates the embedded data and fails
on drift).

The gallery can only uninstall plugins it installed: each install writes
a `.fulcrum-gallery` marker, and uninstalling a directory without one is
refused.

## Layout

A plugin is a directory under Fulcrum's plugins directory
(`FULCRUM_DATA_DIR/plugins`; open it from Settings → Plugins):

```text
epoch/
├── manifest.json     # required
├── epoch.py          # the entry named in the manifest
└── (anything else your plugin needs)
```

## manifest.json

```json
{
  "id": "epoch",
  "name": "Epoch",
  "version": "1.0.0",
  "description": "Unix timestamp ↔ date conversions",
  "icon": "plugin",
  "entry": {"exec": ["python3", "epoch.py"]},
  "commands": [
    {"id": "convert", "name": "Convert timestamp", "keyword": "ts"}
  ],
  "permissions": []
}
```

| Field | Required | Meaning |
|---|---|---|
| `id` | yes | Stable identifier, unique, no colons. Never change it after release. |
| `name` | yes | Display name in Settings. |
| `version` | no | SemVer string shown in Settings. |
| `description` | no | One-line description. |
| `icon` | no | Icon hint for hosts (`"plugin"` by default). |
| `entry.exec` | yes | argv array. Relative paths resolve against the plugin directory; a bare program name is looked up on `PATH`. |
| `commands` | yes (≤32) | The commands this plugin exposes. |
| `permissions` | no | Advisory metadata in v1. Not enforced yet — the README and this doc both say so; do not treat it as a sandbox. |

### Command keywords

A command with a `keyword` claims queries of the form `<keyword> …` or
exactly `<keyword>`. A command without a keyword participates in every
query, so it must be cheap and highly relevant — prefer keywords.

## Wire protocol

One JSON object per line, UTF-8. Unknown fields are ignored; unknown ops
must produce an error response, never a crash.

### Query

```text
→ {"op":"query","command":"convert","query":"1700000000","request_id":1}
← {"request_id":1,"results":[
     {"title":"2023-11-14 23:13:20 UTC",
      "subtitle":"1700000000 → UTC",
      "arg":"1700000000",
      "icon":"plugin"}]}
```

- `query` is the text after the keyword (may be empty).
- Return at most 10 results; the backend truncates.
- `title` is required per result; `subtitle`, `arg`, and `icon` default to `""`.
- `arg` is the opaque payload handed back verbatim in the Run request.

### Run

Sent when the user activates a row.

```text
→ {"op":"run","command":"convert","arg":"1700000000","request_id":2}
← {"request_id":2,"status":"ok"}
```

`status` is `"ok"` or `"error"` (with an optional `message`). The row's
`arg` is whatever the plugin returned in Query.

## Rules the backend enforces

- Manifests must be JSON objects ≤ 64 KiB with ≤ 32 commands.
- Every query/run spawns a fresh process; there is no warm lifecycle in v1.
- A process that misses the timeout is killed; its query contributes no rows.
- Invalid JSON, a non-object response, or a crash surface in
  Settings → Plugins as load/run errors, never as launcher failures.

## Versioning

`FPP1` is frozen. Backwards-compatible additions may extend responses with
new fields; breaking changes become `FPP2` with a long overlap window. The
protocol spec (this file) and the plugin SDK are MIT-licensed — plugins are
your code, and the protocol is open even though the Fulcrum core is not
(see LICENSE).
