import Foundation

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
    public var type: String // "cli" or "web"
    public var tokensUsed: Int
    public var durationMs: Int
    public var status: String // "pending", "completed", "failed"
    public var timestamp: Date
    public var response: String?
    
    public init(id: Int64? = nil, prompt: String, toolName: String? = nil, type: String = "web", tokensUsed: Int = 0, durationMs: Int = 0, status: String = "pending", timestamp: Date = Date(), response: String? = nil) {
        self.id = id
        self.prompt = prompt
        self.toolName = toolName
        self.type = type
        self.tokensUsed = tokensUsed
        self.durationMs = durationMs
        self.status = status
        self.timestamp = timestamp
        self.response = response
    }
}
