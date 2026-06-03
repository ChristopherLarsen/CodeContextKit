import Foundation
import CodeContextKitCore
import CodeContextKitSwiftIndex
import CodeContextKitKotlinIndex

public struct SourceLanguageRegistry: Sendable {
    public static let `default` = SourceLanguageRegistry(
        languageSupports: [
            SwiftLanguageSupport(),
            KotlinLanguageSupport()
        ],
        scanPolicies: [
            KotlinGradleScanPolicy()
        ]
    )

    public let languageSupports: [any SourceLanguageSupport]
    public let scanPolicies: [any FileScanPolicy]

    public init(
        languageSupports: [any SourceLanguageSupport],
        scanPolicies: [any FileScanPolicy] = []
    ) {
        self.languageSupports = languageSupports
        self.scanPolicies = scanPolicies
    }

    public func support(for filePath: String) -> (any SourceLanguageSupport)? {
        languageSupports.first { $0.supports(filePath: filePath) }
    }

    public func splitter(for filePath: String) -> CodeSplitter {
        if let support = support(for: filePath) {
            return support.makeSplitter()
        }

        switch (filePath as NSString).pathExtension.lowercased() {
        case "js", "ts", "jsx", "tsx":
            return RegexSplitter(language: "js")
        case "css", "scss", "less":
            return RegexSplitter(language: "css")
        case "py":
            return RegexSplitter(language: "python")
        case "java":
            return RegexSplitter(language: "java")
        default:
            return RegexSplitter(language: "generic")
        }
    }

    public func outlineRenderer(for filePath: String) -> any OutlineRendering {
        support(for: filePath)?.makeOutlineRenderer() ?? GenericOutlineRenderer()
    }

    public func canonicalLanguage(for filePath: String) -> String {
        support(for: filePath)?.canonicalLanguage ?? (filePath as NSString).pathExtension.lowercased()
    }

    public func codeFence(for filePath: String) -> String {
        if let support = support(for: filePath) {
            return support.codeFence
        }

        switch (filePath as NSString).pathExtension.lowercased() {
        case "js": return "javascript"
        case "ts": return "typescript"
        case "py": return "python"
        case "java": return "java"
        case "html": return "html"
        case "css": return "css"
        case "json": return "json"
        case "md": return "markdown"
        default: return ""
        }
    }
}
