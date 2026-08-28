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
/// Verified by: `IndexerTests`, `WebContextTests.testWebProjectIndexing`
public final class Indexer: Sendable {
    private let db: Database
    private let wax: WaxStore
    
    public init(db: Database, wax: WaxStore) {
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

        // Current Wax commits every single-frame delete and does not expose a
        // batch-delete or frame-enumeration API. Detect semantic changes before
        // mutation and replace the derived Wax arena once when anything changed.
        // No-op runs retain the arena and the fast SQLite hash skip.
        let existingFiles = try db.getAllFiles()
        let existingByPath = Dictionary(uniqueKeysWithValues: existingFiles.map { ($0.path, $0) })
        let previousWaxRecordCount = try db.waxFrameCount()
        var contentByPath: [String: String] = [:]
        contentByPath.reserveCapacity(files.count)
        var semanticInputsChanged = forceWaxRebuild
        for fileURL in files {
            let relativePath = relativePath(for: fileURL, rootPath: absolutePath)
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            contentByPath[relativePath] = content
            if existingByPath[relativePath]?.sha256 != hasher.hash(content: content) {
                semanticInputsChanged = true
            } else if existingByPath[relativePath] != nil,
                      try !db.hasWaxCoverage(path: relativePath) {
                // A prior rebuild did not finish this file, or this is the
                // first run after coverage markers were introduced. Retry the
                // derived arena instead of treating its SQLite hash as enough.
                semanticInputsChanged = true
            }
        }
        if Set(existingByPath.keys) != scannedRelativePaths {
            semanticInputsChanged = true
        }

        if semanticInputsChanged {
            try db.clearWaxFrameRecords()
            try await wax.resetStore()
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
            if let cap = maxArenaBytes, cap > 0 {
                let allocated = await wax.allocatedBytes()
                if allocated > cap {
                    let error = IndexerError.arenaGrowthCapExceeded(allocatedBytes: allocated, capBytes: cap)
                    delegate?.indexerDidFail(error: error)
                    throw error
                }
            }
            
            do {
                let content = try contentByPath[relativePath]
                    ?? String(contentsOf: fileURL, encoding: .utf8)
                let currentHash = hasher.hash(content: content)
                
                if let existingFile = try db.getFile(path: relativePath) {
                    if !semanticInputsChanged && existingFile.sha256 == currentHash {
                        skippedCount += 1
                        continue
                    }
                    // The old Wax arena has already been replaced for this run.
                    // Remove only the relational row and its cascaded children.
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
                // so a true no-op does not rebuild forever.
                try db.markWaxCoverage(fileId: fileId)
                
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
                // File deletion participated in the preflight comparison, so
                // Wax was rebuilt before this stale SQLite row is removed.
                try db.deleteFile(path: indexedFile.path)
                print("Removed stale file from index: \(indexedFile.path)")
            }
        }

        try await wax.flush()
        let currentWaxRecordCount = try db.waxFrameCount()

        delegate?.indexerDidFinish(updated: updatedCount, skipped: skippedCount, totalSymbols: totalSymbols)
        // Carry this run's counts on the result so the CLI can persist them on
        // the ledger row (ActionRecord) — durationMs alone cannot distinguish
        // a no-op pass from a near-full re-embed.
        return WaxCompactResult(
            scanned: previousWaxRecordCount,
            deleted: semanticInputsChanged ? previousWaxRecordCount : 0,
            kept: currentWaxRecordCount,
            updated: updatedCount,
            skipped: skippedCount,
            totalSymbols: totalSymbols,
            rebuiltWax: semanticInputsChanged
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
