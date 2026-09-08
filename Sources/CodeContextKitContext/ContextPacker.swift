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
    /// Primaries dropped by assembly to stay under the budget. Zero means the
    /// packet is complete for its primary set (or there was no primary set).
    public let droppedPrimaries: Int
    /// Explicitly requested targets that resolution selected.
    public let requiredTargetIDs: [String]
    /// Targets that actually appear in the delivered packet.
    public let deliveredTargetIDs: [String]
    /// Requested or resolved targets omitted, with reasons.
    public let omitted: [PacketOmission]
    /// True when at least one delivered file's current hash differs from the index.
    public let contentStale: Bool

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
        waxHitCount: Int = 0,
        droppedPrimaries: Int = 0,
        requiredTargetIDs: [String] = [],
        deliveredTargetIDs: [String] = [],
        omitted: [PacketOmission] = [],
        contentStale: Bool = false
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
        self.droppedPrimaries = droppedPrimaries
        self.requiredTargetIDs = requiredTargetIDs
        self.deliveredTargetIDs = deliveredTargetIDs
        self.omitted = omitted
        self.contentStale = contentStale
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
    private let wax: WaxStore?
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
    /// Total token budget reserved for a failure summary (all lines together).
    public static let failureSummaryMaxTokens: Int = 200
    /// Tokens reserved for banner, omission notices, and truncation warnings.
    public static let metadataReserveTokens: Int = 80
    /// Preview packets stay under this many tokens regardless of requested budget —
    /// the tier exists so looking is cheap.
    public static let previewBudgetCap: Int = 1500

    public init(
        db: Database,
        wax: WaxStore?,
        rootPath: String = ".",
        maxPrimarySymbols: Int = 5,
        maxAssociatedSkeletons: Int = 3
    ) {
        self.db = db
        self.wax = wax
        self.rootPath = rootPath
        self.maxPrimarySymbols = maxPrimarySymbols
        self.maxAssociatedSkeletons = maxAssociatedSkeletons
        self.repoMapBuilder = RepoMapBuilder(db: db, counter: { text in await wax?.countTokens(text) ?? TokenEstimator.shared.estimate(text) })
    }

    /// True when a semantic arena backs this packer. Lexical-only packers
    /// skip the MiniLM fill pass; retrieval relies on lexical identifier hits.
    public var hasSemantic: Bool { wax != nil }

    /// Token counting works identically without an arena (WaxStore.countTokens
    /// delegates to the shared estimator).
    private func countTokens(_ text: String) async -> Int {
        await wax?.countTokens(text) ?? TokenEstimator.shared.estimate(text)
    }

    /// Public token estimate for callers measuring packets outside the pack
    /// path (e.g. the CLI's budget-truncation probe).
    public func estimateTokens(_ text: String) async -> Int {
        await countTokens(text)
    }

    /// Append a budget-truncation notice to a packet body. A low budget used
    /// to silently deliver a header-only packet at exit 0; this makes the
    /// truncation visible inside the packet the caller actually reads.
    public static func appendBudgetNotice(
        to packet: String,
        budget: Int,
        unconstrainedTokens: Int,
        primaries: Int
    ) -> String {
        let notice =
            "Budget \(budget) truncated this packet to zero primaries. An unconstrained pack for this "
                + "task is ~\(unconstrainedTokens) tokens across \(primaries) primaries; the delivered "
                + "packet is header chrome only. Re-run with a larger --budget."
        return packet.trimmingCharacters(in: .newlines) + "\n\n## Warning\n\n" + notice + "\n"
    }

    public func pack(
        task: String,
        budget: Int,
        failureLog: String? = nil,
        mode: PackMode = .auto,
        mapBudget: Int? = nil,
        relatedHintCap: Int = 5
    ) async throws -> PackResult {
        let resolver = PacketTargetResolver(
            db: db,
            wax: wax,
            rootPath: rootPath,
            maxPrimarySymbols: maxPrimarySymbols
        )
        let evidence = try await resolver.resolve(task: task)

        if mode == .auto {
            let surgical = try await render(
                evidence: evidence,
                task: task,
                budget: budget,
                failureLog: failureLog,
                mode: .surgical,
                mapBudget: mapBudget,
                relatedHintCap: relatedHintCap
            )
            let raw = try await render(
                evidence: evidence,
                task: task,
                budget: budget,
                failureLog: failureLog,
                mode: .raw,
                mapBudget: 0,
                relatedHintCap: relatedHintCap
            )
            let surgicalTokens = await countTokens(surgical.packet)
            let rawTokens = await countTokens(raw.packet)
            var counted: [(PackAssembly, PackMode, Int)] = [
                (surgical, .surgical, surgicalTokens),
                (raw, .raw, rawTokens),
            ]
            if requiredCoverage(surgical, evidence: evidence) < evidence.required.count
                || surgicalTokens > rawTokens
            {
                let full = try await render(
                    evidence: evidence,
                    task: task,
                    budget: budget,
                    failureLog: failureLog,
                    mode: .full,
                    mapBudget: mapBudget,
                    relatedHintCap: relatedHintCap
                )
                let fullTokens = await countTokens(full.packet)
                counted.append((full, .full, fullTokens))
            }
            let picked = pickEqualCoverage(counted, evidence: evidence)
            let sourceWhole = await countWholeFileTokens(paths: picked.assembly.primaryFilePaths)
            return makeResult(
                assembly: picked.assembly,
                requested: .auto,
                delivered: picked.mode,
                tokens: picked.tokens,
                surgicalTokens: surgicalTokens,
                fullBaselineTokens: counted.first(where: { $0.1 == .full })?.2,
                sourceWhole: sourceWhole,
                evidence: evidence
            )
        }

        if mode == .preview {
            let previewBudget = min(budget, Self.previewBudgetCap)
            let assembled = try await render(
                evidence: evidence,
                task: task,
                budget: previewBudget,
                failureLog: failureLog,
                mode: .preview,
                mapBudget: min(mapBudget ?? 400, 400),
                relatedHintCap: relatedHintCap
            )
            let tokens = await countTokens(assembled.packet)
            let sourceWhole = await countWholeFileTokens(paths: assembled.primaryFilePaths)
            return makeResult(
                assembly: assembled,
                requested: .preview,
                delivered: .preview,
                tokens: tokens,
                surgicalTokens: nil,
                fullBaselineTokens: nil,
                sourceWhole: sourceWhole,
                evidence: evidence
            )
        }

        let assembled = try await render(
            evidence: evidence,
            task: task,
            budget: budget,
            failureLog: failureLog,
            mode: mode == .raw ? .raw : mode,
            mapBudget: mapBudget,
            relatedHintCap: relatedHintCap
        )
        let tokens = await countTokens(assembled.packet)
        let sourceWhole = await countWholeFileTokens(paths: assembled.primaryFilePaths)
        return makeResult(
            assembly: assembled,
            requested: mode == .raw ? .full : mode,
            delivered: mode,
            tokens: tokens,
            surgicalTokens: mode == .surgical ? tokens : nil,
            fullBaselineTokens: (mode == .full || mode == .raw) ? tokens : nil,
            sourceWhole: sourceWhole,
            evidence: evidence
        )
    }

    private func requiredCoverage(_ assembly: PackAssembly, evidence: PacketEvidence) -> Int {
        let delivered = Set(assembly.deliveredTargetIDs)
        return evidence.required.filter { delivered.contains($0.targetID) }.count
    }

    private func pickEqualCoverage(
        _ candidates: [(PackAssembly, PackMode, Int)],
        evidence: PacketEvidence
    ) -> (assembly: PackAssembly, mode: PackMode, tokens: Int) {
        let requiredCount = evidence.required.count
        let complete = candidates.filter { requiredCoverage($0.0, evidence: evidence) == requiredCount }
        let pool = complete.isEmpty ? candidates : complete
        let bestCoverage = pool.map { requiredCoverage($0.0, evidence: evidence) }.max() ?? 0
        let covered = pool.filter { requiredCoverage($0.0, evidence: evidence) == bestCoverage }
        let winner = covered.min(by: { $0.2 < $1.2 }) ?? candidates[0]
        return (winner.0, winner.1, winner.2)
    }

    private func makeResult(
        assembly: PackAssembly,
        requested: PackMode,
        delivered: PackMode,
        tokens: Int,
        surgicalTokens: Int?,
        fullBaselineTokens: Int?,
        sourceWhole: Int,
        evidence: PacketEvidence
    ) -> PackResult {
        PackResult(
            packet: assembly.packet,
            requestedMode: requested,
            deliveredMode: delivered,
            deliveredTokens: tokens,
            surgicalTokens: surgicalTokens,
            fullBaselineTokens: fullBaselineTokens,
            sourceWholeFileTokens: sourceWhole,
            primaryCount: assembly.primaryCount,
            waxFillRan: evidence.waxFillRan,
            waxHitCount: evidence.waxHitCount,
            droppedPrimaries: assembly.droppedPrimaries,
            requiredTargetIDs: evidence.requiredIDs,
            deliveredTargetIDs: assembly.deliveredTargetIDs,
            omitted: assembly.omissions,
            contentStale: evidence.contentStale
        )
    }

    private struct PackAssembly: Sendable {
        var packet: String
        /// Primary files actually emitted (slices or full dumps). Savings baseline
        /// uses this set — associated skeletons are not whole-file Reads.
        var primaryFilePaths: Set<String>
        var primaryCount: Int
        /// Primaries that did not fit the budget.
        var droppedPrimaries: Int = 0
        var deliveredTargetIDs: [String] = []
        var omissions: [PacketOmission] = []
    }

    private func countWholeFileTokens(paths: Set<String>) async -> Int {
        let rootURL = URL(fileURLWithPath: rootPath)
        var total = 0
        for path in paths.sorted() {
            guard let content = readFile(path: path, rootURL: rootURL) else { continue }
            total += await countTokens(content)
        }
        return total
    }

    private func render(
        evidence: PacketEvidence,
        task: String,
        budget: Int,
        failureLog: String?,
        mode: PackMode,
        mapBudget: Int?,
        relatedHintCap: Int
    ) async throws -> PackAssembly {
        let bodyBudget = max(32, budget - Self.metadataReserveTokens)
        var output = "# Context Packet\n\n"
        let taskText = truncateToBudget(task, tokens: min(200, bodyBudget / 4))
        output += "## Task\n\(taskText)\n\n"

        let skipFiller = SemanticIndexPolicy.shouldSkipPackFiller(task: task)
        let targets = evidence.required + evidence.optional
        var associatedFiles: [String: String] = [:]
        if !skipFiller {
            for target in evidence.required {
                let refs = try db.getReferencesInFile(path: target.symbol.filePath)
                for ref in refs {
                    let defs = try db.getSymbols(qualifiedName: ref.name)
                    for def in defs where def.filePath != target.symbol.filePath {
                        let leaf = target.symbol.filePath.split(separator: "/").last.map(String.init)
                            ?? target.symbol.filePath
                        associatedFiles[def.filePath] = "Defines '\(def.name)' used in '\(leaf)'"
                    }
                }
            }
        }

        let resolvedMapBudget: Int
        if mode == .raw || mode == .preview {
            resolvedMapBudget = mode == .preview ? (mapBudget ?? 0) : 0
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

        if let failureLog {
            let summary = extractFailureSummary(from: failureLog, tokenBudget: Self.failureSummaryMaxTokens)
            output += "## Failure Summary\n\(summary)\n\n"
        }

        var currentTokens = await countTokens(output)
        var primarySymbolCount = 0
        var primaryFullFileCount = 0
        var associatedSkeletonCount = 0
        var droppedPrimaries = 0
        var emittedFullPaths = Set<String>()
        var primaryFilePaths = Set<String>()
        var deliveredIDs: [String] = []
        var omissions = evidence.omissions
        var anyHintsTruncated = false

        func content(for path: String) -> String? {
            evidence.fileContents[path] ?? readFile(path: path, rootURL: URL(fileURLWithPath: rootPath))
        }

        func tryAppend(_ section: String) async -> Bool {
            let sectionTokens = await countTokens(section)
            if currentTokens + sectionTokens <= bodyBudget {
                output += section
                currentTokens += sectionTokens
                return true
            }
            return false
        }

        if mode == .preview {
            output += "## Primary hits\n\n"
            output += "Bodies omitted (preview). Fetch one with `symbol` "
            output += "(qualified name), or re-gather with `mode=surgical` for slices "
            output += "or `mode=full` for whole files.\n\n"
            for target in targets {
                let sym = target.symbol
                let bodyTokens: Int
                if let fileContent = content(for: sym.filePath) {
                    let slice = FreshSymbolResolver.slice(
                        symbol: sym,
                        content: fileContent,
                        indexedHash: evidence.indexedHashes[sym.filePath],
                        currentHash: evidence.sourceHashes[sym.filePath] ?? ""
                    )
                    bodyTokens = await countTokens(slice.body)
                } else {
                    bodyTokens = 0
                }
                var line = "- \(sym.qualifiedName) (\(sym.kind.rawValue) · "
                line += "\(sym.filePath):\(sym.startLine)-\(sym.endLine)"
                if bodyTokens > 0 {
                    line += " · body ≈\(bodyTokens) tokens"
                }
                if !ImplementationSpanPolicy.hasReliableImplementationSpan(filePath: sym.filePath) {
                    line += " · locator-only"
                }
                line += ")\n"
                if await tryAppend(line) {
                    primarySymbolCount += 1
                    primaryFilePaths.insert(sym.filePath)
                    deliveredIDs.append(target.targetID)
                } else {
                    droppedPrimaries += 1
                    omissions.append(PacketOmission(targetID: target.targetID, reason: "budget"))
                }
            }
            output += "\n"
            return await finishPacket(
                output: output,
                budget: budget,
                mode: mode,
                primarySymbolCount: primarySymbolCount,
                primaryFullFileCount: 0,
                associatedSkeletonCount: 0,
                primaryFilePaths: primaryFilePaths,
                droppedPrimaries: droppedPrimaries,
                deliveredIDs: deliveredIDs,
                omissions: omissions
            )
        }

        if mode != .raw {
            output += "## Surgical Context\n\n"
        }

        if mode == .full || mode == .raw {
            var stagedFiles: [String] = []
            var seenPaths = Set<String>()
            var idsByFile: [String: [String]] = [:]
            for target in targets {
                idsByFile[target.symbol.filePath, default: []].append(target.targetID)
                if seenPaths.insert(target.symbol.filePath).inserted {
                    stagedFiles.append(target.symbol.filePath)
                }
            }

            for path in stagedFiles {
                guard let fileContent = content(for: path) else { continue }
                let section = formatFullFileSection(path: path, content: fileContent)
                if await tryAppend(section) {
                    primaryFullFileCount += 1
                    emittedFullPaths.insert(path)
                    primaryFilePaths.insert(path)
                    deliveredIDs.append(contentsOf: idsByFile[path] ?? [])
                } else {
                    droppedPrimaries += (idsByFile[path] ?? []).count
                    for id in idsByFile[path] ?? [] {
                        omissions.append(PacketOmission(targetID: id, reason: "budget"))
                    }
                }
            }
        } else {
            for target in targets {
                let sym = target.symbol
                guard let fileContent = content(for: sym.filePath) else { continue }
                let slice = FreshSymbolResolver.slice(
                    symbol: sym,
                    content: fileContent,
                    indexedHash: evidence.indexedHashes[sym.filePath],
                    currentHash: evidence.sourceHashes[sym.filePath] ?? ""
                )
                let body = slice.body
                if slice.locatorOnly {
                    let note = formatLocatorSection(symbol: slice.symbol, locator: body)
                    if await tryAppend(note) {
                        primarySymbolCount += 1
                        primaryFilePaths.insert(sym.filePath)
                        deliveredIDs.append(target.targetID)
                    } else {
                        droppedPrimaries += 1
                        omissions.append(PacketOmission(targetID: target.targetID, reason: "budget"))
                    }
                    continue
                }

                let preferFullFast = shouldPreferFullFile(symbol: slice.symbol, content: fileContent, body: body)
                let section: String
                let emittedAsFull: Bool
                if preferFullFast {
                    if emittedFullPaths.contains(sym.filePath) {
                        deliveredIDs.append(target.targetID)
                        continue
                    }
                    section = formatFullFileSection(path: sym.filePath, content: fileContent)
                    emittedAsFull = true
                } else {
                    let fileSymbols = try db.getSymbols(path: sym.filePath)
                    let fileRefs = try db.getReferencesInFile(path: sym.filePath)
                    let related = buildSameFileRelatedHints(
                        symbol: slice.symbol,
                        fileSymbols: fileSymbols,
                        fileRefs: fileRefs,
                        limitPerCategory: relatedHintCap
                    )
                    anyHintsTruncated = anyHintsTruncated || related.truncated
                    let symbolSection = formatSymbolSection(
                        symbol: slice.symbol,
                        body: body,
                        relatedHints: related.text
                    )
                    if !emittedFullPaths.contains(sym.filePath) {
                        let fullSection = formatFullFileSection(path: sym.filePath, content: fileContent)
                        let symbolTokens = await countTokens(symbolSection)
                        let fullTokens = await countTokens(fullSection)
                        if fullTokens <= symbolTokens {
                            section = fullSection
                            emittedAsFull = true
                        } else {
                            section = symbolSection
                            emittedAsFull = false
                        }
                    } else {
                        deliveredIDs.append(target.targetID)
                        continue
                    }
                }

                if await tryAppend(section) {
                    primaryFilePaths.insert(sym.filePath)
                    deliveredIDs.append(target.targetID)
                    if emittedAsFull {
                        primaryFullFileCount += 1
                        emittedFullPaths.insert(sym.filePath)
                    } else {
                        primarySymbolCount += 1
                    }
                } else {
                    droppedPrimaries += 1
                    omissions.append(PacketOmission(targetID: target.targetID, reason: "budget"))
                }
            }
        }

        if mode != .raw && mode != .preview {
            let primaryPaths = Set(targets.map { $0.symbol.filePath })
            for (path, reason) in associatedFiles
            where !primaryPaths.contains(path) && !emittedFullPaths.contains(path) {
                if associatedSkeletonCount >= maxAssociatedSkeletons { break }
                let symbols = try db.getSymbols(path: path)
                let section = formatSkeletonSection(path: path, reason: reason, symbols: symbols)
                if await tryAppend(section) {
                    associatedSkeletonCount += 1
                }
            }
        }

        if mode == .surgical && primarySymbolCount > 0 && anyHintsTruncated {
            let guidance = packingGuidanceSection(
                relatedHintCap: relatedHintCap,
                anyTruncated: true
            )
            _ = await tryAppend(guidance)
        }

        if !omissions.isEmpty {
            var notice = "## Omitted\n"
            for omission in omissions.prefix(12) {
                notice += "- \(omission.targetID): \(omission.reason)\n"
            }
            notice += "\n"
            _ = await tryAppend(notice)
        }

        return await finishPacket(
            output: output,
            budget: budget,
            mode: mode,
            primarySymbolCount: primarySymbolCount,
            primaryFullFileCount: primaryFullFileCount,
            associatedSkeletonCount: associatedSkeletonCount,
            primaryFilePaths: primaryFilePaths,
            droppedPrimaries: droppedPrimaries,
            deliveredIDs: deliveredIDs,
            omissions: omissions
        )
    }

    private func finishPacket(
        output: String,
        budget: Int,
        mode: PackMode,
        primarySymbolCount: Int,
        primaryFullFileCount: Int,
        associatedSkeletonCount: Int,
        primaryFilePaths: Set<String>,
        droppedPrimaries: Int,
        deliveredIDs: [String],
        omissions: [PacketOmission]
    ) async -> PackAssembly {
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

        var workingBody = body
        var extra = ""
        var packet = makeBanner(tokens: 0) + workingBody
        var finalTokens = await countTokens(packet)
        if finalTokens > budget {
            extra =
                "\n## Warning\n\nPacket exceeded the \(budget)-token ceiling after serialization "
                + "(\(finalTokens) tokens). Raise --budget; required targets may be listed under Omitted.\n"
            var guardrail = 0
            while finalTokens > budget && !workingBody.isEmpty && guardrail < 40 {
                let dropCount = max(1, workingBody.count / 5)
                workingBody = String(workingBody.dropLast(dropCount))
                packet = makeBanner(tokens: 0) + workingBody + extra
                finalTokens = await countTokens(packet)
                guardrail += 1
            }
        }
        packet = makeBanner(tokens: finalTokens) + workingBody + extra
        return PackAssembly(
            packet: packet,
            primaryFilePaths: primaryFilePaths,
            primaryCount: primarySymbolCount + primaryFullFileCount,
            droppedPrimaries: droppedPrimaries,
            deliveredTargetIDs: deliveredIDs,
            omissions: omissions
        )
    }

    private func truncateToBudget(_ text: String, tokens: Int) -> String {
        if TokenEstimator.shared.estimate(text) <= tokens { return text }
        var end = text.endIndex
        while end > text.startIndex {
            let candidate = String(text[..<end])
            if TokenEstimator.shared.estimate(candidate) <= tokens {
                return candidate + "…"
            }
            end = text.index(before: end)
        }
        return "…"
    }

    private func formatLocatorSection(symbol: SymbolRecord, locator: String) -> String {
        let header =
            "### \(symbol.name) (LOCATOR · \(symbol.filePath):\(symbol.startLine)-\(symbol.endLine))\n"
        return header
            + "Implementation span is unavailable for this language; declaration line only.\n"
            + "```\n\(locator)\n```\n\n"
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

    private func extractFailureSummary(from logPath: String, tokenBudget: Int = ContextPacker.failureSummaryMaxTokens) -> String {
        do {
            let content = try String(contentsOfFile: logPath, encoding: .utf8)
            let lines = content.components(separatedBy: .newlines)
            let errorLines = lines.filter {
                $0.lowercased().contains("error:") || $0.lowercased().contains("failed")
            }
            if errorLines.isEmpty {
                return "No explicit errors found in log."
            }
            var kept: [String] = []
            var used = 0
            for line in errorLines.prefix(10) {
                let clipped = String(line.prefix(Self.failureLineMaxChars))
                let cost = TokenEstimator.shared.estimate(clipped)
                if used + cost > tokenBudget {
                    kept.append("… failure summary truncated to \(tokenBudget) tokens")
                    break
                }
                kept.append(clipped)
                used += cost
            }
            return kept.joined(separator: "\n")
        } catch {
            return "Could not read failure log: \(error.localizedDescription)"
        }
    }
}
