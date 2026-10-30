public import ProjectModel

/// One place where a rule's obligation is not kept.
public struct Finding: Codable, Sendable, Hashable {
    /// A line on the path from the trigger to where the obligation fails.
    public struct Step: Codable, Sendable, Hashable {
        public let line: Int
        public let text: String

        public init(line: Int, text: String) {
            self.line = line
            self.text = text
        }
    }

    public let rule: RuleID
    public let severity: Severity
    public let path: String
    public let line: Int
    public let column: Int
    /// The enclosing function, as `Type.name(labels:)`.
    public let function: String
    public let message: String
    /// The path through the function that breaks the obligation, in order.
    public let witness: [Step]

    public init(
        rule: RuleID, severity: Severity, path: String, line: Int, column: Int, function: String, message: String,
        witness: [Step]
    ) {
        self.rule = rule
        self.severity = severity
        self.path = path
        self.line = line
        self.column = column
        self.function = function
        self.message = message
        self.witness = witness
    }
}

/// What analysing one file produced; what the cache stores.
public struct FileResult: Codable, Sendable, Equatable {
    public var findings: [Finding]
    /// Functions in this file that return a handle they acquired, so callers acquire through them, as
    /// `Type.name#required-total` (roadmap 0025, F4).
    public var acquirers: [String]
    /// The last name of every call in the file, sorted and unique: the second pass reruns a file only when one of them
    /// names a corpus acquirer.
    public var calledNames: [String] = []
    /// The suppression directives found in the file.
    public var directives: [Directive]
    /// Why the file was not analysed, when its syntax tree nests too deeply to walk (analyzerkit roadmap 0041).
    public var degraded: String?
    /// The file's region (`CodeRegion.rawValue`) as its project and its content say (analyzerkit ADR-0024); 0 is
    /// production code.
    public var region: UInt8

    public init(
        findings: [Finding] = [], acquirers: [String] = [], directives: [Directive] = [], degraded: String? = nil,
        region: UInt8 = 0
    ) {
        self.findings = findings
        self.acquirers = acquirers
        self.directives = directives
        self.degraded = degraded
        self.region = region
    }
}
