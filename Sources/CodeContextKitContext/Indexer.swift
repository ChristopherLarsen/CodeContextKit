import Foundation
import CodeContextKitCore
import CodeContextKitStorage
import CodeContextKitRetrieval

/// Delegate protocol for monitoring the progress of the indexing process.
/// Verified by: `IndexerTests.testIncrementalIndexing`
public protocol IndexerProgressDelegate: Sendable {
    /// Called when indexing starts with the total number of files to be processed.
    func indexerDidStart(totalFiles: Int)
    
    /// Called as each file is processed.
    func indexerDidProgress(completedFiles: Int, totalFiles: Int, currentFile: String)
    
    /// Called when indexing completes successfully.
    func indexerDidFinish(updated: Int, skipped: Int, totalSymbols: Int)
    
    /// Called if the indexing process encounters a fatal error.
    func indexerDidFail(error: Error)
}

public enum IndexerError: LocalizedError {
    /// The arena crossed its mid-run growth cap. Aborting while the bytes are
    /// still being written beats the post-hoc bloat veto, which can only arm a
    /// marker after 186 GB are already on disk.
    case arenaGrowthCapExceeded(allocatedBytes: Int, capBytes: Int)

    public var errorDescription: String? {
        switch self {
        case .arenaGrowthCapExceeded(let allocated, let cap):
            return "Aborting index run: repo.wax reached \(allocated)B materialized, over the mid-run cap of \(cap)B. " +
                "Run 'cckit index . --clean' to rebuild from scratch."
        }
    }
}

/// The core engine responsible for scanning the filesystem, extracting symbols, and persisting them to the database and vector store.
///
/// `Indexer` coordinates the entire indexing pipeline:
/// 1. Scans the filesystem for relevant files using `FileScanner`.
/// 2. Hashes file content to support incremental updates.
/// 3. Routes files to the appropriate `CodeSplitter`.
/// 4. Persists extracted symbols and references to the `Database`.
/// 5. Populates the `WaxStore` with symbol bodies for semantic search.
///
/// `wax` may be nil for lexical-only indexing (`--no-semantic`): locators are
/// all SQLite-backed and need no arena, so a team can skip the ~18-minute
/// embedding pass and the arena's disk cost entirely.
///
/// Verified by: `IndexerTests`, `WebContextTests.testWebProjectIndexing`
public final class Indexer: Sendable {
    private let db: Database
    private let wax: WaxStore?

    public init(db: Database, wax: WaxStore?) {
        self.db = db
        self.wax = wax
    }
    
