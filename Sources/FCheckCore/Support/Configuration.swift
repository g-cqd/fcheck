internal import AemiJSON
public import ProjectModel
internal import SourceCorpus

#if canImport(FoundationEssentials)
    internal import FoundationEssentials
#else
    internal import Foundation
#endif

/// What `.fcheck.json` can say.
///
/// ```json
/// { "disable": ["cut-then-decode"],
///   "severity": { "leak-on-exit": "error" },
///   "resources": [ { "label": "socket", "acquire": ["socket"], "release": ["close"], "negativeIsInvalid": true } ],
///   "flush": ["SessionFileIO.flush"],
///   "exclude": ["/Generated/"] }
/// ```
public struct Configuration: Codable, Sendable, Equatable {
    /// A kind of handle: what acquires it and what releases it.
    public struct Resource: Codable, Sendable, Equatable {
        public var label: String
        /// Callee texts that acquire, matched whole (`open`, `FileDescriptor.open`).
        public var acquire: [String]
        /// Callee texts that release when called with the handle, and method names that release when called on it.
        public var release: [String]
        /// Whether a negative result is a failed acquisition, as for a C `open`.
        public var negativeIsInvalid: Bool

        public init(label: String, acquire: [String], release: [String], negativeIsInvalid: Bool = false) {
            self.label = label
            self.acquire = acquire
            self.release = release
            self.negativeIsInvalid = negativeIsInvalid
        }
    }

    public var disable: [RuleID]
    public var severity: [RuleID: Severity]
    public var resources: [Resource]
    public var flush: [String]
    public var exclude: [String]
    /// Whether test and generated code is analyzed. By default it is not.
    public var includeTests: Bool

    public init(
        disable: [RuleID] = [], severity: [RuleID: Severity] = [:], resources: [Resource] = [], flush: [String] = [],
        exclude: [String] = [], includeTests: Bool = false
    ) {
        self.disable = disable
        self.severity = severity
        self.resources = resources
        self.flush = flush
        self.exclude = exclude
        self.includeTests = includeTests
    }

    public static let `default` = Configuration()

    private enum CodingKeys: String, CodingKey { case disable, severity, resources, flush, exclude, includeTests }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        disable = try values.decodeIfPresent([RuleID].self, forKey: .disable) ?? []
        let named = try values.decodeIfPresent([String: Severity].self, forKey: .severity) ?? [:]
        var parsed: [RuleID: Severity] = [:]
        for (name, level) in named {
            guard let rule = RuleID(rawValue: name) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .severity, in: values, debugDescription: "no rule named \(name)")
            }
            parsed[rule] = level
        }
        severity = parsed
        resources = try values.decodeIfPresent([Resource].self, forKey: .resources) ?? []
        flush = try values.decodeIfPresent([String].self, forKey: .flush) ?? []
        exclude = try values.decodeIfPresent([String].self, forKey: .exclude) ?? []
        includeTests = try values.decodeIfPresent(Bool.self, forKey: .includeTests) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(disable, forKey: .disable)
        try values.encode(
            Dictionary(uniqueKeysWithValues: severity.map { ($0.key.rawValue, $0.value) }), forKey: .severity)
        try values.encode(resources, forKey: .resources)
        try values.encode(flush, forKey: .flush)
        try values.encode(exclude, forKey: .exclude)
        try values.encode(includeTests, forKey: .includeTests)
    }

    /// Why a configuration file was not used.
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case unreadable(path: String, reason: String)
        case invalid(path: String, reason: String)

        public var description: String {
            switch self {
            case .unreadable(let path, let reason): "cannot read configuration \(path): \(reason)"
            case .invalid(let path, let reason): "invalid configuration \(path): \(reason)"
            }
        }
    }

    /// The configuration in the file at `path`; the default when there is no file.
    /// - Throws: a ``Failure`` for a file that cannot be read or parsed, so a typo never silently turns a rule off.
    public static func load(from path: String) throws(Failure) -> Configuration {
        let data: Data
        do {
            data = try BoundedFileReader.readConfiguration(path: path)
        } catch .unreadable(let reason)
            where reason == "not a regular file" && !FileManager.default.fileExists(atPath: path)
        {
            return .default
        } catch {
            throw .unreadable(path: path, reason: "\(error)")
        }
        do {
            return try AemiJSON.JSONDecoder().decode(Configuration.self, from: [UInt8](data))
        } catch {
            throw .invalid(path: path, reason: "\(error)")
        }
    }

    /// What the cache's facts depend on: any change here invalidates every entry. Which rules are reported does not
    /// belong here: every rule always runs, so switching one on or off finds what the cache already holds.
    public var salt: String {
        var kept = self
        kept.disable = []
        var encoder = AemiJSON.JSONEncoder()
        encoder.options.keyOrder = .sorted
        let bytes = (try? encoder.encodeToBytes(kept)) ?? []
        return ContentFingerprint.of(bytes)
    }

    func severity(of rule: RuleID) -> Severity { severity[rule] ?? rule.defaultSeverity }
    public func isEnabled(_ rule: RuleID) -> Bool { !disable.contains(rule) }
}
