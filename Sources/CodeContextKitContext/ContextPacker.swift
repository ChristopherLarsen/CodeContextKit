import Foundation
import CodeContextKitCore
import CodeContextKitStorage
import CodeContextKitRetrieval

/// Controls how primary search hits are emitted into a context packet.
public enum PackMode: String, Sendable, Codable {
    /// Emit symbol body slices for primary hits when cheaper than the whole file;
    /// tiny / high-coverage files are emitted as full file bodies (no related-hint chrome).
    case surgical
    /// Emit entire files for primary hits.
    case full
    /// Assemble surgical, full, and raw packets and return the smaller.
    case auto
    /// Delivered-only: unique primary whole files, no map/skeletons/hints/guidance.
    /// Not accepted as a requested CLI/MCP mode.
    case raw
    /// Progressive disclosure first tier: hit list with qualified names, line
    /// ranges, and per-hit token sizes plus a capped map/skeletons — no bodies.
    /// Agents expand via `symbol` or re-gather with surgical/full.
    case preview
}

/// Outcome of a pack run, including honest delivery vs whole-file source size.
public struct PackResult: Sendable {
    public let packet: String
    /// Mode the caller requested (`auto`, `surgical`, or `full`).
    public let requestedMode: PackMode
    /// Mode of the packet that was actually returned.
    public let deliveredMode: PackMode
    public let deliveredTokens: Int
    /// Surgical packet size when computed (auto, or surgical-only).
    public let surgicalTokens: Int?
    /// Full-mode packet size when computed (auto dual-pack comparison only).
    /// Not used as the primary savings baseline — see `sourceWholeFileTokens`.
    public let fullBaselineTokens: Int?
    /// Sum of whole-file token counts for every source file drawn into the packet.
    /// This is the honest "what you'd pay if you Read each file" baseline.
    public let sourceWholeFileTokens: Int
    /// Primary symbols the packet actually delivered (slices + full files).
    public let primaryCount: Int
    /// True when the Wax semantic fill actually ran for this packet. When
    /// false (identifier-only tasks skip the filler), a zero-symbol packet is
    /// a real lexical miss — never evidence of a semantic fault.
    public let waxFillRan: Bool
    /// Raw Wax search hits behind the fill (0 when the fill did not run).
    public let waxHitCount: Int

    public init(
        packet: String,
        requestedMode: PackMode,
        deliveredMode: PackMode,
        deliveredTokens: Int,
        surgicalTokens: Int? = nil,
        fullBaselineTokens: Int? = nil,
        sourceWholeFileTokens: Int = 0,
        primaryCount: Int = 0,
        waxFillRan: Bool = false,
        waxHitCount: Int = 0
    ) {
        self.packet = packet
        self.requestedMode = requestedMode
        self.deliveredMode = deliveredMode
        self.deliveredTokens = deliveredTokens
        self.surgicalTokens = surgicalTokens
        self.fullBaselineTokens = fullBaselineTokens
        self.sourceWholeFileTokens = sourceWholeFileTokens
        self.primaryCount = primaryCount
        self.waxFillRan = waxFillRan
        self.waxHitCount = waxHitCount
    }

    /// Tokens avoided versus reading whole source files drawn into the packet.
    /// May be negative when the packet is larger than the raw files (a real regression).
    public var tokensSavedVersusSourceFiles: Int {
        sourceWholeFileTokens - deliveredTokens
    }

    @available(*, deprecated, renamed: "tokensSavedVersusSourceFiles")
    public var tokensSavedVersusFull: Int {
        tokensSavedVersusSourceFiles
    }
}

/// Orchestrates the assembly of surgical context packets for AI consumption.
///
/// `ContextPacker` intelligently combines various sources of information into a single Markdown document:
/// 1. **Architectural Map**: A budget-aware overview of the repository.
/// 2. **Failure Analysis**: Extracts key error messages from provided log files.
/// 3. **Dependency Crawling**: Automatically identifies and includes related code based on semantic search tasks.
/// 4. **Surgical Precision**: Includes symbol bodies for primary targets and structural skeletons for supporting context.
///
/// Verified by: `WebContextTests.testWebContextPacking`, `ContextPackerSliceTests`
public final class ContextPacker {
    private let db: Database
    private let wax: WaxStore
    private let rootPath: String
    private let repoMapBuilder: RepoMapBuilder
    private let maxPrimarySymbols: Int
    /// Associated skeletons are capped by count (budget is a ceiling, not a fill target).
    private let maxAssociatedSkeletons: Int

