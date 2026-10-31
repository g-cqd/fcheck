import AnalyzerCLI
import AnalyzerConfiguration
import ArgumentParser
import CorpusScan
import FCheckCore
import ProjectModel
import ReportSupport
import SourceCorpus
import SystemPackage

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// `fcheck analyze`, on analyzerkit's shared option groups (ADR-0019): Input, Output, Rules, Cache, in that order.
struct Analyze: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Analyze Swift files or directories (default: the current directory).")

    @OptionGroup(title: OptionGroupTitle.input) var input: InputOptions
    @OptionGroup(title: OptionGroupTitle.output) var output: OutputOptions
    @OptionGroup(title: OptionGroupTitle.rules) var rules: RuleOptions
    @OptionGroup(title: OptionGroupTitle.cache) var cache: CacheOptions

    func validate() throws {
        // Without a scope every finding is already reported, so there is nothing to promote (ADR-0028).
        if output.reportNewSince != nil, input.only.isEmpty, input.onlyFrom == nil {
            throw ValidationError("--report-new-since requires --only or --only-from")
        }
    }

    func run() async throws {
        for deprecation in input.deprecations { note(deprecation.message(tool: ToolInfo.name)) }
        // Read before the analysis, so a bad path fails with 78 without the analysis cost.
        let newSince = try output.reportNewSince.map { path in try loadBaseline(path) }
        let configuration: Configuration
        do { configuration = try loadConfiguration() } catch let failure as Configuration.Failure {
            write("fcheck: \(failure)\n", to: .standardError)
            throw ExitCode(ExitStatus.badConfiguration.rawValue)
        } catch {
            // A usage error: a `--rules` name no rule has, a region no one has.
            write("fcheck: \(error)\n", to: .standardError)
            throw ExitCode(ExitStatus.usage.rawValue)
        }
        if let missing = input.paths.first(where: { !FileManager.default.fileExists(atPath: $0) }) {
            write("fcheck: no such file or directory: \(missing)\n", to: .standardError)
            throw ExitCode(ExitStatus.usage.rawValue)
        }
        let commandLine = PathFilter(input.excludePaths, root: FileManager.default.currentDirectoryPath)
        let fromFile = configuration.pathFilter
        let files = discover(input.paths) { fromFile.excludes($0) || commandLine.excludes($0) }
        guard !files.isEmpty else {
            write("fcheck: no Swift files under \(input.paths.joined(separator: ", "))\n", to: .standardError)
            throw ExitCode(ExitStatus.usage.rawValue)
        }

        var report = try await Analyzer(configuration: configuration).analyze(
            paths: files, cache: cache.noCache ? nil : cacheLocation(files))
        let root = RepositoryRoot.common(of: report.findings.map(\.path)) ?? RepositoryRoot.common(of: files)
        let fingerprint = { (finding: Finding) in finding.fingerprint(root: root) }

        var promoted: Set<String> = []
        var baselineMatchesNothing = false
        if let scope = try scopedFiles() {
            let inScope = report.findings.filter { scope.contains($0.path) }
            let outOfScope = report.findings.filter { !scope.contains($0.path) }
            report.findings = inScope
            if let newSince {
                let known = Set(newSince.fingerprints)
                baselineMatchesNothing = NewSince.matchesNothing(
                    inScope + outOfScope, in: known, fingerprint: fingerprint)
                let promotion = NewSince.promote(
                    inScope: inScope, outOfScope: outOfScope, notIn: known, fingerprint: fingerprint)
                report.findings = Self.sorted(promotion.reported)
                promoted = promotion.promoted
            }
        }
        var baselined = 0
        if let writeBaseline = output.writeBaseline {
            do { try Baseline(findings: report.findings, root: root).write(to: writeBaseline) } catch {
                write("fcheck: cannot write baseline \(writeBaseline): \(error)\n", to: .standardError)
                throw ExitCode(ExitStatus.outputFailure.rawValue)
            }
            note("fcheck: wrote a baseline of \(report.findings.count) finding(s) to \(writeBaseline)")
            return
        }
        if let baseline = output.baseline {
            (report.findings, baselined) = try loadBaseline(baseline).filter(report.findings, root: root)
        }
        if let path = output.reportNewSince {
            // Counted after --baseline, so the note states what the report shows.
            let count = report.findings.count { promoted.contains(fingerprint($0)) }
            for message in NewSince.notes(promoted: count, matchesNothing: baselineMatchesNothing, baseline: path) {
                report.runNotes.append(RunNote(code: "report-new-since", severity: "note", message: message))
                note(message)
            }
        }

        let relative = output.relativeTo.map(SourcePath.canonical)
        write(
            try ReportFormatter.render(
                report, format: OutputFormat(output.format), root: root, relativeTo: relative, baselined: baselined,
                timings: output.timings, verbose: output.verbose),
            to: .standardOutput)
        summarize(report, baselined: baselined)
        // ADR-0018: an error fails the run, a warning only under --strict; reading no file at all is a failure too.
        let status = RunOutcome.status(
            severities: report.findings.map(\.severity), strict: output.strict,
            analyzedFileCount: report.analyzedFileCount - report.degraded.count, skippedFileCount: report.degraded.count
        )
        if status != .success { throw ExitCode(status.rawValue) }
    }

    private static func sorted(_ findings: [Finding]) -> [Finding] {
        findings.sorted {
            ($0.path, $0.line, $0.column, $0.rule.rawValue) < ($1.path, $1.line, $1.column, $1.rule.rawValue)
        }
    }

    /// A line on stderr, unless `--quiet`.
    private func note(_ line: String) {
        if !output.quiet { write(line + "\n", to: .standardError) }
    }

    private func loadBaseline(_ path: String) throws -> Baseline {
        do { return try Baseline.load(from: path) } catch {
            write("fcheck: \(error)\n", to: .standardError)
            throw ExitCode(ExitStatus.badConfiguration.rawValue)
        }
    }

    private func loadConfiguration() throws -> Configuration {
        // --config, or the configuration directory's shared and own files (ADR-0020).
        let resolved = try Configuration.resolve(
            explicit: input.config, currentDirectory: FileManager.default.currentDirectoryPath,
            analyzedPaths: input.paths)
        if output.verbose {
            for line in resolved.sources.verboseLines(tool: ToolInfo.name) { note(line) }
        }
        var configuration = resolved.configuration
        // `--define` adds to the configuration's defines (ADR-0029).
        configuration.defines = Array(Set(configuration.defines).union(input.defines)).sorted()
        // The command line's region lists replace the file's, side by side.
        if input.includeRegions != nil || input.excludeRegions != nil {
            let given = try RegionSelection(include: input.includeRegions, exclude: input.excludeRegions)
            configuration.regions = RegionSelection(
                include: input.includeRegions == nil ? configuration.regions.include : given.include,
                exclude: input.excludeRegions == nil ? configuration.regions.exclude : given.exclude)
        }
        if let wanted = rules.rules {
            let ids = try wanted.map { name -> RuleID in
                guard let rule = RuleID(rawValue: name) else {
                    throw ValidationError("no rule named \(name); `fcheck rules` lists them")
                }
                return rule
            }
            configuration.disable = RuleID.allCases.filter { !ids.contains($0) }
        }
        return configuration
    }

    /// The Swift files under `paths`; a walk prunes what `isExcluded` leaves out, and a file named directly is dropped
    /// when it matches.
    private func discover(_ paths: [String], isExcluded: @escaping @Sendable (String) -> Bool) -> [String] {
        var files: [String] = []
        for path in paths {
            let type = (try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType
            if type == .typeDirectory {
                files += SourceDiscovery.swiftFiles(under: path, isExcluded: isExcluded)
            } else if !isExcluded(path) {
                files.append(path)
            }
        }
        return files
    }

    private func scopedFiles() throws -> Set<String>? {
        var entries = input.only
        if let onlyFrom = input.onlyFrom {
            if onlyFrom == "-" {
                while let line = readLine() { entries.append(line) }
            } else {
                let text = try String(contentsOfFile: onlyFrom, encoding: .utf8)
                entries += text.split(whereSeparator: \.isNewline).map(String.init)
            }
        }
        return entries.isEmpty && input.onlyFrom == nil ? nil : Set(entries.map(SourcePath.canonical))
    }

    /// The cache's root (`--cache-path`, or the user cache directory) and the workspace the run serves (ADR-0011).
    private func cacheLocation(_ files: [String]) -> CacheLocation {
        let environment = ProcessInfo.processInfo.environment
        let root =
            cache.cachePath.map(SourcePath.absolute)
            ?? CacheLocation.defaultRoot(
                tool: ToolInfo.name, environment: environment, home: environment["HOME"] ?? "/tmp")
        let workspace =
            ProjectLayout.discover(paths: input.paths)?.root ?? RepositoryRoot.common(of: files)
            ?? FileManager.default.currentDirectoryPath
        return CacheLocation(root: root, workspace: workspace)
    }

    private func summarize(_ report: AnalysisReport, baselined: Int) {
        for (path, reason) in report.degraded.sorted(by: { $0.key < $1.key }) {
            write("fcheck: could not read \(path): \(reason)\n", to: .standardError)
        }
        if let cacheNote = report.cacheNote { note("fcheck: \(cacheNote)") }
        for issue in report.classificationIssues {
            note("fcheck: note: \(issue.message)")
            if output.verbose { for path in issue.paths { note("    \(path)") } }
        }
        if output.timings {
            for (phase, seconds) in report.timings.sorted(by: { $0.key < $1.key }) {
                note("fcheck: timing: \(phase) \(Int((seconds * 1000).rounded())) ms")
            }
        }
        let errors = report.findings.filter { $0.severity == .error }.count
        let warnings = report.findings.filter { $0.severity == .warning }.count
        note(
            "fcheck: \(report.findings.count) finding(s) (\(errors) error(s), \(warnings) warning(s)) in "
                + "\(report.analyzedFileCount) file(s)\(ReportSummary.notChecked(report.degraded.count)); "
                + "\(report.suppressed.count) suppressed, \(baselined) baselined; cache: "
                + "\(report.cacheHits) reused, \(report.cacheMisses) parsed")
    }
}

extension OutputFormat {
    init(_ format: OutputOptions.Format) {
        switch format {
        case .xcode: self = .xcode
        case .json: self = .json
        case .sarif: self = .sarif
        }
    }
}
