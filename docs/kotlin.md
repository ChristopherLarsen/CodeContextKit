# Kotlin support

CodeContextKit indexes Kotlin through a separate `CodeContextKitKotlinIndex` module. Swift indexing remains in `CodeContextKitSwiftIndex`; shared routing, outline rendering contracts, and body extraction live in Core/Context so the CLI and server do not need language-specific casts.

If you are coming from Android development and only want to install and use the CLI, start with [Android developer setup](android.md).

## What is indexed

- `.kt` source files
- `.java` files through the existing generic route
- `.kts` source scripts, excluding Gradle build scripts by default

Kotlin extraction is backed by SwiftPM-managed Tree-sitter runtime and Kotlin grammar dependencies. It records packages, classes, interfaces, objects, companion objects, enum entries, constructors, properties, functions, extension functions, type aliases, KDoc, and common Kotlin test annotations.

## Gradle projects

When a repository contains `settings.gradle`, `settings.gradle.kts`, `build.gradle`, or `build.gradle.kts`, the scanner treats it as a Gradle project. It discovers modules from `include(...)`, supports simple `project(":module").projectDir = file("...")` remaps, and walks `src/*/kotlin` and `src/*/java` source-set directories for JVM, Android, and Kotlin Multiplatform layouts.

Generated Gradle/Kotlin output directories are skipped by default, including `.gradle/`, `.kotlin/`, `.idea/`, `.cxx/`, `captures/`, and `build/`.

Use `cckit index --include-generated` to include generated sources.

Kotlin v1 uses CLI flags and autodetection only. There is no persistent `cckit.toml` or `.cckit/project.json` config surface yet; Gradle/KMP structure is detected during indexing, and users opt into noisy surfaces with `--include-build-scripts` or `--include-generated`.

## Kotlin scripts

Gradle `.kts` files are skipped by default because they tend to flood symbol search with DSL helpers and dependency declarations. The classifier uses path and content signals such as `build.gradle.kts`, `settings.gradle.kts`, `plugins { ... }`, and `dependencies { ... }`.

Use `cckit index --include-build-scripts` when Gradle DSL code is the target.

## Current limitations

- Gradle discovery is text-based; CodeContextKit does not execute Gradle.
- Source-set discovery is used for project understanding and scanner policy, not full Gradle dependency resolution.
- Persistent project config (`cckit.toml`, `.cckit/project.json`, and config commands) is deferred; v1 uses autodetection plus CLI flags.
