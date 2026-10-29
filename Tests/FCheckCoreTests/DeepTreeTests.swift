import FCheckCore
import Foundation
import Testing

/// A deeply nested file never crashes the run: one nested within reason is analysed on the large stack, one nested past
/// the limit is listed as degraded, and the rest of the corpus is analysed as usual (analyzerkit roadmap 0041).
@Suite struct DeepTreeTests {
    private static func chain(_ links: Int) -> String {
        "func f() {\n    let v = view" + String(repeating: ".m(1)", count: links) + "\n    print(v)\n}\n"
    }

    @Test func `a deep file is analysed or listed as degraded, and the corpus still reports`() async throws {
        let leak = "func g(_ p: String) {\n    let d = open(p, O_RDONLY)\n    print(d)\n}\n"
        try await withCorpus(["Deep.swift": Self.chain(3_000), "Deeper.swift": Self.chain(15_000), "Leak.swift": leak])
        {
            root in
            let paths = ["Deep.swift", "Deeper.swift", "Leak.swift"].map { root + "/" + $0 }
            let report = try await Analyzer().analyze(paths: paths, cacheURL: nil)
            #expect(report.findings.map(\.rule) == [.leakOnExit], "the ordinary file is still analysed")
            #expect(report.degraded.keys.map { ($0 as NSString).lastPathComponent } == ["Deeper.swift"])
            #expect(report.degraded.values.first?.contains("nested") == true)
        }
    }
}