    /// Prefer a full-file dump when the symbol body covers this fraction of the file.
    private let fullFileCoverageThreshold: Double = 0.80
    /// Prefer a full-file dump (no related-hint chrome) at or below this many lines.
    /// ~100 Swift lines ≈ related-name chrome cost; whole file is clearer and usually smaller.
    public static let tinyFileLineThreshold: Int = 100

    /// Per-line cap for failure-log summaries (minified bundles are unbounded).
    public static let failureLineMaxChars: Int = 500
    /// Preview packets stay under this many tokens regardless of requested budget —
    /// the tier exists so looking is cheap.
    public static let previewBudgetCap: Int = 1500

    public init(
        db: Database,
        wax: WaxStore,
        rootPath: String = ".",
        maxPrimarySymbols: Int = 5,
        maxAssociatedSkeletons: Int = 3
    ) {
        self.db = db
        self.wax = wax
        self.rootPath = rootPath
        self.maxPrimarySymbols = maxPrimarySymbols
        self.maxAssociatedSkeletons = maxAssociatedSkeletons
        self.repoMapBuilder = RepoMapBuilder(db: db, counter: { text in await wax.countTokens(text) })
    }

    public func pack(
        task: String,
        budget: Int,
        failureLog: String? = nil,
        mode: PackMode = .auto,
        mapBudget: Int? = nil,
        relatedHintCap: Int = 5
    ) async throws -> PackResult {
        if mode == .auto {
            // Identifier-only tasks skip MiniLM fill; one surgical pack is enough.
            if SemanticIndexPolicy.shouldSkipPackFiller(task: task) {
                let surgical = try await packOnce(
                    task: task,
                    budget: budget,
                    failureLog: failureLog,
                    mode: .surgical,
                    mapBudget: mapBudget,
                    relatedHintCap: relatedHintCap
                )
                let surgicalTokens = await wax.countTokens(surgical.packet)
                let sourceWhole = await countWholeFileTokens(paths: surgical.primaryFilePaths)
                // Auto must never deliver more than reading the files outright.
                // If surgical lost to the baseline, fall back to raw (and then to
                // raw-minimal) before admitting defeat.
                let delivered = await enforceBaseline(
                    candidates: [(surgical, .surgical, surgicalTokens)],
                    fallbackPaths: surgical.primaryFilePaths,
                    failureLog: failureLog,
                    task: task,
                    budget: budget,
                    relatedHintCap: relatedHintCap,
                    sourceWhole: sourceWhole
                )
                return PackResult(
                    packet: delivered.packet,
                    requestedMode: .auto,
                    deliveredMode: delivered.mode,
                    deliveredTokens: delivered.tokens,
                    surgicalTokens: surgicalTokens,
                    fullBaselineTokens: nil,
                    sourceWholeFileTokens: sourceWhole,
                    primaryCount: delivered.primaryCount,
                    waxFillRan: delivered.waxFillRan,
                    waxHitCount: delivered.waxHitCount
                )
            }
            let surgical = try await packOnce(
                task: task,
                budget: budget,
                failureLog: failureLog,
                mode: .surgical,
                mapBudget: mapBudget,
                relatedHintCap: relatedHintCap
            )
            let surgicalTokens = await wax.countTokens(surgical.packet)
            let raw = try await packOnce(
                task: task,
                budget: budget,
                failureLog: failureLog,
                mode: .raw,
                mapBudget: 0,
                relatedHintCap: relatedHintCap
            )
            let rawTokens = await wax.countTokens(raw.packet)
            // Full is chrome on top of the same primaries as raw. If surgical
            // already beats raw, full cannot win — skip the third assembly.
            if surgicalTokens <= rawTokens {
                let sourceWhole = await countWholeFileTokens(paths: surgical.primaryFilePaths)
                let delivered = await enforceBaseline(
                    candidates: [(surgical, .surgical, surgicalTokens), (raw, .raw, rawTokens)],
                    fallbackPaths: surgical.primaryFilePaths,
                    failureLog: failureLog,
                    task: task,
                    budget: budget,
                    relatedHintCap: relatedHintCap,
                    sourceWhole: sourceWhole
                )
                return PackResult(
                    packet: delivered.packet,
                    requestedMode: .auto,
                    deliveredMode: delivered.mode,
                    deliveredTokens: delivered.tokens,
                    surgicalTokens: surgicalTokens,
                    fullBaselineTokens: nil,
                    sourceWholeFileTokens: sourceWhole,
                    primaryCount: delivered.primaryCount,
                    waxFillRan: delivered.waxFillRan,
                    waxHitCount: delivered.waxHitCount
                )
            }
            let full = try await packOnce(
                task: task,
                budget: budget,
                failureLog: failureLog,
                mode: .full,
                mapBudget: mapBudget,
                relatedHintCap: relatedHintCap
            )
            let fullTokens = await wax.countTokens(full.packet)
            let candidates: [(PackAssembly, PackMode, Int)] = [
                (surgical, .surgical, surgicalTokens),
                (full, .full, fullTokens),
                (raw, .raw, rawTokens),
            ]
            let best = candidates.min(by: { $0.2 < $1.2 })!
            let sourceWhole = await countWholeFileTokens(paths: best.0.primaryFilePaths)
            let delivered = await enforceBaseline(
                candidates: candidates,
                fallbackPaths: best.0.primaryFilePaths,
                failureLog: failureLog,
                task: task,
                budget: budget,
                relatedHintCap: relatedHintCap,
                sourceWhole: sourceWhole
            )
            return PackResult(
                packet: delivered.packet,
                requestedMode: .auto,
                deliveredMode: delivered.mode,
                deliveredTokens: delivered.tokens,
                surgicalTokens: surgicalTokens,
                fullBaselineTokens: fullTokens,
                sourceWholeFileTokens: sourceWhole,
                primaryCount: delivered.primaryCount,
                waxFillRan: delivered.waxFillRan,
                waxHitCount: delivered.waxHitCount
            )
        }

        if mode == .preview {
            // Progressive disclosure first tier: keep it cheap enough that an
            // agent can afford to look before committing to bodies.
            let previewBudget = min(budget, Self.previewBudgetCap)
            let assembled = try await packOnce(
                task: task,
                budget: previewBudget,
                failureLog: failureLog,
                mode: .preview,
                mapBudget: min(mapBudget ?? 400, 400),
                relatedHintCap: relatedHintCap
            )
            let tokens = await wax.countTokens(assembled.packet)
            let sourceWhole = await countWholeFileTokens(paths: assembled.primaryFilePaths)
            return PackResult(
                packet: assembled.packet,
                requestedMode: .preview,
                deliveredMode: .preview,
                deliveredTokens: tokens,
                sourceWholeFileTokens: sourceWhole,
                primaryCount: assembled.primaryCount,
                waxFillRan: assembled.waxFillRan,
                waxHitCount: assembled.waxHitCount
            )
        }

        if mode == .raw {
            // Requested raw is not a public mode; treat as full primary dumps without chrome.
        }

        let assembled = try await packOnce(
            task: task,
            budget: budget,
            failureLog: failureLog,
            mode: mode == .raw ? .raw : mode,
            mapBudget: mapBudget,
            relatedHintCap: relatedHintCap
        )
        let tokens = await wax.countTokens(assembled.packet)
        let sourceWhole = await countWholeFileTokens(paths: assembled.primaryFilePaths)
        return PackResult(
            packet: assembled.packet,
            requestedMode: mode == .raw ? .full : mode,
            deliveredMode: mode,
            deliveredTokens: tokens,
            surgicalTokens: mode == .surgical ? tokens : nil,
            fullBaselineTokens: (mode == .full || mode == .raw) ? tokens : nil,
            sourceWholeFileTokens: sourceWhole,
            primaryCount: assembled.primaryCount,
            waxFillRan: assembled.waxFillRan,
            waxHitCount: assembled.waxHitCount
        )
    }

