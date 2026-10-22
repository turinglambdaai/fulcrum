# MCP — Fulcrum's side of the fence (design note)

**Status: decision recorded + spike proven.** This note answers #55: which
side of the MCP fence Fulcrum stands on, in what order, and why. The
hello-world spike lives in [`scripts/mcp/`](../scripts/mcp/) and runs
end-to-end against the real embedded backend.

## The decision, in one paragraph

Fulcrum does **both, in this order**: first **Fulcrum as an MCP server**
(the differentiated side — Fulcrum becomes the local action layer that
external agents drive), then **Fulcrum as an MCP client** (the Raycast-shaped
side — third-party MCP tools surface inside the launcher), and the client
direction is explicitly gated on FPP2's permission ladder reaching proxy
enforcement. Neither direction ships user data anywhere: both speak stdio to
local processes only, consistent with the no-cloud contract.

## Why this order

- **The server direction is ours to define.** A launcher is where intent
  lives — the thing an agent needs to *act*. Making Fulcrum the MCP server
  lets an IDE agent, a CLI agent, or another machine's agent ask "what's in
  the clipboard", "find the receipts PDF", "convert 100 usd to eur" through
  the same Racket brain the native UIs use. That is a category position, not
  a feature.
- **The server direction is the lower risk.** The tools Fulcrum exposes are
  first-party, reviewed here, and gated by code we own. The client direction
  ingests *third-party tool output* — untrusted text flowing into an AI
  surface that can take actions. That is exactly the threat the FPP2 staged
  permission ladder ([docs/fpp2.md](fpp2.md)) is being built for, and it
  should land after that ladder enforces, not before.
- **Architecturally they are the same seam.** An MCP server is a daemon-mode
  plugin with a different wire dialect. The lifecycle (spawn, health,
  timeout, crash isolation) and the permission model should be the FPP2
  machinery, reused — not a parallel stack.

## What the spike proves

`scripts/mcp/spike-server.rkt` is a stdio MCP server that embeds the same
backend module the native hosts embed (the wire-test initialization order:
settings manager → stores → engine → index rebuild), speaks newline-framed
JSON-RPC 2.0, and exposes exactly two **read-only** tools:

- `fulcrum_search` — one ranked search over the launcher engine (apps,
  clipboard, snippets, quicklinks, calculator, inline conversions);
- `fulcrum_clipboard_history` — the on-device clipboard history, optionally
  filtered.

`scripts/mcp/spike-demo.rkt` spawns the server as a real subprocess and
drives initialize → tools/list → tools/call end-to-end, asserting the
product's own acceptance scenario (`12*12` → `144`), an honest empty-history
answer, and that an unknown/action-shaped tool name fails closed as an MCP
tool error rather than reaching any action RPC. It passed on macOS (2026-10-22);
the server is platform-neutral Racket — the same file runs wherever `racket`
runs.

## Threat model

**Prompt injection via tool results.** Any tool output is untrusted text.
The spike's defense is structural: external agents get read-only tools, and
the AI surface renders answers as rows a human explicitly selects. The rule
for every future write path: *tool-derived text is data, never an action
selection*. No auto-chaining from a tool result to `run-action` — an agent
may propose, only the user disposes (the same grammar as the ⌘K panel).

**Local malware driving the server.** stdio MCP has no authentication: any
local process can spawn the shim. We say this honestly. The v1 surface is
read-only, which exposes nothing the spawning process could not read anyway
(same user, same machine, same files). When action tools arrive, they arrive
behind an explicit, off-by-default Fulcrum setting ("Allow external agents
to run actions") plus a per-tool grant list — and the settings page names the
residual risk.

**Key exposure.** BYOK AI keys (`ai-keys.json`) are local-only secrets and
are never exposed through MCP: the shim never reads the keys file, and no
tool returns anything the AI provider sent. Plugin secrets
(`plugin-secrets.json`) are likewise outside the MCP surface.

**Data minimization.** Tools return rows (title/subtitle/kind), not raw
store dumps; clipboard rows are truncated previews exactly like the ones the
native panel shows. The full text of a row is available only via a future,
explicitly-granted `fulcrum_get_row` — not in v1.

## Relation to FPP2

- **Client direction = daemon-mode plugin.** A configured MCP server becomes
  an FPP2 plugin whose manifest declares `"transport": "mcp"`; the daemon
  supervisor owns lifecycle; each MCP tool surfaces as a command row; each
  tool declaration maps onto the permission ladder (`network:`-style scopes,
  displayed at install, enforced when the proxy stage lands). Nothing in
  FPP1/FPP2 changes meaning.
- **Server direction = the backend behind a dialect shim.** The spike is the
  production shape: MCP stdio in, RVT1 calls against the embedded backend —
  no business logic outside `app/`. Productizing means shipping the shim in
  the app bundle, a settings page (enable + tool allowlist), and reading the
  data dir of the *installed* app.

## Roadmap

1. **v1 (read-only server)** — productize the spike as `fulcrum-mcp`:
   shipped shim, settings toggle, the two tools above, docs. No action RPC
   reachable.
2. **v2 (action server)** — `fulcrum_run` behind the off-by-default grant +
   per-tool allowlist + a user-confirmation badge on every agent-initiated
   action; audit log of agent-initiated runs.
3. **v3 (client)** — MCP servers as FPP2 plugins, gated on the FPP2 proxy
   enforcement stage; the `ai` surface may compose MCP tools, with the same
   "propose, don't dispose" grammar.

## What would change this decision

- If MCP consolidates on a remote/managed transport with real auth earlier
  than expected, the client direction's risk drops and can move up.
- If the registry work ([docs/registry.md](registry.md)) lands with a
  security story stronger than the FPP2 ladder, revisit the v3 gate.
