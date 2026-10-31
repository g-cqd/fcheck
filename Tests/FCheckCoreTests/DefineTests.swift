import FCheckCore
import Testing

/// `--define` and the configuration's `defines` (analyzerkit roadmap 0059): with either, only the clauses active under
/// those conditions are read; without, every clause is, as before.
@Suite struct DefineTests {
    private let declarations = """
        import Darwin
        #if FEATURE
        func f() { let fd = open("a", O_RDONLY); print(fd) }
        #else
        func f() { let fd = open("a", O_RDONLY); close(fd) }
        #endif
        """

    private let statements = """
        import Darwin
        func f() {
            let fd = open("a", O_RDONLY)
            #if FEATURE
            print(fd)
            #else
            close(fd)
            #endif
        }
        """

    private func leaks(_ source: String, defines: [String]) -> [Finding] {
        analyze(source, rules: [.leakOnExit], configuration: Configuration(defines: defines))
    }

    @Test func `a leak inside #if FEATURE is reported without a define and with FEATURE, not with OTHER`() {
        #expect(leaks(declarations, defines: []).count == 1)
        #expect(leaks(declarations, defines: ["FEATURE"]).count == 1)
        #expect(leaks(declarations, defines: ["OTHER"]).isEmpty)
    }

    @Test func `a statement-level #if in a body follows the same rule`() {
        // Without a define both clauses are read in order: the close in #else releases the handle.
        #expect(leaks(statements, defines: ["FEATURE"]).count == 1)
        #expect(leaks(statements, defines: ["OTHER"]).isEmpty)
    }

    @Test func `the defines are part of the cache salt`() {
        #expect(Configuration(defines: ["A"]).salt != Configuration(defines: ["B"]).salt)
        #expect(Configuration(defines: ["A"]).salt != Configuration().salt)
    }
}
