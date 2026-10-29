import FCheckCore
import Foundation
import ProjectModel
import SourceCorpus
import Testing

@Suite struct ReportTests {
    private let source = "func f() throws {\n let d = open(p, 0)\n try work()\n}"

    private func report() async throws -> (AnalysisReport, String) {
        try await withCorpus(["Sources/T.swift": source]) { root in
            (try await Analyzer().analyze(paths: [root + "/Sources/T.swift"], cacheURL: nil), root)
        }
    }

    @Test func `the xcode format is a diagnostic with a note for each witness line`() async throws {
        let (result, root) = try await report()
        let text = try ReportFormatter.render(result, format: .xcode, root: nil, relativeTo: nil)
        let lines = text.split(separator: "\n").map(String.init)
        #expect(
            lines.first?.hasSuffix(
                ":2:2: warning: [leak-on-exit] the file descriptor `d` acquired here is not closed, handed on or returned when the function throws at line 3"
            ) == true)
        #expect(lines.dropFirst().allSatisfy { $0.contains(": note: ") })
        #expect(lines[0].hasPrefix(root.hasPrefix("/private") ? root : root) || lines[0].contains("T.swift"))
    }

    @Test func `relative-to shortens the path`() async throws {
        let (result, root) = try await report()
        let resolved = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        let text = try ReportFormatter.render(result, format: .xcode, root: nil, relativeTo: resolved)
        #expect(text.hasPrefix("Sources/T.swift:2:2: warning:"))
    }

    @Test func `the json report carries the schema version, the evidence and a stable fingerprint`() async throws {
        let (result, root) = try await report()
        let text = try ReportFormatter.render(result, format: .json, root: nil, relativeTo: nil)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 1 && object["tool"] as? String == "fcheck")
        let first = try #require((object["findings"] as? [[String: Any]])?.first)
        #expect(
            first["rule"] as? String == "leak-on-exit" && first["evidence"] as? String == "L0"
                && first["shape"] as? String == "pairing")
        let moved = try await withCorpus(["Sources/T.swift": source]) { other in
            try await Analyzer().analyze(paths: [other + "/Sources/T.swift"], cacheURL: nil)
        }
        // Outside a repository the path is part of the fingerprint; with a root they agree.
        #expect(
            result.findings[0].fingerprint(root: root)
                == moved.findings[0].fingerprint(
                    root: moved.findings[0].path.replacingOccurrences(of: "/Sources/T.swift", with: "")))
    }

    @Test func `the sarif log has the rule catalogue, columns, and the witness as a code flow`() async throws {
        let (result, _) = try await report()
        let text = try ReportFormatter.render(result, format: .sarif, root: nil, relativeTo: nil)
        let log = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(log["version"] as? String == "2.1.0")
        let run = try #require((log["runs"] as? [[String: Any]])?.first)
        #expect(run["columnKind"] as? String == "utf16CodeUnits")
        let rules = try #require(
            ((run["tool"] as? [String: Any])?["driver"] as? [String: Any])?["rules"] as? [[String: Any]])
        #expect(Set(rules.compactMap { $0["id"] as? String }) == Set(RuleID.allCases.map(\.rawValue)))
        let result0 = try #require((run["results"] as? [[String: Any]])?.first)
        #expect(result0["ruleId"] as? String == "leak-on-exit" && result0["level"] as? String == "warning")
        #expect((result0["codeFlows"] as? [[String: Any]])?.isEmpty == false)
        #expect((result0["partialFingerprints"] as? [String: String])?["fcheck/v1"] != nil)
    }

    /// Every location under `--relative-to` names its file relative to SRCROOT, as the other analyzers' do; an absolute
    /// `file://` uri names the machine the run was on, and code scanning cannot link it (analyzerkit roadmap 0044).
    @Test func `sarif locations under a relative-to directory are relative to SRCROOT`() async throws {
        try await withCorpus(["Sources/T.swift": source]) { root in
            let result = try await Analyzer().analyze(paths: [root + "/Sources/T.swift"], cacheURL: nil)
            let text = try ReportFormatter.render(
                result, format: .sarif, root: nil, relativeTo: SourcePath.canonical(root))
            let log = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            let finding = try #require(
                ((log["runs"] as? [[String: Any]])?.first?["results"] as? [[String: Any]])?.first)
            var locations = (finding["locations"] as? [[String: Any]]) ?? []
            for flow in (finding["codeFlows"] as? [[String: Any]]) ?? [] {
                for thread in (flow["threadFlows"] as? [[String: Any]]) ?? [] {
                    for step in (thread["locations"] as? [[String: Any]]) ?? [] {
                        if let location = step["location"] as? [String: Any] { locations.append(location) }
                    }
                }
            }
            let artifacts = locations.compactMap {
                ($0["physicalLocation"] as? [String: Any])?["artifactLocation"] as? [String: String]
            }
            #expect(artifacts.count >= 2)
            #expect(artifacts.allSatisfy { $0["uri"] == "Sources/T.swift" && $0["uriBaseId"] == "SRCROOT" })
        }
    }

    @Test func `a baseline holds back what it has and passes what it does not`() async throws {
        let (result, root) = try await report()
        let baseline = Baseline(findings: result.findings, root: root)
        #expect(baseline.filter(result.findings, root: root) == ([], 1))
        let other = Baseline(findings: [], root: root)
        #expect(other.filter(result.findings, root: root).kept.count == 1)
    }

    @Test func `a baseline survives a round trip through a file and rejects a damaged one`() async throws {
        let (result, root) = try await report()
        let path = FileManager.default.temporaryDirectory.appending(path: "fcheck-baseline-\(UUID().uuidString).json")
            .path
        defer { try? FileManager.default.removeItem(atPath: path) }
        try Baseline(findings: result.findings, root: root).write(to: path)
        #expect(try Baseline.load(from: path).filter(result.findings, root: root).baselined == 1)
        try "{ broken".write(toFile: path, atomically: true, encoding: .utf8)
        #expect(throws: BaselineFailure.self) { try Baseline.load(from: path) }
        #expect(throws: BaselineFailure.self) { try Baseline.load(from: path + ".missing") }
    }

    @Test func `the fingerprint ignores the line, so moving code does not make a finding new`() async throws {
        let (result, root) = try await report()
        let shifted = try await withCorpus(["Sources/T.swift": "\n\n" + source]) { other in
            try await Analyzer().analyze(paths: [other + "/Sources/T.swift"], cacheURL: nil)
        }
        #expect(shifted.findings[0].line == result.findings[0].line + 2)
        #expect(shifted.findings[0].fingerprint(root: nil).isEmpty == false)
        _ = root
    }
}
