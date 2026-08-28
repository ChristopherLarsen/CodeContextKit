import Foundation
import GRDB
import CodeContextKitCore

/// Robust SQLite-backed storage for repository metadata, symbol records, and context configurations.
/// 
/// `Database` serves as the primary persistence layer for CodeContextKit. It uses **GRDB.swift** for type-safe 
/// interaction with SQLite and handles:
/// - File tracking and content hashing.
/// - Symbol extraction results and cross-references.
/// - User preferences (favorites, view modes).
/// - Context Pack configurations.
/// 
/// Verified by: `StorageTests`
public final class Database: @unchecked Sendable {
    private let writer: DatabaseWriter
    
    public init(path: String) throws {
        // Create directory if it doesn't exist
        let url = URL(fileURLWithPath: path)
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        
        self.writer = try DatabaseQueue(path: path)
        try migrator.migrate(writer)
    }
    
    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        
        migrator.registerMigration("v1") { db in
            try db.create(table: "fileRecord") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("path", .text).notNull().unique()
                t.column("language", .text).notNull()
                t.column("sha256", .text).notNull()
                t.column("sizeBytes", .integer).notNull()
                t.column("modifiedAt", .datetime)
                t.column("indexedAt", .datetime).notNull()
            }
            
            try db.create(table: "symbolRecordInternal") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("fileId", .integer)
                    .notNull()
                    .references("fileRecord", column: "id", onDelete: .cascade)
                t.column("kind", .text).notNull()
                t.column("name", .text).notNull()
                t.column("qualifiedName", .text).notNull()
                t.column("signature", .text)
                t.column("enclosingType", .text)
                t.column("accessLevel", .text)
                t.column("startLine", .integer).notNull()
                t.column("endLine", .integer).notNull()
                t.column("docComment", .text)
                t.column("estimatedTokens", .integer)
                
