import Foundation
import CodeContextKitCore

/// One resolved declaration that packing may render.
public struct ResolvedTarget: Sendable {
    public var symbol: SymbolRecord
    public var identity: DeclarationIdentity
    public var required: Bool
    public var request: String

    public init(symbol: SymbolRecord, required: Bool, request: String) {
        self.symbol = symbol
        self.identity = DeclarationIdentity(symbol)
        self.required = required
        self.request = request
    }

    public var targetID: String { identity.targetID }
}

/// Resolve-once contract: required targets, optional neighbors, source hashes,
/// and omission reasons. Rendering chooses a representation of this evidence;
/// a smaller packet is an improvement only when it preserves required evidence.
public struct PacketEvidence: Sendable {
    public var required: [ResolvedTarget]
    public var optional: [ResolvedTarget]
    public var sourceHashes: [String: String]
    public var indexedHashes: [String: String]
    public var fileContents: [String: String]
    public var omissions: [PacketOmission]
    public var waxFillRan: Bool
    public var waxHitCount: Int
    public var contentStale: Bool

    public var allTargets: [ResolvedTarget] { required + optional }

    public var requiredIDs: [String] { required.map(\.targetID) }

    public init(
        required: [ResolvedTarget] = [],
        optional: [ResolvedTarget] = [],
        sourceHashes: [String: String] = [:],
        indexedHashes: [String: String] = [:],
        fileContents: [String: String] = [:],
        omissions: [PacketOmission] = [],
        waxFillRan: Bool = false,
        waxHitCount: Int = 0,
        contentStale: Bool = false
    ) {
        self.required = required
        self.optional = optional
        self.sourceHashes = sourceHashes
        self.indexedHashes = indexedHashes
        self.fileContents = fileContents
        self.omissions = omissions
        self.waxFillRan = waxFillRan
        self.waxHitCount = waxHitCount
        self.contentStale = contentStale
    }
}
