public import CorpusScan
public import ProjectModel
public import ReportSupport
import SourceCorpus
import SwiftParser
import SwiftSyntax

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
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
    /// What the run says about itself besides the cache and classification, such as `--report-new-since`'s notes.
    public var runNotes: [RunNote] = []
    /// Files classified by path conventions although a project encloses them (`project-unknown`, `project-unclaimed`).
    public var classificationIssues: [ClassificationIssue] = []
    /// Seconds per phase (`discover`, `scan`, `rules`), for `--timings`.
    public var timings: [String: Double] = [:]

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
    public func analyze(paths: [String], cache: CacheLocation?) async throws -> AnalysisReport {
        let configuration = configuration
        let identity = CacheIdentity.current(tool: ToolInfo.name, version: ToolInfo.version)
        let exclusion = configuration.pathFilter
        let started = ContinuousClock.now
        // Regions come from the project before path conventions (ADR-0024): the path decides first, cheaply, so a test
        // target is never parsed; the content signals (a test-framework import, a generator's header) decide after.
        let classification =
            ProjectLayout.discover(paths: paths).map(ProjectClassification.load) ?? .conventionsOnly
        let candidates = paths.filter { !exclusion.excludes($0) }
        let included = candidates.filter {
            configuration.analyzes(classification.classify(SourcePath.canonical($0)).region)
        }
        let classified = ContinuousClock.now
        let scan = try await CorpusScanner.scan(
            paths: included, cache: cache, identity: identity, salt: configuration.salt + Self.factsFormat
        ) { path, bytes in
            Analyzer(configuration: configuration)
                .analyze(bytes: bytes, path: path, acquirers: [], classification: classification)
        }
        let scanned = ContinuousClock.now

        var results: [String: FileResult] = [:]
        var report = AnalysisReport(findings: [])
        report.cacheNote = scan.cacheLoadFailure
        report.classificationIssues = classification.issues(for: included.map(SourcePath.canonical))
        // A file its content places in a region the run leaves out (a test-framework import under `Sources/`) is
        // neither analysed nor counted.
        let files = scan.files.filter { file in
            configuration.analyzes(CodeRegion(rawValue: file.facts?.region ?? 0))
        }
        report.analyzedFileCount = files.count
        report.cacheHits = files.count { $0.cacheHit }
        for file in files {
            if let reason = file.failure ?? file.facts?.degraded {
                report.degraded[file.path] = reason
            } else if let facts = file.facts {
                results[file.path] = facts
            }
        }

        try await secondPass(&results, cache: cache, identity: identity)

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
        report.timings = [
            "discover": Self.seconds(classified - started), "scan": Self.seconds(scanned - classified),
            "rules": Self.seconds(ContinuousClock.now - scanned),
        ]
        return report
    }

    /// The result for one file.
    ///
    /// - Parameters:
    ///   - bytes: the file's UTF-8 text.
    ///   - path: how findings name it.
    ///   - acquirers: simple names of corpus functions that return a handle, which `leak-on-exit` treats as acquiring.
    /// Corpus acquirers to a fixed point (roadmap 0025, F1): each round reruns, in parallel and through the cache, the
    /// files that call a name that became an acquirer, with every acquirer known so far; what those files return
    /// makes the next round's acquirers. A file's leak findings are those of the last round it ran in.
    ///
    /// Each round has its own cache workspace and the acquirers' digest as its salt, so a warm run that finds the same
    /// acquirers reads every round from the cache.
    private func secondPass(_ results: inout [String: FileResult], cache: CacheLocation?, identity: CacheIdentity?)
        async throws
    {
        let configuration = configuration
        var latest = results.mapValues(\.acquirers)
        var acquirers = Set(latest.values.joined())
        let called = results.mapValues { Set($0.calledNames) }
        var ranWith: [String: Set<String>] = [:]
        var round = 0
        while !acquirers.isEmpty, round < Self.maximumRounds {
            let names = Set(acquirers.map { ResourceRule.Acquirer.parse($0).name })
            let relevant: (String) -> Set<String> = { path in
                let calls = called[path] ?? []
                return acquirers.filter { calls.contains(ResourceRule.Acquirer.parse($0).name) }
            }
            let rerun = called.keys.filter { path in
                guard called[path]?.contains(where: names.contains) == true else { return false }
                return relevant(path) != (ranWith[path] ?? [])
            }.sorted()
            if rerun.isEmpty { break }
            let known = acquirers
            let location = cache.map {
                CacheLocation(
                    root: $0.root, workspace: $0.workspace + "#acquirers-\(round)", maximumBytes: $0.maximumBytes)
            }
            let salt =
                configuration.salt + "|" + ContentFingerprint.of(Array(known.sorted().joined(separator: "\n").utf8))
            let scan = try await CorpusScanner.scan(paths: rerun, cache: location, identity: identity, salt: salt) {
                path, bytes in
                Analyzer(configuration: configuration).analyze(bytes: bytes, path: path, acquirers: known)
            }
            for file in scan.files {
                guard let again = file.facts, again.degraded == nil, var merged = results[file.path] else { continue }
                ranWith[file.path] = relevant(file.path)
                merged.findings =
                    merged.findings.filter { $0.rule != .leakOnExit } + again.findings.filter { $0.rule == .leakOnExit }
                results[file.path] = merged
                latest[file.path] = again.acquirers
            }
            acquirers = Set(latest.values.joined())
            round += 1
        }
    }

    /// The cached facts' shape: acquirer keys with arity and type, and the called names (roadmap 0025).
    static let factsFormat = "|facts-2"

    /// A bound on the rounds, which only a chain of wrappers this deep reaches.
    static let maximumRounds = 16

    public func analyze(
        bytes: [UInt8], path: String, acquirers: Set<String>, classification: ProjectClassification? = nil
    ) -> FileResult {
        let tree = Parser.parse(source: String(decoding: bytes, as: UTF8.self))
        let region = classification?.classify(path, tree: tree).region.rawValue ?? 0
        // Every walk below recurses once per level of the tree; past the limit the file is listed, not walked.
        if SyntaxDepth.exceeds(tree) {
            return FileResult(
                degraded: "nested deeper than \(SyntaxDepth.defaultLimit) levels; not analysed", region: region)
        }
        let converter = SourceLocationConverter(fileName: path, tree: tree)
        let (units, definitions, declared) = UnitCollector.collect(tree, converter: converter, path: path)
        var result = FileResult(directives: Directive.scan(tree, converter: converter), region: region)

        let leaks = ResourceRule(configuration: configuration, acquirers: acquirers, declared: declared)
        let durability = DurabilityRule(configuration: configuration)
        let decodes = DecodeCutRule(configuration: configuration)
        var returning: Set<String> = []
        // Every rule runs whether or not it is reported, so the cached result serves any choice of rules.
        for unit in units {
            let outcome = leaks.analyze(unit)
            result.findings += outcome.findings
            if outcome.returnsHandle { returning.insert(unit.acquirerKey) }
            result.findings += durability.analyze(unit)
            result.findings += decodes.analyze(unit, definitions: definitions)
        }
        result.acquirers = returning.sorted()
        result.calledNames = CalledNames.of(tree)
        return result
    }

    private static func seconds(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) + Double(attoseconds) / 1e18
    }

}
