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
        .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "604.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.8.2"),
        .package(url: "https://github.com/apple/swift-system.git", exact: "1.8.1"),
        .package(
            url: "https://github.com/g-cqd/AemiJSON.git",
            revision: "75deac170071149540c436bdab47a5c6d5520a4a"
        ),
        .package(
            url: "https://github.com/g-cqd/analyzerkit.git",
            revision: "678bf5543d3029456c4852cf8829f5598d49652c"
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
