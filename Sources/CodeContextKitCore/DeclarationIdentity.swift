import Foundation

/// Stable identity for a declaration. Display names (`qualifiedName` alone)
/// are not unique: overloads share a name, and extensions share a type name.
public struct DeclarationIdentity: Hashable, Sendable, Codable {
    public var filePath: String
    public var startLine: Int
    public var endLine: Int
    public var qualifiedName: String
    public var signature: String

    public init(
        filePath: String,
        startLine: Int,
        endLine: Int,
        qualifiedName: String,
        signature: String
    ) {
        self.filePath = filePath
        self.startLine = startLine
        self.endLine = endLine
        self.qualifiedName = qualifiedName
        self.signature = signature
    }

    public init(_ symbol: SymbolRecord) {
        self.init(
            filePath: symbol.filePath,
            startLine: symbol.startLine,
            endLine: symbol.endLine,
            qualifiedName: symbol.qualifiedName,
            signature: symbol.signature
        )
    }

    /// Compact id for packet stats and omission lists.
    public var targetID: String {
        "\(qualifiedName)@\(filePath):\(startLine)-\(endLine)"
    }
}

/// Why a resolved or requested target did not appear in the delivered packet.
public struct PacketOmission: Hashable, Sendable, Codable {
    public var targetID: String
    public var reason: String

    public init(targetID: String, reason: String) {
        self.targetID = targetID
        self.reason = reason
    }

    public var dictionary: [String: String] {
        ["targetID": targetID, "reason": reason]
    }
}

/// Languages whose indexer records declaration lines, not implementation spans.
public enum ImplementationSpanPolicy: Sendable {
    /// JS/TS/Java/Python regex extractors set `endLine == startLine`.
    /// CSS spans to the matching brace and is trustworthy.
    public static func hasReliableImplementationSpan(filePath: String) -> Bool {
        switch (filePath as NSString).pathExtension.lowercased() {
        case "swift", "kt", "kts", "m", "h", "mm", "c", "cpp", "hpp",
             "css", "scss", "less":
            return true
        default:
            return false
        }
    }
}
