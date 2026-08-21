import Foundation
import CodeContextKitCore
import CodeContextKitStorage

/// Ranking and formatting for locator tools (`find-symbol`, candidates blocks).
public enum SymbolRanking: Sendable {
    /// Exact name / qualified / leaf-suffix match for a query fragment.
    public static func isExactHit(_ sym: SymbolRecord, query: String) -> Bool {
        sym.name == query
            || sym.qualifiedName == query
            || sym.qualifiedName.hasSuffix(".\(query)")
    }

    /// Sort key: exact hits first, then type kinds before members, then shorter
    /// qualifiedName, filePath, startLine.
    public static func compare(_ lhs: SymbolRecord, _ rhs: SymbolRecord, query: String) -> Bool {
        let lExact = isExactHit(lhs, query: query)
        let rExact = isExactHit(rhs, query: query)
        if lExact != rExact { return lExact && !rExact }

        let lType = SemanticIndexPolicy.typeKinds.contains(lhs.kind)
        let rType = SemanticIndexPolicy.typeKinds.contains(rhs.kind)
        if lType != rType { return lType && !rType }

        if lhs.qualifiedName.count != rhs.qualifiedName.count {
            return lhs.qualifiedName.count < rhs.qualifiedName.count
        }
        if lhs.filePath != rhs.filePath {
            return lhs.filePath < rhs.filePath
        }
        return lhs.startLine < rhs.startLine
    }

    public static func ranked(_ symbols: [SymbolRecord], query: String) -> [SymbolRecord] {
        symbols.sorted { compare($0, $1, query: query) }
    }

    /// Alternate query forms tried when the original fragment has zero hits.
    ///
    /// Covers snake_case/kebab-case vs CamelCase drift ("refresh_token" →
    /// "refreshtoken", which LIKE-matches `refreshToken` case-insensitively)
    /// and hump-splitting so "RefreshToken" can AND/OR match per word.
    public static func queryVariants(for query: String) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var out: [String] = []
        if trimmed.contains("_") || trimmed.contains("-") {
            let joined = trimmed
                .replacingOccurrences(of: "_", with: "")
                .replacingOccurrences(of: "-", with: "")
            if !joined.isEmpty && joined != trimmed { out.append(joined) }
            let spaced = trimmed
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
            if spaced != trimmed { out.append(spaced) }
        }

