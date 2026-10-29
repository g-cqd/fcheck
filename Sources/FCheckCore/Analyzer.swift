import CorpusScan
import ProjectModel
import SourceCorpus
import SwiftParser
import SwiftSyntax

#if canImport(FoundationEssentials)
    public import FoundationEssentials
#else
    public import Foundation
#endif

/// What a run found.
public struct AnalysisReport: Sendable {
    /// Findings not suppressed by a comment or a baseline, sorted by path, line, column and rule.
    public var findings: [Finding]
    /// Findings a `@fc:` comment suppressed, with the reason it gave.
    public var suppressed: [(finding: Finding, reason: String?)] = []
    public var analyzedFileCount = 0
    public var cacheHits = 0
    /// Files that could not be read, with why.
    public var degraded: [String: String] = [:]
    public var cacheNote: String?

    public var cacheMisses: Int { analyzedFileCount - cacheHits }
}

/// Runs the rules over a corpus.
public struct Analyzer: Sendable {
    public let configuration: Configuration

    public init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    /// Analyses `paths`, reusing each unchanged file's result from the cache.
    ///
    /// The run has two passes. The first finds, file by file and cached, the findings and the functions that return
    /// a handle they acquired. The second repeats `leak-on-exit` over the files that mention such a function, so a
    /// caller of a helper is held to the same obligation as a caller of `open`.
    /// - Throws: `CancellationError`.
    /// - Complexity: O(*n*) in the corpus over the available cores; the second pass reads only files that mention a helper.
    public func analyze(paths: [String], cacheURL: URL?) async throws -> AnalysisReport {
        let configuration = configuration
        let identity = FactsCache<FileResult>.Identity.current(tool: ToolInfo.name, version: ToolInfo.version)
        let included = paths.filter { path in
            !configuration.exclude.contains { path.contains($0) }
                && (configuration.includeTests || !Self.isTestOrGenerated(path))
        }
        let scan = try await CorpusScanner.scan(
            paths: included, cacheURL: cacheURL, identity: identity, salt: configuration.salt
        ) { path, bytes in
            Analyzer(configuration: configuration).analyze(bytes: bytes, path: path, acquirers: [])
        }

        var results: [String: FileResult] = [:]
        var report = AnalysisReport(findings: [])
        report.analyzedFileCount = scan.files.count
        report.cacheHits = scan.cacheHits
        report.cacheNote = scan.cacheLoadFailure
        for file in scan.files {
            if let reason = file.failure ?? file.facts?.degraded {
                report.degraded[file.path] = reason
            } else if let facts = file.facts {
                results[file.path] = facts
            }
        }

        let acquirers = Set(results.values.flatMap(\.acquirers))
        if !acquirers.isEmpty {
            for path in results.keys.sorted() {
                guard let bytes = try? BoundedFileReader.read(path: path, cap: BoundedFileReader.sourceByteCap),
                    Self.mentions(bytes, any: acquirers)
                else { continue }
                // The second pass parses again, so it needs the large stack as much as the first (roadmap 0041).
                let again = await LargeStack.run { [self] in analyze(bytes: bytes, path: path, acquirers: acquirers) }
                var merged = results[path] ?? again
                merged.findings =
                    merged.findings.filter { $0.rule != .leakOnExit } + again.findings.filter { $0.rule == .leakOnExit }
                results[path] = merged
            }
        }

        var kept: [Finding] = []
        for (path, result) in results {
            let table = SuppressionTable(directives: result.directives)
            for finding in result.findings where configuration.isEnabled(finding.rule) {
                if let reason = table.suppression(of: finding.rule, at: finding.line) {
                    report.suppressed.append((finding, reason))
                } else {
                    kept.append(finding)
                }
            }
            _ = path
        }
        report.findings = kept.sorted {
            ($0.path, $0.line, $0.column, $0.rule.rawValue) < ($1.path, $1.line, $1.column, $1.rule.rawValue)
        }
        return report
    }

    /// The result for one file.
    ///
    /// - Parameters:
    ///   - bytes: the file's UTF-8 text.
    ///   - path: how findings name it.
    ///   - acquirers: simple names of corpus functions that return a handle, which `leak-on-exit` treats as acquiring.
    public func analyze(bytes: [UInt8], path: String, acquirers: Set<String>) -> FileResult {
        let tree = Parser.parse(source: String(decoding: bytes, as: UTF8.self))
        // Every walk below recurses once per level of the tree; past the limit the file is listed, not walked.
        if SyntaxDepth.exceeds(tree) {
            return FileResult(degraded: "nested deeper than \(SyntaxDepth.defaultLimit) levels; not analysed")
        }
        let converter = SourceLocationConverter(fileName: path, tree: tree)
        let (units, definitions, declared) = UnitCollector.collect(tree, converter: converter, path: path)
        var result = FileResult(directives: Directive.scan(tree, converter: converter))

        let leaks = ResourceRule(configuration: configuration, acquirers: acquirers, declared: declared)
        let durability = DurabilityRule(configuration: configuration)
        let decodes = DecodeCutRule(configuration: configuration)
        var returning: Set<String> = []
        // Every rule runs whether or not it is reported, so the cached result serves any choice of rules.
        for unit in units {
            let outcome = leaks.analyze(unit)
            result.findings += outcome.findings
            if outcome.returnsHandle { returning.insert(unit.simpleName) }
            result.findings += durability.analyze(unit)
            result.findings += decodes.analyze(unit, definitions: definitions)
        }
        result.acquirers = returning.sorted()
        return result
    }

    private static func isTestOrGenerated(_ path: String) -> Bool {
        TestConventions.isTestPath(path) || GeneratedCode.isGenerated(path: path, header: "")
    }

    private static func mentions(_ bytes: [UInt8], any names: Set<String>) -> Bool {
        let text = String(decoding: bytes, as: UTF8.self)
        return names.contains { text.contains($0) }
    }
}
