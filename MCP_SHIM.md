# cckit MCP Shim

This repository now contains a local MCP shim at `mcp/cckit_mcp.py`.

The shim is a separate integration artifact, not part of the Kotlin parser/indexer implementation. It wraps the local `cckit` binary and exposes useful commands to Claude Code over stdio.

## Goal

Provide a small local Python MCP server that wraps the local `cckit` binary and exposes useful `cckit` commands to Claude Code over stdio.

The shim should:

- live in this repository under `mcp/cckit_mcp.py`;
- run locally through `uv run --script`;
- use the official Python `mcp` package;
- call the local `cckit` binary through `subprocess.run`;
- return structured JSON-like dictionaries to the MCP caller;
- avoid packaging, publishing, or multi-user installation work for v1.

## Non-Goals

The shim should not:

- wrap `cckit serve`;
- wrap benchmark or long-running interactive commands;
- auto-edit project files;
- introduce a separate package layout;
- become part of the Kotlin parser/indexer implementation;
- depend on a separate Kotlin skill or adoption package.

## File Layout

```text
CodeContextKit/
└── mcp/
    └── cckit_mcp.py
```

No `pyproject.toml` is required for the initial version. Use a PEP-723 inline dependency header.

## Script Header

```python
#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["mcp>=1.0"]
# ///
```

## Claude Code Registration

Preferred local registration:

```bash
CCKIT_ROOT="$(pwd)"
claude mcp add cckit --scope local \
  --env CCKIT_BIN="$CCKIT_ROOT/.build/release/cckit" \
  -- uv run --script "$CCKIT_ROOT/mcp/cckit_mcp.py"
```

Equivalent local config:

```json
{
  "mcpServers": {
    "cckit": {
      "type": "stdio",
      "command": "uv",
      "args": [
        "run",
        "--script",
        "${CCKIT_ROOT}/mcp/cckit_mcp.py"
      ],
      "env": {
        "CCKIT_BIN": "${CCKIT_ROOT}/.build/release/cckit"
      }
    }
  }
}
```

Use absolute paths. Claude Code may launch the MCP server from a different working directory.

## Agent Discovery (critical)

Agents route from **server instructions** and **tool descriptions**. Copy must stay lean (those strings sit in the agent prompt) while still winning against Grep/Read/Glob.

Tone:

- Prefer these tools for relevance/token savings; never forbid built-ins.
- `gather_code_context` is the starting retrieval for a symptom, a change, more than one file, or a failure log — even when names are visible (those names go in `task`). Treat the packet as starting context. Prefer gather over Grep/Read for source on the first retrieval. `symbol` for one known body; `find_symbol` after gather, or when you only need a qualified name, not a packet.
- Content tools (`gather_code_context`, `symbol`, `outline`) read disk; locators (`find_symbol`, `find_references`) use the last index. A dirty worktree does not retire these tools. MCP auto-refreshes HEAD drift and dirty indexable files.
- After a gather or locator hit, do not Grep that name. If you lack the next name, outline the file. Huge ranges: narrow Read, not symbol of the whole type.
- On a locator miss, MCP indexes once and retries internally — do not ask the agent to call `index`. A miss that still fails attaches outlines of dirty files when it can; otherwise outline those files. Grep/Read remain appropriate for non-indexable files (markdown, project files, logs) and string literals. For source symbols, Grep only if outline lacks the name, then return to `symbol()`; do not Grep a committed symbol because some other file is dirty. `find_references` wants a symbol name, not a string.
- `find_symbol` prints line ranges only for huge hits. Named-identifier gather misses (real CamelCase / qualified names absent from the packet) return a short miss (no filler packet). Title-case English is not an identifier. Gather misses invite retrying gather with prose; locator misses invite outline/symbol. Successful locator responses do not append a `Next:` footer — server instructions already steer. `symbol()` returns bodies only (call sites stay on `find_references`).
- Do not brand CodeContextKit/cckit to the user; work under the hood.
- Avoid force words (`REQUIRED`, `DO NOT`, `PRIMARY`, `must`), except the dirty-tree anti-pattern above.
- Expose pack as `gather_code_context`; CLI remains `cckit pack`.
- Keep `index` last.
- Pass `repo=` when unsure (document on every tool).
- Ideal MCP v1 surface: `find_symbol`, `find_references`, `gather_code_context`, `symbol`, `outline`, `map`, `index`.
  Omit `search`, `estimate`, `summarize`, `explain` from MCP (CLI still has them).
- Responses omit freshness when the index is current; `stale: true` only when not.

The shim must keep:

