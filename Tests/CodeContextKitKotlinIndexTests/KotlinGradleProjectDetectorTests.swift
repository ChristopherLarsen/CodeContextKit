import XCTest
import CodeContextKitCore
@testable import CodeContextKitKotlinIndex

final class KotlinGradleProjectDetectorTests: XCTestCase {
    func testDetectsKotlinMultiplatformSourceSetsAndProjectDirRemaps() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try """
        pluginManagement { repositories { gradlePluginPortal() } }
        dependencyResolutionManagement { repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS) }
        rootProject.name = "Sample"
        include(":app", ":shared", ":custom")
        project(":custom").projectDir = file("custom-dir")
        """.write(to: tempDir.appendingPathComponent("settings.gradle.kts"), atomically: true, encoding: .utf8)
        try "plugins { kotlin(\"multiplatform\") version \"2.0.0\" apply false }"
            .write(to: tempDir.appendingPathComponent("build.gradle.kts"), atomically: true, encoding: .utf8)

        try createDirectory("app/src/main/kotlin", in: tempDir)
        try createDirectory("shared/src/commonMain/kotlin", in: tempDir)
        try createDirectory("shared/src/androidMain/kotlin", in: tempDir)
        try createDirectory("custom-dir/src/jvmTest/java", in: tempDir)

        let project = try XCTUnwrap(GradleProjectDetector.detect(at: tempDir.path))
        XCTAssertEqual(project.modules.map(\.name), [":", ":app", ":custom", ":shared"])

        let sourceRoots = project.sourceRoots.map { path in
            path.replacingOccurrences(of: tempDir.path + "/", with: "")
        }
        XCTAssertTrue(sourceRoots.contains("app/src/main/kotlin"))
        XCTAssertTrue(sourceRoots.contains("shared/src/commonMain/kotlin"))
        XCTAssertTrue(sourceRoots.contains("shared/src/androidMain/kotlin"))
        XCTAssertTrue(sourceRoots.contains("custom-dir/src/jvmTest/java"))
    }

    func testScannerExcludesGradleScriptsAndGeneratedSourcesByDefault() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try """
        rootProject.name = "Sample"
        include(":app")
        """.write(to: tempDir.appendingPathComponent("settings.gradle.kts"), atomically: true, encoding: .utf8)
        try "plugins { kotlin(\"jvm\") }"
            .write(to: tempDir.appendingPathComponent("build.gradle.kts"), atomically: true, encoding: .utf8)

        try write("app/src/main/kotlin/App.kt", in: tempDir, contents: "class App")
        try write("scripts/migrate.kts", in: tempDir, contents: "println(\"migrate\")")
        try write("app/build/generated/ksp/main/kotlin/Generated.kt", in: tempDir, contents: "class Generated")

        let scanner = FileScanner()
        let defaultPaths = scanner.scan(
            at: tempDir.path,
            include: [],
            exclude: [],
            policies: [KotlinGradleScanPolicy()]
        )
            .map { relativePath(for: $0, root: tempDir) }
            .sorted()

        XCTAssertEqual(defaultPaths, ["app/src/main/kotlin/App.kt", "scripts/migrate.kts"])

        let expandedPaths = scanner.scan(
            at: tempDir.path,
            include: [],
            exclude: [],
            includeBuildScripts: true,
            includeGenerated: true,
            policies: [KotlinGradleScanPolicy()]
        )
            .map { relativePath(for: $0, root: tempDir) }
            .sorted()

        XCTAssertTrue(expandedPaths.contains("build.gradle.kts"))
        XCTAssertTrue(expandedPaths.contains("settings.gradle.kts"))
        XCTAssertTrue(expandedPaths.contains("app/build/generated/ksp/main/kotlin/Generated.kt"))
    }

    private func makeTempDir() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func createDirectory(_ path: String, in root: URL) throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(path, isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    private func write(_ path: String, in root: URL, contents: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func relativePath(for url: URL, root: URL) -> String {
        let rootPath = root.resolvingSymlinksInPath().path
        let filePath = url.resolvingSymlinksInPath().path
        guard filePath.hasPrefix(rootPath + "/") else { return filePath }
        return String(filePath.dropFirst(rootPath.count + 1))
    }
}
