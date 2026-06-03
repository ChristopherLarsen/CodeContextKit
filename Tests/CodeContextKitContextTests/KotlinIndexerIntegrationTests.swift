import XCTest
import Foundation
@testable import CodeContextKitContext
@testable import CodeContextKitStorage
@testable import CodeContextKitRetrieval

final class KotlinIndexerIntegrationTests: XCTestCase {
    func testKotlinIndexingFullCycle() async throws {
        let uuid = UUID().uuidString
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(uuid)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceDir = tempDir.appendingPathComponent("app/src/main/kotlin/com/acme", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        let fileURL = sourceDir.appendingPathComponent("UserRepository.kt")
        try """
        package com.acme

        class UserRepository {
            fun fetchUser(id: String): User = User(id)
        }

        data class User(val id: String)
        """.write(to: fileURL, atomically: true, encoding: .utf8)

        let db = try Database(path: NSTemporaryDirectory() + uuid + ".sqlite")
        let wax = try await WaxStore(path: NSTemporaryDirectory() + uuid + ".wax")
        let indexer = Indexer(db: db, wax: wax)

        try await indexer.index(at: tempDir.path)

        let files = try db.getAllFiles()
        XCTAssertTrue(files.contains { $0.path == "app/src/main/kotlin/com/acme/UserRepository.kt" && $0.language == "kotlin" })

        let symbols = try db.getSymbols(path: "app/src/main/kotlin/com/acme/UserRepository.kt")
        XCTAssertTrue(symbols.contains { $0.qualifiedName == "com.acme.UserRepository.fetchUser" })
        XCTAssertTrue(symbols.contains { $0.qualifiedName == "com.acme.User.id" })
    }

    func testGradleBuildScriptsAreOptInForIndexer() async throws {
        let uuid = UUID().uuidString
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(uuid)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try """
        rootProject.name = "Sample"
        include(":app")
        """.write(to: tempDir.appendingPathComponent("settings.gradle.kts"), atomically: true, encoding: .utf8)
        try """
        plugins { kotlin("jvm") }

        fun helperForBuild() = "build"
        """.write(to: tempDir.appendingPathComponent("build.gradle.kts"), atomically: true, encoding: .utf8)

        let sourceDir = tempDir.appendingPathComponent("app/src/main/kotlin/com/acme", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try "package com.acme\nclass App".write(
            to: sourceDir.appendingPathComponent("App.kt"),
            atomically: true,
            encoding: .utf8
        )

        let db = try Database(path: NSTemporaryDirectory() + uuid + ".sqlite")
        let wax = try await WaxStore(path: NSTemporaryDirectory() + uuid + ".wax")
        let indexer = Indexer(db: db, wax: wax)

        try await indexer.index(at: tempDir.path)
        var files = try db.getAllFiles().map(\.path)
        XCTAssertTrue(files.contains("app/src/main/kotlin/com/acme/App.kt"))
        XCTAssertFalse(files.contains("build.gradle.kts"))
        XCTAssertFalse(files.contains("settings.gradle.kts"))

        try await indexer.index(at: tempDir.path, includeBuildScripts: true)
        files = try db.getAllFiles().map(\.path)
        XCTAssertTrue(files.contains("build.gradle.kts"))
        XCTAssertTrue(files.contains("settings.gradle.kts"))
    }
}
