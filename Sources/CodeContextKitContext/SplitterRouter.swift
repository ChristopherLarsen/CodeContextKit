import Foundation
import CodeContextKitCore

/// Directs source files to the appropriate `CodeSplitter` based on file extension.
///
/// First-class language modules register their own splitters through
/// `SourceLanguageRegistry`; generic text languages use regex fallbacks.
public struct SplitterRouter {
    private let registry: SourceLanguageRegistry

    public init(registry: SourceLanguageRegistry = .default) {
        self.registry = registry
    }
    
    public func splitter(for filePath: String) -> CodeSplitter {
        registry.splitter(for: filePath)
    }
}
