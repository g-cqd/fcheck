import FCheckCore
import Foundation
import Testing

/// Test and generated code is classified from the project before path conventions (analyzerkit ADR-0024, roadmap
/// 0043 and 0021): a test target outside `Tests/`, and a file importing a test framework, are test code.
@Suite struct ProjectRegionTests {
    private static let leak =
        "func leaks(_ p: String) throws {\n    let d = open(p, 0)\n    try work()\n    close(d)\n}\n"

    private static let manifest = """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "P",
            targets: [
                .target(name: "Lib", path: "Lib"),
                .testTarget(name: "Checks", dependencies: ["Lib"], path: "Checks"),
            ])
        """

    @Test func `a test target the manifest declares outside Tests is test code`() async throws {
        let paths = try await withCorpus([
            "Package.swift": Self.manifest, "Lib/A.swift": Self.leak, "Checks/ACheck.swift": Self.leak,
        ]) { root in
            try await Analyzer().analyze(paths: [root + "/Lib/A.swift", root + "/Checks/ACheck.swift"], cache: nil)
                .findings.map { URL(fileURLWithPath: $0.path).lastPathComponent }
        }
        #expect(paths == ["A.swift"])
    }

    @Test func `a file importing a test framework is test code wherever it is`() async throws {
        let report = try await withCorpus([
            "Package.swift": Self.manifest, "Lib/A.swift": Self.leak, "Lib/Helper.swift": "import XCTest\n" + Self.leak,
        ]) { root in
            try await Analyzer().analyze(paths: [root + "/Lib/A.swift", root + "/Lib/Helper.swift"], cache: nil)
        }
        #expect(report.findings.map { URL(fileURLWithPath: $0.path).lastPathComponent } == ["A.swift"])
        #expect(report.analyzedFileCount == 1)
    }

    @Test func `include-regions test brings both back`() async throws {
        var configuration = Configuration()
        configuration.regions = try .init(include: "test", exclude: nil)
        let paths = try await withCorpus([
            "Package.swift": Self.manifest, "Lib/A.swift": Self.leak, "Checks/ACheck.swift": Self.leak,
        ]) { root in
            try await Analyzer(configuration: configuration)
                .analyze(paths: [root + "/Lib/A.swift", root + "/Checks/ACheck.swift"], cache: nil)
                .findings.map { URL(fileURLWithPath: $0.path).lastPathComponent }.sorted()
        }
        #expect(paths == ["A.swift", "ACheck.swift"])
    }
}
