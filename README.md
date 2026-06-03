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
| `cckit index` | Build the SQLite & Semantic knowledge base. |
| `cckit pack` | Generate a surgical context packet for an AI task. |
| `cckit search` | Unified discovery: Symbol, Literal (Grep), and Semantic search. |
| `cckit outline` | Get the structural "skeleton" of Swift and Kotlin files. |
| `cckit symbol` | Retrieve the exact implementation of any named symbol. |

---

## MCP vs CLI

Use the Claude Code MCP integration when Claude Code is doing the work. MCP lets Claude call `cckit` directly for indexing, search, outlines, repo maps, and context packs, which avoids pasting command output and can save tokens by steering Claude toward indexed symbols and focused packets instead of broad file reads.

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

CodeContextKit includes a local MCP shim at `mcp/cckit_mcp.py` so Claude Code can call `cckit` for indexing, search, outlines, repo maps, and context packs.

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
Use the cckit MCP server to index this repo.
Use cckit MCP to search for UserRepository.
```

Available MCP tools:

| MCP tool | cckit command | Notes |
| :--- | :--- | :--- |
| `index` | `cckit index .` | Supports `clean`, `include`, `exclude`, `include_build_scripts`, and `include_generated`. |
| `search` | `cckit search --json` | Searches files, symbols, text, or `semantic:` queries. |
| `symbol` | `cckit symbol --json` | Fetches exact qualified symbols. |
| `outline` | `cckit outline` | Works for Swift and Kotlin files. |
| `map` | `cckit map` | Builds a budgeted repo map. |
| `pack` | `cckit pack` | Generates the surgical Markdown context packet. |
| `estimate` | `cckit estimate` | Estimates tokens for a file or raw text. |
| `summarize` | `cckit summarize --memory` | Produces deterministic project memory. |
| `explain` | `cckit explain` | Explains index, pack, or symbol behavior. |

The shim returns structured errors such as `bad_repo`, `cckit_not_found`, `timeout`, `no_index`, `bad_json`, and `cckit_failed` when setup or CLI calls fail.

---

Built with ❤️ by [Nicholas Trienens](https://github.com/NickTrienens2025)
