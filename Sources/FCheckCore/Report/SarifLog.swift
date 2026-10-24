internal import AemiJSON
internal import ProjectModel
internal import ReportSupport

/// A SARIF 2.1.0 log: one run, the rules, each finding with its witness as a code flow.
enum SarifLog {
    private struct Message: Encodable { let text: String }
    private struct ArtifactLocation: Encodable {
        let uri: String
        let uriBaseId: String?
    }
    private struct Region: Encodable {
        let startLine: Int
        let startColumn: Int?
    }
    private struct Physical: Encodable {
        let artifactLocation: ArtifactLocation
        let region: Region
    }
    private struct Location: Encodable {
        let physicalLocation: Physical
        let message: Message?
    }
    private struct FlowLocation: Encodable { let location: Location }
    private struct ThreadFlow: Encodable { let locations: [FlowLocation] }
    private struct CodeFlow: Encodable { let threadFlows: [ThreadFlow] }
    private struct Result: Encodable {
        let ruleId: String
        let level: String
        let message: Message
        let locations: [Location]
        let codeFlows: [CodeFlow]
        let partialFingerprints: [String: String]
    }
    private struct RuleDescriptor: Encodable {
        let id: String
        let shortDescription: Message
        let fullDescription: Message
        let defaultConfiguration: [String: String]
        let properties: [String: String]
    }
    private struct Driver: Encodable {
        let name = ToolInfo.name
        let version = ToolInfo.version
        let informationUri = ToolInfo.informationURI
        let rules: [RuleDescriptor]
    }
    private struct Tool: Encodable { let driver: Driver }
    private struct Run: Encodable {
        let tool: Tool
        let columnKind = "utf16CodeUnits"
        let originalUriBaseIds: [String: ArtifactLocation]?
        let results: [Result]
    }
    private struct Log: Encodable {
        let version = "2.1.0"
        let schema = "https://json.schemastore.org/sarif-2.1.0.json"
        let runs: [Run]

        private enum CodingKeys: String, CodingKey {
            case version
            case schema = "$schema"
            case runs
        }
    }

    static func render(_ report: AnalysisReport, root: String?) throws -> String {
        var columns = SarifColumns(root: root, byteOrderMark: .parsed, readCap: 10 << 20)
        func location(_ path: String, line: Int, column: Int?, text: String?) -> Location {
            let (uri, base) = ArtifactURI.location(of: path, root: root)
            let converted = column.map { columns.column($0, line: line, path: path) }
            return Location(
                physicalLocation: Physical(
                    artifactLocation: ArtifactLocation(uri: uri, uriBaseId: base),
                    region: Region(startLine: line, startColumn: converted)),
                message: text.map(Message.init))
        }
        let results = report.findings.map { finding in
            Result(
                ruleId: finding.rule.rawValue, level: finding.severity.rawValue,
                message: Message(text: finding.message),
                locations: [location(finding.path, line: finding.line, column: finding.column, text: nil)],
                codeFlows: finding.witness.isEmpty
                    ? []
                    : [
                        CodeFlow(
                            threadFlows: [
                                ThreadFlow(
                                    locations: finding.witness.map {
                                        FlowLocation(
                                            location: location(finding.path, line: $0.line, column: nil, text: $0.text))
                                    })
                            ])
                    ],
                partialFingerprints: ["fcheck/v1": finding.fingerprint(root: root)])
        }
        let rules = RuleID.allCases.map {
            RuleDescriptor(
                id: $0.rawValue, shortDescription: Message(text: $0.summary),
                fullDescription: Message(text: $0.explanation),
                defaultConfiguration: ["level": $0.defaultSeverity.rawValue],
                properties: ["shape": $0.shape, "evidence": $0.evidence])
        }
        let bases = root.map {
            [ArtifactURI.baseID: ArtifactLocation(uri: ArtifactURI.baseURI(of: $0), uriBaseId: nil)]
        }
        let log = Log(runs: [Run(tool: Tool(driver: Driver(rules: rules)), originalUriBaseIds: bases, results: results)]
        )
        var encoder = AemiJSON.JSONEncoder()
        encoder.options.keyOrder = .sorted
        encoder.prettyPrinted = true
        return String(decoding: try encoder.encodeToBytes(log), as: UTF8.self) + "\n"
    }
}
