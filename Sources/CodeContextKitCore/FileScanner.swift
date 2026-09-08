import Foundation

public struct FileScanner {
    private static let defaultSupportedExtensions: Set<String> = [
        "swift", "h", "m", "mm", "c", "cpp", "hpp", "js", "ts", "json", "md", "yaml", "yml", "skill", "html", "css"
    ]

    public init() {}
    
    public func scan(
        at path: String,
        include: [String],
        exclude: [String],
        includeFolders: [String] = [],
        includeBuildScripts: Bool = false,
        includeGenerated: Bool = false,
        policies: [any FileScanPolicy] = []
    ) -> [URL] {
        let rootURL = URL(fileURLWithPath: path)
        var results: [URL] = []
        var supportedExtensions = Self.defaultSupportedExtensions
        var policyExcludeFragments: [String] = []

        for policy in policies {
            supportedExtensions.formUnion(policy.supportedExtensions)
            policyExcludeFragments.append(contentsOf: policy.excludedPathFragments(rootPath: path, includeGenerated: includeGenerated))
        }

        let rules = IgnoreRules(rootURL: rootURL, exclude: exclude, includeFolders: includeFolders)
        
        let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        
        while let fileURL = enumerator?.nextObject() as? URL {
            do {
                let resourceValues = try fileURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
                let relativePath = relativePath(for: fileURL, rootURL: rootURL)

                if resourceValues.isDirectory == true {
                    if rules.shouldSkipDirectory(path: relativePath)
                        || policyExcludeFragments.contains(where: { relativePath.contains($0) }) {
                        enumerator?.skipDescendants()
                    }
                } else if resourceValues.isRegularFile == true {
                    if shouldInclude(path: relativePath, include: include, rules: rules, supportedExtensions: supportedExtensions, policyExcludeFragments: policyExcludeFragments),
                       policies.allSatisfy({ $0.shouldInclude(fileURL: fileURL, relativePath: relativePath, includeBuildScripts: includeBuildScripts) }) {
                        results.append(fileURL)
                    }
                }
            } catch {
                continue
            }
        }
        
        return results
    }
    
    private func shouldInclude(path: String, include: [String], rules: IgnoreRules, supportedExtensions: Set<String>, policyExcludeFragments: [String]) -> Bool {
        if policyExcludeFragments.contains(where: { path.contains($0) }) { return false }
        if rules.excludesFile(path: path) { return false }
        if rules.isIncluded(path: path) { return hasSupportedExtension(path, supportedExtensions: supportedExtensions) }

        if include.isEmpty {
            return hasSupportedExtension(path, supportedExtensions: supportedExtensions)
        }
        
        for pattern in include {
            if path.contains(pattern) { return true }
        }
        
        return false
    }

    private func hasSupportedExtension(_ path: String, supportedExtensions: Set<String>) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return supportedExtensions.contains(ext)
    }

    private func relativePath(for url: URL, rootURL: URL) -> String {
        let rootPath = rootURL.resolvingSymlinksInPath().path
        let filePath = url.resolvingSymlinksInPath().path
        guard filePath.hasPrefix(rootPath) else { return url.lastPathComponent }

        var relativePath = String(filePath.dropFirst(rootPath.count))
        if relativePath.hasPrefix("/") {
            relativePath.removeFirst()
        }
        return relativePath
    }
}

private struct IgnoreRules {
    private let defaultRules: [IgnoreRule]
    private let excludeRules: [IgnoreRule]
    private let includeRules: [IgnoreRule]
    /// Patterns from every `.gitignore`, rooted at the file's directory. Last match wins.
    private let gitignoreLayers: [(base: String, rules: [GitIgnoreLine])]

    init(rootURL: URL, exclude: [String], includeFolders: [String]) {
        let defaultRules = [".build/", ".git/", "DerivedData/", "node_modules/", ".DS_Store"]
        self.defaultRules = defaultRules.compactMap(IgnoreRule.init)
        self.excludeRules = exclude.compactMap(IgnoreRule.init)
        self.includeRules = includeFolders.compactMap(IgnoreRule.init)
        self.gitignoreLayers = Self.loadGitignoreLayers(rootURL: rootURL)
    }

    func shouldSkipDirectory(path: String) -> Bool {
        if defaultRules.contains(where: { $0.matches(path: path, isDirectory: true) }) { return true }
        if excludeRules.contains(where: { $0.matches(path: path, isDirectory: true) }) { return true }
        if isIncluded(path: path) || containsIncludedDescendant(path: path) { return false }
        // Do not skipDescendants for gitignore: a later `!` pattern may re-include a child.
        return false
    }

    func excludesFile(path: String) -> Bool {
        if defaultRules.contains(where: { $0.matches(path: path, isDirectory: false) }) { return true }
        if excludeRules.contains(where: { $0.matches(path: path, isDirectory: false) }) { return true }
        if isIncluded(path: path) { return false }
        return gitIgnored(path: path, isDirectory: false)
    }