    private struct PackAssembly: Sendable {
        var packet: String
        /// Primary files actually emitted (slices or full dumps). Savings baseline
        /// uses this set — associated skeletons are not whole-file Reads.
        var primaryFilePaths: Set<String>
        var primaryCount: Int
        var waxFillRan: Bool
        var waxHitCount: Int
    }

    private struct BaselineDelivery: Sendable {
        var packet: String
        var mode: PackMode
        var tokens: Int
        var primaryCount: Int
        var waxFillRan: Bool
        var waxHitCount: Int
    }

    /// Auto must never deliver a packet larger than reading its primary files
    /// outright — a negative-savings row is a real regression, not bookkeeping.
    ///
    /// If the token-smallest candidate still loses to the whole-file baseline,
    /// fall back to raw, then to raw-minimal (files with per-path headers only).
    private func enforceBaseline(
        candidates: [(PackAssembly, PackMode, Int)],
        fallbackPaths: Set<String>,
        failureLog: String?,
        task: String,
        budget: Int,
        relatedHintCap: Int,
        sourceWhole: Int
    ) async -> BaselineDelivery {
        guard let best = candidates.min(by: { $0.2 < $1.2 }) else {
            return BaselineDelivery(packet: "", mode: .raw, tokens: 0, primaryCount: 0, waxFillRan: false, waxHitCount: 0)
        }
        if best.2 <= sourceWhole || fallbackPaths.isEmpty {
            return BaselineDelivery(
                packet: best.0.packet,
                mode: best.1,
                tokens: best.2,
                primaryCount: best.0.primaryCount,
                waxFillRan: best.0.waxFillRan,
                waxHitCount: best.0.waxHitCount
            )
        }

        // First fallback: chrome-free raw over the same primaries.
        if best.1 != .raw {
            let raw = try? await packOnce(
                task: task,
                budget: budget,
                failureLog: nil,
                mode: .raw,
                mapBudget: 0,
                relatedHintCap: relatedHintCap
            )
            if let raw {
                let rawTokens = await wax.countTokens(raw.packet)
                if rawTokens <= sourceWhole {
                    return BaselineDelivery(
                        packet: raw.packet,
                        mode: .raw,
                        tokens: rawTokens,
                        primaryCount: raw.primaryCount,
                        waxFillRan: raw.waxFillRan,
                        waxHitCount: raw.waxHitCount
                    )
                }
            }
        }

        // Last resort: raw-minimal strips every header but one line per file.
        let minimal = await rawMinimalPacket(paths: fallbackPaths, budget: budget)
        let minimalTokens = await wax.countTokens(minimal)
        if minimalTokens < best.2 {
            return BaselineDelivery(
                packet: minimal,
                mode: .raw,
                tokens: minimalTokens,
                primaryCount: best.0.primaryCount,
                waxFillRan: best.0.waxFillRan,
                waxHitCount: best.0.waxHitCount
            )
        }
        return BaselineDelivery(
            packet: best.0.packet,
            mode: best.1,
            tokens: best.2,
            primaryCount: best.0.primaryCount,
            waxFillRan: best.0.waxFillRan,
            waxHitCount: best.0.waxHitCount
        )
    }

