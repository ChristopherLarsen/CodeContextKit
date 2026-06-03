// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodeContextKit",
    platforms: [
        .macOS("15.0")
    ],
    products: [
        .executable(name: "cckit", targets: ["CodeContextKitCLI"]),
        .library(name: "CodeContextKitCore", targets: ["CodeContextKitCore"]),
        .library(name: "CodeContextKitSwiftIndex", targets: ["CodeContextKitSwiftIndex"]),
        .library(name: "CodeContextKitKotlinIndex", targets: ["CodeContextKitKotlinIndex"]),
        .library(name: "CodeContextKitStorage", targets: ["CodeContextKitStorage"]),
        .library(name: "CodeContextKitRetrieval", targets: ["CodeContextKitRetrieval"]),
        .library(name: "CodeContextKitContext", targets: ["CodeContextKitContext"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "600.0.1"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", from: "2.0.0"),
        .package(url: "https://github.com/unum-cloud/usearch.git", from: "2.16.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter.git", from: "0.22.6"),
        .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-kotlin.git", from: "1.1.0"),
        .package(url: "https://github.com/christopherkarani/Wax.git", branch: "main"),
        .package(url: "https://github.com/christopherkarani/ContextCore.git", branch: "main")
    ],
    targets: [
        .executableTarget(
            name: "CodeContextKitCLI",
            dependencies: [
                "CodeContextKitCore",
                "CodeContextKitSwiftIndex",
                "CodeContextKitStorage",
                "CodeContextKitRetrieval",
                "CodeContextKitContext",
                "CodeContextKitServer",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .target(
            name: "CodeContextKitServer",
            dependencies: [
                "CodeContextKitCore",
                "CodeContextKitStorage",
                "CodeContextKitSwiftIndex",
                "CodeContextKitRetrieval",
                "CodeContextKitContext",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
                .product(name: "HummingbirdRouter", package: "hummingbird")
            ]
        ),
        .target(
            name: "CodeContextKitCore"
        ),
        .target(
            name: "CodeContextKitSwiftIndex",
            dependencies: [
                "CodeContextKitCore",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax")
            ]
        ),
        .target(
            name: "CodeContextKitKotlinIndex",
            dependencies: [
                "CodeContextKitCore",
                .product(name: "TreeSitter", package: "tree-sitter"),
                .product(name: "TreeSitterKotlin", package: "tree-sitter-kotlin")
            ]
        ),
        .target(
            name: "CodeContextKitStorage",
            dependencies: [
                "CodeContextKitCore",
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        ),
        .target(
            name: "CodeContextKitRetrieval",
            dependencies: [
                "CodeContextKitCore",
                "CodeContextKitStorage",
                .product(name: "USearch", package: "usearch"),
                .product(name: "Wax", package: "Wax"),
                .product(name: "WaxVectorSearchMiniLM", package: "Wax")
            ]
        ),
        .target(
            name: "CodeContextKitContext",
            dependencies: [
                "CodeContextKitCore",
                "CodeContextKitSwiftIndex",
                "CodeContextKitKotlinIndex",
                "CodeContextKitStorage",
                "CodeContextKitRetrieval",
                .product(name: "ContextCore", package: "ContextCore")
            ]
        ),
        .testTarget(
            name: "CodeContextKitSwiftIndexTests",
            dependencies: ["CodeContextKitSwiftIndex"]
        ),
        .testTarget(
            name: "CodeContextKitKotlinIndexTests",
            dependencies: ["CodeContextKitKotlinIndex"]
        ),
        .testTarget(
            name: "CodeContextKitContextTests",
            dependencies: ["CodeContextKitContext"]
        ),
        .testTarget(
            name: "CodeContextKitStorageTests",
            dependencies: ["CodeContextKitStorage"]
        ),
        .testTarget(
            name: "CodeContextKitServerTests",
            dependencies: ["CodeContextKitServer"]
        )
    ]
)
