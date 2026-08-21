import ArgumentParser
import Foundation

struct ExplainCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "explain",
        abstract: "Explains stored index or context state."
    )

    @Argument(help: "The topic to explain (index, pack, symbol).")
    var topic: String

    @Argument(help: "Additional context for the explanation.")
    var context: String?

    func run() async throws {
        switch topic {
        case "index":
            print("The index is stored in .cckit/index.sqlite (metadata) and .cckit/repo.wax (semantic search).")
        case "pack":
            print(
                """
                Context packing combines repo map, failure summaries, and semantic search results.

                Modes (MCP gather_code_context / CLI cckit pack):
                - auto (default): assemble surgical, full, and raw; deliver the smallest.
                  Raw is primary files plus the packet banner (not a literal cat).
                - surgical (--surgical): symbol body slices plus same-file related name
                  lists (callers/callees/siblings); neighbor bodies omitted.
                - full (--full / mode=full): whole primary file bodies.

                Escalation: if a surgical packet is not enough, call gather_code_context
                again with mode=full (CLI: cckit pack --full). For one-off neighbors,
                use symbol(name) or outline(path).
                """.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        case "symbol":
            print("Symbols are extracted using SwiftSyntax and include types, functions, and properties.")
        default:
            print("No explanation available for '\(topic)'.")
        }
    }
}
