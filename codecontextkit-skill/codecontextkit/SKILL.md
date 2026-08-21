---
name: codecontextkit
description: Use CodeContextKit (cckit) MCP tools or CLI to index Swift/Kotlin repos and retrieve surgical, token-budgeted context instead of reading whole files. Trigger when gathering code context, finding symbols/references, outlining files, or packing context for a task.
---

# CodeContextKit Skill

This skill routes you through CodeContextKit (`cckit`) for codebase retrieval.
It is a rendering of the canonical playbook at `docs/agent-playbook.md` in the
CodeContextKit repo — keep the two in sync.

Prefer the **MCP tools** when a `cckit` MCP server is registered; the CLI
commands in parentheses do the same thing for shell use.

## Decision table

| You need... | Use |
| :--- | :--- |
| Context for a symptom, a change, more than one file, or a failure log | `gather_code_context(task)` (CLI: `cckit pack --task ...`) — even when names are visible; put those names in `task` |
| A cheap look before committing to bodies | `gather_code_context(task, mode="preview")` — names, line ranges, body sizes (~1500 token cap) |
| One known symbol body | `symbol` with the qualified name (CLI: `cckit symbol Name --json`) |
| A qualified name / where something is defined | `find_symbol` (CLI: `cckit find-symbol`) |
| Call sites of `Foo.bar` | `find_references` (CLI: `cckit find-references`) |
| Structure of one file | `outline` (CLI: `cckit outline path/to/File.swift`) |
| Names-only overview of the repo | `map` (CLI: `cckit map`) |

## Rules

1. Prefer gather over Grep/Read for source on the first retrieval of task-shaped work. Treat the packet as starting context.
2. After a gather or locator hit, do not Grep that name. If you lack the next name, outline the file. Huge hits: nested name or narrow Read — symbol will not dump the whole type.
3. Content tools read disk; locators use the last index. A dirty worktree does not retire them — MCP auto-refreshes HEAD drift and dirty files, and retries once on a locator miss.
4. On a miss: gather misses invite retrying gather with prose; locator misses invite outline/symbol (find_symbol after gather, or when you only need a qualified name). Grep stays valid for markdown, project files, logs, and string literals.
5. Successful responses carry a savings line (`~delivered vs whole-file`). Stay surgical when it shows a big win; escalate to `mode=full` only when truly needed.
6. Pass `repo=` when unsure. Do not call `index` yourself — MCP auto-refreshes; index only on `no_index`.

## Setup

```bash
cckit index .            # once per repo (SQLite + semantic store)
./scripts/install_mcp.sh --repo /path/to/project   # register MCP with Claude Code
```

The local visualizer (`cckit serve`) offers a Context Cart, force-directed
graph, terminal runner, and on-device chat — useful for humans staging context,
not required for agents.
