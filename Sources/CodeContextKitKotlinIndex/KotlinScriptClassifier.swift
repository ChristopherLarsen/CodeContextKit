import Foundation

public enum KotlinScriptClassification: Sendable, Equatable {
    case buildScript
    case sourceScript
}

public enum KotlinScriptClassifier {
    public static func classify(path: String, contentPreview: String = "") -> KotlinScriptClassification {
        let filename = URL(fileURLWithPath: path).lastPathComponent
        let normalizedPath = path.replacingOccurrences(of: "\\", with: "/")

        if filename == "build.gradle.kts" || filename == "settings.gradle.kts" {
            return .buildScript
        }

        if normalizedPath.contains("/buildSrc/") || normalizedPath.hasPrefix("buildSrc/") {
            return .buildScript
        }

        let preview = contentPreview.prefix(4096)
        if preview.contains("plugins {") || preview.contains("dependencies {") || preview.contains("kotlin {") {
            return .buildScript
        }

        return .sourceScript
    }
}
