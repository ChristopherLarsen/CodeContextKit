import XCTest
@testable import CodeContextKitCore
@testable import CodeContextKitKotlinIndex

final class KotlinIndexTests: XCTestCase {
    func testBasicSymbolExtractionAndReferences() {
        let content = """
        package com.acme.app

        /** User repository. */
        class UserRepository {
            val cache: MutableMap<String, User> = mutableMapOf()

            fun fetchUser(id: String): User {
                val local = User(id)
                return local
            }
        }

        data class User(val id: String)
        """

        let kotlinFile = KotlinSourceFile(filePath: "UserRepository.kt", content: content)
        let (symbols, references) = kotlinFile.extractSymbols()

        XCTAssertTrue(symbols.contains { $0.qualifiedName == "com.acme.app.UserRepository" && $0.kind == .class })
        XCTAssertTrue(symbols.contains { $0.qualifiedName == "com.acme.app.UserRepository.cache" && $0.kind == .property })
        XCTAssertTrue(symbols.contains { $0.qualifiedName == "com.acme.app.UserRepository.fetchUser" && $0.kind == .method })
        XCTAssertTrue(symbols.contains { $0.qualifiedName == "com.acme.app.User" && $0.kind == .dataClass })
        XCTAssertTrue(symbols.contains { $0.qualifiedName == "com.acme.app.User.id" && $0.kind == .property })

        XCTAssertTrue(references.contains { $0.name == "User" && $0.context == "com.acme.app.UserRepository.fetchUser" })
        XCTAssertEqual(symbols.first { $0.name == "UserRepository" }?.docComment, "User repository.")
    }

    func testTestDetectionByAnnotationAndPath() {
        let annotated = """
        package com.acme

        class UserRepositoryTest {
            @Test
            fun fetchesUser() {}
        }
        """

        let pathBased = """
        package com.acme

        class UserRepositoryTest {
            fun testFetchesUser() {}
            fun helperFactory() {}
        }
        """

        let (annotatedSymbols, _) = KotlinSourceFile(filePath: "UserRepositoryTest.kt", content: annotated).extractSymbols()
        XCTAssertEqual(annotatedSymbols.first { $0.name == "fetchesUser" }?.kind, .test)

        let (pathSymbols, _) = KotlinSourceFile(filePath: "app/src/test/kotlin/com/acme/UserRepositoryTest.kt", content: pathBased).extractSymbols()
        XCTAssertEqual(pathSymbols.first { $0.name == "testFetchesUser" }?.kind, .test)
        XCTAssertEqual(pathSymbols.first { $0.name == "helperFactory" }?.kind, .method)
    }

    func testKDocGenericsInheritanceAndNestedQualifiedNames() {
        let content = """
        package com.acme.model

        /**
         * Box docs.
         * @param T value type
         */
        sealed class Box<T : Any> : BaseBox {
            data class Full<T : Any>(val value: T) : Box<T>()
            object Empty : Box<Nothing>()
        }
        """

        let (symbols, _) = KotlinSourceFile(filePath: "Box.kt", content: content).extractSymbols()

        let box = symbols.first { $0.qualifiedName == "com.acme.model.Box" }
        XCTAssertEqual(box?.kind, .sealedClass)
        XCTAssertEqual(box?.signature, "sealed class Box<T : Any> : BaseBox")
        XCTAssertEqual(box?.docComment, "Box docs.\n@param T value type")

        XCTAssertTrue(symbols.contains { $0.qualifiedName == "com.acme.model.Box.Full" && $0.kind == .dataClass })
        XCTAssertTrue(symbols.contains { $0.qualifiedName == "com.acme.model.Box.Full.value" && $0.kind == .property })
        XCTAssertTrue(symbols.contains { $0.qualifiedName == "com.acme.model.Box.Empty" && $0.kind == .object })
    }

