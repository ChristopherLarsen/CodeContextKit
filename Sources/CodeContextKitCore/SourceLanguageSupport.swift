import Foundation

public protocol SourceLanguageSupport: Sendable {
    var supportedExtensions: Set<String> { get }
    var canonicalLanguage: String { get }
    var codeFence: String { get }

    func makeSplitter() -> CodeSplitter
    func makeOutlineRenderer() -> any OutlineRendering
}

public extension SourceLanguageSupport {
    func supports(filePath: String) -> Bool {
        supportedExtensions.contains((filePath as NSString).pathExtension.lowercased())
    }
}

public protocol FileScanPolicy: Sendable {
    var supportedExtensions: Set<String> { get }

    func excludedPathFragments(rootPath: String, includeGenerated: Bool) -> [String]
    func shouldInclude(fileURL: URL, relativePath: String, includeBuildScripts: Bool) -> Bool
}

public extension FileScanPolicy {
    func excludedPathFragments(rootPath: String, includeGenerated: Bool) -> [String] {
        []
    }

    func shouldInclude(fileURL: URL, relativePath: String, includeBuildScripts: Bool) -> Bool {
        true
    }
}
