# CCKit token-efficiency audit — 7 September 2026

**Recommendation:** optimize tokens spent to complete a task correctly. Fix retrieval correctness and delivery accounting before adding more compression. The current implementation can make a packet smaller by losing requested evidence, and can report deduplication savings while increasing the response size.

Audited `d080e7e` on `cckit-improvements`. Product source was unchanged. Scope: packing, identifier and semantic retrieval, symbol extraction/resolution, freshness, MCP response shaping and deduplication, token accounting, maps, scanning, and benchmarks. Semantic ranking observations below are code inspection; the runtime probes used a separate lexical-only fixture. This was not an evaluation of embedding quality across production repositories.

The release build passed. Thirty focused Swift tests passed. All 112 shim unit tests passed with `CCKIT_BIN=/usr/bin/false` to isolate unmocked external CLI calls. An initial unisolated shim run was stopped when unit tests invoked slow semantic searches against the workspace. Separate fixture probes exercised the real release CLI and MCP functions.

Numbers labeled **CCKit estimate** use the shipped estimator. Numbers labeled **o200k** use `tiktoken`'s `o200k_base` encoding on the specified strings; these are not provider billing measurements. Detailed results are in [the evidence file](/Users/christopherlarsen/Workspace/CodeContextKit/docs/token-efficiency-audit-2026-09-07-evidence.json).

## Confirmed bugs

### 1. P1 — Auto mode chooses incomplete or empty packets over useful ones

**Reproduced.** With a large file containing a small `targetMethod`, `--surgical --budget 2000` returned the implementation in **627 estimated tokens**. The identical task in default auto mode selected a **72-estimated-token raw packet with zero primaries**. A second task requesting that method and a method in a small file returned both in surgical mode, but only the small file in auto mode.

Each mode independently drops whatever does not fit. Auto then compares their token counts without requiring equivalent coverage. The raw candidate is cheap precisely because the large file was dropped. The zero-result probe compounds this by advising a larger budget even though surgical context already fit.

Evidence: [candidate comparison](/Users/christopherlarsen/Workspace/CodeContextKit/Sources/CodeContextKitContext/ContextPacker.swift:223), [minimum selection](/Users/christopherlarsen/Workspace/CodeContextKit/Sources/CodeContextKitContext/ContextPacker.swift:273), [raw budget rejection](/Users/christopherlarsen/Workspace/CodeContextKit/Sources/CodeContextKitContext/ContextPacker.swift:651).

**Fix:** select targets once, then compare representations that cover the same required targets. An incomplete candidate must not beat a complete one on size. Test both zero-primary and partial-primary cases, with target identities rather than just packet size assertions.

### 2. P1 — Indexed offsets can return unrelated current text as a symbol body

**Reproduced with actual refresh locking, without a mocked read path.** After inserting 15 lines above an indexed method, `symbol` returned three inserted comment lines as that method's implementation. With the refresh lock held to model an index in progress, the response's refresh metadata said `stale: false`, because HEAD had not changed.

There is also a persistent case: index an uncommitted version, then restore the file to HEAD. The dirty-path list becomes empty, `working_tree_needs_index` returns false, and freshness reports current. The fixture then returned an empty body at obsolete lines 17–19 for a method now at lines 2–4.

Evidence: [disk read using stored offsets](/Users/christopherlarsen/Workspace/CodeContextKit/Sources/CodeContextKitCLI/Commands/SymbolCommand.swift:185), [range extractor](/Users/christopherlarsen/Workspace/CodeContextKit/Sources/CodeContextKitCore/LineRangeBodyExtractor.swift:4), [dirty-path-only check](/Users/christopherlarsen/Workspace/CodeContextKit/mcp/cckit_mcp.py:1656), [HEAD-only freshness](/Users/christopherlarsen/Workspace/CodeContextKit/mcp/cckit_mcp.py:1692). Packing uses the same stored-range/current-content combination.

**Fix:** validate the current content hash before slicing. If changed, parse that file locally and resolve the symbol against the new parse; semantic re-embedding can remain asynchronous. Freshness must describe the indexed file contents, including reversions to a clean worktree.

### 3. P1 — More precise identifiers can retrieve less precise context

**Reproduced.** `--task targetMethod --surgical --budget 2000` returned the body. `--task BigAuditService.targetMethod` returned zero primaries and suggested about **6,405 estimated tokens**. `--task 'targetMethod secondTarget'` returned only the first body, despite both fitting easily.

The tokenizer splits qualified names on dots. It considers the enclosing type first, then rejects the explicitly named method because that file already has a primary. Independently, the one-primary-per-file rule suppresses a second explicitly requested method. The same-leaf-name rule can also suppress explicitly named implementations in different types.

