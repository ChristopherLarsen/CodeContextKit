# Wax storage audit for CodeContextKit

Audit date: 2026-08-27 (addendum 2026-09-01, commit of the same day)  
Incident baseline: cckit `46155d396979f132402517906f8250091f048714`, Wax `d4de9d6a8af73b55b0fefe3a5786bab27f6d8cf1`  
Current Wax pin: `3405b8c6ecf1dd0b6322936f1681ec8b480a3b08` (`Package.swift:28`, `Package.resolved:340-343`)

## 2026-09-01 audit addendum

Full re-audit of the Wax arena lifecycle and the token-savings accounting against the
post-97733a8 code. Findings and dispositions (all fixed in the same-day commit unless noted):

| ID | Finding | Disposition |
|---|---|---|
| WAX-14 | Delta runs had no atomicity: SQLite coverage/mandate rows committed per file while Wax saves stayed uncommitted until the end-of-run flush. An interrupted run (SIGKILL, mid-run cap abort) left coverage rows claiming arena documents that died with the process — silently partial arena, invisible to WaxReadGate (frameCount > 0, no uncovered paths). | Fixed: mandate + coverage rows are now written only AFTER the flush commits (Indexer durability contract). An interrupted run leaves files uncovered and the existing delta preflight retries them. |
| WAX-15 | One torn/malformed line in `pack_savings.jsonl` / `action_history.jsonl` made every search/pack fail permanently (`JSONLRetention.load` threw on decode). Cross-process prune-rewrite vs append could also drop rows. | Fixed: load skips malformed lines with a stderr warning; prune is serialized under the repo refresh lock. |
| WAX-16 | Server opened `repo.wax` unconditionally at startup: created an empty arena on lexical-only repos and held the arena lease for the process lifetime, so any CLI read failed fast while the dashboard ran. | Partially fixed: lexical-only servers never open the arena (no creation, no lease; semantic endpoints degrade; dashboard reindex stays lexical; semantic-graph links are pure local math and still work). A semantic repo's server still holds the handle for its lifetime — concurrent CLI reads fail fast by contract. The residual fix (read-only or bounded-wait open) is upstream-bound; see WAX-08. |
| WAX-17 | Every MiniLM document embedded a trailing random `cckitwax_<mandate>` token: wasted model context and injected per-document noise; nothing ever searched by it (mandate bookkeeping is SQLite-side). | Fixed: mandate rides in metadata only; previews of legacy arenas still strip the token. Embedder identity bumped `v2-selective` → `v3-selective` so the next index re-embeds everything for consistent scoring. |
| SAV-1 | Partial budget truncation was silent: a packet delivering 2-of-5 primaries read as a confident small answer (only the 0-primary case was noticed). | Fixed: packer counts dropped primaries; pack warns on stderr, stamps the packet warning section, and adds `droppedPrimaries` to PACK_STATS. |
| SAV-2 | Surgical assembly could re-emit a symbol slice of a file already fully delivered by an earlier primary (asymmetric guard vs the preferFullFast branch). | Fixed: the already-emitted branch skips. |
| SAV-3 | Chrome-only packets (empty lexical results, budget-truncated headers) recorded negative "savings" (the cost of the warning text) into `pack_savings.jsonl`. | Fixed: savings records require `primaryCount > 0`; `action_history` still carries every call. |
| SAV-4 | Lexical-only pack with zero primaries delivered a silent empty packet (the "Note" from the 97733a8 probing round). | Fixed: packet carries an explicit lexicalEmpty warning, stderr warning, and PACK_STATS `lexicalEmpty`. The underlying narrowness of lexical primary selection (Titlecase single words are not identifier-like, so prose tasks find nothing) is a deliberate `SemanticIndexPolicy` trade-off, unchanged. |
| SAV-5 | Breach-marker operator message ("NEXT index aborts") and doc comment contradicted the actual behavior (staged rebuild + swap, marker cleared post-swap). Mid-run cap doc named a nonexistent `CCKIT_WAX_MIN_BYTES` env var. | Fixed (text). |

Residual, upstream-bound: WAX-08 read-only/bounded-wait arena open (server lifetime lease),
WAX-01/02 batch delete (twin leak bounded by the delta band), W7's >64x shrink blind spot
(treated as impossible watermark by design).

# Original 2026-08-27 audit

## Current integration status

Wax is an upstream dependency, not a cckit-owned component. cckit now tracks upstream `main` at the immutable revision above and does not patch `.build/checkouts/Wax`.

The new Wax revision fixes delete ordering and ghost-vector durability: it removes text/vector entries before the delete commit. It does **not** batch deletion; `Memory.delete(frameID:)` still performs one full commit per frame (`Wax@3405b8c:Sources/Wax/Orchestrator/MemoryOrchestrator.swift:1497-1519`). The same 256-document/64-delete harness still grew allocated storage from 2,846,720 to 105,594,880 bytes (37.1x).

Upstream also removed the public APIs cckit formerly used for save-returned frame IDs, frame enumeration, storage liveness diagnostics, live-set configuration, and forced maintenance. cckit now stays within Wax's documented public surface:

- `Memory.Config.embedding = .builtIn(.miniLM)` for an explicit semantic store;
- `save`, vector-only `search`, `stats`, `flush`, and `close`;
- no calls to `Memory.delete` during indexing or compaction.

Before mutation, `Indexer` compares the scanned source set and hashes with SQLite. A no-op run retains the existing arena. Any added, changed, deleted, previously unbound, explicitly compacted, or breach-marked index triggers one complete replacement of the derived Wax arena and re-ingests the current corpus. `--compact` is therefore a safe rebuild, not an in-place delete pass. This trades incremental embedding speed for bounded storage and correct stale-result removal until Wax exposes a batch transaction.

Each successfully processed file receives a SQLite coverage marker after all eligible symbols are saved. That makes interrupted/partial rebuilds retryable while allowing files with no semantic documents to remain true no-ops. cckit also holds `repo.wax.lock`, a stable sidecar lease, for every `WaxStore` lifetime. Index acquires it before deleting or replacing the arena, so a long-lived server can no longer keep writing an unlinked old inode. If the arena is absent after an interrupted upstream promotion, cckit restores exactly one regular `repo.wax.pre-liveset-*` backup and refuses ambiguous multi-backup recovery.

## Executive verdict

The 200 MB to 186 GB incident has a sufficient single-process explanation: cckit retracts every recorded frame individually (`Sources/CodeContextKitRetrieval/WaxStore.swift:69-78`), and Wax's high-level `delete(frameId:)` performs a full `session.commit()` for every frame before returning (`Wax@d4de9d6:Sources/Wax/Orchestrator/MemoryOrchestrator.swift:1516-1534`). Staging that commit serializes the entire dirty FTS database and vector arena (`Wax@d4de9d6:Sources/Wax/WaxSession.swift:428-460`, `Wax@d4de9d6:Sources/WaxTextSearch/FTS5SearchEngine.swift:736-771`, `Wax@d4de9d6:Sources/WaxVectorSearch/AccelerateVectorEngine.swift:168-182`), and Wax appends those blobs at `dataEnd` instead of replacing their predecessors (`Wax@d4de9d6:Sources/WaxCore/Wax.swift:1717-1786`).

This is stronger than the prior “many commits were required” conclusion: the public delete path supplies those commits deterministically. A near-full incremental refresh can call delete once for every SQLite-recorded Wax frame before saving replacements (`Sources/CodeContextKitContext/Indexer.swift:96-123`, `Sources/CodeContextKitContext/Indexer.swift:230-241`). Saves themselves do not commit (`Wax@d4de9d6:Sources/Wax/Memory.swift:159-171`, `Wax@d4de9d6:Sources/Wax/Orchestrator/MemoryOrchestrator.swift:344-608`); deletes do.