    /// Last-resort delivery when even raw lost to the baseline: file contents
    /// only (plus one banner line), separated by blank lines. Any per-file
    /// marker (header, fence) costs tokens the baseline does not pay, so this
    /// is the one form that cannot meaningfully lose to reading files outright.
    private func rawMinimalPacket(paths: Set<String>, budget: Int) async -> String {
        let rootURL = URL(fileURLWithPath: rootPath)
        var body = ""
        for path in paths.sorted() {
            guard let content = readFile(path: path, rootURL: rootURL) else { continue }
            body += content + "\n"
        }
        let tokens = await wax.countTokens(body)
        return "# Context Packet (Tokens: \(tokens)/\(budget) · mode: raw)\n\n" + body
    }

    private func countWholeFileTokens(paths: Set<String>) async -> Int {
        let rootURL = URL(fileURLWithPath: rootPath)
        var total = 0
        for path in paths.sorted() {
            guard let content = readFile(path: path, rootURL: rootURL) else { continue }
            total += await wax.countTokens(content)
        }
        return total
    }

    private func packOnce(
        task: String,
        budget: Int,
        failureLog: String?,
        mode: PackMode,
        mapBudget: Int?,
        relatedHintCap: Int
    ) async throws -> PackAssembly {
        var output = "# Context Packet\n\n"
        output += "## Task\n\(task)\n\n"

        // Lexical identifier hits first. Identifier-heavy tasks skip vector fill,
        // associated skeletons, and the repo map (`shouldSkipPackFiller`). Prose
        // that names types still vector-fills remaining slots.
        var primaries: [SymbolRecord] = []
        var seenQualifiedNames = Set<String>()
        var associatedFiles: [String: String] = [:] // Path -> Reason
        var waxFillRan = false
        var waxHitCount = 0

        func considerPrimary(_ sym: SymbolRecord) {
            guard primaries.count < maxPrimarySymbols else { return }
            guard seenQualifiedNames.insert(sym.qualifiedName).inserted else { return }
            // One primary hit per file: further same-file symbols are neighbors (related
            // hints / skeletons), not additional bodies. Without this, Wax fill can stack
            // several slices from one file and reintroduce noise the lexical hit avoided.
            if primaries.contains(where: { $0.filePath == sym.filePath }) { return }
            primaries.append(sym)
        }

        // Exact leaf / qualified matches only (not loose LIKE) so prose identifiers
        // surface ground-truth symbols without dragging in every substring hit.
        let lexicalTokens = SemanticIndexPolicy.identifierTokens(in: task)
        for token in lexicalTokens {
            guard primaries.count < maxPrimarySymbols else { break }
            let likes = try db.getSymbolsLike(name: token, strict: true).filter { sym in
                sym.name == token
                    || sym.qualifiedName == token
                    || sym.qualifiedName.hasSuffix(".\(token)")
            }
            let ranked = likes.sorted { lhs, rhs in
                let lType = SemanticIndexPolicy.typeKinds.contains(lhs.kind)
                let rType = SemanticIndexPolicy.typeKinds.contains(rhs.kind)
                // Prefer members over types so a method hit isn't replaced by its enclosing type
                // (which would force a whole-file dump and reintroduce noise).
                if lType != rType { return !lType && rType }
                return lhs.qualifiedName.count < rhs.qualifiedName.count
            }
            for sym in ranked {
                guard primaries.count < maxPrimarySymbols else { break }
                if SemanticIndexPolicy.typeKinds.contains(sym.kind),
                   primaries.contains(where: { $0.filePath == sym.filePath }) {
                    continue
                }
                // One primary per leaf NAME across files: a generic method name
                // (e.g. `bump`) matches ten near-duplicate types — stacking five
                // of them as primaries is noise that also torches the savings
                // baseline. find_symbol exists for enumerating same-name hits.
                if primaries.contains(where: { $0.name == sym.name }) {
                    continue
                }
                considerPrimary(sym)
            }
        }

        let skipFiller = SemanticIndexPolicy.shouldSkipPackFiller(task: task)

        let remainingSlots = maxPrimarySymbols - primaries.count
        if remainingSlots > 0 && !skipFiller {
            waxFillRan = true
            // Modest overfetch for unresolved Wax hits; never request more than 2× remaining slots.
            let searchResults = try await wax.search(task, limit: remainingSlots * 2)
            waxHitCount = searchResults.count
            for res in searchResults {
                guard primaries.count < maxPrimarySymbols else { break }
                guard let sym = try db.getSymbols(qualifiedName: res.symbol).first else { continue }
                considerPrimary(sym)
            }
        }

        if !skipFiller {
            for sym in primaries {
                let refs = try db.getReferencesInFile(path: sym.filePath)
                for ref in refs {
                    let defs = try db.getSymbols(qualifiedName: ref.name)
                    for def in defs where def.filePath != sym.filePath {
                        let leaf = sym.filePath.split(separator: "/").last.map(String.init) ?? sym.filePath
                        associatedFiles[def.filePath] = "Defines '\(def.name)' used in '\(leaf)'"
                    }
                }
            }
        }

        // Repo map — skipped at small budgets / raw / named-identifier filler skip
        // unless the caller passed an explicit mapBudget.
        let resolvedMapBudget: Int
        if mode == .raw {
            resolvedMapBudget = 0
        } else if skipFiller && mapBudget == nil {
            resolvedMapBudget = 0
        } else {
            resolvedMapBudget = mapBudget ?? (budget < 6000 ? 0 : min(800, max(1, budget / 10)))
        }
        if resolvedMapBudget > 0 {
            let repoMap: String
            do {
                repoMap = try await repoMapBuilder.buildMap(budget: resolvedMapBudget, focusTerms: task)
            } catch {
                repoMap = "(repo map unavailable: \(error))"
            }
            output += "## Repository Map\n\(repoMap)\n\n"
        }

        if let failureLog = failureLog {
            let summary = extractFailureSummary(from: failureLog)
            output += "## Failure Summary\n\(summary)\n\n"
        }

        // Preview assembly: names and spans only — no bodies. Everything else
        // (map, skeletons) still applies so the agent can decide what to expand.
        let rootURL = URL(fileURLWithPath: rootPath)
        var currentTokens = await wax.countTokens(output)
        var primarySymbolCount = 0
        var primaryFullFileCount = 0
        var associatedSkeletonCount = 0
        var emittedFullPaths = Set<String>()
        var primaryFilePaths = Set<String>()
        var anyHintsTruncated = false

        if mode == .preview {
            output += "## Primary hits\n\n"
            output += "Bodies omitted (preview). Fetch one with `symbol` "
            output += "(qualified name), or re-gather with `mode=surgical` for slices "
            output += "or `mode=full` for whole files.\n\n"
            for sym in primaries {
                let bodyTokens: Int
                if let content = readFile(path: sym.filePath, rootURL: rootURL) {
                    let body = LineRangeBodyExtractor.body(for: sym, content: content)
                    bodyTokens = await wax.countTokens(body)
                } else {
                    bodyTokens = 0
                }
                output += "- \(sym.qualifiedName) (\(sym.kind.rawValue) · "
                output += "\(sym.filePath):\(sym.startLine)-\(sym.endLine)"
                if bodyTokens > 0 {
                    output += " · body ≈\(bodyTokens) tokens"
                }
                output += ")\n"
                primarySymbolCount += 1
                primaryFilePaths.insert(sym.filePath)
            }
            output += "\n"
            currentTokens = await wax.countTokens(output)
        } else {
            if mode != .raw {
                output += "## Surgical Context\n\n"
            }
        }

        if mode == .full || mode == .raw {
            var stagedFiles: [String] = []
            var seenPaths = Set<String>()
            for sym in primaries where seenPaths.insert(sym.filePath).inserted {
                stagedFiles.append(sym.filePath)
            }

            for path in stagedFiles {
                if currentTokens >= budget { break }
                guard let content = readFile(path: path, rootURL: rootURL) else { continue }
                let section = formatFullFileSection(path: path, content: content)
                let sectionTokens = await wax.countTokens(section)
                if currentTokens + sectionTokens < budget {
                    output += section
                    currentTokens += sectionTokens
                    primaryFullFileCount += 1
                    emittedFullPaths.insert(path)
                    primaryFilePaths.insert(path)
                }
            }
        } else {
            for sym in primaries {
                if currentTokens >= budget { break }
                guard let content = readFile(path: sym.filePath, rootURL: rootURL) else { continue }

                let body = LineRangeBodyExtractor.body(for: sym, content: content)
                let preferFullFast = shouldPreferFullFile(symbol: sym, content: content, body: body)

                let section: String
                let emittedAsFull: Bool
                if preferFullFast {
                    if emittedFullPaths.contains(sym.filePath) { continue }
                    // Tiny / high-coverage: whole file, no related-hint chrome.
                    section = formatFullFileSection(path: sym.filePath, content: content)
                    emittedAsFull = true
                } else {
                    let fileSymbols = try db.getSymbols(path: sym.filePath)
                    let fileRefs = try db.getReferencesInFile(path: sym.filePath)
                    let related = buildSameFileRelatedHints(
                        symbol: sym,
                        fileSymbols: fileSymbols,
                        fileRefs: fileRefs,
                        limitPerCategory: relatedHintCap
                    )
                    anyHintsTruncated = anyHintsTruncated || related.truncated
                    let symbolSection = formatSymbolSection(
                        symbol: sym,
                        body: body,
                        relatedHints: related.text
                    )
                    // If surgical chrome (slice + related lists) is not cheaper than the
                    // whole file, emit the file instead — no point paying for "surgical".
                    if !emittedFullPaths.contains(sym.filePath) {
                        let fullSection = formatFullFileSection(path: sym.filePath, content: content)
                        let symbolTokens = await wax.countTokens(symbolSection)
                        let fullTokens = await wax.countTokens(fullSection)
                        if fullTokens <= symbolTokens {
                            section = fullSection
                            emittedAsFull = true
                        } else {
                            section = symbolSection
                            emittedAsFull = false
                        }
                    } else {
                        section = symbolSection
                        emittedAsFull = false
                    }
                }

                let sectionTokens = await wax.countTokens(section)
                if currentTokens + sectionTokens < budget {
                    output += section
                    currentTokens += sectionTokens
                    primaryFilePaths.insert(sym.filePath)
                    if emittedAsFull {
                        primaryFullFileCount += 1
                        emittedFullPaths.insert(sym.filePath)
                    } else {
                        primarySymbolCount += 1
                    }
                }
            }
        }

        // Skeletons — skipped in raw mode.
        if mode != .raw {
        let primaryPaths = Set(primaries.map(\.filePath))
        for (path, reason) in associatedFiles
        where !primaryPaths.contains(path) && !emittedFullPaths.contains(path) {
            if associatedSkeletonCount >= maxAssociatedSkeletons { break }
            if currentTokens >= budget { break }

            let symbols = try db.getSymbols(path: path)
            let section = formatSkeletonSection(path: path, reason: reason, symbols: symbols)
            let sectionTokens = await wax.countTokens(section)
            if currentTokens + sectionTokens < budget {
                output += section
                currentTokens += sectionTokens
                associatedSkeletonCount += 1
            }
        }
        }

        if mode == .surgical && primarySymbolCount > 0 && anyHintsTruncated {
            let guidance = packingGuidanceSection(
                relatedHintCap: relatedHintCap,
                anyTruncated: true
            )
            let guidanceTokens = await wax.countTokens(guidance)
            if currentTokens + guidanceTokens < budget {
                output += guidance
                currentTokens += guidanceTokens
            }
        }

        let packetPrefix = "# Context Packet\n\n"
        let body: String
        if output.hasPrefix(packetPrefix) {
            body = String(output.dropFirst(packetPrefix.count))
        } else {
            body = output
        }

        let modeLabel: String
        switch mode {
        case .surgical: modeLabel = "surgical"
        case .full: modeLabel = "full"
        case .raw: modeLabel = "raw"
        case .auto: modeLabel = "auto"
        case .preview: modeLabel = "preview"
        }
        func makeBanner(tokens: Int) -> String {
            "# Context Packet (Tokens: \(tokens)/\(budget) · primary: \(primarySymbolCount) symbols"
                + (primaryFullFileCount > 0 ? ", \(primaryFullFileCount) full files" : "")
                + " · associated: \(associatedSkeletonCount) skeletons · mode: \(modeLabel))\n\n"
        }

        // Stamp once with a provisional count, then recount the assembled packet so
        // the banner matches what callers actually receive.
        var packet = makeBanner(tokens: currentTokens) + body
        let finalTokens = await wax.countTokens(packet)
        packet = makeBanner(tokens: finalTokens) + body
        return PackAssembly(
            packet: packet,
            primaryFilePaths: primaryFilePaths,
            primaryCount: primarySymbolCount + primaryFullFileCount,
            waxFillRan: waxFillRan,
            waxHitCount: waxHitCount
        )
    }

