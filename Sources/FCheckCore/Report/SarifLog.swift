internal import AemiJSON
internal import ProjectModel
internal import ReportSupport
internal import SourceCorpus

/// fcheck's SARIF 2.1.0 log on analyzerkit's shared model (roadmap 0011): one run, the rules, each finding with its
/// witness as a code flow.
enum SarifLog {
    static func render(_ report: AnalysisReport, root: String?) throws -> String {
        var columns = SarifColumns(root: root, byteOrderMark: .parsed, readCap: 10 << 20)
        func location(_ path: String, line: Int, column: Int?, text: String?) -> Sarif.Location {
            // ArtifactURI and SarifColumns take the path as the report spells it: relative to `root` when inside it.
            let path = root.map { RepositoryRoot.relativize(path, to: $0) } ?? path
            let converted = column.map { columns.column($0, line: line, path: path) }
            return Sarif.Location(
                physicalLocation: Sarif.PhysicalLocation(
                    artifactLocation: Sarif.ArtifactLocation(path: path, root: root),
                    region: Sarif.Region(startLine: line, startColumn: converted)),
                message: text.map(Sarif.Text.init))
        }
        let results = report.findings.map { finding in
            Sarif.Result(
                ruleId: finding.rule.rawValue, level: finding.severity.rawValue,
                message: Sarif.Text(finding.message),
                locations: [location(finding.path, line: finding.line, column: finding.column, text: nil)],
                // Always written, `[]` without a witness, as fcheck always has.
                codeFlows: finding.witness.isEmpty
                    ? []
                    : [
                        Sarif.CodeFlow(threadFlows: [
                            Sarif.ThreadFlow(
                                locations: finding.witness.map {
                                    Sarif.ThreadFlowLocation(
                                        location: location(finding.path, line: $0.line, column: nil, text: $0.text))
                                })
                        ])
                    ],
                partialFingerprints: ["fcheck/v1": finding.fingerprint(root: root)])
        }
        let rules = RuleID.allCases.map {
            Sarif.Rule(
                id: $0.rawValue, shortDescription: Sarif.Text($0.summary),
                fullDescription: Sarif.Text($0.explanation),
                defaultConfiguration: ["level": $0.defaultSeverity.rawValue],
                properties: ["shape": .string($0.shape), "evidence": .string($0.evidence)])
        }
        let driver = Sarif.Driver(
            name: ToolInfo.name, version: ToolInfo.version, informationUri: ToolInfo.informationURI, rules: rules)
        let log = Sarif.Log(runs: [
            Sarif.Run(tool: Sarif.Tool(driver: driver), invocations: nil, root: root, results: results)
        ])
        var encoder = AemiJSON.JSONEncoder()
        encoder.options.keyOrder = .sorted
        encoder.prettyPrinted = true
        return String(decoding: try encoder.encodeToBytes(log), as: UTF8.self) + "\n"
    }
}
