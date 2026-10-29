internal import AemiJSON
internal import ProjectModel
internal import ReportSupport
internal import SourceCorpus

#if canImport(FoundationEssentials)
    internal import FoundationEssentials
#else
    internal import Foundation
#endif

/// A set of accepted findings, so a rule can be adopted on code that already has them and fail only on new ones.
public struct Baseline: Codable, Sendable, Equatable {
    public var tool: String
    public var fingerprints: [String]

    init(tool: String, fingerprints: [String]) {
        self.tool = tool
        self.fingerprints = fingerprints
    }

    public init(findings: [Finding], root: String?) {
        tool = ToolInfo.name
        fingerprints = Set(findings.map { $0.fingerprint(root: root) }).sorted()
    }

    /// The baseline in the file at `path`.
    /// - Throws: a message saying why the file is not usable; a baseline that cannot be read fails the run rather
    ///   than silently accepting nothing.
    public static func load(from path: String) throws -> Baseline {
        let data: Data
        do { data = try BoundedFileReader.readConfiguration(path: path) } catch {
            throw BaselineFailure(message: "cannot read baseline \(path): \(error)")
        }
        let file: BaselineFile
        do { file = try AemiJSON.JSONDecoder().decode(BaselineFile.self, from: [UInt8](data)) } catch {
            throw BaselineFailure(message: "invalid baseline \(path): \(error)")
        }
        do {
            let valid = try file.validated(requiringVersion: false)
            return Baseline(tool: valid.tool, fingerprints: valid.fingerprints)
        } catch {
            throw BaselineFailure(message: "invalid baseline \(path): \(error)")
        }
    }

    public func write(to path: String) throws {
        var encoder = AemiJSON.JSONEncoder()
        encoder.options.keyOrder = .sorted
        encoder.prettyPrinted = true
        let file = BaselineFile(tool: tool, fingerprints: fingerprints, versioned: false)
        try Data(try encoder.encodeToBytes(file)).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// The findings this baseline does not hold, and how many it did.
    public func filter(_ findings: [Finding], root: String?) -> (kept: [Finding], baselined: Int) {
        let known = Set(fingerprints)
        let (kept, accepted) = findings.partitioned { known.contains($0.fingerprint(root: root)) }
        return (kept, accepted.count)
    }
}

public struct BaselineFailure: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}
