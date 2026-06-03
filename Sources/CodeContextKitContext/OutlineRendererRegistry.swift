import Foundation
import CodeContextKitCore

public struct OutlineRendererRegistry {
    private let registry: SourceLanguageRegistry

    public init(registry: SourceLanguageRegistry = .default) {
        self.registry = registry
    }

    public func renderer(for filePath: String) -> any OutlineRendering {
        registry.outlineRenderer(for: filePath)
    }
}

public enum LanguageFence {
    public static func fence(for filePath: String) -> String {
        SourceLanguageRegistry.default.codeFence(for: filePath)
    }
}
