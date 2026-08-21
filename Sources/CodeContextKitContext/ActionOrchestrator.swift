import Foundation
import CodeContextKitCore
import CodeContextKitRetrieval

/// Provenance for `.cckit/action_history.jsonl` rows.
///
/// The MCP shim sets `CCKIT_CALLER=mcp` on the subprocess. Direct CLI use
/// leaves it unset, so rows stay `"type": "cli"`.
public enum ActionCaller: Sendable {
    public static let callerEnv = "CCKIT_CALLER"

    public static func recordType(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let raw = environment[callerEnv]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if raw == "mcp" { return "mcp" }
        return "cli"
    }
}

/// Manages the history of actions (CLI commands and agent interactions).
/// Persists to `.cckit/action_history.jsonl` so `index --clean` does not wipe telemetry.
public actor ActionOrchestrator {
    private let wax: WaxStore?
    private let history: ActionHistoryStore
    private var activeActions: [Int64: Date] = [:]

    public init(wax: WaxStore, repoRoot: String = ".") {
        self.wax = wax
        self.history = ActionHistoryStore(repoRoot: repoRoot)
    }

    /// Ledger-only path — skips Wax/MiniLM so locators and `map` do not load an embedder.
    public init(repoRoot: String = ".") {
        self.wax = nil
        self.history = ActionHistoryStore(repoRoot: repoRoot)
    }

    /// Registers a new action and returns its unique ID.
    public func startAction(prompt: String, toolName: String? = nil, type: String = "web") throws -> Int64 {
        let id = try history.nextId()
        let record = ActionRecord(
            id: id,
            prompt: prompt,
            toolName: toolName,
            type: type,
            status: "pending"
        )
        try history.append(record)
        activeActions[id] = Date()
        return id
    }

    /// Finalizes an action with its result and usage stats.
    public func finishAction(id: Int64, response: String, status: String = "completed") async throws {
        guard let startTime = activeActions.removeValue(forKey: id) else { return }
        let duration = Int(Date().timeIntervalSince(startTime) * 1000)

        let existing = try? history.loadEntries().first(where: { $0.id == id })
        let promptTokens = await countTokens("prompt: " + (existing?.prompt ?? ""))
        let responseTokens = await countTokens(response)
        let tokens = promptTokens + responseTokens

        var updated = existing ?? ActionRecord(id: id, prompt: "", type: "web")
        updated.id = id
        updated.status = status
        updated.durationMs = duration
        updated.tokensUsed = tokens
        updated.response = response
        try history.upsert(updated)
    }

    /// Retrieves recent actions for visualization (newest first).
    public func getRecentActions(limit: Int = 20) throws -> [ActionRecord] {
        try history.recent(limit: limit)
    }

    /// Records a simple CLI action that has already completed.
    public func recordCLIAction(
        command: String,
        toolName: String,
        durationMs: Int,
        tokensUsed: Int = 0,
        sourceWholeFileTokens: Int = 0,
        status: String = "completed"
    ) throws {
        let id = try history.nextId()
        let record = ActionRecord(
            id: id,
            prompt: command,
            toolName: toolName,
            type: ActionCaller.recordType(),
            tokensUsed: tokensUsed,
            sourceWholeFileTokens: sourceWholeFileTokens,
            durationMs: durationMs,
            status: status
        )
        try history.append(record)
    }

    private func countTokens(_ text: String) async -> Int {
        if let wax {
            return await wax.countTokens(text)
        }
        return TokenEstimator.shared.estimate(text)
    }
}
