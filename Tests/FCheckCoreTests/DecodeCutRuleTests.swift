import FCheckCore
import Testing

@Suite struct DecodeCutRuleTests {
    private func cuts(_ source: String) -> [Finding] { analyze(source, rules: [.cutThenDecode]) }

    @Test func `decoding a prefix of the bytes is reported`() throws {
        let found = try #require(
            cuts("func f(_ b: [UInt8], _ n: Int) -> String {\n String(decoding: b.prefix(n), as: UTF8.self)\n}").first)
        #expect(found.line == 2 && found.message.contains("`prefix`"))
    }

    @Test func `a suffix, through a local, is reported with the line of the cut`() throws {
        let found = try #require(
            cuts(
                """
                func f(_ text: String, _ n: Int) -> String {
                    let utf8 = text.utf8
                    let tail = utf8.suffix(n)
                    return String(decoding: tail, as: UTF8.self)
                }
                """
            ).first)
        #expect(found.message.contains("`suffix` at line 3") && found.line == 4)
    }

    @Test func `a member filled from a prefix in another method is followed`() {
        #expect(
            cuts(
                """
                struct Buffer {
                    var head: [UInt8] = []
                    mutating func append(_ bytes: [UInt8], _ room: Int) {
                        let taken = bytes.prefix(room)
                        head += taken
                    }
                    var text: String { String(decoding: head, as: UTF8.self) }
                }
                """
            ).count == 1)
    }

    @Test func `stopping at a byte the caller chose is not a cut at a count`() {
        #expect(
            cuts(
                "func f(_ b: [CChar]) -> String {\n String(decoding: b.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)\n}"
            ).isEmpty)
        #expect(
            cuts("func f(_ b: [UInt8]) -> String {\n String(decoding: b.prefix(while: { $0 != 10 }), as: UTF8.self)\n}")
                .isEmpty)
    }

    @Test func `a value that went through another call may have been moved to a boundary`() {
        #expect(
            cuts(
                "func f(_ b: [UInt8], _ n: Int) -> String {\n String(decoding: wholeCharacters(b.prefix(n)), as: UTF8.self)\n}"
            ).isEmpty)
        #expect(
            cuts(
                """
                func f(_ text: String, _ n: Int) -> String {
                    let head = UTF8Cut.droppingPartialEnd(Array(text.utf8.prefix(n))[...])
                    return String(decoding: head, as: UTF8.self)
                }
                """
            ).isEmpty)
    }

    @Test func `a view conversion in between does not hide the cut`() {
        #expect(
            cuts("func f(_ b: [UInt8], _ n: Int) -> String {\n String(decoding: Array(b.prefix(n)), as: UTF8.self)\n}")
                .count == 1)
    }

    @Test func `a function that handles continuation bytes is left alone`() {
        #expect(
            cuts(
                """
                func f(_ b: [UInt8], _ n: Int) -> String {
                    var end = n
                    while end > 0, b[end] & 0xC0 == 0x80 { end -= 1 }
                    return String(decoding: b.prefix(end), as: UTF8.self)
                }
                """
            ).isEmpty)
    }

    @Test func `dropping a marker, slicing by a range, and decoding whole bytes are not cuts`() {
        #expect(cuts("func f(_ b: [UInt8]) -> String {\n String(decoding: b.dropFirst(3), as: UTF8.self)\n}").isEmpty)
        #expect(
            cuts(
                "func f(_ b: [UInt8], _ s: Int, _ e: Int) -> String {\n String(decoding: b[s ..< e], as: UTF8.self)\n}"
            ).isEmpty)
        #expect(cuts("func f(_ b: [UInt8]) -> String {\n String(decoding: b, as: UTF8.self)\n}").isEmpty)
    }

    @Test func `a loop of self-referencing assignments terminates`() {
        #expect(
            cuts(
                "func f(_ n: Int) -> String {\n var a = [UInt8]()\n var b = [UInt8]()\n a = b\n b = a\n return String(decoding: a, as: UTF8.self)\n}"
            ).isEmpty)
    }

    @Test func `dropFirst and dropLast with count and range subscripts are reported`() {
        let code = """
            func s1(_ bytes: [UInt8], _ n: Int) -> String { String(decoding: bytes.suffix(n), as: UTF8.self) }
            func s2(_ bytes: [UInt8], _ n: Int) -> String { String(decoding: bytes.dropFirst(n), as: UTF8.self) }
            func s3(_ bytes: [UInt8], _ n: Int) -> String { String(decoding: bytes[n...], as: UTF8.self) }
            func s4(_ bytes: [UInt8], _ n: Int) -> String { String(decoding: bytes[..<n], as: UTF8.self) }
            func s5(_ bytes: [UInt8], _ n: Int) -> String { String(decoding: bytes[...n], as: UTF8.self) }
            func s6(_ bytes: [UInt8], _ n: Int) -> String { String(decoding: bytes[0 ..< n], as: UTF8.self) }
            func s7(_ bytes: [UInt8], _ n: Int) -> String { String(decoding: bytes.prefix(upTo: n), as: UTF8.self) }
            func s8(_ bytes: [UInt8], _ n: Int) -> String { String(decoding: bytes.dropLast(n), as: UTF8.self) }
            func s9(_ bytes: [UInt8], _ n: Int) -> String { String(decoding: bytes.prefix(n), as: UTF8.self) }
            """
        let findings = cuts(code)
        #expect(findings.count == 9)
        let lines = findings.map(\.line).sorted()
        #expect(lines == [1, 2, 3, 4, 5, 6, 7, 8, 9])
    }
}
