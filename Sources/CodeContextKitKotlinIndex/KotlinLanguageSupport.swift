import Foundation
import CodeContextKitCore

public struct KotlinLanguageSupport: SourceLanguageSupport {
    public let supportedExtensions: Set<String> = ["kt", "kts"]
    public let canonicalLanguage = "kotlin"
    public let codeFence = "kotlin"

    public init() {}

    public func makeSplitter() -> CodeSplitter {
        KotlinSourceFile()
    }

    public func makeOutlineRenderer() -> any OutlineRendering {
        KotlinOutlineRenderer()
    }
}

public struct KotlinGradleScanPolicy: FileScanPolicy {
    public let supportedExtensions: Set<String> = ["kt", "kts", "java"]

    public init() {}

    public func excludedPathFragments(rootPath: String, includeGenerated: Bool) -> [String] {
        guard GradleProjectDetector.detect(at: rootPath) != nil else {
            return []
        }

        var fragments = GradleDenylist.defaultExcludedPathFragments
        if !includeGenerated {
            fragments.append(contentsOf: GradleDenylist.generatedPathFragments)
        }
        return fragments
    }

    public func shouldInclude(fileURL: URL, relativePath: String, includeBuildScripts: Bool) -> Bool {
        guard (relativePath as NSString).pathExtension.lowercased() == "kts" else {
            return true
        }

        if includeBuildScripts {
            return true
        }

        let preview = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        return KotlinScriptClassifier.classify(path: relativePath, contentPreview: preview) == .sourceScript
    }
}
