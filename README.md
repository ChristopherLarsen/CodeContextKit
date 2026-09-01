# 🚀 CodeContextKit (cckit)

### *The Surgeon’s Scalpel for AI-Assisted Swift and Kotlin Development.*

**CodeContextKit** is a high-performance indexing and context-packing engine designed for developers who want to stop sending entire repositories to LLMs and start sending high-signal, surgical context. Built with **Swift 6**, **Hummingbird 2**, and **SQLite**, it provides an architect-level understanding of Swift and Kotlin codebases while running entirely on-device.

---

## Start Here

- Swift developers: [Swift Developer Setup](#swift-developer-setup)
- Android, Kotlin, Gradle, or KMP developers: [Android and Kotlin Developer Setup](#android-and-kotlin-developer-setup)
- Claude Code users: [Claude Code MCP Installation](#claude-code-mcp-installation)

---

## 🌟 Why CodeContextKit?

Traditional AI tools either know too little about your project structure or overwhelm the LLM with irrelevant tokens. **cckit** solves this by treating your codebase as a queryable semantic graph.

- **💾 Token Efficiency**: Stop wasting millions of tokens. Pack exactly what the AI needs—including skeletons, call sites, and captured terminal errors—into a single, surgical Markdown packet.
- **🏗️ Architect-Level Insight**: Automatically extract symbol hierarchies, protocol conformances, and complex reference maps.
- **🍎 Apple Intelligence Native**: The core CLI runs locally on macOS; visualizer chat and symbol summaries use **Apple Foundation Models** on macOS 26+ with Apple Intelligence. No code leaves your machine.
- **⚡ High-Performance Indexing**: Incremental, SQLite-backed indexing that keeps up with large-scale projects without the lag.

---

## 📺 The Visualizer (A DocC-Inspired Experience)

Launch a local, interactive portal to your codebase. It’s not just a file browser; it’s an AI-ready command center.

- **Monaco Editor Support**: View your code with the same engine that powers VS Code.
- **Interactive Graph**: See how your modules and files connect in a real-time force-directed graph.
- **🛒 Context Cart**: Stage specific files and symbols into a "cart" and pack them instantly. Perfect for building targeted feature context.
- **🖥️ Integrated Terminal**: Run `swift test` or `build` directly from the browser and append failure logs to your AI context with one click.
- **⚙️ Unused Code Detection**: Instantly identify potentially dead functions and properties across your modules.

---

## Swift Developer Setup

Use this path when you are indexing a SwiftPM, Xcode, or mixed Swift repository.

### Requirements

- macOS 15 or newer.
- Xcode Command Line Tools:
  ```bash
  xcode-select --install
  ```
- Swift 6 toolchain.

Optional visualizer chat and symbol-summary features require macOS 26+ with Apple Intelligence. The CLI index/search/pack/outline workflow does not.

### Install

Using Mint:

```bash
mint install NickTrienens2025/CodeContextKit
```

Or build from source:

```bash
git clone git@github.com:NickTrienens2025/CodeContextKit.git
cd CodeContextKit
swift build -c release
.build/release/cckit --help
```

### Index and use a Swift project

From the Swift project root:

```bash
cckit index .
cckit search "APIClient"
cckit outline Sources/Auth/APIClient.swift
cckit pack --task "fix token refresh retry"
```

Launch the visualizer:

```bash
cckit serve
```

---

## Android and Kotlin Developer Setup

Use this path when you are indexing an Android, Kotlin, Gradle, Java, or Kotlin Multiplatform repository.

### Requirements

- macOS 15 or newer.
- Xcode Command Line Tools:
  ```bash
  xcode-select --install
  ```
- Swift 6 toolchain.

You do not need Kotlin, Gradle, Android Studio, or a JVM for `cckit` indexing. `cckit` reads Kotlin source and Gradle project files directly; it does not run Gradle.

### Install

Clone CodeContextKit and install the CLI:

```bash
git clone git@github.com:NickTrienens2025/CodeContextKit.git
cd CodeContextKit
./scripts/install-cckit.sh
```

This builds a release binary and links it to `~/.local/bin/cckit`. If `~/.local/bin` is not on your `PATH`, the script prints the exact `export PATH=...` line to add.

### Index and use an Android/Kotlin project

From the Android or Kotlin project root:

```bash
cckit index . --stats
cckit search "UserRepository"
cckit outline app/src/main/kotlin/com/acme/UserRepository.kt
cckit symbol com.acme.UserRepository.fetchUser
cckit pack --task "fix login retry after token refresh"
```

Or index a project from anywhere:

```bash
cckit index /path/to/android-project --stats
```

Gradle build scripts and generated output are skipped by default. Opt in only when those files are relevant:

```bash
cckit index . --include-build-scripts
cckit index . --include-generated
```

Swift and Kotlin are indexed into the same local database. Kotlin symbols use package-qualified names such as `com.acme.UserRepository.fetchUser`; Swift symbols keep their Swift qualified names.

---

## 🧭 CLI at a Glance

| Command | Purpose |
| :--- | :--- |
| `cckit index` | Build the SQLite & Semantic knowledge base. `--compact` reclaims leaked Wax vectors without re-embedding. `--no-semantic` (or `CCKIT_NO_SEMANTIC=1`) indexes SQLite locators only — no arena, no embedding pass, seconds instead of ~18 minutes. Rebuilds are staged and swapped in atomically, so the live index keeps serving consistent reads during the build, and failed runs are recorded in the ledger. Lexical repos write a `.cckit/lexical-only` marker that MCP auto-refresh honors (it re-spawns `index --no-semantic` instead of upgrading the repo). |
| `cckit pack` | Generate a surgical context packet for an AI task. |
| `cckit find-symbol` | Name fragment → qualified names + paths (no bodies). |
| `cckit find-references` | Symbol name → indexed call sites (paths + lines, no bodies). |
| `cckit search` | Unified discovery: Symbol, Literal (Grep), and Semantic search. |
| `cckit outline` | Get the structural "skeleton" of Swift and Kotlin files. |
| `cckit symbol` | Retrieve the exact implementation of any named symbol. |
| `cckit history-benchmark` | Sample git history for pack tokens + file-level recall@k. |

### 📦 Pack Examples

Generate a targeted Markdown context packet for your AI assistant:

```bash
# Basic task-based packing (default: auto — smallest of surgical, full, raw)
cckit pack --task "Implement OAuth2 login flow"

# Budgeted packing (token ceiling, not a fill target)
cckit pack --task "Add retry logic to network requests" --budget 15000

# Cheap first look (~1500 token cap): hit list, line ranges, body sizes, map —
# no bodies. Expand with `cckit symbol` or re-gather with --surgical/--full.
cckit pack --task "Fix login retry" --preview

# Force surgical-only or legacy full-file primaries
cckit pack --task "Fix login retry" --surgical
cckit pack --task "Review entire auth module" --full

# Output the packet to a specific file
cckit pack --task "Fix the crash in the CoreData migration" --output migration_context.md

# Combined example
cckit pack --task "Update the sync service to handle workout reminders" --budget 15000 --output my_context.md

# Lexical-only repo (indexed with --no-semantic): pack without an arena
cckit pack --task "findMe in LexA" --no-semantic --budget 2000
```

Default **`auto`** delivers the smallest of surgical, full, and raw — and never
delivers a packet larger than reading its primary files outright (when even raw
loses, chrome is stripped until it cannot lose). Raw is primary files plus the
packet banner (not a literal `cat`). Surgical mode uses symbol body slices plus
a compact **same-file related** list (callers / callees / siblings — names and
line ranges only, capped at 5 per category). Files ≤100 lines (or ≥80% body
coverage) are emitted as whole files without related-hint chrome. When same-file
related lists are truncated, surgical packets append **Packing notes** that tell
agents to call `gather_code_context` again with `mode=full` (CLI: `cckit pack --full`)
for whole-file context, or `symbol` / `outline` for individual neighbors.
Untruncated related lists omit that footer.

If a budget is too small to fit even one primary, the packet says so: a stderr
warning plus an in-packet `## Warning` section reports the unconstrained pack
size (measured with one probe at a generous budget) instead of silently
returning a header-only packet.

Auto packs append savings to `.cckit/pack_savings.jsonl`. Tool calls append to
`.cckit/action_history.jsonl` (survives `cckit index --clean`). Both JSONL
ledgers keep **at most 7 days** of rows (override with `CCKIT_LEDGER_KEEP_DAYS`);
prune runs **at most once per day** (stamp: `.cckit/jsonl_retention_stamp`).
`find-symbol` / `find-references` rows carry `baselineTokens`: what `rg -F` for
the same name costs repo-wide (`-1` = unmeasured), so locator savings are
auditable — and visibly bimodal (large wins on common names, ~1× on rare ones).
Evicted rows are folded into monthly rollups (`pack_savings_monthly.jsonl`,
`tool_usage_monthly.jsonl`) so lifetime numbers survive pruning. Metrics compare
**delivered tokens** to the **whole-file size of files already loaded for that
call** — not vs Grep or other tools (dual-running those spends the tokens you
would claim to save). MCP responses attach a one-line `savings` summary
(`~delivered vs whole-file`) on successful gather/symbol/outline/map calls; MCP
pack calls print a machine-readable `PACK_STATS {...}` line. Review with:

```bash
cckit pack-stats
# Pack savings (vs whole source files already loaded into packets)
# By month (rollups survive the 7-day ledger window) + lifetime totals
# Tool usage (from …/action_history.jsonl)
```

---

## Keep the index fresh across branch checkouts

`cckit index` stamps the current git commit/branch into `.cckit/index-stamp.json`.
MCP responses omit freshness when the index is current; a `stale: true` field
appears only when it is not. Re-index (or let MCP auto-refresh) before trusting
symbols from another commit. MCP also runs an incremental index when indexable
working-tree files differ from the stored hashes, so uncommitted edits are
picked up without a branch change.

Optional refresh-only post-checkout hook (skips worktrees with no index, so shared
`.git/hooks` across many worktrees will not trigger a full multi-minute build):

```bash
cp scripts/git-hooks/post-checkout .git/hooks/post-checkout
chmod +x .git/hooks/post-checkout
```

The hook runs only when `[ -f "$root/.cckit/index.sqlite" ]` and a branch checkout
occurred; it then runs an incremental `cckit index .` in the background.

---

## MCP vs CLI

Use the Claude Code MCP integration when Claude Code is doing the work. MCP lets Claude call `cckit` directly for context packs, outlines, repo maps, and symbols, which avoids pasting command output and can save tokens by steering Claude toward focused packets instead of broad file reads.

Use the CLI when you are working manually, scripting, debugging setup, or launching the visualizer. The CLI is also the best way to verify what MCP is doing underneath:

```bash
cckit --help
cckit index . --stats
cckit search "UserRepository"
cckit serve
```

In practice: install MCP for Claude Code workflows, keep the CLI for direct control, troubleshooting, scripts, and the browser visualizer.

---

## Kotlin Support

Kotlin indexing is backed by SwiftPM-managed Tree-sitter dependencies and lives in a separate `CodeContextKitKotlinIndex` module. It supports Kotlin packages, classes, interfaces, objects, companion objects, data/sealed/value classes, enum entries, constructors, properties, functions, extension functions, typealiases, KDoc, references, and common test detection.

Gradle/KMP projects are detected without running Gradle. Build scripts and generated outputs are skipped by default:

```bash
cckit index .
cckit index . --include-build-scripts
cckit index . --include-generated
```

Kotlin v1 configuration is intentionally flag-driven: `cckit` autodetects Gradle/KMP structure at index time, and users opt into build scripts or generated code with CLI flags. Persistent project config (`cckit.toml` / `.cckit/project.json`) is deferred.

Known v1 gaps: no compiler-grade `expect`/`actual` validation and no Swift/Kotlin cross-language reference resolution yet.

---

## 🔐 Privacy & Security

CodeContextKit is **local-first**. Your code is indexed into a local SQLite database, and optional visualizer chat/summaries are processed by local Apple Foundation Models when available. Your intellectual property stays where it belongs: **on your disk.**

---

## Claude Code MCP Installation

CodeContextKit includes a local MCP shim at `mcp/cckit_mcp.py` so Claude Code can call `cckit` for context packs, outlines, repo maps, symbols, and indexing.

Recommended use: install the MCP when you plan to use Claude Code on the same Swift, Android, or Kotlin repository repeatedly. Once registered, Claude Code can call `cckit` tools directly instead of asking you to paste command output or reading broad swaths of files. That usually makes project navigation more automatic and can save tokens by using indexed symbols, outlines, repo maps, and focused context packs instead of full-file dumps.

Install `cckit` first:

```bash
./scripts/install-cckit.sh
```

Then register the MCP server with Claude Code:

```bash
./scripts/install_mcp.sh --repo /path/to/project-to-index
```

The installer defaults to `--scope user`, which makes the server available across Claude Code workspaces. Use `--scope local` to register it only for the current workspace:

```bash
./scripts/install_mcp.sh --scope local --repo /path/to/project-to-index
```

If `uv` is not installed, either install it yourself:

```bash
brew install uv
```

Or let the installer do it through Homebrew:

```bash
./scripts/install_mcp.sh --install-uv --repo /path/to/project-to-index
```

Useful options:

- `--repo PATH`: default repository for MCP calls. If omitted, tools can still receive an explicit `repo` argument.
- `--scope user|local|project`: Claude Code MCP registration scope. Default: `user`.
- `--cckit-bin PATH`: use a specific `cckit` binary instead of auto-detecting `~/.local/bin/cckit`, `.build/release/cckit`, or `cckit` on `PATH`.

Verify registration:

```bash
claude mcp get cckit
claude mcp list
```

Smoke test in Claude Code:

```text
Use the cckit MCP server to gather code context for fixing login retry.
Use cckit MCP to outline Sources/Auth/APIClient.swift.
```

Available MCP tools:

| MCP tool | cckit command | Notes |
| :--- | :--- | :--- |
| `gather_code_context` | `cckit pack` | Budgeted source packet for a symptom, change, multi-file task, or failure log (`auto` by default; `mode=surgical` / `mode=full` / `mode=preview` via `mode`). Successful calls carry a one-line savings summary. |
| `find_symbol` | `cckit find-symbol` | Name lookup after gather, or when you only need a qualified name (no bodies). |
| `find_references` | `cckit find-references` | Indexed call sites (paths + lines). Check `truncated`/`totalCount`; raise `limit` before concluding unused. |
| `symbol` | `cckit symbol --json` | Exact qualified name → **implementation body**. |
| `outline` | `cckit outline` | Works for Swift and Kotlin files. |
| `map` | `cckit map` | Names-only budgeted repo map; prefer gather when you need source. Skip if the packet already included a map. |
| `index` | `cckit index .` | Supports `clean`, `include`, `exclude`, `include_build_scripts`, and `include_generated`. Stamps git HEAD. |

MCP responses omit freshness metadata when the index is current; `stale: true`
appears only when the stamp disagrees with `HEAD`. Set `CCKIT_REFRESH=never` to
skip auto-reindex; `CCKIT_DEBUG_STDERR=1` to keep stderr on successful calls.

The shim returns structured errors such as `bad_repo`, `cckit_not_found`, `timeout`, `no_index`, `bad_json`, and `cckit_failed` when setup or CLI calls fail.

---

Built with ❤️ by [Nicholas Trienens](https://github.com/NickTrienens2025)
