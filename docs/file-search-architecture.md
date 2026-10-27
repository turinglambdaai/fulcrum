# File search architecture

Status: implementation contract. This document distinguishes the current
incremental cache from the target full filename index; it is not a claim that
every stage below has shipped.

## Product contract

File search is a core launcher path, not a shell-command convenience. For one
million indexed paths on supported hardware, warm filename queries target
p50 below 20 ms and p95 below 50 ms. A rename/create/delete should become
visible within two seconds at p95. Superseded queries must stop work and must
never paint stale rows. An unavailable OS index, malformed cache, permission
denial, disconnected volume, or path encoding edge case must degrade to an
honest partial result rather than an exception in the UI.

The Racket backend owns query parsing, candidate fusion, ranking, persistence,
cancellation, scopes, ignores and result semantics. Native code may enumerate
platform records, subscribe to filesystem changes and open/reveal a selected
path. It must not grow a second ranking implementation in Swift, C# or C++.

Filename search is local by default. Content search is a separate, explicit
mode because it has different latency, privacy and indexing costs. Indexed
names and paths never enter Fulcrum sync or telemetry.

## Current slice (schema 4)

`file-index.sqlite3` is a rebuildable local B-tree of file names and paths.
The backend starts a cancellable background inventory at application boot of
Desktop, Documents and Downloads, plus OneDrive/iCloud/XDG equivalents when
present. Normal launcher queries of at least two characters read only the
bounded local SQLite filename/pinyin index, merge those matches with apps and
other suggestions, and do not spawn PowerShell or a slow filesystem walk on
every keystroke. The explicit `find <query>` command continues to ask the
platform index and its configured fallback for broader locations.
It writes bounded batches and tags every row with a root and generation; only
a successfully completed root scan prunes unseen paths, so cancellation or an
I/O failure cannot turn a partial scan into mass deletion. Dependency/cache
trees are excluded. Results returned by a platform search also seed the index.

Exact and filename-prefix queries are merged with fresh platform candidates
and ranked by the common Racket ranker. Cached candidates rescue a query when
the platform process times out or its tool is temporarily unavailable. The
catalog is rescanned once per process after its first file query; host-native
change streams are not wired yet.

Schema 4 adds a sparse pinyin term table for Chinese basenames. Tone-free full
pinyin and initials are generated offline from a pinned MIT-licensed dataset;
literal name/stem/prefix matches retain the larger ranking bonuses. Only names
containing mapped Han characters add rows, so ordinary Latin-only indexes do
not pay a two-terms-per-file storage tax.

The checked-in benchmark generates one million synthetic paths in the OS temp
directory. On the 2026-10-26 Windows development machine, schema 3 measured:

- initial insertion: 163.0 seconds;
- database size: 188.6 MiB;
- 500 warm prefix queries (including one- and two-character prefixes):
  p50 4.586 ms, p95 8.752 ms, max 11.948 ms.

The query SLO passes. Initial build time, disk size, substring recall and live
filesystem coverage do not yet meet the final product contract. Run the same
workload with `racket scripts/benchmark-file-index.rkt`; smaller diagnostic
runs accept `--entries` and `--queries`.

The issue #95 mixed-language workload uses 100,000 synthetic paths with 20%
Chinese basenames and 300 full-pinyin/initial/literal queries. On the same
Windows development machine, schema 4 measured 12.9 seconds to ingest, 43.0
MiB on disk, p50 3.672 ms, p95 5.467 ms and max 6.279 ms. Reproduce it with
`racket scripts/benchmark-pinyin-index.rkt`.

## Target index

The next storage format is a crash-safe collection of immutable segments:

1. A compact path table interns directory prefixes and stores display name,
   stable platform identity, volume identity, type, modification time and a
   monotonic generation.
2. A case-folded basename table is sorted for exact and prefix range lookup.
3. Trigram postings are delta-encoded and block-compressed for infix recall.
   Very short queries use prefix ranges; fuzzy fallback has a strict candidate
   and time budget.
