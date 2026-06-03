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

## Tool Surface

Keep the first version small:

| MCP tool | Wraps | Notes |
|---|---|---|
| `index` | `cckit index .` | Supports `clean`, `include`, `exclude`, `include_build_scripts`, and `include_generated`. |
| `search` | `cckit search --json` | Parses JSON output. |
| `symbol` | `cckit symbol --json` | Fetch exact qualified symbols. |
| `outline` | `cckit outline` | Works for Swift and Kotlin through cckit's registry. |
| `map` | `cckit map` | Token-budgeted repo map. |
| `pack` | `cckit pack` | Main context-building tool. |
| `estimate` | `cckit estimate` | Token estimate helper. |
| `summarize` | `cckit summarize --memory` | Deterministic project memory output. |
| `explain` | `cckit explain` | Current diagnostic command. |

Omit for v1:

- `serve`
- `benchmark-serve`
- `history-benchmark`
- any future `clean`, `detect`, `config`, or language-diagnostic commands that do not exist in the current CLI.

## Repo Resolution

Every tool should accept an explicit `repo` argument.

Resolution order:

1. Tool call `repo` argument.
2. Optional `CCKIT_REPO` environment variable.
3. MCP server launch cwd as a last resort.

The recommended path is to always pass `repo`.

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

## Pack Tool Shape

`cckit pack` remains the primary context tool. The current focused Kotlin support does not include a Gradle failure-log parser, so the MCP shim should not document Kotlin-specific failure-log behavior as implemented.

```python
def pack(
    repo: str | None,
    task: str,
    budget: int = 12000,
) -> dict:
    return run_cckit(
        ["pack", "--task", task, "--budget", str(budget)],
        repo=repo,
        timeout=120,
    )
```

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
4. Implemented `index`, `search`, `symbol`, `outline`, `pack`, `map`, `estimate`, `summarize`, and `explain`.

Remaining local setup:

1. Build `cckit` with `swift build -c release`.
2. Register the shim in Claude Code.
3. Restart Claude Code.
4. Verify a tool call such as `search(repo: "...", query: "UserRepository")`.

## Current Status

Implemented as `mcp/cckit_mcp.py`.

The Kotlin indexing feature does not depend on this shim. The shim is a local integration layer for Claude Code workflows.
