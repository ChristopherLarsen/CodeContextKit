import Foundation
import Wax
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Deterministic, local-only embeddings keep the harness independent of MiniLM
/// while exercising Wax's real text and vector serialization paths.
private struct DeterministicEmbedder: BatchEmbeddingProvider {
    let dimensions: Int
    let normalize = true
    let executionMode: ProviderExecutionMode = .onDeviceOnly

    var identity: EmbeddingIdentity? {
        EmbeddingIdentity(
            provider: "cckit-audit",
            model: "deterministic",
            dimensions: dimensions,
            normalized: true
        )
    }

    func embed(_ text: String) async throws -> [Float] {
        var state: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            state ^= UInt64(byte)
            state &*= 0x100000001b3
        }
        var vector = [Float](repeating: 0, count: dimensions)
        var squaredNorm: Float = 0
        for index in vector.indices {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let value = Float(Int32(truncatingIfNeeded: state >> 32)) / Float(Int32.max)
            vector[index] = value
            squaredNorm += value * value
        }
        let scale = 1 / sqrt(max(squaredNorm, .leastNonzeroMagnitude))
        return vector.map { $0 * scale }
    }

    func embed(batch texts: [String]) async throws -> [[Float]] {
        var vectors: [[Float]] = []
        vectors.reserveCapacity(texts.count)
        for text in texts {
            vectors.append(try await embed(text))
        }
        return vectors
    }
}

private struct Options {
    var documents = 256
    var deletes = 64
    var payloadBytes = 1_024
    var dimensions = 384
    var sampleEvery = 8
    var outputPath: String?
    var inspectPath: String?
    var keep = false

    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            func value() throws -> String {
                guard index + 1 < arguments.count else {
                    throw HarnessError.usage("missing value for \(argument)")
                }
                index += 1
                return arguments[index]
            }
            switch argument {
            case "--documents": options.documents = try positiveInt(value(), name: argument)
            case "--deletes": options.deletes = try positiveInt(value(), name: argument)
            case "--payload-bytes": options.payloadBytes = try positiveInt(value(), name: argument)
            case "--dimensions": options.dimensions = try positiveInt(value(), name: argument)
            case "--sample-every": options.sampleEvery = try positiveInt(value(), name: argument)
            case "--output": options.outputPath = try value()
            case "--inspect": options.inspectPath = try value()
            case "--keep": options.keep = true
            case "--help", "-h": throw HarnessError.help
            default: throw HarnessError.usage("unknown argument: \(argument)")
            }
            index += 1
        }
        return options
    }

    private static func positiveInt(_ raw: String, name: String) throws -> Int {
        guard let value = Int(raw), value > 0 else {
            throw HarnessError.usage("\(name) must be a positive integer")
        }
        return value
    }
}

private enum HarnessError: LocalizedError {
    case help
    case usage(String)

    var errorDescription: String? {
        switch self {
        case .help: return nil
        case .usage(let message): return message
        }
    }
}

