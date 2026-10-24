import FCheckCore
import Foundation

/// The findings of one in-memory source file.
func analyze(
    _ source: String, rules: Set<RuleID>? = nil, configuration: Configuration = .default, acquirers: Set<String> = []
) -> [Finding] {
    Analyzer(configuration: configuration)
        .analyze(bytes: Array(source.utf8), path: "T.swift", acquirers: acquirers).findings
        .filter { configuration.isEnabled($0.rule) && (rules?.contains($0.rule) ?? true) }
}

/// A scratch directory of Swift files, removed afterwards.
func withCorpus<T>(_ files: [String: String], _ body: (String) async throws -> T) async throws -> T {
    let root = FileManager.default.temporaryDirectory.appending(path: "fcheck-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for (name, text) in files {
        let url = root.appending(path: name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    return try await body(root.path)
}