4. A small mutable journal receives creates, renames and deletes immediately.
   Background compaction merges it into immutable segments. A checksummed
   manifest is atomically replaced only after all new segments are durable.
5. Ranking consumes a bounded candidate set and combines exact/stem/prefix/
   substring/fuzzy quality, path depth, recency, user selection history,
   active scope and generated-directory penalties. Tie-breaking is stable.

This removes a subprocess from the warm query path while preserving OS search
as a content-search and recovery source. The target budgets at one million
paths are: less than 150 MiB on disk, less than 80 MiB steady-state RAM, and a
useful progressive result before a first scan completes.

## Platform ingestion

### Windows

- Initial inventory: use NTFS volume records/USN journal where available for
  fast enumeration, with a permission-safe directory walker for unsupported
  filesystems and user-selected network/removable roots.
- Changes: persist the journal cursor and replay USN records after restart;
  fall back to `ReadDirectoryChangesW` for roots without a journal and perform
  periodic reconciliation after overflow or volume identity changes.
- Secondary source: query Windows Search through its documented
  `ISearchQueryHelper`/`SYSTEMINDEX` interface for content and recovery. The
  PowerShell/OLE DB path remains a compatibility fallback, not the warm path.
- Paths: preserve display spelling, normalize separators only for matching,
  retain volume identity, and handle drive, UNC and long-path forms.

### macOS

- Initial inventory: enumerate allowed roots progressively; do not block app
  startup or require Full Disk Access for ordinary use.
- Changes: consume FSEvents with persisted event IDs, mark roots dirty on
  dropped/coalesced events, then reconcile only those roots.
- Secondary source: use `NSMetadataQuery`/Spotlight for content, tags and
  recovery candidates. Spotlight availability must not determine whether the
  local filename index can answer.
- Respect privacy/TCC exclusions and surface a scoped explanation rather than
  repeatedly prompting for broader access.

### Linux

- Initial inventory: walk configured roots with `.gitignore`-style ignore
  rules and filesystem-boundary controls. Import `plocate` candidates when
  present to accelerate a cold start, but never require it.
- Changes: use inotify for selected directory trees, detect queue overflow and
  watch-limit exhaustion, then reconcile. Large/unwatchable roots use bounded
  periodic scans; mounts and network shares are explicit scopes.
- Secondary source: `plocate` is filename-only; Recoll can be an optional
  content provider. Neither defines Fulcrum ranking or result semantics.

## Open-source lessons and licensing boundary

- [FSearch](https://github.com/cboxdoerfer/fsearch): instant-as-you-type UX,
  explicit include/exclude scopes, filters and sortable results.
- [plocate](https://plocate.sesse.net/): compact posting lists and an index
  shaped for query-time work rather than repeated tree walks.
- [ripgrep's guide](https://github.com/BurntSushi/ripgrep/blob/master/GUIDE.md):
  predictable ignore precedence, hidden-file behavior and filesystem walking.
- [Recoll](https://recoll.org/usermanual/usermanual.html): keep filename and
  content indexing as separate cost/privacy modes, with incremental updates
  and bounded batch reconciliation.
- [Flow Launcher Explorer](https://github.com/Flow-Launcher/docs/blob/main/plugin-explorer.md):
  users need a clear choice of scopes/providers and graceful Windows Search
  versus Everything-style availability.

These are behavioral and data-structure references, not code dependencies.
GPL implementations such as FSearch, plocate and Recoll are not copied into
Fulcrum's BUSL/MIT codebase. Any future library adoption needs an explicit
license and packaging review first.

## Acceptance gates

Every index-format change ships with deterministic fixtures for Unicode,
case folding, Windows/POSIX/UNC paths, spaces, duplicate names, inaccessible
directories, symlink cycles, volume removal, journal overflow, corruption and
schema migration. Benchmarks report build time, disk and RAM, cold/warm p50,
p95 and max latency, mutation visibility, cancellation latency and result
recall against a brute-force oracle.

The product gate still requires backend/wire tests plus native build, package
and accessibility E2E on Windows, macOS and Linux. Passing a storage benchmark
or source review is not native runtime proof.
