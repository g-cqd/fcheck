// swift-tools-version: 6.4
import PackageDescription

let strictSwiftSettings: [SwiftSetting] = [
    .treatAllWarnings(as: .error),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .strictMemorySafety(),
]

let package = Package(
    name: "fcheck",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "FCheckCore", targets: ["FCheckCore"]),
        .executable(name: "fcheck", targets: ["fcheck"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "604.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
        .package(url: "https://github.com/apple/swift-system.git", from: "1.8.1"),
        .package(
            url: "https://github.com/g-cqd/AemiJSON.git",
            revision: "53e572d875cc42ade99083641efdfac7ab865f31"
        ),
        .package(
            url: "https://github.com/g-cqd/analyzerkit.git",
            revision: "4b090013d19f9e86e48096081670cec744a4d9dc"
        ),
    ],
    targets: [
        .target(
            name: "FCheckCore",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "AemiJSON", package: "AemiJSON"),
                .product(name: "ProjectModel", package: "analyzerkit"),
                .product(name: "AnalyzerConfiguration", package: "analyzerkit"),
                .product(name: "SourceCorpus", package: "analyzerkit"),
                .product(name: "Suppression", package: "analyzerkit"),
                .product(name: "CorpusScan", package: "analyzerkit"),
                .product(name: "ReportSupport", package: "analyzerkit"),
                .product(name: "ControlFlow", package: "analyzerkit"),
            ],
            swiftSettings: strictSwiftSettings
        ),
        .executableTarget(
            name: "fcheck",
            dependencies: [
                "FCheckCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "SystemPackage", package: "swift-system"),
                .product(name: "AnalyzerCLI", package: "analyzerkit"),
                .product(name: "SourceCorpus", package: "analyzerkit"),
                .product(name: "ProjectModel", package: "analyzerkit"),
                .product(name: "ReportSupport", package: "analyzerkit"),
            ],
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "FCheckCoreTests",
            dependencies: [
                "FCheckCore",
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "ProjectModel", package: "analyzerkit"),
                .product(name: "SourceCorpus", package: "analyzerkit"),
            ],
            exclude: ["Goldens"],
            swiftSettings: strictSwiftSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