1. `FastMCP("cckit", instructions=...)` — gather_code_context for task-shaped work (symptom, change, multi-file, failure log) even when names are visible; find_symbol after gather or for a qualified name only; symbol for one known body; freshness free; dirty tree does not retire these tools; auto-refresh on HEAD drift and dirty indexable hash mismatches; miss-time force-index + single retry (no agent `index` call); occupancy rule (after a gather or locator hit, do not Grep that name; outline when unnamed; huge ranges → narrow Read); miss attaches dirty-file outlines; Grep stays valid for strings/docs/logs.
2. Lean `@server.tool(title=..., description=...)` — capability, cost anchors where useful, `no_index` / `stale` → `index`.
3. Short `Field(description=...)` on parameters — agents often choose args from schema text.
4. `gather_code_context` schema: `task`, `repo`, `budget`, `failure`, `mode` only.

Pin the script dependency to `mcp>=1.0,<2` (mcp 2.x removed FastMCP).

## Tool Surface

Ideal MCP v1 (keep small):

| MCP tool | Wraps | Notes |
|---|---|---|
| `find_symbol` | `cckit find-symbol` | Name lookup after gather, or when you only need a qualified name, not a packet. Zero-hit queries retry normalized variants (snake_case ↔ CamelCase). A single exact hit ≤40 lines returns its body inline as `inlinedBody`. |
| `find_references` | `cckit find-references` | Indexed call sites. Batch via `names=[...]` (single-name JSON shape unchanged). Resolution ladder: exact → variants → names-containing (labeled Approximate) → did-you-mean candidates. Rejects non-symbol strings. Returns `truncated` + `totalCount`. |
| `gather_code_context` | `cckit pack` | Budgeted source packet for a symptom, change, multi-file task, or failure log. Names in `task` help matching. Identifier miss → short miss, not a filler packet. Prose-only tasks (no identifiers ⇒ all matches are Wax guesses) are tagged `semanticGuessOnly` with an attached candidate block. Zero primaries from a degraded semantic path are tagged `semanticUnavailable` (never mistake a fault for a true absence). |
| `symbol` | `cckit symbol --json` | Exact qualified **body**. Batch names after `find_symbol`, or for a name a gather packet did not include. Bodies unchanged since earlier this session return as one-line stubs (`refresh=true` forces full). |
| `outline` | `cckit outline` | Structural skeleton before full-file reads (metadata only). Identical re-deliveries stub like `symbol` (`refresh=true` bypasses). |
| `map` | `cckit map` | Names-only repo map; prefer gather when you need source. Skip if the gather packet already included a repository map. |
| `search_text` | `rg` / in-process scan | Budgeted literal text search over the working tree: capped hits, per-file grouped ranges, one preview per file, honors .gitignore (ripgrep path) and skips junk dirs. Use instead of raw Grep so output stays bounded; regex/case/glob params available. |
| `index` | `cckit index .` | Last. Usually unnecessary — MCP auto-refreshes on HEAD drift / dirty files, auto-compacts leaked Wax vectors, and retries once on locator miss (`CCKIT_REFRESH=auto`). |

Responses omit freshness when the index is current; `stale: true` appears only when it is not. MCP flattens CLI JSON fields to the top level (not nested under `data`). Set `CCKIT_REFRESH=never` to disable auto-reindex. `CCKIT_CALLER=mcp` is set on subprocesses so `pack-stats` can separate agent traffic from shell runs.

### Degraded-arena contract

An arena that opens is not proof it is serviceable. Reads surface evidence instead of serving silent confident negatives:

