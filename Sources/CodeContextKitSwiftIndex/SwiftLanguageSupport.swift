import CodeContextKitCore

public struct SwiftLanguageSupport: SourceLanguageSupport {
    public let supportedExtensions: Set<String> = ["swift"]
    public let canonicalLanguage = "swift"
    public let codeFence = "swift"

    public init() {}

    public func makeSplitter() -> CodeSplitter {
        SwiftSourceFile()
    }

    public func makeOutlineRenderer() -> any OutlineRendering {
        SwiftOutlineRenderer()
    }
}
