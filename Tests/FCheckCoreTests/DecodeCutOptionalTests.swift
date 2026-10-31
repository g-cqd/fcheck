import FCheckCore
import Testing

/// Cuts decoded to an optional (analyzerkit roadmap 0066): the split character makes the whole result nil.
@Suite struct DecodeCutOptionalTests {
    private func cuts(_ source: String) -> [Finding] { analyze(source, rules: [.cutThenDecode]) }

    @Test(arguments: [
        "String(data: data.prefix(n), encoding: .utf8)", "String(bytes: data.prefix(n), encoding: .utf8)",
    ])
    func `bytes cut and decoded to an optional are reported, saying the whole text is lost`(decode: String) throws {
        let found = try #require(cuts("func f(_ data: Data, _ n: Int) -> String? {\n \(decode)\n}").first)
        #expect(found.rule == .cutThenDecode && found.line == 2)
        #expect(found.message.contains("`prefix`") && found.message.contains("nil"))
    }

    @Test func `a cut through a local is followed as for String(decoding:)`() throws {
        let found = try #require(
            cuts(
                """
                func preview(_ body: Data) -> String {
                    let head = body.prefix(1024)
                    return String(data: head, encoding: .utf8) ?? ""
                }
                """
            ).first)
        #expect(found.message.contains("`prefix` at line 2") && found.line == 3)
    }

    @Test func `UTF-16 code units cut and turned back into a string are reported`() throws {
        let found = try #require(
            cuts("func f(_ s: String, _ n: Int) -> String? {\n String(s.utf16.prefix(n))\n}").first)
        #expect(found.message.contains("UTF-16") && found.message.contains("nil"))
    }

    @Test func `another encoding, a whole value, or characters cut are not`() {
        #expect(
            cuts("func f(_ d: Data, _ n: Int) -> String? {\n String(data: d.prefix(n), encoding: .ascii)\n}").isEmpty)
        #expect(cuts("func f(_ d: Data) -> String? {\n String(data: d, encoding: .utf8)\n}").isEmpty)
        #expect(cuts("func f(_ s: String, _ n: Int) -> String {\n String(s.prefix(n))\n}").isEmpty)
    }
}