- `waxBreachMarker` — attached to every shim response when `wax-breach-marker.json` is armed (the CLI's bloat veto refused this arena). Carries `allocatedBytes` / `expectedLiveBytes` / `reclaimableBytes` and the `--clean` remediation.
- `breachWarning` / `semanticUnavailable` (`gather_code_context`) — the CLI tags a zero-primary packet that DID consult Wax against a populated index as a likely retrieval fault; both ride the `PACK_STATS` line into the payload and a visible `Warning:` note in the packet text.
- Hard faults (exit non-zero) — `pack` and vector `search` refuse a **truncated arena** (materialized bytes far below the last known-complete stamp), a **silent-empty arena** (0 frames against a populated keep-set), or an **interrupted rebuild** (indexed files with no Wax coverage row). Lexical `search` answers from SQLite but carries `arenaFault` / `breachWarning` in its JSON. Remediation for all three is `cckit index .`.

Small semantic deltas (few changed files, arena inside its allocation band) now index incrementally: changed files append fresh documents, the arena is retained, and stale twins leak only until the next rebuild (`WaxDeltaPolicy`, `CCKIT_WAX_DELTA_MAX_FILES` / `CCKIT_WAX_DELTA_MAX_GROWTH`). This makes the partial-arena window rare — but every window is still gated as above.

### Miss behavior

On any locator miss (`find_symbol`, `find_references`, `symbol`, `gather`), the shim retries once after a forced incremental index (dirty files), then returns a short miss response containing: ranked dirty-file outlines (only files lexically related to the query), plus a **Nearest indexed symbols** block of up to 5 Wax semantic candidates (names + `path:lines`, ~15 tokens each). Grep is the last resort, not the default.

### Session dedup ledger

The shim fingerprints delivered content per session (LRU 512): `symbol` bodies, gather primary bodies (≥200 chars), and whole outlines. Identical re-deliveries come back as one-line stubs with the prior token estimate; changed content always delivers in full and updates the fingerprint. State persists to `.cckit/delivery_ledger.json` (survives shim self-reload/reconnect) and savings append to `.cckit/dedup_savings.jsonl`, which `cckit pack-stats` reports under "Dedup savings". Opt out with `CCKIT_DEDUP=off`; per-call `refresh=true` forces full delivery.

Omit from MCP (still available via CLI):

- `estimate`
- `summarize`
- `explain`
- `serve`
- `benchmark-serve`
- `history-benchmark`

(`search` remains CLI-first; its forced-vector mode powers the shim's candidate blocks.)

## Repo Resolution

Every tool should accept an explicit `repo` argument.

Resolution order:

1. Tool call `repo` argument.
2. Optional `CCKIT_REPO` environment variable.
3. MCP server launch cwd as a last resort.

The recommended path is to always pass `repo`. Do not set `CCKIT_REPO` globally
in a Cursor MCP config shared across workspaces — every other project then
searches the wrong tree unless each tool call passes `repo=`.

## Subprocess Wrapper

The implemented wrapper resolves `repo`, runs `[CCKIT_BIN, *args]` in that repository, captures stdout/stderr, parses JSON where requested, and returns structured errors instead of raising across the MCP boundary.

## Kotlin-Aware Index Tool Shape

The shim should expose the current Kotlin index flags without inventing new CLI features:

```python
def index(
    repo: str | None = None,
    include_build_scripts: bool = False,
    include_generated: bool = False,
) -> dict:
    args = ["index", "."]
    if include_build_scripts:
        args.append("--include-build-scripts")
    if include_generated:
        args.append("--include-generated")
    return run_cckit(args, repo=repo, timeout=300)
```

## Context tool shape (`gather_code_context` → `cckit pack`)

`cckit pack` remains the CLI. The MCP surface exposes it as `gather_code_context`
so agents match on “need code context for this work.” The current focused Kotlin
support does not include a Gradle failure-log parser, so the MCP shim should not
document Kotlin-specific failure-log behavior as implemented.

```python
@server.tool(name="gather_code_context", title="Gather code context", ...)
def gather_code_context(
    task: str,
    repo: str | None = None,
    budget: int = 12000,
    failure: str | None = None,
    mode: Annotated[
        str,
        Field(description="auto (default)=smallest of surgical|full|raw; surgical; full"),
    ] = "auto",
) -> dict:
    args = ["pack", "--task", task, "--budget", str(budget)]
    if failure:
        args.extend(["--failure", failure])
    if mode == "full":
        args.append("--full")
    elif mode == "surgical":
        args.append("--surgical")
    return run_cckit(args, repo=repo, timeout=180)
```

MCP schema is `task`, `repo`, `budget`, `failure`, `mode` only (`format`/`full` not exposed).
Default packing is **`auto`**: deliver the smallest of surgical, full, and raw.
Raw is primary files plus the packet banner (not a literal `cat`); it is
delivered-only — requested modes are `auto|surgical|full`. Surgical mode uses
symbol body slices plus same-file related name lists (cap 5); files ≤100 lines
dump as whole files without related-hint chrome. Pass `mode=full` (CLI `--full`)
for forced whole-file primary dumps. Surfacing mode on the MCP schema (not only
the tool docstring) matters: agents often choose args from schema descriptions.
If `cckit pack --failure` exists and works generically, the shim can pass it through as a generic option. It should not claim Kotlin compiler log anchoring unless that feature is reintroduced.

## Error Handling

Return structured dictionaries instead of raising exceptions across the MCP boundary:

- `{"error": "cckit_not_found"}`
- `{"error": "timeout"}`
- `{"error": "cckit_failed", "stderr": "..."}`
- `{"error": "bad_json", "stdout": "..."}`

This lets Claude Code decide whether to run `index`, retry, or show the error.

## Build Order

Completed:

1. Created `mcp/cckit_mcp.py`.
2. Added the PEP-723 header.
3. Implemented `run_cckit`.
4. Ideal MCP v1 tools: `find_symbol`, `find_references`, `gather_code_context` (wraps pack), `symbol`, `outline`, `map`, `index`.

Remaining local setup:

1. Build `cckit` with `swift build -c release`.
2. Register the shim in Claude Code.
3. Restart Claude Code.
4. Verify a tool call such as `gather_code_context(repo: "...", task: "Fix login retry")`.

## Current Status

Implemented as `mcp/cckit_mcp.py`.

The Kotlin indexing feature does not depend on this shim. The shim is a local integration layer for Claude Code workflows.
