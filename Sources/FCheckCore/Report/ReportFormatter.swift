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
        _ report: AnalysisReport, format: OutputFormat, root: String?, relativeTo: String?, baselined: Int = 0
    ) throws -> String {
        switch format {
        case .xcode: return xcode(report, relativeTo: relativeTo)
        case .json: return try json(report, root: root, relativeTo: relativeTo, baselined: baselined)
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
                "\(path):\(finding.line):\(finding.column): \(finding.severity.rawValue): [\(finding.rule.rawValue)] \(finding.message)"
            )
            for step in finding.witness where step.line != finding.line {
                lines.append("\(path):\(step.line):1: note: \(step.text)")
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
        let schemaVersion = ReportSchema.version
        let tool = ToolInfo.name
        let version = ToolInfo.version
        let analyzedFileCount: Int
        let cacheHits: Int
        let cacheMisses: Int
        let suppressed: Int
        let baselined: Int
        let degradedFiles: [[String: String]]
        let findings: [JSONFinding]
    }

    private static func json(_ report: AnalysisReport, root: String?, relativeTo: String?, baselined: Int) throws
        -> String
    {
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
        return String(decoding: try encoder.encodeToBytes(value), as: UTF8.self) + "\n"
    }
}