Evidence: [identifier splitting](/Users/christopherlarsen/Workspace/CodeContextKit/Sources/CodeContextKitRetrieval/SemanticIndexPolicy.swift:80), [one primary per file](/Users/christopherlarsen/Workspace/CodeContextKit/Sources/CodeContextKitContext/ContextPacker.swift:504), [one primary per leaf](/Users/christopherlarsen/Workspace/CodeContextKit/Sources/CodeContextKitContext/ContextPacker.swift:538).

**Fix:** resolve exact qualified names before token decomposition. Preserve all explicitly requested targets; use file diversity only for optional discovery hits. Merge overlapping body ranges instead of dropping distinct requested bodies.

### 4. P1 — Symbol delivery silently loses overloads and extensions

**Reproduced.** A fixture with `processValue(Int)` and `processValue(String)` returned only the integer overload for `symbol OverloadService.processValue`. Fetching the enclosing type omitted its extension. Neither response disclosed the missing declaration.

The database retains multiple declaration ranges, but the CLI discards subsequent records with the same qualified name. Function qualified names do not encode their signatures. Semantic retrieval also deduplicates by qualified name and resolves a hit using the first matching SQLite declaration, ignoring the hit's file.

Evidence: [delivery deduplication](/Users/christopherlarsen/Workspace/CodeContextKit/Sources/CodeContextKitCLI/Commands/SymbolCommand.swift:40), [exact resolver returns multiple declarations](/Users/christopherlarsen/Workspace/CodeContextKit/Sources/CodeContextKitRetrieval/SymbolRanking.swift:365), [semantic deduplication](/Users/christopherlarsen/Workspace/CodeContextKit/Sources/CodeContextKitRetrieval/WaxStore.swift:174), [semantic hit resolution](/Users/christopherlarsen/Workspace/CodeContextKit/Sources/CodeContextKitContext/ContextPacker.swift:559). The semantic consequences are inspection-verified, not separately reproduced against Wax.

**Fix:** distinguish declaration identity from display name. Preserve file, declaration range, and signature/overload identity; either return the requested declarations or offer compact ambiguity choices. Deduplicate actual overlapping content, not names.

### 5. P2 — Preview mode includes bodies and double-counts a hit

**Reproduced.** `pack --task targetMethod --preview` printed “Bodies omitted” and then the complete function body. Its banner counted two symbols for one target.

Preview emits its hit list, then falls through to the surgical body branch because that branch is the `else` for full/raw. The primary counter is incremented in both places.

Evidence: [preview assembly](/Users/christopherlarsen/Workspace/CodeContextKit/Sources/CodeContextKitContext/ContextPacker.swift:614), [fallthrough](/Users/christopherlarsen/Workspace/CodeContextKit/Sources/CodeContextKitContext/ContextPacker.swift:644).

**Fix:** make preview a terminal assembly path. Verify the actual CLI/MCP output contains no bodies and counts each hit once. The existing preview test mocks the packet and only checks argument forwarding.

### 6. P2 — The token ceiling is not enforced on the final response

**Reproduced.** Ten error lines, each below the existing 500-character per-line cap, produced a **1,905-estimated-token banner at a 512-token budget**; the final output measured **1,101 o200k tokens**. A long task also overran the preview budget. Task text, failure summaries, preview rows, replacement banners, and later warnings are not all covered by a final ceiling check.

The estimator has a separate correctness defect: **2,400 Chinese characters were estimated as 1 token**, versus **1,500 o200k tokens**. Its word regex matches ASCII letters and numbers, leaving other letters uncounted.

Evidence: [unbudgeted task](/Users/christopherlarsen/Workspace/CodeContextKit/Sources/CodeContextKitContext/ContextPacker.swift:492), [failure summary](/Users/christopherlarsen/Workspace/CodeContextKit/Sources/CodeContextKitContext/ContextPacker.swift:597), [banner recount without trimming](/Users/christopherlarsen/Workspace/CodeContextKit/Sources/CodeContextKitContext/ContextPacker.swift:790), [estimator](/Users/christopherlarsen/Workspace/CodeContextKit/Sources/CodeContextKitCore/TokenEstimator.swift:29).

**Fix:** use one model/encoding-aware counter through the final serialization boundary. Reserve room for metadata and warnings; allocate a total failure-summary budget. Provide a conservative Unicode-aware fallback when the target tokenizer is unavailable.

### 7. P2 — Raw fallback removes requested evidence and file identity

**Reproduced.** A small-symbol task with `--failure build.log` silently lost the failure summary. The final fallback also removes per-file paths and fences, concatenating source contents below a banner. Even after discarding that information, the fixture still cost **58 estimated tokens versus a 34-token source baseline**, contradicting the documented guarantee that auto cannot lose to whole files.

