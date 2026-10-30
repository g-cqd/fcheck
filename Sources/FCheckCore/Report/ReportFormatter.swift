internal import AemiJSON
internal import ProjectModel
internal import ReportSupport
internal import SourceCorpus

/// The output formats.
public enum OutputFormat: String, CaseIterable, Sendable {
    /// `path:line:col: warning: [rule] message`, which Xcode and most editors turn into diagnostics.
    case xcode
    case json
    case sarif
}

public enum ReportFormatter {
    /// `report` in `format`.
    /// - Parameters:
    ///   - root: the repository root, which makes fingerprints and SARIF paths independent of the checkout.
    ///   - relativeTo: when set, the directory paths in `xcode` and `json` output are made relative to.
    /// - Throws: an encoding error.
    public static func render(
        _ report: AnalysisReport, format: OutputFormat, root: String?, relativeTo: String?, baselined: Int = 0,
        timings: Bool = false, verbose: Bool = false
    ) throws -> String {
        switch format {
        case .xcode: return xcode(report, relativeTo: relativeTo)
        case .json:
            return try json(
                report, root: root, relativeTo: relativeTo, baselined: baselined,
                timings: timings ? report.timings : nil, verbose: verbose)
        case .sarif: return try SarifLog.render(report, root: relativeTo ?? root)
        }
    }

    private static func shown(_ path: String, _ relativeTo: String?) -> String {
        relativeTo.map { RepositoryRoot.relativize(path, to: $0) } ?? path
    }

    private static func xcode(_ report: AnalysisReport, relativeTo: String?) -> String {
        var lines: [String] = []
        for finding in report.findings {
            let path = shown(finding.path, relativeTo)
            lines.append(
                XcodeDiagnostic.line(
                    path: path, line: finding.line, column: finding.column, severity: finding.severity.rawValue,
                    rule: finding.rule.rawValue, message: finding.message))
            for step in finding.witness where step.line != finding.line {
                lines.append(
                    XcodeDiagnostic.line(
                        path: path, line: step.line, column: 1, severity: "note", rule: nil, message: step.text))
            }
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    private struct JSONFinding: Encodable {
        let rule: String
        let shape: String
        let evidence: String
        let severity: String
        let path: String
        let line: Int
        let column: Int
        let function: String
        let message: String
        let fingerprint: String
        let witness: [Finding.Step]
    }

    private struct JSONReport: Encodable {
        let analyzedFileCount: Int
        let cacheHits: Int
        let cacheMisses: Int
        let suppressed: Int
        let baselined: Int
        let degradedFiles: [[String: String]]
        let findings: [JSONFinding]
    }

    private static func json(
        _ report: AnalysisReport, root: String?, relativeTo: String?, baselined: Int, timings: [String: Double]?,
        verbose: Bool
    ) throws -> String {
        let value = JSONReport(
            analyzedFileCount: report.analyzedFileCount, cacheHits: report.cacheHits, cacheMisses: report.cacheMisses,
            suppressed: report.suppressed.count, baselined: baselined,
            degradedFiles: report.degraded.sorted { $0.key < $1.key }.map { ["path": $0.key, "reason": $0.value] },
            findings: report.findings.map {
                JSONFinding(
                    rule: $0.rule.rawValue, shape: $0.rule.shape, evidence: $0.rule.evidence,
                    severity: $0.severity.rawValue,
                    path: shown($0.path, relativeTo), line: $0.line, column: $0.column, function: $0.function,
                    message: $0.message, fingerprint: $0.fingerprint(root: root), witness: $0.witness)
            })
        var encoder = AemiJSON.JSONEncoder()
        encoder.options.keyOrder = .sorted
        encoder.prettyPrinted = true
        // ADR-0017: schemaVersion, tool and version as before, from the shared envelope, with runNotes and skippedFiles.
        let envelope = ReportEnvelope(
            value, tool: ToolInfo.name, version: ToolInfo.version,
            runNotes: (report.cacheNote.map { [RunNote(code: "cache", severity: "note", message: $0)] } ?? [])
                + report.classificationIssues.map { issue in
                    RunNote(
                        code: issue.code, severity: "note", message: issue.message,
                        paths: issue.paths.map { shown($0, relativeTo) }, verbose: verbose)
                } + report.runNotes,
            skippedFiles: report.degraded.keys.sorted().map {
                SkippedFile(path: shown($0, relativeTo), reason: .degraded)
            }, timings: timings)
        return String(decoding: try encoder.encodeToBytes(envelope), as: UTF8.self) + "\n"
    }
}