@main
private struct WaxAmplificationHarness {
    static func main() async throws {
        let options: Options
        do {
            options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
        } catch let error as HarnessError {
            if let message = error.errorDescription {
                FileHandle.standardError.write(Data("error: \(message)\n\n".utf8))
            }
            printUsage()
            if case .usage = error { Foundation.exit(2) }
            return
        }

        let fileManager = FileManager.default
        if let inspectPath = options.inspectPath {
            let storeURL = URL(fileURLWithPath: inspectPath).standardizedFileURL
            let memory = try await Memory(at: storeURL)
            print("phase,delete_count,logical_bytes,allocated_bytes,frame_count,pending_frames")
            try await printMeasurement(phase: "inspect", deleteCount: 0, memory: memory, storeURL: storeURL)
            try await memory.close()
            return
        }

        let storeURL: URL
        let ownsDirectory: Bool
        if let outputPath = options.outputPath {
            storeURL = URL(fileURLWithPath: outputPath).standardizedFileURL
            try fileManager.createDirectory(
                at: storeURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: storeURL.path) {
                try fileManager.removeItem(at: storeURL)
            }
            ownsDirectory = false
        } else {
            let directory = fileManager.temporaryDirectory
                .appendingPathComponent("wax-amplification-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            storeURL = directory.appendingPathComponent("amplification.wax")
            ownsDirectory = true
        }
        defer {
            if ownsDirectory, !options.keep {
                try? fileManager.removeItem(at: storeURL.deletingLastPathComponent())
            }
        }

        var config = Memory.Config.default
        config.embedding = .custom(DeterministicEmbedder(dimensions: options.dimensions))
        let memory = try await Memory(at: storeURL, config: config)

        for document in 0..<options.documents {
            let text = makeDocument(index: document, bytes: options.payloadBytes)
            try await memory.save(text, metadata: ["document": String(document)])
        }
        try await memory.flush()

        // Current Wax no longer returns frame IDs from save. Resolve one indexed
        // child per document through the public search result API.
        var indexedFrameIDs: [UInt64] = []
        indexedFrameIDs.reserveCapacity(options.documents)
        var seen = Set<UInt64>()
        for document in 0..<options.documents {
            let searchOptions = Memory.SearchOptions(topK: 8, mode: .textOnly)
            let results = try await memory.search("waxauditdoc\(document)x", options: searchOptions)
            if let match = results.items.first(where: {
                $0.metadata["document"] == String(document) && seen.insert($0.frameId).inserted
            }) {
                indexedFrameIDs.append(match.frameId)
            }
        }

        print("phase,delete_count,logical_bytes,allocated_bytes,frame_count,pending_frames")
        try await printMeasurement(phase: "baseline", deleteCount: 0, memory: memory, storeURL: storeURL)

        let deleteCount = min(options.deletes, indexedFrameIDs.count)
        for (offset, frameID) in indexedFrameIDs.prefix(deleteCount).enumerated() {
            try await memory.delete(frameID: frameID)
            let completed = offset + 1
            if completed == 1 || completed == deleteCount || completed.isMultiple(of: options.sampleEvery) {
                try await printMeasurement(
                    phase: "delete",
                    deleteCount: completed,
                    memory: memory,
                    storeURL: storeURL
                )
            }
        }

        try await memory.close()
        let finalSizes = try fileSizes(at: storeURL)
        print("closed,\(deleteCount),\(finalSizes.logical),\(finalSizes.allocated),,")
        print("store=\(storeURL.path)")
    }

    private static func makeDocument(index: Int, bytes: Int) -> String {
        let prefix = "document \(index) waxauditdoc\(index)x storage amplification audit "
        var text = prefix
        var token = 0
        while text.utf8.count < bytes {
            text += "term_\(index)_\(token) wax commit segment "
            token += 1
        }
        return String(text.prefix(bytes))
    }

    private static func printMeasurement(
        phase: String,
        deleteCount: Int,
        memory: Memory,
        storeURL: URL
    ) async throws {
        let stats = await memory.stats()
        let sizes = try fileSizes(at: storeURL)
        print([
            phase,
            String(deleteCount),
            String(sizes.logical),
            String(sizes.allocated),
            String(stats.frameCount),
            String(stats.pendingFrames),
        ].joined(separator: ","))
    }

    private static func fileSizes(at url: URL) throws -> (logical: Int, allocated: Int) {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        return (logical: max(0, Int(info.st_size)), allocated: max(0, Int(info.st_blocks) * 512))
    }

    private static func printUsage() {
        print("""
        Usage: swift run wax-amplification-harness [options]

          --documents N       Initial corpus documents (default: 256)
          --deletes N         Indexed frames deleted one-by-one (default: 64)
          --payload-bytes N   Approximate bytes per document (default: 1024)
          --dimensions N      Deterministic vector dimensions (default: 384)
          --sample-every N    Emit a measurement every N deletes (default: 8)
          --output PATH       Keep the arena at PATH
          --inspect PATH      Print accounting for an existing arena, then exit
          --keep              Keep an automatically-created temporary arena
        """)
    }
}