    func isIncluded(path: String) -> Bool {
        includeRules.contains { $0.matches(path: path, isDirectory: false) || $0.matches(path: path, isDirectory: true) }
    }

    private func containsIncludedDescendant(path: String) -> Bool {
        includeRules.contains { $0.isDescendant(of: path) }
    }

    private func gitIgnored(path: String, isDirectory: Bool) -> Bool {
        var ignored = false
        for layer in gitignoreLayers {
            let relative: String
            if layer.base.isEmpty {
                relative = path
            } else if path == layer.base || path.hasPrefix(layer.base + "/") {
                relative = String(path.dropFirst(layer.base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            } else {
                continue
            }
            for line in layer.rules {
                if line.rule.matches(path: relative, isDirectory: isDirectory)
                    || line.rule.matches(path: path, isDirectory: isDirectory)
                {
                    ignored = !line.negated
                }
            }
        }
        return ignored
    }

    private static func loadGitignoreLayers(rootURL: URL) -> [(base: String, rules: [GitIgnoreLine])] {
        var layers: [(base: String, rules: [GitIgnoreLine])] = []
        if let root = parseGitignore(rootURL.appendingPathComponent(".gitignore")) {
            layers.append((base: "", rules: root))
        }
        let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants]
        )
        while let fileURL = enumerator?.nextObject() as? URL {
            if fileURL.lastPathComponent == ".git" {
                enumerator?.skipDescendants()
                continue
            }
            guard fileURL.lastPathComponent == ".gitignore" else { continue }
            let parent = fileURL.deletingLastPathComponent()
            let rootPath = rootURL.resolvingSymlinksInPath().path
            var rel = String(parent.resolvingSymlinksInPath().path.dropFirst(rootPath.count))
            if rel.hasPrefix("/") { rel.removeFirst() }
            if rel.isEmpty { continue }
            if let parsed = parseGitignore(fileURL) {
                layers.append((base: rel, rules: parsed))
            }
        }
        return layers
    }

    private static func parseGitignore(_ url: URL) -> [GitIgnoreLine]? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var lines: [GitIgnoreLine] = []
        for raw in content.components(separatedBy: .newlines) {
            var trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            var negated = false
            if trimmed.hasPrefix("!") {
                negated = true
                trimmed.removeFirst()
                trimmed = trimmed.trimmingCharacters(in: .whitespaces)
            }
            guard let rule = IgnoreRule(trimmed) else { continue }
            lines.append(GitIgnoreLine(negated: negated, rule: rule))
        }
        return lines
    }
}

private struct GitIgnoreLine {
    var negated: Bool
    var rule: IgnoreRule
}

private struct IgnoreRule {
    private let pattern: String
    private let requiresDirectory: Bool
    private let anchored: Bool

    init?(_ rawPattern: String) {
        var pattern = rawPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else { return nil }

        self.anchored = pattern.hasPrefix("/")
        if pattern.hasPrefix("/") {
            pattern.removeFirst()
        }

        self.requiresDirectory = pattern.hasSuffix("/")
        if pattern.hasSuffix("/") {
            pattern.removeLast()
        }

        guard !pattern.isEmpty else { return nil }
        self.pattern = pattern
    }

    func matches(path: String, isDirectory: Bool) -> Bool {
        let normalizedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !normalizedPath.isEmpty else { return false }

        if requiresDirectory && !isDirectory {
            let isDescendantFile = normalizedPath.hasPrefix(pattern + "/") || normalizedPath.contains("/\(pattern)/")
            if !isDescendantFile { return false }
        }

        if pattern.contains("*") {
            return globMatches(path: normalizedPath)
        }

        if anchored || pattern.contains("/") {
            return normalizedPath == pattern || normalizedPath.hasPrefix(pattern + "/")
        }

        let components = normalizedPath.split(separator: "/").map(String.init)
        if components.contains(pattern) { return true }

        return normalizedPath == pattern || normalizedPath.hasSuffix("/" + pattern)
    }

    func isDescendant(of path: String) -> Bool {
        let normalizedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !normalizedPath.isEmpty else { return false }

        if anchored || pattern.contains("/") {
            return pattern.hasPrefix(normalizedPath + "/")
        }

        return false
    }

    private func globMatches(path: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*\\*", with: ".*")
            .replacingOccurrences(of: "\\*", with: "[^/]*")
        let prefix = anchored || pattern.contains("/") ? "^" : "(^|.*/)"
        let suffix = requiresDirectory ? "(/.*)?$" : "(/.*)?$"
        let regexPattern = prefix + escaped + suffix
        return path.range(of: regexPattern, options: .regularExpression) != nil
    }
}
