# ``CodeContextKitContext``

The high-level orchestrator for generating surgical code context and architectural repo maps.

## Overview

CodeContextKitContext builds token-budgeted packets and repo maps from the local SQLite index and Wax MiniLM store. Ranking is local (focus, kind, visibility) — it does not use ContextCore or CoreML embeddings. Packing defaults to `auto` (smallest of surgical slices, full files, and raw primaries). Semantic search uses Wax's on-device MiniLM vectors.

## Topics

### Mapping and Packing
- ``RepoMapBuilder``
- ``ContextPacker``
- ``PackMode``
- ``PackResult``
- ``PackSavingsLedger``

### Orchestration
- ``ActionOrchestrator``
- ``Indexer``
