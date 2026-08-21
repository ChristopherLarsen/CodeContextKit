# cckit Agent Playbook (canonical)

This is the single source of truth for how coding agents should use CodeContextKit
(`cckit`). The MCP server instructions (`mcp/cckit_mcp.py`), tool descriptions,
and the packaged skill (`codecontextkit-skill/`) are renderings of this file.
Keep the routing table and rules identical across all three; a consistency test
(`mcp/test_cckit_mcp.py::PlaybookConsistencyTests`) guards the shared phrases.

## Decision table

| You need... | Use |
| :--- | :--- |
| Context for a symptom, a change, more than one file, or a failure log | `gather_code_context(task)` — even when names are visible; those names go in `task` |
| A cheap look before committing to bodies | `gather_code_context(task, mode="preview")` — names, line ranges, body sizes (~1500 token cap) |
| One known symbol body | `symbol` (qualified name) |
| A qualified name / where something is defined | `find_symbol` |
| Call sites of `Foo` or `Foo.bar` | `find_references` |
| Structure of one file | `outline` |
| Names-only overview of the repo | `map` |

## Rules

1. Prefer `gather_code_context` over Grep/Read for source on the first
   retrieval of task-shaped work. Treat the packet as starting context.
2. After a gather or locator hit, do not Grep that name. If you lack the next
   name, outline the file. Huge hits: nested name or narrow Read — `symbol`
   will not dump the whole type.
3. Content tools (`gather_code_context`, `symbol`, `outline`) read disk;
   locators (`find_symbol`, `find_references`, `map`) use the last index. A
   dirty worktree does not retire these tools — MCP auto-refreshes HEAD drift
   and dirty indexable files, and retries once on a locator miss.
4. On a miss: gather misses invite retrying gather with prose; locator misses
   invite outline/symbol. Grep stays valid for non-indexable files (markdown,
   project files, logs) and string literals.
5. Successful responses carry a savings line (`~delivered vs whole-file`).
   Stay surgical when it shows a big win; escalate to `mode=full` only when the
   task truly needs whole files.
6. Pass `repo=` when unsure. Do not call `index` yourself — MCP auto-refreshes;
   `index` is last resort on `no_index`.
