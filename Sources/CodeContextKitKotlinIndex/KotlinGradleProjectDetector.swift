import Foundation

public struct GradleProject: Sendable, Equatable {
    public let rootPath: String
    public let modules: [GradleModule]

    public var sourceRoots: [String] {
        modules.flatMap(\.sourceRoots)
    }
}

public struct GradleModule: Sendable, Equatable {
    public let name: String
    public let path: String
    public let sourceRoots: [String]
}

public enum GradleProjectDetector {
    public static func detect(at path: String) -> GradleProject? {
        let rootURL = URL(fileURLWithPath: path).standardizedFileURL
        let fileManager = FileManager.default
        let settingsURL = settingsFile(in: rootURL)
        let rootBuildFile = buildFile(in: rootURL)

        guard settingsURL != nil || rootBuildFile != nil else {
            return nil
        }

        var modulePaths: [String: URL] = [":": rootURL]
        var remappedProjectDirs: [String: URL] = [:]

        if let settingsURL {
            let settings = (try? String(contentsOf: settingsURL, encoding: .utf8)) ?? ""
            remappedProjectDirs = parseProjectDirs(from: settings, rootURL: rootURL)

            for moduleName in parseIncludedModules(from: settings) {
                modulePaths[moduleName] = remappedProjectDirs[moduleName] ?? defaultModuleURL(for: moduleName, rootURL: rootURL)
            }
        } else if rootBuildFile != nil {
            modulePaths[":"] = rootURL
        }

        if modulePaths.count == 1, settingsURL == nil {
            for child in (try? fileManager.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey])) ?? [] {
                guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                guard buildFile(in: child) != nil else { continue }
                modulePaths[":\(child.lastPathComponent)"] = child
            }
        }

        let modules = modulePaths
            .map { name, url in
                GradleModule(
                    name: name,
                    path: url.standardizedFileURL.path,
                    sourceRoots: discoverSourceRoots(in: url)
                )
            }
            .sorted { $0.name < $1.name }

        return GradleProject(rootPath: rootURL.path, modules: modules)
    }

    private static func settingsFile(in rootURL: URL) -> URL? {
        for filename in ["settings.gradle.kts", "settings.gradle"] {
            let url = rootURL.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    private static func buildFile(in rootURL: URL) -> URL? {
        for filename in ["build.gradle.kts", "build.gradle"] {
            let url = rootURL.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    private static func parseIncludedModules(from settings: String) -> [String] {
        let includePattern = #"(?m)\binclude\s*(?:\(([^)]*)\)|([^\n]*))"#
        let modulePattern = #"['"](:[^'"]+)['"]"#
        return matches(pattern: includePattern, in: settings)
            .flatMap { includeMatch -> [String] in
                let body = includeMatch.first ?? includeMatch.dropFirst().first ?? ""
                return matches(pattern: modulePattern, in: body).compactMap(\.first)
            }
    }

    private static func parseProjectDirs(from settings: String, rootURL: URL) -> [String: URL] {
        let pattern = #"project\(\s*['"](:[^'"]+)['"]\s*\)\.projectDir\s*=\s*file\(\s*['"]([^'"]+)['"]\s*\)"#
        var results: [String: URL] = [:]
        for match in matches(pattern: pattern, in: settings) where match.count >= 2 {
            let moduleName = match[0]
            let path = match[1]
            results[moduleName] = URL(fileURLWithPath: path, relativeTo: rootURL).standardizedFileURL
        }
        return results
    }

    private static func defaultModuleURL(for moduleName: String, rootURL: URL) -> URL {
        let components = moduleName.split(separator: ":").map(String.init)
        return components.reduce(rootURL) { url, component in
            url.appendingPathComponent(component, isDirectory: true)
        }
    }

    private static func discoverSourceRoots(in moduleURL: URL) -> [String] {
        let fileManager = FileManager.default
        let srcURL = moduleURL.appendingPathComponent("src", isDirectory: true)
        guard let sourceSetURLs = try? fileManager.contentsOfDirectory(
            at: srcURL,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return []
        }

        var roots: [String] = []
        for sourceSetURL in sourceSetURLs {
            guard (try? sourceSetURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }

            for language in ["kotlin", "java"] {
                let languageURL = sourceSetURL.appendingPathComponent(language, isDirectory: true)
                guard fileManager.fileExists(atPath: languageURL.path) else { continue }
                roots.append(languageURL.standardizedFileURL.path)
            }
        }

        return roots.sorted()
    }

    private static func matches(pattern: String, in string: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        let range = NSRange(string.startIndex..., in: string)
        return regex.matches(in: string, range: range).map { match in
            (1..<match.numberOfRanges).compactMap { index in
                let range = match.range(at: index)
                guard range.location != NSNotFound, let swiftRange = Range(range, in: string) else {
                    return nil
                }
                return String(string[swiftRange])
            }
        }
    }
}
