import ArgumentParser
import Foundation
import CodeContextKitCore
import CodeContextKitStorage
import CodeContextKitRetrieval
import CodeContextKitContext

struct PackCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pack",
        abstract: "Creates a model-ready context packet."
    )

    @Option(help: "The task description.")
    var task: String

    @Option(help: "Maximum token count for the packet (ceiling, not a fill target). Default: 12000.")
    var budget: Int = 12000

    @Option(help: "The output file path.")
    var output: String?

    @Option(help: "A failure log file to extract context from.")
    var failure: String?

    @Flag(
        name: .long,
        help: """
            Force whole-file primary dumps. Default is auto (smallest of surgical, \
            full, and raw). Tiny files (≤100 lines) never get related-hint chrome \
            in surgical mode.
            """
    )
    var full: Bool = false

    @Flag(
        name: .long,
        help: "Force surgical packing only (no dual pack). Default is auto for token savings."
    )
    var surgical: Bool = false

    @Flag(
        name: .long,
        help: """
            Cheap first look (~≤1500 tokens): primary hit list with qualified names, \
            line ranges, body-size estimates, map and skeletons — no bodies. Expand \
            with symbol() or re-gather with --surgical/--full.
            """
    )
    var preview: Bool = false

    @Flag(help: "Skip appending this pack to .cckit/pack_savings.jsonl.")
    var noLedger: Bool = false

    @Flag(
        name: .long,
        help: """
            Pack from the SQLite locators only — no Wax arena, no MiniLM fill. \
            Required on lexical-only indexes (indexed with --no-semantic); \
            otherwise optional.
            """
    )
    var noSemantic: Bool = false

    func run() async throws {
        let startTime = Date()
        let dbPath = ".cckit/index.sqlite"
        let waxPath = ".cckit/repo.wax"
        let lexicalOnly = noSemantic
        guard lexicalOnly || FileManager.default.fileExists(atPath: waxPath) else {
            print("Error: Index not found. Run 'cckit index' first (or pass --no-semantic for a lexical-only index).")
            throw ExitCode.failure
        }

        guard FileManager.default.fileExists(atPath: dbPath) else {
            print("Error: Index not found. Run 'cckit index' first.")
            throw ExitCode.failure
        }

        if !lexicalOnly {
            do {
                try WaxEmbedderIdentity.requireCurrent()
            } catch {
                print("Error: \(error.localizedDescription)")
                throw ExitCode.failure
            }
        }

        let db = try Database(path: dbPath)
        var breachWarning: String?
        let wax: WaxStore? = lexicalOnly ? nil : try await WaxStore(path: waxPath)
        if let wax {
            do {
                try await wax.requireEmbeddings()
            } catch {
                print("Error: \(error.localizedDescription)")
                throw ExitCode.failure
            }

            // Read-path integrity gate: the store opening is not proof it is
            // serviceable. A truncated arena (interrupted rebuild) or an armed
            // breach marker must be visible here — a silent `0 symbols` packet
            // reads as a confident negative to any agent consuming it.
            let gate = await WaxReadGate.evaluate(waxPath: waxPath, cckitDir: ".cckit", db: db, wax: wax)
            if let fault = gate.hardFault {
                print("Error: \(fault.localizedDescription)")
                throw ExitCode.failure
            }
            if let warning = gate.breachWarning {
                InteractiveProgress.write("Warning: \(warning)\n", to: .standardError)
            }
            breachWarning = gate.breachWarning
        }

        let actionOrchestrator = ActionOrchestrator(repoRoot: ".")
        let packer = ContextPacker(db: db, wax: wax, rootPath: ".")
        if full && surgical {
            print("Error: use either --full or --surgical, not both.")
            throw ExitCode.failure
        }
        if preview && (full || surgical) {
            print("Error: --preview cannot be combined with --full or --surgical.")
            throw ExitCode.failure
        }
        let mode: PackMode = preview ? .preview : (full ? .full : (surgical ? .surgical : .auto))

        let result = try await packer.pack(
            task: task,
            budget: budget,
            failureLog: failure,
            mode: mode
        )

        // Budget truncation used to be silent: a low ceiling trimmed every
        // primary out of the packet and still exited 0 with negative savings.
        // Distinguish a true absence (probe finds nothing either) from
        // truncation (probe at a generous budget finds content).
        var truncation: (unconstrainedTokens: Int, primaries: Int)?
        if !preview, result.primaryCount == 0 {
            // Probing is budget-shaped, not arena-shaped: lexical packs need
            // it too. One extra assembly only on the failure path.
            let probeBudget = max(budget * 4, 12000)
            if let probe = try? await packer.pack(
                task: task,
                budget: probeBudget,
                failureLog: nil,
                mode: mode
            ), probe.primaryCount > 0 {
                let probeTokens = await packer.estimateTokens(probe.packet)
                truncation = (probeTokens, probe.primaryCount)
            }
        }

        let duration = Int(Date().timeIntervalSince(startTime) * 1000)
        let fullCommand = "cckit " + CommandLine.arguments.dropFirst().joined(separator: " ")
        try await actionOrchestrator.recordCLIAction(
            command: fullCommand,
            toolName: "pack",
            durationMs: duration,
            tokensUsed: result.deliveredTokens
        )

        // Preview is a routing aid (map + names), not a compressed delivery —
        // comparing it against whole-file baselines produces fake negatives.
        let recordsSavings = !noLedger && mode != .preview
        if recordsSavings {
            let repo = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).path
            try PackSavingsLedger(repoRoot: ".").record(
                from: result,
                task: task,
                repo: repo,
                budget: budget
            )
        }

        let freshness = IndexFreshness.check(repoRoot: ".")
        if let warning = freshness.softWarning {
            InteractiveProgress.write(warning + "\n", to: .standardError)
        }

        // Zero primaries from a run that DID consult Wax against a populated
        // keep-set is far more likely a retrieval fault than a true absence.
        // Distinguish it (and the armed breach marker) inside the packet and
        // the machine-readable stats so callers can tell a real negative from
        // a broken one.
        var semanticUnavailable = false
        if result.primaryCount == 0, result.waxFillRan, result.waxHitCount == 0, let wax {
            semanticUnavailable = ((try? db.waxMandateCount()) ?? 0) > 0
        }
        var packet = result.packet
        if let truncation {
            packet = ContextPacker.appendBudgetNotice(
                to: packet,
                budget: budget,
                unconstrainedTokens: truncation.unconstrainedTokens,
                primaries: truncation.primaries
            )
            InteractiveProgress.write(
                "Warning: budget \(budget) delivered 0 primaries for this task; an unconstrained pack is "
                    + "~\(truncation.unconstrainedTokens) tokens (\(truncation.primaries) primaries). "
                    + "Raise --budget to retrieve real context.\n",
                to: .standardError
            )
        }
        if semanticUnavailable || breachWarning != nil {
            packet = Self.appendDegradedNotice(
                to: packet,
                semanticUnavailable: semanticUnavailable,
                breachWarning: breachWarning
            )
        }

        if let outputPath = output {
            try packet.write(toFile: outputPath, atomically: true, encoding: .utf8)
            print("Context packet written to \(outputPath)")
            print(
                "Pack metrics: delivered \(result.deliveredTokens) (\(result.deliveredMode.rawValue)) · "
                    + "source whole files \(result.sourceWholeFileTokens) · "
                    + "saved \(PackSavingsLedger.formatTokenCount(result.tokensSavedVersusSourceFiles))"
            )
        } else {
            print(packet)
            // Machine-readable trailing line for the MCP shim (CCKIT_CALLER=mcp):
            // powers the per-response savings footer without parsing prose.
            if ProcessInfo.processInfo.environment["CCKIT_CALLER"] == "mcp", mode != .preview {
                let stats: [String: Any] = [
                    "deliveredTokens": result.deliveredTokens,
                    "sourceWholeFileTokens": result.sourceWholeFileTokens,
                    "tokensSaved": result.tokensSavedVersusSourceFiles,
                    "deliveredMode": result.deliveredMode.rawValue,
                ]
                var enriched = stats
                if semanticUnavailable {
                    enriched["semanticUnavailable"] = true
                }
                if let warning = breachWarning {
                    enriched["breachWarning"] = warning
                }
                if let truncation {
                    enriched["budgetTruncated"] = true
                    enriched["unconstrainedTokens"] = truncation.unconstrainedTokens
                }
                if let data = try? JSONSerialization.data(withJSONObject: enriched, options: [.sortedKeys]) {
                    print("PACK_STATS \(String(decoding: data, as: UTF8.self))")
                }
            }
        }
        if let wax {
            try? await wax.close()
        }
    }


    /// Append a degraded-retrieval notice to a packet body. Kept as a trailing
    /// section so packet consumers see it without disturbing the banner.
    static func appendDegradedNotice(
        to packet: String,
        semanticUnavailable: Bool,
        breachWarning: String?
    ) -> String {
        var lines: [String] = []
        if semanticUnavailable {
            lines.append(
                "Semantic retrieval returned zero hits against a populated index; " +
                    "this packet's `primary: 0 symbols` may be a retrieval fault, not a true absence. " +
                    "Verify with lexical search before concluding something does not exist."
            )
        }
        if let breachWarning {
            lines.append(breachWarning)
        }
        guard !lines.isEmpty else { return packet }
        return packet.trimmingCharacters(in: .newlines) + "\n\n## Warning\n\n" + lines.joined(separator: "\n") + "\n"
    }
}