    public func index(
        at path: String,
        include: [String] = [],
        exclude: [String] = [],
        includeBuildScripts: Bool = false,
        includeGenerated: Bool = false,
        maxArenaBytes: Int? = nil,
        forceWaxRebuild: Bool = false,
        cckitDir: String = ".cckit",
        delegate: IndexerProgressDelegate? = nil
    ) async throws -> WaxCompactResult {
        let absolutePath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let scanner = FileScanner()
        let hasher = FileHasher()
        let settings = ProjectSettings.load(projectRoot: absolutePath)
        let effectiveExclude = Array(Set(settings.excludedFolders + exclude))
        let effectiveIncludeFolders = settings.includedFolders
        let languageRegistry = SourceLanguageRegistry.default

        let files = scanner.scan(
            at: absolutePath,
            include: include,
            exclude: effectiveExclude,
            includeFolders: effectiveIncludeFolders,
            includeBuildScripts: includeBuildScripts,
            includeGenerated: includeGenerated,
            policies: languageRegistry.scanPolicies
        )
        let scannedRelativePaths = Set(files.map { fileURL in
            relativePath(for: fileURL, rootPath: absolutePath)
        })
        delegate?.indexerDidStart(totalFiles: files.count)

        // Wax returns no frame IDs and exposes no batch-delete; cckit cannot
        // retract arena documents. So a run either REPLACES the arena (only
        // when the delta is large or the store is suspect) or APPENDS
        // incrementally: changed files re-save their rows and append fresh
        // documents, stale twins leak until the next rebuild, bounded by
        // WaxDeltaPolicy's growth margin. No-op runs retain the arena and the
        // fast SQLite hash skip either way. Lexical-only runs have no arena
        // and no delta concept at all.
        let existingFiles = try db.getAllFiles()
        let existingByPath = Dictionary(uniqueKeysWithValues: existingFiles.map { ($0.path, $0) })
        let previousWaxRecordCount = try db.waxFrameCount()
        var contentByPath: [String: String] = [:]
        contentByPath.reserveCapacity(files.count)
        var changedPaths = Set<String>()
        var uncoveredPaths = Set<String>()
        for fileURL in files {
            let relativePath = relativePath(for: fileURL, rootPath: absolutePath)
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            contentByPath[relativePath] = content
            guard let existing = existingByPath[relativePath] else { continue }
            if existing.sha256 != hasher.hash(content: content) {
                changedPaths.insert(relativePath)
            } else if wax != nil, try !db.hasWaxCoverage(path: relativePath) {
                // A prior rebuild did not finish this file, or this is the
                // first run after coverage markers were introduced. Retry the
                // file instead of treating its SQLite hash as enough.
                uncoveredPaths.insert(relativePath)
            }
        }
        let newPathCount = scannedRelativePaths.subtracting(existingByPath.keys).count
        let removedPathCount = Set(existingByPath.keys).subtracting(scannedRelativePaths).count
        let deltaFileCount = changedPaths.count + uncoveredPaths.count + newPathCount + removedPathCount

        let deltaDecision: WaxDeltaPolicy.Decision?
        if let wax {
            deltaDecision = WaxDeltaPolicy.evaluate(
                forceRebuild: forceWaxRebuild,
                deltaFileCount: deltaFileCount,
                stampAllocatedBytes: WaxCompactStamp.readWatermark(cckitDir: cckitDir)?.waxBytes ?? 0,
                arenaAllocatedBytes: await wax.allocatedBytes(),
                arenaFrameCount: await wax.frameCount(),
                keepSetMandateCount: (try? db.waxMandateCount()) ?? 0,
                maxFiles: WaxDeltaPolicy.maxFilesFromEnvironment(),
                maxGrowth: WaxDeltaPolicy.maxGrowthFromEnvironment(),
                allowanceBytes: WaxDeltaPolicy.allowanceBytesFromEnvironment(),
                allowanceScale: WaxDeltaPolicy.allowanceScaleFromEnvironment()
            )
            // Make the eligibility decision observable: ceiling, measured
            // bytes, and which predicate refused — a rebuild used to be
            // inferable only after the fact.
            if delegate != nil {
                print(deltaDecision!.summary)
            }
        } else {
            deltaDecision = nil
        }
        let deltaEligible = deltaDecision?.eligible ?? false
        let arenaReplaced = wax != nil && !deltaEligible
        if arenaReplaced {
            try db.clearWaxFrameRecords()
            try await wax!.resetStore()
        }
        
        var updatedCount = 0
        var skippedCount = 0
        var totalSymbols = 0
        
        for (index, fileURL) in files.enumerated() {
            let relativePath = relativePath(for: fileURL, rootPath: absolutePath)
            
            delegate?.indexerDidProgress(completedFiles: index, totalFiles: files.count, currentFile: relativePath)
            
            // Mid-run growth cap: a single stat per file. When the arena
            // crosses the cap, stop before more bytes land on disk instead of
            // arming a marker after a 929x blowup has fully materialized.
            if let cap = maxArenaBytes, cap > 0, let wax {
                let allocated = await wax.allocatedBytes()
                if allocated > cap {
                    let error = IndexerError.arenaGrowthCapExceeded(allocatedBytes: allocated, capBytes: cap)
                    delegate?.indexerDidFail(error: error)
                    throw error
                }
            }
            
            do {
                let content: String
                do {
                    content = try contentByPath[relativePath]
                        ?? String(contentsOf: fileURL, encoding: .utf8)
                } catch {
                    // An unreadable file can never be processed. Mark it
                    // "considered" when it already has a relational row, or a
                    // completed run would leave coverage residue forever —
                    // wedging the read-path rebuild-incomplete gate and every
                    // subsequent preflight rebuild.
                    print("Failed to read \(relativePath): \(error) — marking considered")
                    if let existing = try? db.getFile(path: relativePath), let fileId = existing.id {
                        try? db.markWaxCoverage(fileId: fileId)
                    }
                    continue
                }
                let currentHash = hasher.hash(content: content)
                
                if let existingFile = try db.getFile(path: relativePath) {
                    if existingFile.sha256 == currentHash {
                        if arenaReplaced {
                            // Arena was reset: every file re-saves, no skips.
                        } else if !uncoveredPaths.contains(relativePath) {
                            skippedCount += 1
                            continue
                        }
                        // Delta mode, unchanged but uncovered: fall through
                        // to delete+resave so the arena regains a complete
                        // document set and the coverage marker is restored.
                    }
                    // Append-only: the old arena documents stay (or were
                    // already reset in full-rebuild mode). Remove only the
                    // relational row and its cascaded children.
                    try db.deleteFile(path: relativePath)
                }
                
                let lines = content.components(separatedBy: .newlines)
                var docLines = 0
                var codeLines = 0
                
                for line in lines {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.isEmpty { continue }
                    if trimmed.hasPrefix("///") || trimmed.hasPrefix("//") {
                        docLines += 1
                    } else {
                        codeLines += 1
                    }
                }
                
                let language = languageRegistry.canonicalLanguage(for: relativePath)
                let router = SplitterRouter(registry: languageRegistry)
                let splitter = router.splitter(for: relativePath)
                
                var (symbols, references) = splitter.extractSymbols(content: content, filePath: relativePath)
                if symbols.isEmpty {
                    symbols = [SymbolRecord(
                        kind: .file,
                        name: relativePath,
                        qualifiedName: relativePath,
                        signature: "File: \(relativePath)",
                        filePath: relativePath,
                        startLine: 1,
                        endLine: lines.count,
                        estimatedTokens: TokenEstimator.shared.estimate(content)
                    )]
                }
                
                let fileId = try db.saveFile(
                    path: relativePath,
                    language: language,
                    sha256: currentHash,
                    sizeBytes: content.utf8.count,
                    modifiedAt: try fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                    docLines: docLines,
                    codeLines: codeLines
                )
                
                try db.saveSymbols(symbols, references: references, fileId: fileId)

                if let wax {
                    for symbol in symbols {
                        let body = symbol.kind == .file ? content : LineRangeBodyExtractor.body(for: symbol, content: content)
                        let ingest = try await wax.saveSymbol(symbol, body: body)
                        if ingest.didWrite {
                            try db.saveWaxFrames(
                                fileId: fileId,
                                mandate: ingest.mandate,
                                frameIDs: ingest.frameIDs
                            )
                        }
                    }

                    // Written last: an interrupted or partially failed file has
                    // no coverage marker, forcing the next run to rebuild/retry.
                    // Files with no eligible semantic symbols still get covered,
                    // so a true no-op does not rebuild forever. Lexical-only
                    // runs claim no semantic coverage.
                    try db.markWaxCoverage(fileId: fileId)
                }
                
                updatedCount += 1
                totalSymbols += symbols.count
            } catch {
                print("Failed to index \(relativePath): \(error)")
            }
        }
        
        // Cleanup Phase: Remove files from DB that are no longer on disk
        let allIndexedFiles = try db.getAllFiles()
        for indexedFile in allIndexedFiles {
            let fullURL = URL(fileURLWithPath: absolutePath).appendingPathComponent(indexedFile.path)
            if !FileManager.default.fileExists(atPath: fullURL.path) || !scannedRelativePaths.contains(indexedFile.path) {
                // The preflight comparison counted this removal; in delta mode
                // its arena documents leak (bounded by the growth margin), in
                // rebuild mode the arena was already replaced.
                try db.deleteFile(path: indexedFile.path)
                print("Removed stale file from index: \(indexedFile.path)")
            }
        }

        if let wax {
            try await wax.flush()
        }
        let currentWaxRecordCount = try db.waxFrameCount()

        delegate?.indexerDidFinish(updated: updatedCount, skipped: skippedCount, totalSymbols: totalSymbols)
        // Carry this run's counts on the result so the CLI can persist them on
        // the ledger row (ActionRecord) — durationMs alone cannot distinguish
        // a no-op pass from a near-full re-embed.
        return WaxCompactResult(
            scanned: previousWaxRecordCount,
            deleted: arenaReplaced ? previousWaxRecordCount : 0,
            kept: currentWaxRecordCount,
            updated: updatedCount,
            skipped: skippedCount,
            totalSymbols: totalSymbols,
            rebuiltWax: arenaReplaced,
            deltaApplied: deltaEligible
        )
    }

    private func relativePath(for fileURL: URL, rootPath: String) -> String {
        let resolvedFileURL = fileURL.resolvingSymlinksInPath()
        let resolvedRootURL = URL(fileURLWithPath: rootPath).resolvingSymlinksInPath()

        var relativePath = resolvedFileURL.path
        if relativePath.hasPrefix(resolvedRootURL.path) {
            relativePath = String(relativePath.dropFirst(resolvedRootURL.path.count))
            if relativePath.hasPrefix("/") {
                relativePath = String(relativePath.dropFirst())
            }
        }
        return relativePath
    }
}