Evidence: [failure log dropped](/Users/christopherlarsen/Workspace/CodeContextKit/Sources/CodeContextKitContext/ContextPacker.swift:408), [raw-minimal formatting](/Users/christopherlarsen/Workspace/CodeContextKit/Sources/CodeContextKitContext/ContextPacker.swift:459).

**Fix:** retain file attribution and requested diagnostic evidence in every representation. Allow an honest small formatting cost instead of deleting useful context to pursue an impossible zero-overhead baseline.

### 8. P2 — MCP conceals truncation and its gather miss detector matches the task echo

**Reproduced.** The partial auto packet above reached MCP with only `text` and `savings`; the agent received no indication that a requested primary was dropped. The CLI writes the warning to stderr and `PACK_STATS`; success stderr is hidden, and the shim strips the stats without preserving `droppedPrimaries`.

A query for `NonexistentService` was not classified as a gather miss, because the echoed `## Task` contained the name. Checking the whole packet for query text cannot distinguish a retrieval hit from a repeated request.

Evidence: [CLI truncation warning](/Users/christopherlarsen/Workspace/CodeContextKit/Sources/CodeContextKitCLI/Commands/PackCommand.swift:221), [stats consumption](/Users/christopherlarsen/Workspace/CodeContextKit/mcp/cckit_mcp.py:2133), [miss detector](/Users/christopherlarsen/Workspace/CodeContextKit/mcp/cckit_mcp.py:725).

**Fix:** carry selected, delivered, and omitted target IDs plus omission reasons in structured results. Put a short omission notice in the rendered text. Detect absence from retrieval results, never from free-text substring searches.

### 9. P2 — Deduplication can spend tokens, cannot deduplicate across tools, and gives an unusable gather retry instruction

**Reproduced.** Repeating a small symbol grew the complete JSON response from **120 to 163 o200k tokens**, while `dedupSavedTokens` claimed **14 saved**. The code replaces even tiny bodies and credits their whole estimated size without subtracting the stub and added metadata.

Gathering a method and then fetching it with `symbol` delivered the body twice: the two tools use different fingerprint keys. Gather deduplication only recognizes `SYMBOL` sections, so full-file and raw outputs are outside that mechanism. Gather stubs tell the agent to pass `refresh=true`, but `gather_code_context` has no such argument.

Inspection also found `load_delivery_ledger` has no production caller. Restart-retention benchmarks manually call it, so they do not demonstrate automatic restoration by the shipped server. Any persistence fix needs a conversation/context-generation scope: a repository-wide fingerprint alone does not prove a new agent has seen the body.

Evidence: [symbol stubbing/accounting](/Users/christopherlarsen/Workspace/CodeContextKit/mcp/cckit_mcp.py:818), [gather identity](/Users/christopherlarsen/Workspace/CodeContextKit/mcp/cckit_mcp.py:973), [gather API](/Users/christopherlarsen/Workspace/CodeContextKit/mcp/cckit_mcp.py:2061), [unused loader](/Users/christopherlarsen/Workspace/CodeContextKit/mcp/cckit_mcp.py:868).

**Fix:** compare the complete original and replacement payloads; stub only if net tokens decrease. Share content/range identities across tools, support refresh consistently, and scope delivery memory to a known conversation context, resetting it after context loss.

### 10. P2 — Literal search can silently hide matches or change semantics

**Reproduced.** A file with 75 matching lines reported only 40 total and `truncated: false`, because ripgrep has a hidden per-file cap. Across three files, another query reported 75 total, showed 50, and still reported `truncated: false`. With ripgrep unavailable, a literal `a.b` query also matched `axb`; the Python fallback always compiles the query as a regex. That fallback also does not apply the requested include glob.

Evidence: [ripgrep cap](/Users/christopherlarsen/Workspace/CodeContextKit/mcp/cckit_mcp.py:1146), [truncation and fallback handling](/Users/christopherlarsen/Workspace/CodeContextKit/mcp/cckit_mcp.py:1315).

**Fix:** distinguish exact totals from lower bounds and flag every truncation source. Escape literal fallback queries, honor the include filter, and surface subprocess/regex failures as errors rather than clean misses.

## Further inspection findings