                t.uniqueKey(["fileId", "qualifiedName", "startLine", "endLine"])
            }
            
            try db.create(index: "idx_symbols_name", on: "symbolRecordInternal", columns: ["name"])
            try db.create(index: "idx_symbols_qualifiedName", on: "symbolRecordInternal", columns: ["qualifiedName"])
            try db.create(index: "idx_symbols_kind", on: "symbolRecordInternal", columns: ["kind"])
        }

        migrator.registerMigration("addReferences") { db in
            try db.create(table: "symbolReferenceInternal") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("fileId", .integer)
                    .notNull()
                    .references("fileRecord", column: "id", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("startLine", .integer).notNull()
                t.column("endLine", .integer).notNull()
                t.column("context", .text)
            }
            try db.create(index: "idx_references_name", on: "symbolReferenceInternal", columns: ["name"])
        }

        migrator.registerMigration("addLineMetrics") { db in
            try db.alter(table: "fileRecord") { t in
                t.add(column: "docLineCount", .integer).defaults(to: 0)
                t.add(column: "codeLineCount", .integer).defaults(to: 0)
            }
        }

        migrator.registerMigration("addFavorites") { db in
            try db.create(table: "favoriteRecord") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("filePath", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.uniqueKey(["name", "filePath"])
            }
        }
        
        migrator.registerMigration("fixFavoritesTableName") { db in
            if try db.tableExists("favorite") {
                try db.drop(table: "favorite")
            }
            let exists = try db.tableExists("favoriteRecord")
            if !exists {
                try db.create(table: "favoriteRecord") { t in
                    t.autoIncrementedPrimaryKey("id")
                    t.column("name", .text).notNull()
                    t.column("filePath", .text).notNull()
                    t.column("kind", .text).notNull()
                    t.column("createdAt", .datetime).notNull()
                    t.uniqueKey(["name", "filePath"])
                }
            }
        }

        migrator.registerMigration("addFavoriteViewMode") { db in
            try db.alter(table: "favoriteRecord") { t in
                t.add(column: "viewMode", .text).defaults(to: "symbols")
            }
        }

        migrator.registerMigration("addContextPacks") { db in
            try db.create(table: "contextPack") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull().unique()
                t.column("description", .text)
                t.column("createdAt", .datetime).notNull()
            }
            
            try db.create(table: "contextPackItem") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("packId", .integer)
                    .notNull()
                    .references("contextPack", column: "id", onDelete: .cascade)
                t.column("path", .text).notNull()
                t.column("kind", .text).notNull() // 'file' or 'symbol'
                t.column("reason", .text) // Why this was added
            }
        }

        migrator.registerMigration("v5_action_history") { db in
            try db.create(table: "actionRecord") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("prompt", .text).notNull()
                t.column("toolName", .text)
                t.column("type", .text).notNull().defaults(to: "web")
                t.column("tokensUsed", .integer).notNull()
                t.column("durationMs", .integer).notNull()
                t.column("status", .text).notNull()
                t.column("timestamp", .datetime).notNull()
                t.column("response", .text)
            }
        }

        migrator.registerMigration("v6_wax_frames") { db in
            try db.create(table: "waxFrameRecord") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("fileId", .integer)
                    .notNull()
                    .references("fileRecord", column: "id", onDelete: .cascade)
                t.column("frameId", .integer)
                t.column("mandate", .text).notNull()
            }
            try db.create(index: "idx_wax_frames_fileId", on: "waxFrameRecord", columns: ["fileId"])
            try db.create(index: "idx_wax_frames_mandate", on: "waxFrameRecord", columns: ["mandate"])
        }
        
        return migrator
    }
    
    public func saveFile(path: String, language: String, sha256: String, sizeBytes: Int, modifiedAt: Date?, docLines: Int = 0, codeLines: Int = 0) throws -> Int64 {
        try writer.write { db in
            var file = FileRecord(
                id: nil,
                path: path,
                language: language,
                sha256: sha256,
                sizeBytes: sizeBytes,
                modifiedAt: modifiedAt,
                indexedAt: Date(),
                docLineCount: docLines,
                codeLineCount: codeLines
            )
            try file.save(db)
            return file.id!
        }
    }
    
    public func deleteFile(path: String) throws {
        _ = try writer.write { db in
            try FileRecord.filter(Column("path") == path).deleteAll(db)
        }
    }

    /// Wax frame IDs previously ingested for this path (empty when never tracked).
    public func waxFrameIDs(path: String) throws -> [UInt64] {
        try writer.read { db in
            guard let file = try FileRecord.filter(Column("path") == path).fetchOne(db),
                  let fileId = file.id else {
                return []
            }
            return try WaxFrameRecord
                .filter(Column("fileId") == fileId)
                .fetchAll(db)
                .compactMap { row in
                    guard let raw = row.frameId, raw >= 0 else { return nil }
                    return UInt64(raw)
                }
        }
    }

    /// Mandates previously ingested for this path (delete-by-mandate fallback).
    public func waxMandates(path: String) throws -> [String] {
        try writer.read { db in
            guard let file = try FileRecord.filter(Column("path") == path).fetchOne(db),
                  let fileId = file.id else {
                return []
            }
            let rows = try WaxFrameRecord
                .filter(Column("fileId") == fileId)
                .fetchAll(db)
            var seen = Set<String>()
            var out: [String] = []
            for row in rows where seen.insert(row.mandate).inserted && !row.mandate.isEmpty {
                out.append(row.mandate)
            }
            return out
        }
    }

    public func waxFrameCount() throws -> Int {
        try writer.read { db in
            try WaxFrameRecord.fetchCount(db)
        }
    }

    /// Count of documents actually ingested into the current Wax arena
    /// (mandate rows only; coverage markers carry the empty mandate).
    /// A populated keep-set means semantic content SHOULD be retrievable —
    /// zero semantic hits against it is a retrieval fault, not a true absence.
    public func waxMandateCount() throws -> Int {
        try writer.read { db in
            try WaxFrameRecord.filter(Column("mandate") != "").fetchCount(db)
        }
    }

    /// Paths in `fileRecord` with no Wax coverage row for the current arena.
    /// After a completed index run every kept file is covered; any residue
    /// means a rebuild was interrupted before it finished (or a file failed
    /// mid-write). Callers must filter to paths that still exist on disk —
    /// an interrupted run's cleanup phase never ran, so stale rows for
    /// deleted files are expected here.
    public func uncoveredWaxFilePaths() throws -> [String] {
        try writer.read { db in
            try String.fetchAll(db, sql: """
                SELECT f.path FROM fileRecord f
                WHERE NOT EXISTS (SELECT 1 FROM waxFrameRecord w WHERE w.fileId = f.id)
                ORDER BY f.path
                """)
        }
    }

    /// Whether this file completed ingestion into the current Wax arena.
    ///
    /// A coverage row has neither a frame ID nor a mandate. It distinguishes a
    /// successfully processed file with no semantic documents from an
    /// interrupted rebuild that must be retried.
    public func hasWaxCoverage(path: String) throws -> Bool {
        try writer.read { db in
            guard let file = try FileRecord.filter(Column("path") == path).fetchOne(db),
                  let fileId = file.id else {
                return false
            }
            return try WaxFrameRecord
                .filter(Column("fileId") == fileId)
                .filter(Column("frameId") == nil)
                .filter(Column("mandate") == "")
                .fetchCount(db) > 0
        }
    }

    /// Mark one file as completely considered for the current Wax arena.
    /// This is written only after all of that file's eligible symbols save.
    public func markWaxCoverage(fileId: Int64) throws {
        try writer.write { db in
            var record = WaxFrameRecord(id: nil, fileId: fileId, frameId: nil, mandate: "")
            try record.save(db)
        }
    }

    /// Remove all bookkeeping for a Wax arena that cckit is about to replace.
    /// The relational symbol index remains intact until each source file is
    /// successfully refreshed, but no row may claim a frame in the new arena.
    public func clearWaxFrameRecords() throws {
        _ = try writer.write { db in
            try WaxFrameRecord.deleteAll(db)
        }
    }

    /// Every recorded Wax frame ID across the index (for `--compact`).
    public func allWaxFrameIDs() throws -> [UInt64] {
        try writer.read { db in
            try WaxFrameRecord
                .fetchAll(db)
                .compactMap { row in
                    guard let raw = row.frameId, raw >= 0 else { return nil }
                    return UInt64(raw)
                }
        }
    }

    public func saveWaxFrames(fileId: Int64, mandate: String, frameIDs: [UInt64]) throws {
        guard !mandate.isEmpty || !frameIDs.isEmpty else { return }
        try writer.write { db in
            if frameIDs.isEmpty {
                var record = WaxFrameRecord(id: nil, fileId: fileId, frameId: nil, mandate: mandate)
                try record.save(db)
                return
            }
            for frameID in frameIDs {
                var record = WaxFrameRecord(
                    id: nil,
                    fileId: fileId,
                    frameId: Int64(frameID),
                    mandate: mandate
                )
                try record.save(db)
            }
        }
    }
    
    public func getFile(path: String) throws -> FileRecord? {
        try writer.read { db in
            try FileRecord.filter(Column("path") == path).fetchOne(db)
        }
    }
    
    public func saveSymbols(_ symbols: [SymbolRecord], references: [SymbolRecord.Reference], fileId: Int64) throws {
        try writer.write { db in
            for symbol in symbols {
                var record = SymbolRecordInternal(
                    id: nil,
                    fileId: fileId,
                    kind: symbol.kind.rawValue,
                    name: symbol.name,
                    qualifiedName: symbol.qualifiedName,
                    signature: symbol.signature,
                    enclosingType: symbol.enclosingType,
                    accessLevel: symbol.accessLevel,
                    startLine: symbol.startLine,
                    endLine: symbol.endLine,
                    docComment: symbol.docComment,
                    estimatedTokens: symbol.estimatedTokens
                )
                try record.save(db)
            }

            for ref in references {
                var record = SymbolReferenceInternal(
                    id: nil,
                    fileId: fileId,
                    name: ref.name,
                    startLine: ref.startLine,
                    endLine: ref.endLine,
                    context: ref.context
                )
                try record.save(db)
            }
        }
    }
    
    public func getAllFiles() throws -> [FileRecord] {
        try writer.read { db in
            try FileRecord.fetchAll(db)
        }
    }

    /// SQLite LIKE metacharacters. `\` is the escape so `%` / `_` in a name are literals.
    private static let likeEscape = "\\"

    private static func likeContains(_ column: Column, _ term: String) -> SQLExpression {
        return column.like(likePattern(term), escape: likeEscape)
    }

    private static func likePattern(_ term: String) -> String {
        let escaped = term
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return "%\(escaped)%"
    }

    public func getFilesLike(pattern: String, strict: Bool = false) throws -> [FileRecord] {
        let terms = pattern.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        if terms.isEmpty { return [] }
        
        return try writer.read { db in
            var request = FileRecord.all()
            if strict {
                for term in terms {
                    request = request.filter(Self.likeContains(Column("path"), term))
                }
            } else {
                let filters = terms.map { Self.likeContains(Column("path"), $0) }
                request = request.filter(filters.joined(operator: .or))
            }
            return try request.fetchAll(db)
        }
    }
    
    public func getSymbols(fileId: Int64) throws -> [SymbolRecord] {
        try writer.read { db in
            try _getSymbols(db, fileId: fileId)
        }
    }

    private func _getSymbols(_ db: GRDB.Database, fileId: Int64) throws -> [SymbolRecord] {
        let file = try FileRecord.filter(Column("id") == fileId).fetchOne(db)
        let records = try SymbolRecordInternal
            .filter(Column("fileId") == fileId)
            .fetchAll(db)
        
        return records.map { record in
            SymbolRecord(
                kind: SymbolRecord.Kind(rawValue: record.kind) ?? .function,
                name: record.name,
                qualifiedName: record.qualifiedName,
                signature: record.signature ?? "",
                filePath: file?.path ?? "",
                startLine: record.startLine,
                endLine: record.endLine,
                enclosingType: record.enclosingType,
                accessLevel: record.accessLevel,
                docComment: record.docComment,
                estimatedTokens: record.estimatedTokens ?? 0
            )
        }
    }
    
    public func getSymbols(path: String) throws -> [SymbolRecord] {
        try writer.read { db in
            guard let file = try FileRecord.filter(Column("path") == path).fetchOne(db) else {
                return []
            }
            return try _getSymbols(db, fileId: file.id!)
        }
    }

    public func getSymbolsLike(name: String, strict: Bool = false) throws -> [SymbolRecord] {
        let terms = name.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        if terms.isEmpty { return [] }

        // Single joined query — the per-row FileRecord fetch was N+1 on hot
        // locator paths (find-symbol / pack primaries / candidates blocks).
        let patterns = terms.map { Self.likePattern($0) }
        let joiner = strict ? " AND " : " OR "
        let whereClause = patterns
            .map { _ in "(s.name LIKE ? ESCAPE '\\' OR s.qualifiedName LIKE ? ESCAPE '\\')" }
            .joined(separator: joiner)
        let arguments = patterns.flatMap { [$0, $0] }
        let sql = """
            SELECT s.kind, s.name, s.qualifiedName, s.signature, s.enclosingType, \
                   s.accessLevel, s.docComment, s.startLine, s.endLine, s.estimatedTokens, \
                   f.path AS resolvedPath
            FROM symbolRecordInternal s
            JOIN fileRecord f ON f.id = s.fileId
            WHERE \(whereClause)
            ORDER BY s.qualifiedName ASC
            """

        return try writer.read { db in
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
            return rows.map { row in
                SymbolRecord(
                    kind: SymbolRecord.Kind(rawValue: row["kind"] as String) ?? .function,
                    name: row["name"] as String,
                    qualifiedName: row["qualifiedName"] as String,
                    signature: row["signature"] as? String ?? "",
                    filePath: row["resolvedPath"] as String,
                    startLine: row["startLine"] as Int,
                    endLine: row["endLine"] as Int,
                    enclosingType: row["enclosingType"] as? String,
                    accessLevel: row["accessLevel"] as? String,
                    docComment: row["docComment"] as? String,
                    estimatedTokens: row["estimatedTokens"] as? Int ?? 0
                )
            }
        }
    }

    public func getSymbols(qualifiedName: String) throws -> [SymbolRecord] {
        try writer.read { db in
            let records = try SymbolRecordInternal
                .filter(Column("qualifiedName") == qualifiedName)
                .fetchAll(db)
            
            return try records.map { record in
                let file = try FileRecord.filter(Column("id") == record.fileId).fetchOne(db)
                return SymbolRecord(
                    kind: SymbolRecord.Kind(rawValue: record.kind) ?? .function,
                    name: record.name,
                    qualifiedName: record.qualifiedName,
                    signature: record.signature ?? "",
                    filePath: file?.path ?? "",
                    startLine: record.startLine,
                    endLine: record.endLine,
                    enclosingType: record.enclosingType,
                    accessLevel: record.accessLevel,
                    docComment: record.docComment,
                    estimatedTokens: record.estimatedTokens ?? 0
                )
            }
        }
    }

    /// Bulk-fetch symbols for repo-map generation (avoids N+1 per-file queries).
    public func getSymbolsForRepoMap() throws -> [SymbolRecord] {
        return try writer.read { db in
            let files = try FileRecord.fetchAll(db)
            var filePaths: [Int64: String] = [:]
            filePaths.reserveCapacity(files.count)
            for file in files {
                if let id = file.id {
                    filePaths[id] = file.path
                }
            }

            let records = try SymbolRecordInternal
                .order(Column("fileId").asc, Column("startLine").asc)
                .fetchAll(db)

            return records.map { record in
                SymbolRecord(
                    kind: SymbolRecord.Kind(rawValue: record.kind) ?? .function,
                    name: record.name,
                    qualifiedName: record.qualifiedName,
                    signature: record.signature ?? "",
                    filePath: filePaths[record.fileId] ?? "",
                    startLine: record.startLine,
                    endLine: record.endLine,
                    enclosingType: record.enclosingType,
                    accessLevel: record.accessLevel,
                    docComment: record.docComment,
                    estimatedTokens: record.estimatedTokens ?? 0
                )
            }
        }
    }

    public func getReferences(forSymbolName name: String) throws -> [SymbolRecord.Reference] {
        let sql = """
            SELECT r.name AS refName, r.startLine, r.endLine, r.context, f.path AS resolvedPath
            FROM symbolReferenceInternal r
            JOIN fileRecord f ON f.id = r.fileId
            WHERE r.name = ?
            """
        return try writer.read { db in
            let rows = try Row.fetchAll(db, sql: sql, arguments: [name])
            return rows.map { row in
                SymbolRecord.Reference(
                    name: row["refName"] as String,
                    startLine: row["startLine"] as Int,
                    endLine: row["endLine"] as Int,
                    context: row["context"] as? String,
                    file: row["resolvedPath"] as String
                )
            }
        }
    }

    /// References whose stored name contains `name` (closest/shortest first).
    ///
    /// Fallback for exact-name misses so near-name lookups do not retire to
    /// Grep. Results are approximate: callers must label them as such.
    public func getReferencesLike(name: String, limit: Int = 200) throws -> [SymbolRecord.Reference] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let sql = """
            SELECT r.name AS refName, r.startLine, r.endLine, r.context, f.path AS resolvedPath
            FROM symbolReferenceInternal r
            JOIN fileRecord f ON f.id = r.fileId
            WHERE r.name LIKE ? ESCAPE '\\'
            LIMIT ?
            """
        return try writer.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: sql,
                arguments: [Self.likePattern(trimmed), limit * 4]
            )
            let references = rows.map { row -> SymbolRecord.Reference in
                SymbolRecord.Reference(
                    name: row["refName"] as String,
                    startLine: row["startLine"] as Int,
                    endLine: row["endLine"] as Int,
                    context: row["context"] as? String,
                    file: row["resolvedPath"] as String
                )
            }
            return Array(references.sorted {
                ($0.name.count, $0.name) < ($1.name.count, $1.name)
            }.prefix(limit))
        }
    }

    public func getReferencesInFile(path: String) throws -> [SymbolRecord.Reference] {
        try writer.read { db in
            guard let file = try FileRecord.filter(Column("path") == path).fetchOne(db) else { return [] }
            let records = try SymbolReferenceInternal
                .filter(Column("fileId") == file.id!)
                .fetchAll(db)
            return records.map {
                SymbolRecord.Reference(name: $0.name, startLine: $0.startLine, endLine: $0.endLine, context: $0.context, file: path)
            }
        }
    }

    public func getReferenceCount(forSymbolName name: String) throws -> Int {
        try writer.read { db in
            try SymbolReferenceInternal
                .filter(Column("name") == name)
                .fetchCount(db)
        }
    }

    public func getStats(pathPrefix: String? = nil) throws -> [String: Any] {
        try writer.read { db in
            let fileFilter = pathPrefix != nil ? "WHERE path LIKE '\(pathPrefix!)%'" : ""
            let symbolFilter = pathPrefix != nil ? "WHERE fileId IN (SELECT id FROM fileRecord WHERE path LIKE '\(pathPrefix!)%')" : ""

            let fileCountRow = try Row.fetchOne(db, sql: "SELECT count(*) FROM fileRecord \(fileFilter)")
            let fileCount: Int = fileCountRow?[0] ?? 0

            let symbolCountRow = try Row.fetchOne(db, sql: "SELECT count(*) FROM symbolRecordInternal \(symbolFilter)")
            let symbolCount: Int = symbolCountRow?[0] ?? 0
            
            let kindCounts = try Row.fetchAll(db, sql: "SELECT kind, count(*) FROM symbolRecordInternal \(symbolFilter) GROUP BY kind")
            
            var kindDict: [String: Int] = [:]
            for row in kindCounts {
                let kind: String = row[0]
                let count: Int = row[1]
                kindDict[kind] = count
            }
            
            let totalBytesRow = try Row.fetchOne(db, sql: "SELECT sum(sizeBytes) FROM fileRecord \(fileFilter)")
            let totalBytes: Int64 = totalBytesRow?[0] ?? 0
            
            let totalDocLinesRow = try Row.fetchOne(db, sql: "SELECT sum(docLineCount) FROM fileRecord \(fileFilter)")
            let totalDocLines: Int64 = totalDocLinesRow?[0] ?? 0

            let totalCodeLinesRow = try Row.fetchOne(db, sql: "SELECT sum(codeLineCount) FROM fileRecord \(fileFilter)")
            let totalCodeLines: Int64 = totalCodeLinesRow?[0] ?? 0

            return [
                "fileCount": fileCount,
                "symbolCount": symbolCount,
                "kindCounts": kindDict,
                "totalBytes": totalBytes,
                "totalDocLines": totalDocLines,
                "totalCodeLines": totalCodeLines
            ]
        }
    }

    public func addFavorite(name: String, filePath: String, kind: String, viewMode: String = "symbols") throws {
        try writer.write { db in
            var favorite = FavoriteRecord(id: nil, name: name, filePath: filePath, kind: kind, viewMode: viewMode, createdAt: Date())
            try favorite.insert(db)
        }
    }

    public func removeFavorite(name: String, filePath: String) throws {
        _ = try writer.write { db in
            try FavoriteRecord.filter(Column("name") == name && Column("filePath") == filePath).deleteAll(db)
        }
    }

    public func getFavorites() throws -> [FavoriteRecord] {
        try writer.read { db in
            try FavoriteRecord.order(Column("createdAt").desc).fetchAll(db)
        }
    }
    
    // Context Pack Methods
    public func saveContextPack(name: String, description: String?, items: [[String: String]]) throws {
        try writer.write { db in
            // Delete existing pack with same name if any
            try ContextPack.filter(Column("name") == name).deleteAll(db)
            
            var pack = ContextPack(id: nil, name: name, description: description, createdAt: Date())
            try pack.insert(db)
            
            for item in items {
                var packItem = ContextPackItem(
                    id: nil,
                    packId: pack.id!,
                    path: item["path"] ?? "",
                    kind: item["kind"] ?? "",
                    reason: item["reason"]
                )
                try packItem.insert(db)
            }
        }
    }
    
    public func getContextPacks() throws -> [ContextPack] {
        try writer.read { db in
            try ContextPack.order(Column("createdAt").desc).fetchAll(db)
        }
    }
    
    public func getContextPackItems(packId: Int64) throws -> [ContextPackItem] {
        try writer.read { db in
            try ContextPackItem.filter(Column("packId") == packId).fetchAll(db)
        }
    }
    
    public func deleteContextPack(name: String) throws {
        _ = try writer.write { db in
            try ContextPack.filter(Column("name") == name).deleteAll(db)
        }
    }

    // MARK: - Action History
    
    public func saveActionRecord(_ record: ActionRecord) throws -> Int64 {
        var rec = record
        return try writer.write { db in
            try rec.insert(db)
            return db.lastInsertedRowID
        }
    }

    public func updateActionRecord(id: Int64, status: String, durationMs: Int, tokensUsed: Int, response: String? = nil) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE actionRecord SET status = ?, durationMs = ?, tokensUsed = ?, response = ? WHERE id = ?", arguments: [status, durationMs, tokensUsed, response, id])
        }
    }

    public func getActionHistory(limit: Int = 50) throws -> [ActionRecord] {
        try writer.read { db in
            try ActionRecord.order(Column("timestamp").desc).limit(limit).fetchAll(db)
        }
    }

    public func getRecentlyChangedFiles(limit: Int = 10) throws -> [FileRecord] {
        try writer.read { db in
            try FileRecord.order(Column("modifiedAt").desc).limit(limit).fetchAll(db)
        }
    }

    public func getTopReferencedSymbols(limit: Int = 20) throws -> [(name: String, count: Int)] {
        try writer.read { db in
            let rowList = try Row.fetchAll(db, sql: """
                SELECT r.name, COUNT(*) as refCount 
                FROM symbolReferenceInternal r
                JOIN symbolRecordInternal s ON r.name = s.name
                WHERE s.kind IN ('class', 'struct', 'protocol', 'actor', 'enum', 'interface', 'style')
                AND r.name NOT IN (
                    -- Swift Primitives
                    'String', 'Int', 'Bool', 'Double', 'Float', 'Data', 'Date', 'URL', 'Array', 'Dictionary', 'Set', 'self', 'Self', 'Any', 'AnyObject',
                    -- JS/TS Primitives
                    'string', 'number', 'boolean', 'any', 'unknown', 'never', 'void', 'Promise', 'Object', 'this', 'window', 'document', 'console',
                    -- Python Primitives
                    'int', 'float', 'str', 'bool', 'list', 'dict', 'set', 'tuple', 'object', 'cls'
                )
                GROUP BY r.name 
                ORDER BY refCount DESC 
                LIMIT ?
            """, arguments: [limit])
            return rowList.map { (name: $0[0], count: $0[1]) }
        }
    }
    }
