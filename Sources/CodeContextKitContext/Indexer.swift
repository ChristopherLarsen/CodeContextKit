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
        delegate: IndexerProgressDelegate? = nil
    ) async throws {
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
        
        var updatedCount = 0
        var skippedCount = 0
        var totalSymbols = 0
        
        for (index, fileURL) in files.enumerated() {
            let relativePath = relativePath(for: fileURL, rootPath: absolutePath)
            
            delegate?.indexerDidProgress(completedFiles: index, totalFiles: files.count, currentFile: relativePath)
            
            do {
                let content = try String(contentsOf: fileURL, encoding: .utf8)
                let currentHash = hasher.hash(content: content)
                
                if let existingFile = try db.getFile(path: relativePath) {
                    if existingFile.sha256 == currentHash {
                        skippedCount += 1
                        continue
                    }
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
                    try await wax.saveSymbol(symbol, body: body)
                }
                
                updatedCount += 1
                totalSymbols += symbols.count
            } catch {
                print("Failed to index \(relativePath): \(error)")
            }
        }
        
        try await wax.flush()
        
        // Cleanup Phase: Remove files from DB that are no longer on disk
        let allIndexedFiles = try db.getAllFiles()
        for indexedFile in allIndexedFiles {
            let fullURL = URL(fileURLWithPath: absolutePath).appendingPathComponent(indexedFile.path)
            if !FileManager.default.fileExists(atPath: fullURL.path) || !scannedRelativePaths.contains(indexedFile.path) {
                try db.deleteFile(path: indexedFile.path)
                print("Removed stale file from index: \(indexedFile.path)")
            }
        }
        
        delegate?.indexerDidFinish(updated: updatedCount, skipped: skippedCount, totalSymbols: totalSymbols)
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