- **`map --changed` can return the whole map for an empty diff.** An empty changed-path set bypasses the filter. The focus implementation also searches names/docs although the MCP argument advertises path/module focus. [Filtering](/Users/christopherlarsen/Workspace/CodeContextKit/Sources/CodeContextKitContext/RepoMapBuilder.swift:38), [focus](/Users/christopherlarsen/Workspace/CodeContextKit/Sources/CodeContextKitContext/RepoMapBuilder.swift:131).
- **The history benchmark does not measure pack recall.** It creates maps and tests whether an entire focus string appears, despite the README table advertising pack tokens and file recall. It checks out commits in the supplied repository, ignores shell exit status, and restores only on normal completion; a detached starting HEAD restores to `main`, not the starting commit. Fix this before using it for the proposed evaluation. [Benchmark](/Users/christopherlarsen/Workspace/CodeContextKit/Sources/CodeContextKitCLI/Commands/HistoryBenchmarkCommand.swift:54).
- **Regex-indexed languages do not have trustworthy implementation spans.** JS/TS/Java matches get `endLine == startLine`, so `symbol` returns a declaration line as a body. Return an explicit locator-only capability for these languages until structural extraction is available. [Regex extraction](/Users/christopherlarsen/Workspace/CodeContextKit/Sources/CodeContextKitCore/RegexSplitter.swift:62).
- **Scanning does not implement full gitignore semantics.** Only the root ignore file is read; negations are discarded. This can miss intended source and include generated files excluded by nested ignore files, lowering retrieval quality and increasing irrelevant context. [Ignore loading](/Users/christopherlarsen/Workspace/CodeContextKit/Sources/CodeContextKitCore/FileScanner.swift:132).

## Improvements in implementation order

1. **Establish a correctness contract for every packet.** Resolve once; record required targets, optional neighbors, source hashes, and omission reasons. Rendering chooses representations of that same evidence. Fix findings 1–8 against this contract. Smaller output counts as an improvement only when it preserves the needed evidence.

2. **Make exact requests substantially cheaper.** The fixture's target body was **26 o200k tokens**; the surgical packet was **333**. Body plus path and fence was **40**. This is a formatting comparison, not a demonstrated 88% task-level saving, but it identifies a large cost to test. Exact-name tasks should usually return a compact qualified-name/path header and body. Move repeated packing guidance to tool instructions. Include neighbor names, repository maps, docs, and broad skeletons only when they help the task. Replace the blanket “files up to 100 lines are whole” rule with actual candidate token costs.

3. **Make progressive retrieval reliable.** Repair preview, then return a short ranked candidate list with stable IDs, ranges, costs, and match reasons. Allow a batch expansion by those IDs without rerunning discovery. Add explicit symbol/path inputs for already-known targets. For multi-symbol work, union overlapping ranges and include narrowly relevant declarations, constants, or dependency signatures rather than complete files.

4. **Improve lexical coverage before increasing semantic fill.** Query existing symbol names even when they are ordinary words such as `Cache`, `load`, or `retry`; do not require CamelCase to discover a real exact match. Preserve qualified names. Add a measured lexical ranking path over names, split identifier words, paths, signatures, and docs, then blend semantic candidates where lexical evidence is weak. Use file/type provenance and explicit target coverage for ranking; do not simply fill five slots. Associated skeletons currently come from references across each whole primary file and dictionary iteration, so restrict them to relevant ranges and rank them deterministically.

5. **Implement net-positive, shared delivery deduplication.** Coordinate symbol, gather, full-file, and outline deliveries using source revision and content/range identity. Suppress only content known to remain in this agent's context. Keep short content verbatim when a stub would cost more. Return a changed range or full refreshed body when needed. Distinguish metadata-only outlines from bodies; one does not replace the other.

6. **Measure final task cost and quality, not only whole-file compression.** Record the final MCP payload after all enrichment and stubbing, tool-call arguments, retries, misses, and whether retrieved evidence was used. Keep whole-file compression as a clearly named secondary metric. The present ledger is not a session-cost estimate: it measures pre-shim output, uses a whole-file counterfactual per call, and excludes zero-primary/preview calls from pack savings. Repeated calls for one file can repeatedly credit that whole file. Failed and empty retrieval still cost tokens even when it is appropriate to exclude them from a compression percentage.

7. **Add offline task-level evaluation.** Compare CCKit with competent `rg` plus narrow file reads on the same tasks. Include exact symbols, multi-file fixes, overloads, stale worktrees, prose queries, failure logs, and repeated retrieval. Measure required-symbol recall, task correctness, total tokens to completion, follow-up calls, and latency. Use held-out historical tasks against pre-fix snapshots, not maps of already-fixed code. Count both baseline runs offline without sending both outputs into a live agent conversation. Report tokenizer identity and separate cached/uncached usage when available.

The eight registered tool schemas alone serialized to approximately **3,011 o200k tokens** in the local SDK probe, before server instructions. How much enters a model's context depends on the client; verify actual client traces rather than assuming this entire cost is charged on every turn. Likewise, the SDK returns text plus structured content, but this audit did not establish that clients feed both representations to the model.

The workspace's retained telemetry was too small and incomplete for a credible end-to-end savings claim: one pack-savings row and 79 action rows, including possible audit activity. The next useful benchmark should answer **“How many tokens did the agent spend to finish correctly?”**, with packet size as a diagnostic rather than the objective.