extension ActionRecord: FetchableRecord, MutablePersistableRecord {
    public static var databaseTableName: String { "actionRecord" }
    
    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}


// Public GRDB models
public struct FileRecord: Codable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var path: String
    public var language: String
    public var sha256: String
    public var sizeBytes: Int
    public var modifiedAt: Date?
    public var indexedAt: Date
    public var docLineCount: Int
    public var codeLineCount: Int
    
    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public struct SymbolRecordInternal: Codable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var fileId: Int64
    public var kind: String
    public var name: String
    public var qualifiedName: String
    public var signature: String?
    public var enclosingType: String?
    public var accessLevel: String?
    public var startLine: Int
    public var endLine: Int
    public var docComment: String?
    public var estimatedTokens: Int?
    
    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public struct WaxFrameRecord: Codable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var fileId: Int64
    public var frameId: Int64?
    public var mandate: String

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public struct SymbolReferenceInternal: Codable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var fileId: Int64
    public var name: String
    public var startLine: Int
    public var endLine: Int
    public var context: String?
    
    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public struct FavoriteRecord: Codable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var name: String
    public var filePath: String
    public var kind: String
    public var viewMode: String
    public var createdAt: Date
    
    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public struct ContextPack: Codable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var name: String
    public var description: String?
    public var createdAt: Date
    
    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public struct ContextPackItem: Codable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var packId: Int64
    public var path: String
    public var kind: String
    public var reason: String?
    
    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
