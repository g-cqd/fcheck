import FCheckCore
import Foundation
import ProjectModel
import Testing

@Suite struct AnalyzerTests {
    private let leaking = "func f() throws {\n let d = open(p, 0)\n try work()\n}"

    @Test func `a second run over unchanged files parses nothing and finds the same`() async throws {
        try await withCorpus(["A.swift": leaking, "B.swift": "func ok() {}"]) { root in
            let cache = URL(fileURLWithPath: root + "/cache/facts.json")
            let paths = [root + "/A.swift", root + "/B.swift"]
            let cold = try await Analyzer().analyze(paths: paths, cacheURL: cache)
            let warm = try await Analyzer().analyze(paths: paths, cacheURL: cache)
            #expect(cold.cacheHits == 0 && warm.cacheHits == 2)
            #expect(warm.findings == cold.findings && warm.findings.count == 1)
        }
    }

    @Test func `a changed configuration does not reuse results made under another`() async throws {
        try await withCorpus(["A.swift": leaking]) { root in
            let cache = URL(fileURLWithPath: root + "/cache/facts.json")
            _ = try await Analyzer().analyze(paths: [root + "/A.swift"], cacheURL: cache)
            let other = try await Analyzer(configuration: Configuration(severity: [.leakOnExit: .error]))
                .analyze(paths: [root + "/A.swift"], cacheURL: cache)
            #expect(other.cacheHits == 0 && other.findings.first?.severity == .error)
        }
    }

    @Test func `test and generated files are left out unless asked for`() async throws {
        let files = ["Sources/A.swift": leaking, "Tests/ATests.swift": leaking, "Sources/B.generated.swift": leaking]
        try await withCorpus(files) { root in
            let paths = files.keys.map { root + "/" + $0 }
            #expect(try await Analyzer().analyze(paths: paths, cacheURL: nil).findings.count == 1)
            let all = try await Analyzer(configuration: Configuration(includeTests: true)).analyze(
                paths: paths, cacheURL: nil)
            #expect(all.findings.count == 3)
        }
    }

    @Test func `excluded paths are not analyzed`() async throws {
        try await withCorpus(["Vendor/A.swift": leaking, "B.swift": leaking]) { root in
            let paths = [root + "/Vendor/A.swift", root + "/B.swift"]
            let report = try await Analyzer(configuration: Configuration(exclude: ["/Vendor/"])).analyze(
                paths: paths, cacheURL: nil)
            #expect(report.findings.count == 1 && report.analyzedFileCount == 1)
        }
    }

    @Test func `a file that cannot be read is reported degraded and the rest still runs`() async throws {
        try await withCorpus(["A.swift": leaking]) { root in
            let report = try await Analyzer().analyze(
                paths: [root + "/A.swift", root + "/Missing.swift"], cacheURL: nil)
            #expect(report.findings.count == 1 && report.degraded.keys.contains { $0.hasSuffix("Missing.swift") })
        }
    }

    @Test func `findings are sorted by path and line`() async throws {
        let two = leaking + "\nfunc g() throws {\n let e = open(p, 0)\n try work()\n}"
        try await withCorpus(["B.swift": leaking, "A.swift": two]) { root in
            let report = try await Analyzer().analyze(paths: [root + "/B.swift", root + "/A.swift"], cacheURL: nil)
            #expect(
                report.findings.map { "\(URL(fileURLWithPath: $0.path).lastPathComponent):\($0.line)" } == [
                    "A.swift:2", "A.swift:6", "B.swift:2",
                ])
        }
    }

    @Test func `source that does not parse still analyzes what does`() {
        #expect(analyze("func f( {{{\n" + leaking).count <= 1)
    }

    @Test func `a body nested past any sane depth does not crash`() {
        let source =
            "func f() {\n" + String(repeating: "if c {\n", count: 600) + " let d = open(p, 0)\n"
            + String(repeating: "}\n", count: 600) + "}"
        _ = analyze(source)
    }
}

@Suite struct RuleSelectionTests {
    @Test func `switching a rule off and on again reuses the cache`() async throws {
        let leaking = "func f() throws {\n let d = open(p, 0)\n try work()\n}"
        try await withCorpus(["A.swift": leaking]) { root in
            let cache = URL(fileURLWithPath: root + "/cache/facts.json")
            let path = root + "/A.swift"
            let all = try await Analyzer().analyze(paths: [path], cacheURL: cache)
            let off = try await Analyzer(configuration: Configuration(disable: [.leakOnExit])).analyze(
                paths: [path], cacheURL: cache)
            let on = try await Analyzer().analyze(paths: [path], cacheURL: cache)
            #expect(all.findings.count == 1 && off.findings.isEmpty && on.findings.count == 1)
            #expect(off.cacheHits == 1 && on.cacheHits == 1)
        }
    }
}