        let words = splitCamelWords(trimmed)
        if words.count > 1 {
            let spaced = words.joined(separator: " ")
            if spaced != trimmed { out.append(spaced) }
        }
        var seen: Set<String> = []
        return out.filter { $0 != trimmed && seen.insert($0).inserted }
    }

    private enum CharacterKind {
        case lower, upper, digit, separator
    }

    private static func characterKind(_ char: Character) -> CharacterKind {
        if char.isLowercase { return .lower }
        if char.isUppercase { return .upper }
        if char.isNumber { return .digit }
        return .separator
    }

    /// Split "AuthSessionAPI2Handler" into ["Auth", "Session", "API", "2", "Handler"].
    /// Acronym runs stay whole when a lowercased word follows ("APIHandler" → API + Handler).
    public static func splitCamelWords(_ text: String) -> [String] {
        let chars = Array(text)
        guard !chars.isEmpty else { return [] }


        var words: [String] = []
        var current = ""
        var previousKind = Self.characterKind(chars[0])
        current.append(chars[0])

        for index in chars.indices.dropFirst() {
            let kind = Self.characterKind(chars[index])
            if kind == .separator {
                if !current.isEmpty { words.append(current); current = "" }
                previousKind = kind
                continue
            }
            let nextKind = index + 1 < chars.count ? Self.characterKind(chars[index + 1]) : nil
            let breakBefore: Bool
            switch (previousKind, kind) {
            case (.lower, .upper), (.digit, .upper), (.upper, .digit), (.lower, .digit):
                breakBefore = true
            case (.upper, .upper):
                // Break an acronym run only when this char starts a new word
                // ("APIHandler": H is upper, next is lower).
                breakBefore = nextKind == .lower
            default:
                breakBefore = false
            }
            if breakBefore && !current.isEmpty {
                words.append(current)
                current = ""
            }
            current.append(chars[index])
            previousKind = kind
        }
        if !current.isEmpty { words.append(current) }
        return words.filter { !$0.isEmpty }
    }

    /// Merge same qualifiedName in the same file into one entry (type+extension ranges).
    public struct MergedHit: Sendable {
        public var qualifiedName: String
        public var filePath: String
        public var kinds: [String]
        public var ranges: [(start: Int, end: Int)]
        public var bestRank: Int

        public init(
            qualifiedName: String,
            filePath: String,
            kinds: [String],
            ranges: [(start: Int, end: Int)],
            bestRank: Int
        ) {
            self.qualifiedName = qualifiedName
            self.filePath = filePath
            self.kinds = kinds
            self.ranges = ranges
            self.bestRank = bestRank
        }

        public var kindLabel: String {
            // Preserve first-seen order, unique.
            var seen = Set<String>()
            var out: [String] = []
            for k in kinds where seen.insert(k).inserted {
                out.append(k)
            }
            return out.joined(separator: "+")
        }

        public var rangeLabel: String {
            ranges.map { "\($0.start)-\($0.end)" }.joined(separator: ",")
        }
    }

    /// Rank, merge duplicates (same qname+file), then truncate to `limit` merged hits.
    ///
    /// At the default limit, an exact type hit stays tiny: that type plus a handful
    /// of same-file members. Raise `limit` above `SymbolSpanLimits.defaultFindLimit`
    /// to sweep every substring hit.
    public static func rankMergeLimit(
        _ symbols: [SymbolRecord],
        query: String,
        limit: Int,
        compactExactTypes: Bool = true
    ) -> (hits: [MergedHit], totalMerged: Int, truncated: Bool) {
        let ordered = ranked(symbols, query: query)
        var mergedByKey: [String: MergedHit] = [:]
        var orderKeys: [String] = []

        for (rank, sym) in ordered.enumerated() {
            let key = "\(sym.filePath)\0\(sym.qualifiedName)"
            if var existing = mergedByKey[key] {
                existing.kinds.append(sym.kind.rawValue)
                existing.ranges.append((sym.startLine, sym.endLine))
                mergedByKey[key] = existing
            } else {
                mergedByKey[key] = MergedHit(
                    qualifiedName: sym.qualifiedName,
                    filePath: sym.filePath,
                    kinds: [sym.kind.rawValue],
                    ranges: [(sym.startLine, sym.endLine)],
                    bestRank: rank
                )
                orderKeys.append(key)
            }
        }

        let allMerged = orderKeys.compactMap { mergedByKey[$0] }
        let compact = compactExactTypes
            && limit <= SymbolSpanLimits.defaultFindLimit
            && allMerged.contains(where: { isExactTypeHit($0, query: query) })
        let pool: [MergedHit]
        if compact {
            pool = compactExactTypeHits(allMerged, query: query)
        } else {
            pool = allMerged
        }
        let capped = max(1, limit)
        let hits = Array(pool.prefix(capped))
        let truncated = allMerged.count > hits.count
        return (hits, allMerged.count, truncated)
    }

    static func isExactTypeHit(_ hit: MergedHit, query: String) -> Bool {
        let exact = hit.qualifiedName == query
            || hit.qualifiedName.hasSuffix(".\(query)")
            || leafName(hit.qualifiedName) == query
        guard exact else { return false }
        return hit.kinds.contains { SymbolRecord.Kind(rawValue: $0)?.isType == true }
    }

    /// Exact type matches plus a handful of other hits from those same files.
    static func compactExactTypeHits(_ merged: [MergedHit], query: String) -> [MergedHit] {
        let typeHits = merged.filter { isExactTypeHit($0, query: query) }
        guard !typeHits.isEmpty else { return merged }
        let typeFiles = Set(typeHits.map(\.filePath))
        let typeKeys = Set(typeHits.map { "\($0.filePath)\0\($0.qualifiedName)" })
        var kept: [MergedHit] = []
        var extra = 0
        for hit in merged {
            let key = "\(hit.filePath)\0\(hit.qualifiedName)"
            if typeKeys.contains(key) {
                kept.append(hit)
                continue
            }
            if typeFiles.contains(hit.filePath), extra < SymbolSpanLimits.exactTypeSameFileMemberCap {
                kept.append(hit)
                extra += 1
            }
        }
        return kept
    }

    /// Grouped text block for find-symbol / candidates.
    public static func formatGroupedBlock(
        hits: [MergedHit],
        query: String,
        totalMerged: Int,
        truncated: Bool
    ) -> String {
        if hits.isEmpty {
            return "no symbols matching '\(query)'"
        }

        // Group by file; group order = first (best) hit's rank.
        var groupOrder: [String] = []
        var byFile: [String: [MergedHit]] = [:]
        for hit in hits {
            if byFile[hit.filePath] == nil {
                groupOrder.append(hit.filePath)
                byFile[hit.filePath] = []
            }
            byFile[hit.filePath, default: []].append(hit)
        }

        var lines: [String] = []
        for path in groupOrder {
            lines.append(path)
            let group = (byFile[path] ?? []).sorted {
                ($0.ranges.first?.start ?? 0) < ($1.ranges.first?.start ?? 0)
            }
            for hit in group {
                lines.append("  \(hit.kindLabel) \(hit.qualifiedName) \(hit.rangeLabel)")
            }
        }

        if truncated {
            let more = totalMerged - hits.count
            lines.append("(+\(more) more — raise limit or use strict=true)")
        }
        return lines.joined(separator: "\n")
    }

    public static func leafName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let last = trimmed.split(separator: ".").last {
            return String(last)
        }
        return trimmed
    }
}

