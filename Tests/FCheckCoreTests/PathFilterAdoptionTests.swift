import FCheckCore
import Foundation
import Testing

/// `exclude` follows ADR-0008, the rule every tool shares: substrings as before, globs relative to the configuration
/// file's directory (analyzerkit roadmap 0005).
@Suite struct PathFilterAdoptionTests {
    private static let leak = "func g(_ p: String) {\n    let d = open(p, O_RDONLY)\n    print(d)\n}\n"
    private static let files = [
        "Sources/App/Internal/Secret.swift", "Package.swift", "Sources/Generated/API.swift",
        "Sources/App/Internal.swift", "Sources/App/App.swift",
    ]

    @Test func `globs are relative to the configuration file and substrings keep their meaning`() async throws {
        let config = #"{"exclude": ["Sources/*/Internal", "/*.swift", "Generated/"]}"#
        let corpus = Dictionary(uniqueKeysWithValues: Self.files.map { ($0, Self.leak) } + [(".fcheck.json", config)])
        try await withCorpus(corpus) { root in
            let configuration = try Configuration.load(from: root + "/.fcheck.json")
            #expect(configuration.isExcluded(path: root + "/Sources/App/Internal/Secret.swift"))
            #expect(configuration.isExcluded(path: root + "/Package.swift"))
            #expect(configuration.isExcluded(path: root + "/Sources/Generated/API.swift"))
            #expect(!configuration.isExcluded(path: root + "/Sources/App/Internal.swift"))
            let report = try await Analyzer(configuration: configuration)
                .analyze(paths: Self.files.map { root + "/" + $0 }, cacheURL: nil)
            let analysed = Set(report.findings.map { String($0.path.dropFirst(root.count + 1)) })
            #expect(analysed == ["Sources/App/Internal.swift", "Sources/App/App.swift"])
        }
    }
}
