import FCheckCore
import Testing

@Suite struct SuppressionTests {
    private let leaking = "func f() throws {\n let d = open(p, 0)\n try work()\n}"

    private func report(_ source: String) async throws -> AnalysisReport {
        try await withCorpus(["T.swift": source]) { root in
            try await Analyzer().analyze(paths: [root + "/T.swift"], cacheURL: nil)
        }
    }

    @Test func `an accept above the line suppresses it and keeps the reason`() async throws {
        let source =
            "func f() throws {\n // @fc:accept leak-on-exit -- closed by the caller\n let d = open(p, 0)\n try work()\n}"
        let result = try await report(source)
        #expect(result.findings.isEmpty && result.suppressed.count == 1)
        #expect(result.suppressed.first?.reason == "closed by the caller")
    }

    @Test func `accept this and accept next cover one line each`() async throws {
        let this = "func f() throws {\n let d = open(p, 0) // @fc:accept:this\n try work()\n}"
        #expect(try await report(this).findings.isEmpty)
        let next = "func f() throws {\n // @fc:accept:next\n let d = open(p, 0)\n try work()\n}"
        #expect(try await report(next).findings.isEmpty)
        let far = "func f() throws {\n // @fc:accept:next\n let x = 1\n let d = open(p, 0)\n try work()\n}"
        #expect(try await report(far).findings.count == 1)
    }

    @Test func `a disable runs to its enable, or to the end of the file`() async throws {
        let region =
            "// @fc:disable\nfunc f() throws {\n let d = open(p, 0)\n try work()\n}\n// @fc:enable\nfunc g() throws {\n let e = open(p, 0)\n try work()\n}"
        let result = try await report(region)
        #expect(result.findings.map(\.function) == ["g()"] && result.suppressed.count == 1)
    }

    @Test func `a directive for other rules, or for none this version knows, suppresses nothing`() async throws {
        #expect(try await report("// @fc:accept cut-then-decode\n" + leaking).findings.count == 1)
        #expect(try await report("// @fc:accept future-rule\n" + leaking).findings.count == 1)
    }

    @Test func `a directive in a block comment, with the long namespace, works`() async throws {
        let source = "func f() throws {\n /* @fcheck:accept leak-on-exit */\n let d = open(p, 0)\n try work()\n}"
        #expect(try await report(source).findings.isEmpty)
    }

    @Test func `a comment that is not a directive is ignored`() async throws {
        #expect(try await report("// fc:accept\n// @fc:acept\n// @other:accept\n" + leaking).findings.count == 1)
    }
}