    // MARK: - Formatting

    func formatSymbolSection(
        symbol: SymbolRecord,
        body: String,
        relatedHints: String = ""
    ) -> String {
        let fence = LanguageFence.fence(for: symbol.filePath)
        let effectiveBody = body.isEmpty ? symbol.signature : body
        let header =
            "### \(symbol.name) (SYMBOL · \(symbol.filePath):\(symbol.startLine)-\(symbol.endLine))\n"
        var section = header + "```\(fence)\n\(effectiveBody)\n```\n"
        if !relatedHints.isEmpty {
            section += relatedHints
        }
        section += "\n"
        return section
    }

    func formatFullFileSection(path: String, content: String) -> String {
        let fileName = (path as NSString).lastPathComponent
        let fence = LanguageFence.fence(for: path)
        return "### \(fileName) (FULL · \(path))\n```\(fence)\n\(content)\n```\n\n"
    }

    func formatSkeletonSection(path: String, reason: String, symbols: [SymbolRecord]) -> String {
        let skeleton = OutlineRendererRegistry().renderer(for: path).render(filePath: path, symbols: symbols)
        let fileName = (path as NSString).lastPathComponent
        let fileBase = (fileName as NSString).deletingPathExtension

        if symbols.count == 1, let sym = symbols.first, sym.name.lowercased() == fileBase.lowercased() {
            let trimmed = skeleton
                .replacingOccurrences(of: sym.signature, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return "### \(sym.signature) (SKELETON - \(reason))\n\(trimmed)\n\n"
        }
        return "### \(fileName) (SKELETON - \(reason))\n\(skeleton)\n\n"
    }

    public struct RelatedHints: Sendable {
        public var text: String
        public var truncated: Bool
    }

    /// Compact same-file neighborhood index for a surgical symbol hit.
    /// Surfaces callers/callees/siblings without paying for their bodies.
    func buildSameFileRelatedHints(
        symbol: SymbolRecord,
        fileSymbols: [SymbolRecord],
        fileRefs: [SymbolRecord.Reference],
        limitPerCategory: Int = 5
    ) -> RelatedHints {
        let fileDefsByName = Dictionary(grouping: fileSymbols, by: \.name)
        let primaryNames = Set([symbol.name, symbol.qualifiedName])

        var callees: [String] = []
        var seenCallees = Set<String>()
        for ref in fileRefs where ref.startLine >= symbol.startLine && ref.startLine <= symbol.endLine {
            guard !primaryNames.contains(ref.name) else { continue }
            guard let defs = fileDefsByName[ref.name], !defs.isEmpty else { continue }
            let label = formatRelatedSymbolLabel(defs[0])
            if seenCallees.insert(label).inserted {
                callees.append(label)
            }
        }

        var callers: [String] = []
        var seenCallers = Set<String>()
        for ref in fileRefs where ref.name == symbol.name
            && (ref.startLine < symbol.startLine || ref.startLine > symbol.endLine)
        {
            let label: String
            if let ctx = ref.context, !ctx.isEmpty {
                if let defs = fileDefsByName[ctx], let def = defs.first {
                    label = formatRelatedSymbolLabel(def)
                } else {
                    label = "\(ctx) (L\(ref.startLine))"
                }
            } else {
                label = "L\(ref.startLine)"
            }
            if seenCallers.insert(label).inserted {
                callers.append(label)
            }
        }

        var siblings: [String] = []
        var seenSiblings = Set<String>()
        if let enclosing = symbol.enclosingType, !enclosing.isEmpty {
            for other in fileSymbols
            where other.qualifiedName != symbol.qualifiedName
                && other.enclosingType == enclosing
            {
                let label = formatRelatedSymbolLabel(other)
                if seenSiblings.insert(label).inserted {
                    siblings.append(label)
                }
            }
        }

        var lines: [String] = []
        var truncatedCategories = 0

        func appendCategory(title: String, items: [String]) {
            guard !items.isEmpty else { return }
            let shown = Array(items.prefix(limitPerCategory))
            let omitted = items.count - shown.count
            var text = "- \(title): \(shown.joined(separator: ", "))"
            if omitted > 0 {
                truncatedCategories += 1
                text += " — +\(omitted) more not listed"
            }
            lines.append(text)
        }

        appendCategory(title: "Same-file callers", items: callers)
        appendCategory(title: "Same-file callees", items: callees)
        if !siblings.isEmpty {
            let scope = symbol.enclosingType ?? "type"
            appendCategory(title: "Sibling members in \(scope)", items: siblings)
        }

        guard !lines.isEmpty else {
            return RelatedHints(text: "", truncated: false)
        }

        let text = """
        Same-file related:
        \(lines.joined(separator: "\n"))

        """
        return RelatedHints(text: text, truncated: truncatedCategories > 0)
    }

    func packingGuidanceSection(relatedHintCap: Int, anyTruncated: Bool) -> String {
        var body =
            """
            ## Packing notes
            This packet is **surgical**: primary hits include symbol bodies plus same-file \
            related name lists (not neighbor bodies). Neighbor bodies are omitted in surgical mode. \
            Prefer surgical for focused edits.
            When you need whole-module or whole-file context — e.g. refactoring across many \
            siblings, file-level imports/order, or when "Same-file related" lists several \
            neighbors you must read together — call **`gather_code_context` again with `mode=full`** \
            (CLI: `cckit pack --full`). That returns full file bodies for primary hits instead of slices.
            For one-off neighbors without a full pack: call **`symbol`** (by name) or **`outline`** (by path).
            """
        if anyTruncated {
            body +=
                " Lists above are capped at \(relatedHintCap) per category; omitted neighbors are "
                + "only available via a full (non-surgical) pack or by fetching them individually."
        }
        return body + "\n\n"
    }

    func shouldPreferFullFile(symbol: SymbolRecord, content: String, body: String) -> Bool {
        if symbol.kind == .file {
            return true
        }
        let lines = content.components(separatedBy: .newlines)
        if lines.count <= Self.tinyFileLineThreshold {
            return true
        }
        guard !body.isEmpty, !content.isEmpty else {
            return false
        }
        let coverage = Double(body.utf8.count) / Double(content.utf8.count)
        return coverage >= fullFileCoverageThreshold
    }

    // MARK: - Helpers

    private func formatRelatedSymbolLabel(_ symbol: SymbolRecord) -> String {
        "\(symbol.name) (\(symbol.kind.rawValue) L\(symbol.startLine)-\(symbol.endLine))"
    }

    private func readFile(path: String, rootURL: URL) -> String? {
        let fullURL = rootURL.appendingPathComponent(path)
        return try? String(contentsOf: fullURL, encoding: .utf8)
    }

    private func extractFailureSummary(from logPath: String) -> String {
        do {
            let content = try String(contentsOfFile: logPath, encoding: .utf8)
            let lines = content.components(separatedBy: .newlines)
            let errorLines = lines.filter {
                $0.lowercased().contains("error:") || $0.lowercased().contains("failed")
            }
            if errorLines.isEmpty {
                return "No explicit errors found in log."
            }
            // Cap per-line length: one minified-bundle error line once leaked
            // ~50k tokens into a packet.
            return errorLines.prefix(10)
                .map { String($0.prefix(Self.failureLineMaxChars)) }
                .joined(separator: "\n")
        } catch {
            return "Could not read failure log: \(error.localizedDescription)"
        }
    }
}
