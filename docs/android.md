# Android developer setup

This guide is for Android developers who want to use `cckit` on a Kotlin, Java, Gradle, Android, or Kotlin Multiplatform repository.

## Mental model

There are two directories involved:

- The CodeContextKit checkout, which builds the `cckit` command.
- Your Android app or library checkout, which `cckit` indexes.

After installation, run `cckit` from your Android project root or pass the Android project path explicitly.

## Requirements

- A Mac running macOS 15 or newer.
- Xcode Command Line Tools:

  ```bash
  xcode-select --install
  ```

- Swift 6, provided by the active Xcode or command line toolchain.

You do not need Kotlin, Gradle, Android Studio, or a JVM for `cckit` indexing. `cckit` reads source files and Gradle project files directly; it does not run Gradle.

Optional visualizer chat and AI symbol summaries require macOS 26.0 or newer with Apple Intelligence. The normal `index`, `search`, `symbol`, `outline`, `map`, and `pack` commands do not require Apple Intelligence.

## Install from a clone

From the CodeContextKit checkout:

```bash
./scripts/install-cckit.sh
```

The script builds a release binary and links it to `~/.local/bin/cckit` by default. If `~/.local/bin` is not on your `PATH`, the script prints the exact `export PATH=...` line to add.

To install somewhere else:

```bash
PREFIX=/opt/homebrew ./scripts/install-cckit.sh
```

## Index an Android project

From your Android project root:

```bash
cckit index . --stats
```

Or from anywhere:

```bash
cckit index /path/to/android-project --stats
```

The default Android/Kotlin policy is intentionally quiet:

- `.kt` files are indexed.
- `.java` files are included in the scan policy.
- Gradle `.kts` build scripts are skipped.
- Generated output under common Gradle, KSP, Kotlin, CMake, and build directories is skipped.

Only opt into noisy surfaces when they are part of the task:

```bash
# Use when editing Gradle convention plugins, buildSrc, or build logic.
cckit index . --include-build-scripts

# Use when generated Room, Hilt, KSP, or other generated sources are the target.
cckit index . --include-generated
```

## Useful first commands

```bash
cckit search "UserRepository"
cckit outline app/src/main/kotlin/com/acme/UserRepository.kt
cckit symbol com.acme.UserRepository.fetchUser
cckit map --focus "login retry" --budget 6000
cckit pack --task "fix login retry after token refresh"
```

Kotlin symbols use package-qualified names, for example `com.acme.UserRepository.fetchUser`.

## Claude Code MCP setup

Build and install `cckit` first, then install `uv` if needed:

```bash
brew install uv
```

From the CodeContextKit checkout:

```bash
CCKIT_ROOT="$(pwd)"
claude mcp add cckit --scope user \
  --env CCKIT_BIN="$HOME/.local/bin/cckit" \
  --env CCKIT_REPO="/path/to/android-project" \
  -- uv run --script "$CCKIT_ROOT/mcp/cckit_mcp.py"
```

Use `--scope local` instead of `--scope user` if you only want the server registered for the current Claude Code workspace.

Verify:

```bash
claude mcp get cckit
claude mcp list
```

When asking Claude Code to use `cckit`, pass the Android repository path if you did not set `CCKIT_REPO`.

## Troubleshooting

If `swift build` fails because `swift` is missing, run `xcode-select --install` and retry.

If `cckit` is not found after install, add the install directory to `PATH`:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

If a command reports `Index not found`, run this from the Android project root:

```bash
cckit index .
```

If build scripts or generated sources are missing from results, re-run indexing with the relevant opt-in flag:

```bash
cckit index . --include-build-scripts
cckit index . --include-generated
```

If the visualizer AI features report an Apple Intelligence or Foundation Models requirement, use the CLI workflow instead; Kotlin indexing and context packing do not depend on those features.
