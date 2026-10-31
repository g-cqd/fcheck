internal import AemiJSON
public import AnalyzerConfiguration
public import ProjectModel
public import SourceCorpus

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
        /// What the acquiring call makes held (analyzerkit roadmap 0063).
        public var holds: Holds

        /// What an acquiring call makes held.
        public enum Holds: String, Codable, Sendable, Equatable {
            /// The value it returns, released by a release call or method on it, or handed on.
            case result
            /// Its receiver, a simple name: `session.beginConfiguration()` … `session.commitConfiguration()`.
            /// `acquire` and `release` are method names; passing the receiver to a call does not hand it on.
            case receiver
            /// Its first argument, a simple name: `CVPixelBufferLockBaseAddress(b, f)` …
            /// `CVPixelBufferUnlockBaseAddress(b, f)`; passing it to a call does not hand it on.
            case firstArgument
        }

        public init(
            label: String, acquire: [String], release: [String], negativeIsInvalid: Bool = false,
            holds: Holds = .result
        ) {
            self.label = label
            self.acquire = acquire
            self.release = release
            self.negativeIsInvalid = negativeIsInvalid
            self.holds = holds
        }

        private enum CodingKeys: String, CodingKey {
            case label, acquire, release, negativeIsInvalid, holds
        }

        /// `negativeIsInvalid` may be left out, and is then false, as the initializer has it.
        public init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            label = try values.decode(String.self, forKey: .label)
            acquire = try values.decode([String].self, forKey: .acquire)
            release = try values.decode([String].self, forKey: .release)
            negativeIsInvalid = try values.decodeIfPresent(Bool.self, forKey: .negativeIsInvalid) ?? false
            holds = try values.decodeIfPresent(Holds.self, forKey: .holds) ?? .result
        }
    }

    public var disable: [RuleID]
    public var severity: [RuleID: Severity]
    public var resources: [Resource]
    public var flush: [String]
    /// Paths to leave out (ADR-0008, shared by every tool): an entry without `*`, `?` or `[` is a substring of the
    /// path; one with them is a glob relative to ``root``, `/` anchoring it there (`SourceCorpus.PathFilter`).
    public var exclude: [String]
    /// The directory `exclude` globs are relative to: the configuration file's, set by ``load(from:)``. Not part of
    /// the file.
    public var root: String?
    /// Which regions besides production code are analyzed (`includeRegions`, `excludeRegions`; analyzerkit ADR-0019).
    /// By default none: test, generated, script and the other regions are left out.
    public var regions: RegionSelection
    /// The conditions a run compiles under (the shared `defines` and `platforms`, and `--define`). With a define, only
    /// the active `#if` clauses are read (analyzerkit ADR-0029); without, every clause is.
    public var defines: [String]
    public var platforms: [String]

    /// ``defines`` and ``platforms`` as analyzerkit reads them.
    public var conditions: CompilationConditions {
        CompilationConditions(defines: Set(defines), platforms: Set(platforms))
    }

    /// Whether test and generated code is analyzed: the old switch, now `includeRegions: "test,generated"`.
    public var includeTests: Bool {
        get {
            regions.include.isSuperset(of: Self.testAndGenerated) && !regions.exclude.intersects(Self.testAndGenerated)
        }
        set {
            regions = RegionSelection(
                include: newValue
                    ? regions.include.union(Self.testAndGenerated) : regions.include.subtracting(Self.testAndGenerated),
                exclude: regions.exclude)
        }
    }

    private static let testAndGenerated: CodeRegion = [.test, .generated]

    /// Whether a file of `region` is analyzed: production code always, other regions when selected.
    public func analyzes(_ region: CodeRegion) -> Bool { region.isEmpty || regions.isIncluded(region) }

    public init(
        disable: [RuleID] = [], severity: [RuleID: Severity] = [:], resources: [Resource] = [], flush: [String] = [],
        exclude: [String] = [], includeTests: Bool = false, defines: [String] = [], platforms: [String] = []
    ) {
        self.disable = disable
        self.severity = severity
        self.resources = resources
        self.flush = flush
        self.exclude = exclude
        self.regions = includeTests ? RegionSelection(include: Self.testAndGenerated, exclude: []) : .none
        self.defines = defines
        self.platforms = platforms
    }

    public static let `default` = Configuration()

    private enum CodingKeys: String, CodingKey {
        case disable, severity, resources, flush, exclude, includeTests, defines, platforms
    }

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
        defines = try values.decodeIfPresent([String].self, forKey: .defines) ?? []
        platforms = try values.decodeIfPresent([String].self, forKey: .platforms) ?? []
        // ADR-0020 item 6: the shared region lists reach fcheck's one switch for test and generated code.
        let regions = try decoder.container(keyedBy: RegionKeys.self)
        let included = try regions.decodeIfPresent(String.self, forKey: .includeRegions)
        let excluded = try regions.decodeIfPresent(String.self, forKey: .excludeRegions)
        do {
            self.regions = try RegionSelection(include: included, exclude: excluded)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .includeRegions, in: regions, debugDescription: error.description)
        }
        if try values.decodeIfPresent(Bool.self, forKey: .includeTests) == true { includeTests = true }
    }

    /// The shared region keys (ADR-0020 item 6).
    private enum RegionKeys: String, CodingKey { case includeRegions, excludeRegions }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(disable, forKey: .disable)
        try values.encode(
            Dictionary(uniqueKeysWithValues: severity.map { ($0.key.rawValue, $0.value) }), forKey: .severity)
        try values.encode(resources, forKey: .resources)
        try values.encode(flush, forKey: .flush)
        try values.encode(exclude, forKey: .exclude)
        // What a file's facts are depends on the conditions, so they are in ``salt``; absent when unset, so the salt of
        // a configuration without them is what it was.
        if !defines.isEmpty { try values.encode(defines.sorted(), forKey: .defines) }
        if !platforms.isEmpty { try values.encode(platforms.sorted(), forKey: .platforms) }
        // The regions are not encoded: they choose which files are reported, not what a file's facts are, so they stay
        // out of ``salt`` and the cache serves any selection.
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

    /// `exclude` as one filter; build it once for many paths.
    public var pathFilter: PathFilter { PathFilter(exclude, root: root) }

    /// Whether `exclude` leaves `path` out; a trailing `/` asks about a directory.
    public func isExcluded(path: String) -> Bool {
        pathFilter.excludes(path)
    }

    /// The configuration in the file at `path`; the default when there is no file.
    /// - Throws: a ``Failure`` for a file that cannot be read or parsed, so a typo never silently turns a rule off.
    /// What the shared configuration reader checks fcheck's keys against (ADR-0020); the shared keys are its own.
    public static let sharedReading = SharedConfiguration.Tool(
        name: ToolInfo.name, fileName: ".fcheck.json",
        keys: ["disable", "severity", "resources", "flush", "includeTests"])

    /// The configuration of a run (ADR-0020): `explicit` (`--config`) or the configuration directory's
    /// `.swift-analyzers.json` and `.fcheck.json`, merged, every key checked; the default when there is none.
    /// - Throws: a ``Failure``, so a typo never silently turns a rule off.
    public static func resolve(
        explicit: String?, currentDirectory: String, analyzedPaths: [String]
    ) throws(Failure) -> (configuration: Configuration, sources: SharedConfiguration.Resolved) {
        let resolved: SharedConfiguration.Resolved
        do {
            resolved = try SharedConfiguration.resolve(
                for: sharedReading, explicit: explicit, currentDirectory: currentDirectory, analyzedPaths: analyzedPaths
            )
        } catch .unreadable(let path, let reason) {
            throw .unreadable(path: path, reason: reason)
        } catch {
            throw .invalid(path: error.path, reason: error.reason)
        }
        guard let directory = resolved.directory, let last = resolved.sources.last else { return (.default, resolved) }
        do {
            var configuration = try AemiJSON.JSONDecoder().decode(Configuration.self, from: resolved.json)
            configuration.root = directory
            return (configuration, resolved)
        } catch {
            throw .invalid(path: last.path, reason: "\(error)")
        }
    }

    /// The configuration in the file at `path`; the default when there is no file.
    /// - Throws: a ``Failure`` for a file that cannot be read or parsed, so a typo never silently turns a rule off.
    public static func load(from path: String) throws(Failure) -> Configuration {
        guard FileManager.default.fileExists(atPath: path) else { return .default }
        return try resolve(
            explicit: path, currentDirectory: FileManager.default.currentDirectoryPath, analyzedPaths: []
        ).configuration
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
