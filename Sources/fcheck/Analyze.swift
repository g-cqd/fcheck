import ArgumentParser
import FCheckCore
import ProjectModel
import SourceCorpus
import SystemPackage

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

struct Analyze: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Analyze Swift files or directories (default: the current directory).")

    @Argument(help: "Files or directories to analyze.")
    var paths: [String] = ["."]

    @Option(name: .long, help: "Output format: xcode, json or sarif.")
    var format: OutputFormat = .xcode

    @Flag(name: .long, help: "Exit 1 on any warning or error finding.")
    var strict = false

    @Option(name: .long, help: "Configuration file (default: ./.fcheck.json when present).")
    var config: String?

    @Option(name: .long, help: "Only these rules, comma-separated (see `fcheck rules`).")
    var rules: String?

    @Option(name: .long, help: "Baseline file: findings it holds are left out.")
    var baseline: String?

    @Option(name: .long, help: "Write the current findings as a baseline, then exit 0.")
    var writeBaseline: String?

    @Option(name: .long, help: "Report only findings in this file; repeatable. The whole corpus is still analyzed.")
    var only: [String] = []

    @Option(name: .customLong("only-from"), help: "Read --only paths from a file, one per line ('-' reads stdin).")
    var onlyFrom: String?

    @Option(name: .long, help: "Show paths relative to this directory.")
    var relativeTo: String?

    @Flag(name: .long, help: "Analyze test and generated code too.")
    var includeTests = false

    @Flag(name: .long, help: "Do not read or write the facts cache.")
    var noCache = false

    @Option(name: .long, help: "The facts cache file (default: a per-workspace file under the user cache directory).")
    var cachePath: String?

    func run() async throws {
        let configuration: Configuration
        do { configuration = try loadConfiguration() } catch {
            write("fcheck: \(error)\n", to: .standardError)
            throw ExitCode(64)
        }
        if let missing = paths.first(where: { !FileManager.default.fileExists(atPath: $0) }) {
            write("fcheck: no such file or directory: \(missing)\n", to: .standardError)
            throw ExitCode(64)
        }
        let files = discover(paths)
        guard !files.isEmpty else {
            write("fcheck: no Swift files under \(paths.joined(separator: ", "))\n", to: .standardError)
            throw ExitCode(64)
        }

        var report = try await Analyzer(configuration: configuration).analyze(
            paths: files, cacheURL: noCache ? nil : cacheURL())
        let root = RepositoryRoot.common(of: report.findings.map(\.path)) ?? RepositoryRoot.common(of: files)

        if let scope = try scopedFiles() {
            report.findings = report.findings.filter { scope.contains($0.path) }
        }
        var baselined = 0
        if let writeBaseline {
            try Baseline(findings: report.findings, root: root).write(to: writeBaseline)
            write(
                "fcheck: wrote a baseline of \(report.findings.count) finding(s) to \(writeBaseline)\n",
                to: .standardError)
            return
        }
        if let baseline {
            let loaded: Baseline
            do { loaded = try Baseline.load(from: baseline) } catch {
                write("fcheck: \(error)\n", to: .standardError)
                throw ExitCode(64)
            }
            (report.findings, baselined) = loaded.filter(report.findings, root: root)
        }

        let relative = relativeTo.map(SourcePath.canonical)
        write(
            try ReportFormatter.render(report, format: format, root: root, relativeTo: relative, baselined: baselined),
            to: .standardOutput)
        summarize(report, baselined: baselined)
        if strict, report.findings.contains(where: { $0.severity >= .warning }) { throw ExitCode(1) }
    }

    private func loadConfiguration() throws -> Configuration {
        var configuration: Configuration
        if let config {
            guard FileManager.default.fileExists(atPath: config) else {
                throw Configuration.Failure.unreadable(path: config, reason: "no such file")
            }
            configuration = try Configuration.load(from: config)
        } else {
            configuration = try Configuration.load(from: FileManager.default.currentDirectoryPath + "/.fcheck.json")
        }
        if includeTests { configuration.includeTests = true }
        if let rules {
            let wanted = try rules.split(separator: ",").map { name -> RuleID in
                guard let rule = RuleID(rawValue: String(name)) else {
                    throw ValidationError("no rule named \(name); `fcheck rules` lists them")
                }
                return rule
            }
            configuration.disable = RuleID.allCases.filter { !wanted.contains($0) }
        }
        return configuration
    }

    private func discover(_ paths: [String]) -> [String] {
        var files: [String] = []
        for path in paths {
            let type = (try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType
            if type == .typeDirectory { files += SourceDiscovery.swiftFiles(under: path) } else { files.append(path) }
        }
        return files
    }

    private func scopedFiles() throws -> Set<String>? {
        var entries = only
        if let onlyFrom {
            let text: String
            if onlyFrom == "-" {
                text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
            } else {
                text = try String(contentsOfFile: onlyFrom, encoding: .utf8)
            }
            entries += text.split(whereSeparator: \.isNewline).map(String.init)
        }
        return entries.isEmpty && onlyFrom == nil ? nil : Set(entries.map(SourcePath.canonical))
    }

    private func cacheURL() -> URL {
        if let cachePath { return URL(fileURLWithPath: cachePath) }
        let base =
            ProcessInfo.processInfo.environment["XDG_CACHE_HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil }
            ?? NSHomeDirectory() + "/.cache"
        let key = RepositoryRoot.workspaceKey(from: FileManager.default.currentDirectoryPath)
        return URL(fileURLWithPath: base + "/\(ToolInfo.name)/\(key)/facts.json")
    }

    private func summarize(_ report: AnalysisReport, baselined: Int) {
        for (path, reason) in report.degraded.sorted(by: { $0.key < $1.key }) {
            write("fcheck: could not read \(path): \(reason)\n", to: .standardError)
        }
        if let note = report.cacheNote { write("fcheck: \(note)\n", to: .standardError) }
        let errors = report.findings.filter { $0.severity == .error }.count
        let warnings = report.findings.filter { $0.severity == .warning }.count
        write(
            "fcheck: \(report.findings.count) finding(s) (\(errors) error(s), \(warnings) warning(s)) in "
                + "\(report.analyzedFileCount) file(s); \(report.suppressed.count) suppressed, \(baselined) baselined; cache: "
                + "\(report.cacheHits) reused, \(report.cacheMisses) parsed\n", to: .standardError)
    }
}
