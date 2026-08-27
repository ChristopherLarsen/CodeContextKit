import Foundation

/// Shared dump gates so locators, `symbol`, and `outline` fail closed together.
public enum SymbolSpanLimits: Sendable {
    /// Dumping a body this large is usually worse than a windowed Read.
    public static let hugeLines = 200
    /// Default `find-symbol` / MCP `limit`.
    public static let defaultFindLimit = 20
    /// Same-file extras kept with an exact type hit at the default limit.
    public static let exactTypeSameFileMemberCap = 8
    /// Member names listed when `symbol` refuses a huge type.
    public static let hugeMemberListCap = 40
}

public struct SymbolRecord: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case `struct`
        case `class`
        case actor
        case `enum`
        case `protocol`
        case interface
        case `extension`
        case function
        case method
        case initializer
        case property
        case test
        case file
        case style
        case `case`
        case object
        case companion
        case dataClass
        case sealedClass
        case valueClass
        case `typealias` = "typealias"
        case constructor
        case enumEntry

        /// Architectural type kinds (not methods/properties).
        public var isType: Bool {
            switch self {
            case .struct, .class, .actor, .enum, .protocol, .interface,
                 .extension, .object, .companion, .dataClass, .sealedClass, .valueClass:
                true
            default:
                false
            }
        }
    }

    /// Line count of the indexed span (inclusive).
    public var lineSpan: Int {
        max(0, endLine - startLine + 1)
    }

    public var isHuge: Bool {
        lineSpan >= SymbolSpanLimits.hugeLines
    }

    public struct Reference: Codable, Hashable, Sendable {
        public var name: String
        public var startLine: Int
        public var endLine: Int
        public var context: String? // The surrounding symbol or type
        public var file: String? // The file where the reference occurs
        
        public init(name: String, startLine: Int, endLine: Int, context: String? = nil, file: String? = nil) {
            self.name = name
            self.startLine = startLine
            self.endLine = endLine
            self.context = context
            self.file = file
        }
    }

    public var kind: Kind
    public var name: String
    public var qualifiedName: String
    public var signature: String
    public var filePath: String
    public var startLine: Int
    public var endLine: Int
    public var enclosingType: String?
    public var accessLevel: String?
    public var docComment: String?
    public var estimatedTokens: Int

    public init(
        kind: Kind,
        name: String,
        qualifiedName: String,
        signature: String,
        filePath: String,
        startLine: Int,
        endLine: Int,
        enclosingType: String? = nil,
        accessLevel: String? = nil,
        docComment: String? = nil,
        estimatedTokens: Int = 0
    ) {
        self.kind = kind
        self.name = name
        self.qualifiedName = qualifiedName
        self.signature = signature
        self.filePath = filePath
        self.startLine = startLine
        self.endLine = endLine
        self.enclosingType = enclosingType
        self.accessLevel = accessLevel
        self.docComment = docComment
        self.estimatedTokens = estimatedTokens
    }
}

public struct ActionRecord: Codable, Hashable, Sendable {
    public var id: Int64?
    public var prompt: String
    public var toolName: String?
    public var type: String // "cli", "mcp", or "web"
    public var tokensUsed: Int
    /// Whole-file token estimate for files already read by this call (outline/symbol), when known.
    public var sourceWholeFileTokens: Int
    public var durationMs: Int
    public var status: String // "pending", "completed", "failed", "skipped"
    public var timestamp: Date
    public var response: String?
    /// Index-run outcome counts (index rows only). `durationMs` alone cannot
    /// distinguish a 3 s no-op pass from a 21-minute near-full re-embed.
    public var updated: Int?
    public var skipped: Int?
    public var symbols: Int?

    enum CodingKeys: String, CodingKey {
        case id, prompt, toolName, type, tokensUsed, sourceWholeFileTokens
        case durationMs, status, timestamp, response
        case updated, skipped, symbols
    }

    public init(
        id: Int64? = nil,
        prompt: String,
        toolName: String? = nil,
        type: String = "web",
        tokensUsed: Int = 0,
        sourceWholeFileTokens: Int = 0,
        durationMs: Int = 0,
        status: String = "pending",
        timestamp: Date = Date(),
        response: String? = nil,
        updated: Int? = nil,
        skipped: Int? = nil,
        symbols: Int? = nil
    ) {
        self.id = id
        self.prompt = prompt
        self.toolName = toolName
        self.type = type
        self.tokensUsed = tokensUsed
        self.sourceWholeFileTokens = sourceWholeFileTokens
        self.durationMs = durationMs
        self.status = status
        self.timestamp = timestamp
        self.response = response
        self.updated = updated
        self.skipped = skipped
        self.symbols = symbols
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(Int64.self, forKey: .id)
        prompt = try c.decode(String.self, forKey: .prompt)
        toolName = try c.decodeIfPresent(String.self, forKey: .toolName)
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "web"
        tokensUsed = try c.decodeIfPresent(Int.self, forKey: .tokensUsed) ?? 0
        sourceWholeFileTokens = try c.decodeIfPresent(Int.self, forKey: .sourceWholeFileTokens) ?? 0
        durationMs = try c.decodeIfPresent(Int.self, forKey: .durationMs) ?? 0
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "pending"
        timestamp = try c.decodeIfPresent(Date.self, forKey: .timestamp) ?? Date()
        response = try c.decodeIfPresent(String.self, forKey: .response)
        updated = try c.decodeIfPresent(Int.self, forKey: .updated)
        skipped = try c.decodeIfPresent(Int.self, forKey: .skipped)
        symbols = try c.decodeIfPresent(Int.self, forKey: .symbols)
    }

    /// Tokens avoided versus whole files already loaded for this call.
    /// May be negative when the response is larger than those files (a real regression).
    public var tokensAvoidedVersusSourceFile: Int {
        sourceWholeFileTokens - tokensUsed
    }
}