The included harness reproduces the shape without MiniLM or network access (`Tools/WaxAmplificationHarness/main.swift:1-259`). With 256 documents and 64 one-at-a-time deletes, allocated bytes grew from 2,842,624 to 94,531,584 (33.3x), while Wax reported 63,832,012 stale index bytes. The measured growth was 0.504 starting-arena equivalents per delete, so approximately 1,840 equivalent deletes predict 929x. The recovered local index currently has 1,988 non-null `waxFrameRecord.frameId` rows (measured with the command in [Reproduction](#reproduction)), making the observed scale plausible without a concurrent writer or a single enormous `Data` value.

The incident was therefore primarily an upstream Wax API/lifecycle behavior, amplified by cckit's former per-frame integration. A Wax batch-delete transaction would be the ideal upstream fix, but cckit does not own that code. The shipped cckit mitigation is to rebuild the derived arena on semantic change and retain a fresh-filesystem mid-run growth cap.

The remainder of the detailed incident analysis is preserved against the old `d4de9d6` pin. Its `cckit` call sites describe the incident implementation, not the current rebuild-based integration.

## Interface audit

cckit changes only `Memory.Config.liveSetRewrite`; all other fields retain Wax defaults (`Sources/CodeContextKitRetrieval/WaxStore.swift:329-334`, `Wax@d4de9d6:Sources/Wax/Memory.swift:5-40`). Its actual `Memory` surface is:

| cckit operation | Wax public call | cckit site | Storage/lifecycle consequence |
|---|---|---|---|
| Open | `Memory(at:config:builtInEmbedding:)`, then text-only fallback | `Sources/CodeContextKitRetrieval/WaxStore.swift:329-349` | Both modes open a read-write orchestrator/session; Wax takes an exclusive file lock for the handle lifetime (`Wax@d4de9d6:Sources/Wax/Orchestrator/MemoryOrchestrator.swift:250-291`, `Wax@d4de9d6:Sources/WaxCore/Wax.swift:633-638`). |
| Save | `save(_:metadata:)` | `Sources/CodeContextKitRetrieval/WaxStore.swift:47-66` | Appends frame payloads and WAL records, updates in-memory text/vector engines, but does not call commit (`Wax@d4de9d6:Sources/Wax/Orchestrator/MemoryOrchestrator.swift:344-456`, `Wax@d4de9d6:Sources/WaxCore/Wax.swift:890-946`). |
| Delete | `delete(frameID:)` in a loop | `Sources/CodeContextKitRetrieval/WaxStore.swift:69-90` | Every successful call commits once, then dirties the indexes again by removing the frame after the commit (`Wax@d4de9d6:Sources/Wax/Orchestrator/MemoryOrchestrator.swift:1516-1534`). |
| Search | `search`, vector-only for semantic queries; text-only for mandate cleanup | `Sources/CodeContextKitRetrieval/WaxStore.swift:185-210`, `Sources/CodeContextKitRetrieval/WaxStore.swift:433-447` | Search can synchronize pending embeddings into the in-memory vector engine but does not commit (`Wax@d4de9d6:Sources/Wax/WaxSession.swift:488-529`). |
| Flush | `flush()` | `Sources/CodeContextKitRetrieval/WaxStore.swift:107-109`, `Sources/CodeContextKitRetrieval/WaxStore.swift:168`, `Sources/CodeContextKitRetrieval/WaxStore.swift:258` | Stages both indexes and commits, increments `flushCount`, then queues scheduled maintenance (`Wax@d4de9d6:Sources/Wax/Orchestrator/MemoryOrchestrator.swift:1539-1557`). |
| Enumerate | `activeFrames()` | `Sources/CodeContextKitRetrieval/WaxStore.swift:100-168` | Reads committed frame metadata for cckit's external SQLite keep-set diff (`Wax@d4de9d6:Sources/Wax/Memory.swift:240-265`). |
| Diagnostics | `storeDiagnostics()` | `Sources/CodeContextKitRetrieval/WaxStore.swift:395-400` | Reports frame and segment liveness, but its path-size fields are stale after the first call in a session; see defect WAX-04 (`Wax@d4de9d6:Sources/Wax/Memory.swift:277-314`). |
| Force maintenance | `runLiveSetMaintenanceNow()` | `Sources/CodeContextKitRetrieval/WaxStore.swift:402-407` | Writes and validates a candidate; it does not replace the source until a later close (`Wax@d4de9d6:Sources/Wax/Memory.swift:317-325`, `Wax@d4de9d6:Sources/Wax/Orchestrator/MemoryOrchestrator+Maintenance.swift:411-517`). |
| Close | `close()` | `Sources/CodeContextKitRetrieval/WaxStore.swift:259` | Flushes, runs another forced rewrite, closes/releases the arena lock, then promotes only that close-time report's candidate (`Wax@d4de9d6:Sources/Wax/Orchestrator/MemoryOrchestrator.swift:1560-1590`, `Wax@d4de9d6:Sources/Wax/Orchestrator/MemoryOrchestrator.swift:1657-1692`). |

### Configuration interaction

cckit selects `LiveSetRewriteSettings.aggressive`: check every four flushes, 32 MiB or 25% dead bytes, no idle delay, 60-second scheduled cooldown, and promote on close (`Sources/CodeContextKitRetrieval/WaxStore.swift:362-392`, `Wax@d4de9d6:Sources/Wax/Maintenance/StoreMaintenancePublic.swift:43-57`). `Memory` converts that to `keepLatestCandidates: 2` and a zero minimum candidate gain (`Wax@d4de9d6:Sources/Wax/Memory.swift:328-355`).

That policy does not protect the delete loop. `delete` calls `session.commit()` directly and never increments `flushCount`, while maintenance is queued only by `flush()` (`Wax@d4de9d6:Sources/Wax/Orchestrator/MemoryOrchestrator.swift:1523-1557`). cckit's normal indexing path produces approximately four public flushes: one after ingestion, two in `compact`, and one inside `close` (`Sources/CodeContextKitContext/Indexer.swift:188-200`, `Sources/CodeContextKitRetrieval/WaxStore.swift:107-109`, `Sources/CodeContextKitRetrieval/WaxStore.swift:168`, `Wax@d4de9d6:Sources/Wax/Orchestrator/MemoryOrchestrator.swift:1560-1562`). The fourth flush can therefore launch a scheduled candidate immediately before close launches a second forced candidate.

The pinned default WAL is 256 MiB, not 4 MiB (`Wax@d4de9d6:Sources/WaxCore/Constants.swift:38-45`, `Wax@d4de9d6:Sources/WaxCore/Wax.swift:462-466`). The 4 MiB value is the *largest WAL eligible for proactive auto-commit*, not the ring size (`Wax@d4de9d6:Sources/WaxCore/WaxOptions.swift:27-33`, `Wax@d4de9d6:Sources/WaxCore/Wax.swift:427-440`). With the 256 MiB default, proactive auto-commit is disabled; emergency capacity commit is also blocked while embeddings are pending and no vector blob is staged (`Wax@d4de9d6:Sources/WaxCore/Wax.swift:279-365`). Thus WAL pressure is not the source of the incident's repeated commits. It is still a separate failure mode: a sufficiently large unflushed embedding batch throws rather than auto-commits.

## Commit cadence in one cckit run

Let `D` be successful recorded/mandate frame deletions and `K` be additional compaction deletions.

1. For each changed file, cckit calls `retractFromWaxAndSQLite`, which loads all recorded frame IDs and calls `memory.delete` once per ID (`Sources/CodeContextKitContext/Indexer.swift:113-123`, `Sources/CodeContextKitContext/Indexer.swift:230-241`, `Sources/CodeContextKitRetrieval/WaxStore.swift:69-78`). This contributes exactly `D` core commits.
2. The first delete stages an FTS blob because `stageForCommit` sees the pending deleted frame and removes it from FTS before serialization (`Wax@d4de9d6:Sources/WaxTextSearch/FTS5SearchEngine.swift:133-167`, `Wax@d4de9d6:Sources/WaxTextSearch/FTS5SearchEngine.swift:764-771`).
3. After that commit, the same public delete method calls `removeText` and `removeVector`, dirtying both engines for the next delete (`Wax@d4de9d6:Sources/Wax/Orchestrator/MemoryOrchestrator.swift:1526-1534`, `Wax@d4de9d6:Sources/WaxTextSearch/FTS5SearchEngine.swift:127-130`, `Wax@d4de9d6:Sources/WaxVectorSearch/AccelerateVectorEngine.swift:93-106`). Consequently delete two and later normally append both full blobs.
4. Saves between file retractions remain pending. The next file's first delete commits those saves as well because `session.commit()` stages pending embeddings and current FTS state (`Wax@d4de9d6:Sources/Wax/WaxSession.swift:428-460`, `Wax@d4de9d6:Sources/Wax/WaxSession.swift:483-529`).
5. End-of-index flush contributes one more commit when saves or post-delete index changes remain (`Sources/CodeContextKitContext/Indexer.swift:188`, `Wax@d4de9d6:Sources/Wax/Orchestrator/MemoryOrchestrator.swift:1539-1557`). Compaction can contribute `K` more per-frame commits plus one trailing flush for the final post-commit index removal (`Sources/CodeContextKitRetrieval/WaxStore.swift:100-168`).
6. `close()` flushes again. A clean session makes this core commit a no-op, but `flushCount` still advances and maintenance is queued (`Wax@d4de9d6:Sources/WaxCore/Wax.swift:1686-1688`, `Wax@d4de9d6:Sources/Wax/Orchestrator/MemoryOrchestrator.swift:1539-1562`).

The usual generation-increasing commit count is therefore approximately `D + K + 1`, not “one incremental commit.” Maintenance observes only the roughly four public flushes, after those commits have already landed.

## Byte accounting and growth model

### Fixed and append-only regions

An arena starts with two 4 KiB header pages followed by the fixed WAL ring (`Wax@d4de9d6:Sources/WaxCore/Constants.swift:21-45`). Creation places the initial TOC/footer at `8 KiB + W`, where `W` defaults to 256 MiB (`Wax@d4de9d6:Sources/WaxCore/Wax.swift:501-554`). The WAL reservation is sparse on APFS, so logical size starts near 256 MiB while allocated size can be much smaller; cckit's direct allocated-byte helper deliberately uses filesystem allocation values (`Sources/CodeContextKitRetrieval/WaxStore.swift:409-430`).

`put` writes each compressed or plain frame payload directly at `dataEnd`, then records its offset in the WAL; the payload is not duplicated by commit (`Wax@d4de9d6:Sources/WaxCore/Wax.swift:890-946`). A commit then appends, in order:

- the full staged lex blob, if dirty;
- the full staged vec blob, if dirty;
- a complete TOC containing every frame meta and every historical segment-catalog entry;
- one 64-byte footer.

The lex/vec and TOC/footer append sites are `Wax@d4de9d6:Sources/WaxCore/Wax.swift:1717-1861`; TOC encoding is full-state at `Wax@d4de9d6:Sources/WaxCore/FileFormat/WaxTOC.swift:89-155`; the footer is fixed at 64 bytes (`Wax@d4de9d6:Sources/WaxCore/Constants.swift:29-36`). The alternate header page is overwritten, not appended (`Wax@d4de9d6:Sources/WaxCore/Wax.swift:3042-3049`).

For `C` commits, a useful logical-growth model is:

```text
S(C) = 8 KiB + W + T0 + 64
     + sum(frame payload bytes written once)
     + sum[j=1...C](dirtyLex[j] * L[j]
                   + dirtyVec[j] * V[j]
                   + T[j] + 64)
```

`L[j]`, `V[j]`, and `T[j]` are full-corpus sizes at commit `j`; `dirtyLex`/`dirtyVec` are 0 or 1. For a steady corpus and `D` one-at-a-time deletes, `L[j]` and `V[j]` shrink slowly, so first-order growth is `D * (L + V + T)`. FTS can occasionally vacuum when at least 30% of its SQLite pages are free, but otherwise serializes the complete database (`Wax@d4de9d6:Sources/WaxTextSearch/FTS5SearchEngine.swift:736-771`).

Allocated growth follows the appended term, not the sparse fixed reservation. This explains why the incident could become fully materialized even though a fresh `.wax` appears large but sparse.

### Accounting gaps

The segment catalog correctly marks every non-current lex/vec entry stale (`Wax@d4de9d6:Sources/WaxCore/Wax.swift:2015-2054`). It does not catalog old TOCs or footers, even though every commit appends them; therefore `staleSegmentBytes` and `reclaimableBytes` undercount total reclaimable data. `StoreDiagnostics.expectedLiveBytes` also omits both the fixed header/WAL region and the current TOC/footer (`Wax@d4de9d6:Sources/Wax/Maintenance/StoreMaintenancePublic.swift:60-93`). Treat it as “live payload plus current index blobs,” not the documented size of a freshly rewritten arena.

In the 64-delete harness, stale segments explained 63.83 MB of roughly 91.69 MB allocated growth. The balance is dominated by repeated full TOCs/footers and filesystem allocation effects; those bytes are absent from `reclaimableBytes`. A breaker must therefore compare fresh actual allocation with a complete rewritten-size estimate or retain a conservative floor, rather than treating `reclaimableBytes == 0` as proof that all excess is fixed overhead (`Sources/CodeContextKitCLI/Commands/IndexCommand.swift:189-207`).

## Reproduction

The harness is a SwiftPM executable using the current pinned Wax product. It uses deterministic local embeddings, creates one corpus flush, resolves frame IDs through public text-search results, then calls the public single-frame delete API repeatedly.

```bash
swift run wax-amplification-harness \
  --documents 256 \
  --deletes 64 \
  --payload-bytes 1024 \
  --sample-every 8
```

Observed on 2026-08-27:

| phase | deletes | logical bytes | allocated bytes | Wax frame count |
|---|---:|---:|---:|---:|
| baseline | 0 | 270,427,860 | 2,846,720 | 512 |
| delete | 8 | 282,054,380 | 14,471,168 | 512 |
| delete | 32 | 316,385,588 | 55,246,848 | 512 |
| delete | 64 | 360,881,044 | 105,594,880 | 512 |
| closed | 64 | 360,881,044 | 105,594,880 | n/a |

To inspect a repository arena through the current public stats API:

```bash
swift run wax-amplification-harness --inspect .cckit/repo.wax
```

Current Wax no longer exposes storage-liveness diagnostics publicly, so the harness records fresh POSIX logical/allocated sizes plus `Memory.stats()`. The allocation result is worse than the old-pin run (37.1x versus 33.3x), confirming that cckit cannot rely on the upstream update alone to bound deletion amplification.

## Maintenance lifecycle

1. Every public flush increments `flushCount` and queues a utility task (`Wax@d4de9d6:Sources/Wax/Orchestrator/MemoryOrchestrator.swift:1539-1557`, `Wax@d4de9d6:Sources/Wax/Orchestrator/MemoryOrchestrator.swift:1613-1654`).
2. A scheduled pass evaluates cadence, cooldown, idle, and the bytes-or-fraction threshold (`Wax@d4de9d6:Sources/Wax/Orchestrator/MemoryOrchestrator+Maintenance.swift:304-409`). The forced path bypasses cadence/cooldown/idle, but not the dead-byte threshold (`Wax@d4de9d6:Sources/Wax/Orchestrator/MemoryOrchestrator+Maintenance.swift:279-301`, `Wax@d4de9d6:Sources/Wax/Orchestrator/MemoryOrchestrator+Maintenance.swift:328-393`).
3. Rewrite commits the source, snapshots all frame metadata and current index blobs, creates a same-WAL-size destination, preserves dense frame IDs, drops only non-live payload bytes, commits once, verifies, and closes the destination (`Wax@d4de9d6:Sources/Wax/Orchestrator/MemoryOrchestrator+Maintenance.swift:162-275`). Deleted/superseded metadata remains in the TOC by design.
4. The candidate is opened and verified again. Success retains it and prunes only candidates older than the newest two (`Wax@d4de9d6:Sources/Wax/Orchestrator/MemoryOrchestrator+Maintenance.swift:455-517`, `Wax@d4de9d6:Sources/Wax/Orchestrator/MemoryOrchestrator+Maintenance.swift:574-600`).
5. `close()` runs `flush()`, then a forced maintenance pass. It retains only that pass's report, closes the source, and promotes only that report's candidate (`Wax@d4de9d6:Sources/Wax/Orchestrator/MemoryOrchestrator.swift:1560-1590`, `Wax@d4de9d6:Sources/Wax/Orchestrator/MemoryOrchestrator.swift:1657-1692`). A candidate created by the just-queued fourth-flush task is not consumed.
6. Promotion uses `replaceItemAt`, requests a `repo.wax.pre-liveset-*` backup, best-effort deletes the backup, and truncates the promoted file to its last footer (`Wax@d4de9d6:Sources/Wax/Orchestrator/MemoryOrchestrator+Maintenance.swift:603-633`). Promotion errors are swallowed, so `close()` can succeed while retaining the original source and candidate (`Wax@d4de9d6:Sources/Wax/Orchestrator/MemoryOrchestrator.swift:1577-1589`).

The public name `runLiveSetMaintenanceNow()` is misleading: it reports candidate gain but does not reclaim source bytes “now”; source replacement is a later close concern (`Wax@d4de9d6:Sources/Wax/Memory.swift:317-325`, `Wax@d4de9d6:Sources/Wax/Orchestrator/MemoryOrchestrator+Maintenance.swift:506-517`). cckit's breaker already waits until post-close to judge actual bytes (`Sources/CodeContextKitCLI/Commands/IndexCommand.swift:123-130`, `Sources/CodeContextKitCLI/Commands/IndexCommand.swift:623-647`).

### Residue invariant and shipped cckit mitigation

The cckit invariant is now: after a successful Wax close plus sweep, or after a deliberate rebuild sweep, `.cckit` contains `repo.wax` and zero regular-file `repo-liveset-*.wax` / `repo.wax.pre-liveset-*` duplicates. The implementation removes only matching regular files, counts only successful removals, and reports failures (`Sources/CodeContextKitRetrieval/WaxResidueSweeper.swift:3-61`). Compact, normal index, and rebuild paths call it while holding `refresh.lock` (`Sources/CodeContextKitCLI/Commands/IndexCommand.swift:385-435`, `Sources/CodeContextKitCLI/Commands/IndexCommand.swift:488-497`, `Sources/CodeContextKitCLI/Commands/IndexCommand.swift:630-637`). Focused filesystem tests cover fresh backups, candidates, unrelated names, and matching directories (`Tests/CodeContextKitRetrievalTests/WaxResidueSweeperTests.swift:5-48`).

The sweep itself is cleanup, not crash recovery. Upstream still creates a new empty arena when the source path is absent because `MemoryOrchestrator` chooses create solely from path existence (`Wax@d4de9d6:Sources/Wax/Orchestrator/MemoryOrchestrator.swift:250-254`). cckit's current pre-open guard restores one unambiguous regular promotion backup and refuses multiple candidates; Wax still needs a journaled promotion/recovery protocol.

## Multi-process contract

Wax does enforce a single opener, but not safely enough for replace/unlink workflows:

- `Wax.open` always requests an exclusive `flock`; `Memory` always creates a read-write session (`Wax@d4de9d6:Sources/WaxCore/Wax.swift:633-638`, `Wax@d4de9d6:Sources/Wax/Orchestrator/MemoryOrchestrator.swift:282-291`). There is no public read-only `Memory` mode.
- `lockWaitTimeout` exists only in package-internal `WaxOptions` and defaults to `nil`, so a second cckit opener can block indefinitely (`Wax@d4de9d6:Sources/WaxCore/WaxOptions.swift:3-35`, `Wax@d4de9d6:Sources/WaxCore/IO/FileLock.swift:42-49`). `StoreLockProbe` is also package-internal (`Wax@d4de9d6:Sources/Wax/StoreLockProbe.swift:4-27`).
- `CodeContextServer.run` opens one `WaxStore` for the whole server lifetime (`Sources/CodeContextKitServer/Server.swift:77-84`). A normal CLI index can therefore wait forever on Wax's arena lock even after it successfully acquires cckit's separate refresh lock.
- The incident implementation let `--clean` unlink `repo.wax` before attempting to open Wax. POSIX advisory locking does not prevent unlink: a running server could keep writing the old unlinked inode while the CLI created a new path. The refresh lock did not help because the server held it only around dashboard reindex, not around its lifetime (`Sources/CodeContextKitServer/Server.swift:253-278`).
- Wax releases the arena's inode lock before `replaceItemAt` promotion (`Wax@d4de9d6:Sources/Wax/Orchestrator/MemoryOrchestrator.swift:1573-1582`). A waiting process opened the old inode before waiting (`Wax@d4de9d6:Sources/WaxCore/IO/FileLock.swift:42-49`); after it acquires that old-inode lock, it separately opens the path for I/O (`Wax@d4de9d6:Sources/WaxCore/Wax.swift:633-640`). Promotion can swap the pathname between those operations, leaving the process writing a new inode while holding a lock on the old one.

cckit now uses a stable `repo.wax.lock` inode that is never replaced with the arena, acquires it before any rebuild deletion, holds it for the `WaxStore` lifetime, and fails immediately with the lock path on contention. Wax should still adopt the same invariant internally across open, close-time promotion, backup cleanup, and final directory sync so non-cckit consumers are protected too.

## Crash safety

Core commit ordering is sound for the states it covers:

1. Apply pending WAL mutations in memory and append staged index blobs.
2. Append full TOC.
3. Append footer.
4. `fsync` the arena.
5. write the alternate checksummed header page.
6. final `fsync`, checkpoint WAL, then clear pending state.

The implementation and injection points are `Wax@d4de9d6:Sources/WaxCore/Wax.swift:1686-1861`. Headers are mirrored 4 KiB pages with checksums (`Wax@d4de9d6:Sources/WaxCore/FileFormat/WaxHeaderPage.swift:101-175`). Open uses the header footer, optional replay-snapshot footer, and a tail scan, selects the newest valid generation, replays WAL newer than the recovered footer, validates pending payload checksums, and truncates invalid trailing bytes (`Wax@d4de9d6:Sources/WaxCore/Wax.swift:640-803`).

Crash outcomes are:

| checkpoint | recoverable state |
|---|---|
| before a valid new footer | old footer wins; durable newer WAL is replayed; unreferenced staged index/TOC tail is truncated (`Wax@d4de9d6:Sources/WaxCore/Wax.swift:783-803`). |
| valid footer durable, header stale | tail scan finds the newer footer and updates recovered header state (`Wax@d4de9d6:Sources/WaxCore/Wax.swift:648-713`). |
| alternate header written, final fsync absent | old header remains valid; the already-fsynced footer is recoverable by scan (`Wax@d4de9d6:Sources/WaxCore/Wax.swift:1831-1848`). |
| orderly close with dirty core state | core close attempts a commit before closing and prioritizes any commit error (`Wax@d4de9d6:Sources/WaxCore/Wax.swift:2985-3015`). |

Wax has a subprocess crash harness for TOC, post-footer-fsync, and header checkpoints (`Wax@d4de9d6:Sources/WaxCrashHarness/main.swift:24-47`, `Wax@d4de9d6:Sources/WaxCrashHarness/main.swift:97-130`), but its normal test is opt-in and omits `after_footer_write_before_fsync` (`Wax@d4de9d6:Tests/WaxCoreTests/CrashSafetyHarnessTests.swift:17-29`).

The higher-level index transaction is incomplete. Frame payload/meta and embeddings are represented in Wax/WAL, and vector recovery explicitly replays pending embeddings into its engine (`Wax@d4de9d6:Sources/Wax/WaxSession.swift:508-529`). FTS upsert/delete operations live only in the temporary SQLite engine until a staged blob commits; loading from Wax reads only the last committed lex blob and does not reconstruct pending active frame text (`Wax@d4de9d6:Sources/WaxTextSearch/FTS5SearchEngine.swift:55-89`, `Wax@d4de9d6:Sources/WaxTextSearch/FTS5SearchEngine.swift:96-130`). A crash before the new footer can therefore recover a frame/vector but omit that frame from text search. cckit's normal semantic path is vector-only, but mandate cleanup uses text search (`Sources/CodeContextKitRetrieval/WaxStore.swift:185-198`, `Sources/CodeContextKitRetrieval/WaxStore.swift:433-447`). Wax should add high-level crash tests and rebuild FTS from recovered frame `searchText`, or WAL the text-index mutation as part of the same transaction.

Promotion is a second, less protected transaction. There is no durable marker around source-to-backup and candidate-to-source replacement; backup deletion is best effort and post-replacement truncation happens afterward (`Wax@d4de9d6:Sources/Wax/Orchestrator/MemoryOrchestrator+Maintenance.swift:614-633`). Recovery must explicitly recognize source/candidate/backup combinations before normal open.

## Defect table

| ID | Symptom | Root cause | Owner | Fix | Severity |
|---|---|---|---|---|---|
| WAX-01 | One incremental run can append hundreds of GB | `Memory.delete` commits per frame; each commit stages full dirty indexes (`MemoryOrchestrator.swift:1523-1534`, `WaxSession.swift:428-460`) | Wax primary; cckit consumer | Add transactional batch delete; change single delete to update indexes before one atomic commit; make cckit call the batch API | Critical |
| WAX-02 | Full lex/vec corpus duplicated per commit | Index formats are monolithic serialized blobs and commit is append-only (`FTS5SearchEngine.swift:736-771`, `Wax.swift:1717-1786`) | Wax | Add immutable delta segments plus periodic merge, or overwrite/rewrite index storage outside the append log | High |
| WAX-03 | Scheduled `repo-liveset-*` duplicates survive normal close | fourth-flush task and forced close rewrite produce separate reports; close promotes only the latter (`MemoryOrchestrator.swift:1539-1557`, `MemoryOrchestrator.swift:1657-1692`) | Wax; cckit cleanup shipped | Reuse a generation-matched validated candidate at close, delete stale candidates, retain cckit post-close sweep defensively | High |
| WAX-04 | Diagnostics report frozen file/allocated size mid-session | `URL.resourceValues` is read through the stored URL and returns cached size values (`Memory.swift:282-301`); harness contrasts it with `stat` | Wax | Use uncached `stat`/`fstat` and add a growth-with-open-handle test | High |
| WAX-05 | Incidents lack commit/WAL counters | `WaxWALStats` includes pending bytes, writes, wraps, checkpoints, and auto-commits but is package-only (`Wax.swift:38-78`, `Wax.swift:2816-2831`) | Wax | Public immutable runtime stats DTO through `Memory`; include explicit commit count and bytes appended by category | High |
| WAX-06 | `deleted == 0` is reported as “nothing to reclaim” after real shrink | cckit stamp requires `deleted > 0`; stale segments are not frame deletions (`WaxStore.swift:668-689`, `IndexCommand.swift:498-523`) | cckit | Base success/report/stamp on pre-close reclaimable bytes and verified post-close shrink, not frame deletion count | Medium |
| WAX-07 | `reclaimableBytes` misses some real garbage | old TOCs/footers append every commit but are absent from the segment catalog (`Wax.swift:1788-1861`, `StoreMaintenancePublic.swift:83-92`) | Wax | Account fixed/current TOC and stale TOC/footer generations; expose complete predicted rewrite size | Medium |
| WAX-08 | CLI/server can hang, split onto different inodes, or bypass locks during promotion | indefinite exclusive lock on replaceable arena inode; `--clean` formerly unlinked before open; promotion occurs after upstream unlock (`FileLock.swift:42-49`, `MemoryOrchestrator.swift:1573-1582`) | Wax and cckit | cckit stable sidecar lease and bounded failure shipped; Wax still needs a public stable lock/read-only contract across promotion | Critical upstream; cckit mitigated |
| WAX-09 | Core frame recovery can disagree with text search after crash | FTS mutations are not WAL-reconstructed while embeddings are (`FTS5SearchEngine.swift:55-130`, `WaxSession.swift:508-529`) | Wax | WAL text operations or rebuild FTS from frame metadata on recovery; high-level crash matrix | High |
| WAX-10 | “maintenance now” reports reclaimed bytes before source shrinks | public call creates a validated candidate; replacement occurs only at close (`Memory.swift:317-325`, `MemoryOrchestrator+Maintenance.swift:411-517`) | Wax | Rename/report candidate semantics or offer an atomic reclaim-and-reopen API | Medium |
| WAX-11 | Crash during promotion can leave ambiguous source/backup/candidate state | no promotion journal; backup cleanup is best effort (`MemoryOrchestrator+Maintenance.swift:603-633`) | Wax; cckit interim recovery | Journal state plus directory fsync and deterministic open-time recovery; cckit restore sole backup if source is absent | High |
| WAX-12 | Long-lived store TOC grows with all historical tombstones | rewrite preserves dense IDs and copies every frame meta, dropping only non-live payload (`MemoryOrchestrator+Maintenance.swift:189-245`) | Wax | Document/accept for v1; design ID indirection/remap in a future format | Low |

Wax paths in the table are relative to `Wax@d4de9d6:Sources/...`; cckit paths are relative to this repository.

## Prioritized fix plan

### cckit-owned work

1. **Shipped:** pin current Wax `3405b8c`, adopt its `Config.embedding` API, and remove the obsolete standalone MiniLM product dependency.
2. **Shipped:** remove every indexing/compaction call to `Memory.delete`; preflight hashes and source membership, retain the arena for no-op runs, and replace it once for any semantic change.
3. **Shipped:** treat `--compact`, an embedder mismatch, or a breach marker as a full derived-index rebuild before opening the old arena.
4. **Shipped:** clear old Wax bookkeeping at rebuild start and retain mandate-only rows because current `Memory.save` returns `Void`.
5. **Shipped:** retain the fresh-filesystem mid-run cap and sweep candidate/backup residue after successful close and deliberate rebuild.
6. **Shipped:** hold a stable `repo.wax.lock` lease for every cckit `WaxStore` lifetime, acquire it before rebuild deletion, fail immediately on contention, and retain the lease across reset/reopen.
7. **Shipped:** restore a sole regular promotion backup before opening a missing arena; refuse to guess when multiple backups survive.
8. **Still open upstream:** Wax itself should adopt stable locking across its promotion transaction and expose read-only/bounded-wait modes. Non-cckit Wax consumers do not receive cckit's sidecar guarantee.

### Upstream observations (not cckit-owned)

The highest-value upstream improvements remain batch delete, stable sidecar locking across promotion, public bounded lock acquisition, complete uncached storage telemetry, and crash-recoverable promotion. cckit should consume those capabilities if Wax publishes them, but this repository does not patch or fork Wax to obtain them.

### Release checklist

1. Verify `Package.swift` and `Package.resolved` contain the same immutable Wax SHA.
2. Run the current-pin amplification harness and retain its output as upstream behavior evidence.
3. Run focused semantic rebuild/no-op/deletion/lease/recovery tests, `swift build`, full `swift test`, and `uv run --with 'mcp>=1.0,<2' python mcp/test_cckit_mcp.py`.
4. Smoke-test clean index, no-op index, one-file edit, deleted file, `--compact` rebuild, semantic search, and residue absence.
5. Record the Wax and cckit SHAs in release notes.

## Audit-time verification

- Focused residue/lease/recovery test: `swift test --filter WaxResidueSweeperTests` — passed, 5 tests.
- Amplification harness: command and measured output recorded above.
- `swift build` — passed.
- `swift test --skip-build` — passed: 137 XCTest cases plus 5 Swift Testing cases, 0 failures.
- Isolated CLI smoke — first index rebuilt Wax, unchanged index skipped all four files without rebuilding, and `--compact` rebuilt the derived arena; no live-set residue remained.
- MCP shim: `uv run --with 'mcp>=1.0,<2' python mcp/test_cckit_mcp.py` — passed, 112 tests.