/// Grouped text formatting for `find-references` results.
public enum ReferenceResultFormatting: Sendable {
    public static let maxLinesPerFile = 25

    public struct Hit: Sendable, Equatable {
        public var filePath: String
        public var startLine: Int
        public var context: String?

        public init(filePath: String, startLine: Int, context: String? = nil) {
            self.filePath = filePath
            self.startLine = startLine
            self.context = context
        }
    }

    public static func formatBlock(
        leaf: String,
        hits: [Hit],
        totalCount: Int,
        truncated: Bool
    ) -> String {
        if hits.isEmpty {
            return "refs to '\(leaf)' — 0 total, showing 0"
        }

        var byFile: [String: [Hit]] = [:]
        for hit in hits {
            byFile[hit.filePath, default: []].append(hit)
        }

        let orderedPaths = byFile.keys.sorted { a, b in
            let ca = byFile[a]?.count ?? 0
            let cb = byFile[b]?.count ?? 0
            if ca != cb { return ca > cb }
            return a < b
        }

        var header =
            "refs to '\(leaf)' — \(totalCount) total, showing \(hits.count)"
        if truncated {
            header += " (truncated — raise limit)"
        }

        var lines: [String] = [header]
        for path in orderedPaths {
            let fileHits = (byFile[path] ?? []).sorted { $0.startLine < $1.startLine }
            let shown = Array(fileHits.prefix(maxLinesPerFile))
            let omitted = fileHits.count - shown.count
            var parts: [String] = []
            var prevContext: String?
            for hit in shown {
                var part = "\(hit.startLine)"
                if let ctx = hit.context, !ctx.isEmpty, ctx != prevContext {
                    part += "(\(ctx))"
                    prevContext = ctx
                }
                parts.append(part)
            }
            var line = "\(path): \(parts.joined(separator: ", "))"
            if omitted > 0 {
                line += " +\(omitted) more"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}

/// Resolve one or more symbol name requests for the `symbol` tool.
public enum SymbolBodyResolver: Sendable {
    public enum Outcome: Sendable {
        case bodies([SymbolRecord], resolvedFrom: String?)
        case candidates(String)
        case miss(String)
    }

    /// Exact → leaf-strict (1 serve / 2–8 candidates / else top-5 loose) ladder.
    public static func resolve(requested: String, db: Database) throws -> Outcome {
        let exact = try db.getSymbols(qualifiedName: requested)
        if !exact.isEmpty {
            return .bodies(exact, resolvedFrom: nil)
        }

        let leaf = SymbolRanking.leafName(requested)
        let strictLikes = try db.getSymbolsLike(name: leaf, strict: true).filter {
            $0.name == leaf || $0.qualifiedName.hasSuffix(".\(leaf)")
        }
        let ranked = SymbolRanking.ranked(strictLikes, query: leaf)

        if ranked.count == 1 {
            return .bodies(ranked, resolvedFrom: requested)
        }
        if ranked.count >= 2 {
            let shown = min(ranked.count, 8)
            let (hits, total, truncated) = SymbolRanking.rankMergeLimit(
                ranked,
                query: leaf,
                limit: shown
            )
            let block = SymbolRanking.formatGroupedBlock(
                hits: hits,
                query: leaf,
                totalMerged: total,
                truncated: truncated || ranked.count > 8
            )
            return .candidates("for '\(requested)':\n\(block)")
        }

        let loose = try db.getSymbolsLike(name: leaf, strict: false)
        let top = Array(SymbolRanking.ranked(loose, query: leaf).prefix(5))
        if top.isEmpty {
            return .miss("no match for '\(requested)'")
        }
        let (hits, total, _) = SymbolRanking.rankMergeLimit(top, query: leaf, limit: 5)
        let block = SymbolRanking.formatGroupedBlock(
            hits: hits,
            query: leaf,
            totalMerged: total,
            truncated: false
        )
        return .miss("no match for '\(requested)'\n\(block)")
    }

    /// Slim JSON row for a resolved symbol body (no signature / estimatedTokens).
    public static func slimPayload(
        symbol: SymbolRecord,
        body: String,
        resolvedFrom: String?,
        omitted: String? = nil,
        members: String? = nil
    ) -> [String: Any] {
        var row: [String: Any] = [
            "qualifiedName": symbol.qualifiedName,
            "kind": symbol.kind.rawValue,
            "filePath": symbol.filePath,
            "startLine": symbol.startLine,
            "endLine": symbol.endLine,
        ]
        if let from = resolvedFrom {
            row["resolvedFrom"] = from
        }
        if let omitted {
            row["omitted"] = omitted
            if let members, !members.isEmpty {
                row["members"] = members
            }
        } else {
            row["body"] = body
            if let doc = symbol.docComment, !doc.isEmpty, !body.contains(doc) {
                row["docComment"] = doc
            }
        }
        return row
    }

    /// `nil` when the span is small enough to dump. Otherwise a reason + member index.
    public static func hugeOmission(
        for symbol: SymbolRecord,
        db: Database
    ) throws -> (reason: String, members: String)? {
        guard symbol.lineSpan >= SymbolSpanLimits.hugeLines else { return nil }
        let members = try memberList(for: symbol, db: db)
        let reason =
            "spans \(symbol.lineSpan) lines (>= \(SymbolSpanLimits.hugeLines)). "
            + "Pass a nested name or Read \(symbol.filePath):\(symbol.startLine)-\(symbol.endLine)."
        return (reason, members)
    }

    static func memberList(for symbol: SymbolRecord, db: Database) throws -> String {
        let fileSymbols = try db.getSymbols(path: symbol.filePath)
        let prefix = symbol.qualifiedName + "."
        let members = fileSymbols.filter { other in
            other.qualifiedName != symbol.qualifiedName
                && (
                    other.enclosingType == symbol.name
                        || other.enclosingType == symbol.qualifiedName
                        || other.qualifiedName.hasPrefix(prefix)
                )
        }.sorted { $0.startLine < $1.startLine }

        let cap = SymbolSpanLimits.hugeMemberListCap
        var lines: [String] = []
        for member in members.prefix(cap) {
            lines.append(
                "  \(member.kind.rawValue) \(member.qualifiedName) \(member.startLine)-\(member.endLine)"
            )
        }
        if members.count > cap {
            lines.append("  (+\(members.count - cap) more)")
        }
        return lines.joined(separator: "\n")
    }
}
