import Foundation
import Testing

@testable import FCheckCore

/// Compatibility characterization captured before replacing the implementation. Wire models remain tool-owned.
@Suite struct SuppressionCompatibilityTests {
    @Test func `directives retain their cache shape reasons duplicates and unknown rule behavior`() throws {
        let first = try #require(RuleID(rawValue: "leak-on-exit"))
        let second = try #require(RuleID(rawValue: "cut-then-decode"))
        for prefix in ["fc:", "fcheck:"] {
            let parsed = try #require(
                Directive.parse(
                    comment:
                        "/* @\(prefix)accept:this leak-on-exit, cut-then-decode leak-on-exit future -- reviewed */",
                    line: 7))
            #expect(parsed.kind == .acceptThis)
            #expect(parsed.line == 7)
            #expect(parsed.reason == "reviewed")
            #expect(parsed.rules == [first, second, first])
            let data = try JSONEncoder().encode(parsed)
            let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(Set(json.keys) == ["rules", "kind", "line", "reason"])
            #expect(json["kind"] as? String == "acceptThis")
            #expect(json["line"] as? Int == 7)
            #expect(json["reason"] as? String == "reviewed")
            #expect(try JSONDecoder().decode(Directive.self, from: data) == parsed)
            #expect(Directive.parse(comment: "// @\(prefix)accept future", line: 1) == nil)
            #expect(Directive.parse(comment: "// prose @\(prefix)accept", line: 1) == nil)
            #expect(Directive.parse(comment: "/// @\(prefix)accept", line: 1) == nil)
            #expect(Directive.parse(comment: "/** @\(prefix)accept */", line: 1) == nil)
            #expect(Directive.parse(comment: "// @\(prefix)accept --  ", line: 1)?.reason == "")
        }
    }

    @Test func `region switches are not nested and same line directives retain order`() throws {
        let first = try #require(RuleID(rawValue: "leak-on-exit"))
        let table = SuppressionTable(directives: [
            Directive(rules: [], kind: .disable, line: 1, reason: "outer"),
            Directive(rules: [], kind: .disable, line: 2, reason: "inner"),
            Directive(rules: [], kind: .enable, line: 3, reason: nil),
            Directive(rules: [], kind: .acceptThis, line: 4, reason: nil),
            Directive(rules: [], kind: .acceptThis, line: 4, reason: "second"),
        ])
        #expect(table.suppression(of: first, at: 2) == .some("inner"))
        #expect(table.suppression(of: first, at: 3) == nil)
        let withoutReason = table.suppression(of: first, at: 4)
        #expect(try #require(withoutReason) == nil)
    }
}