    func testEnumEntriesExtensionFunctionTopLevelPropertyAndTypealias() {
        let content = """
        package com.acme.util

        enum class AuthState {
            LoggedOut,
            LoggedIn
        }

        const val RetryLimit = 3

        fun String.toSlug(): String = lowercase()

        typealias UserId = String
        """

        let (symbols, _) = KotlinSourceFile(filePath: "Extensions.kt", content: content).extractSymbols()

        XCTAssertTrue(symbols.contains { $0.qualifiedName == "com.acme.util.AuthState" && $0.kind == .enum })
        XCTAssertTrue(symbols.contains { $0.qualifiedName == "com.acme.util.AuthState.LoggedOut" && $0.kind == .enumEntry })
        XCTAssertTrue(symbols.contains { $0.qualifiedName == "com.acme.util.RetryLimit" && $0.kind == .property })

        let extensionFunction = symbols.first { $0.qualifiedName == "com.acme.util.toSlug" }
        XCTAssertEqual(extensionFunction?.kind, .function)
        XCTAssertEqual(extensionFunction?.signature, "fun String.toSlug(): String")

        XCTAssertTrue(symbols.contains { $0.qualifiedName == "com.acme.util.UserId" && $0.kind.rawValue == "typealias" })
    }

    func testLocalVariablesAreNotIndexedAndBodyExtractionWorks() throws {
        let content = """
        package com.acme

        class Service {
            fun work() {
                val local = 1
                println(local)
            }
        }
        """

        let kotlinFile = KotlinSourceFile(filePath: "Service.kt", content: content)
        let (symbols, _) = kotlinFile.extractSymbols()

        XCTAssertFalse(symbols.contains { $0.name == "local" })
        let work = try XCTUnwrap(symbols.first { $0.name == "work" })
        XCTAssertTrue(kotlinFile.body(for: work).contains("println(local)"))
    }

    func testOutlineDoesNotIndentPackageDepth() {
        let content = """
        package com.acme.deep

        class Outer {
            class Inner {
                fun run() {}
            }
        }
        """

        let (symbols, _) = KotlinSourceFile(filePath: "Outer.kt", content: content).extractSymbols()
        let outline = KotlinOutlineRenderer().render(filePath: "Outer.kt", symbols: symbols)

        XCTAssertTrue(outline.contains("class Outer"))
        XCTAssertTrue(outline.contains("  class Inner"))
        XCTAssertTrue(outline.contains("    fun run()"))
        XCTAssertFalse(outline.contains("      class Outer"))
    }

    func testAnnotatedExpectAndNestedClassesKeepScopes() {
        let content = """
        package com.acme.time

        @Serializable(with = LocalDateSerializer::class)
        public expect class LocalDate {
            public companion object {
                public fun parse(input: String): LocalDate
            }
        }

        @Serializable
        public sealed class DateTimeUnit {
            @Serializable
            public class TimeBased(
                public val nanoseconds: Long
            ) : DateTimeUnit() {
                public fun times(scalar: Int): TimeBased = TimeBased(nanoseconds * scalar)
            }

            public companion object {
                public val SECOND: TimeBased = TimeBased(1_000_000_000)
            }
        }
        """

        let (symbols, _) = KotlinSourceFile(filePath: "DateTimeUnit.kt", content: content).extractSymbols()

        XCTAssertEqual(symbols.filter { $0.qualifiedName == "com.acme.time.LocalDate" }.count, 1)
        XCTAssertEqual(symbols.filter { $0.qualifiedName == "com.acme.time.DateTimeUnit" }.count, 1)
        XCTAssertTrue(symbols.contains { $0.qualifiedName == "com.acme.time.LocalDate" && $0.kind == .class })
        XCTAssertTrue(symbols.contains { $0.qualifiedName == "com.acme.time.LocalDate.Companion" && $0.kind == .companion })
        XCTAssertTrue(symbols.contains { $0.qualifiedName == "com.acme.time.LocalDate.Companion.parse" && $0.kind == .method })
        XCTAssertTrue(symbols.contains { $0.qualifiedName == "com.acme.time.DateTimeUnit" && $0.kind == .sealedClass })
        XCTAssertTrue(symbols.contains { $0.qualifiedName == "com.acme.time.DateTimeUnit.TimeBased" && $0.kind == .class })
        XCTAssertTrue(symbols.contains { $0.qualifiedName == "com.acme.time.DateTimeUnit.TimeBased.nanoseconds" && $0.kind == .property })
        XCTAssertTrue(symbols.contains { $0.qualifiedName == "com.acme.time.DateTimeUnit.TimeBased.times" && $0.kind == .method })
        XCTAssertTrue(symbols.contains { $0.qualifiedName == "com.acme.time.DateTimeUnit.Companion.SECOND" && $0.kind == .property })
    }
}
