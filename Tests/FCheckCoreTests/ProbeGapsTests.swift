import FCheckCore
import Foundation
import Testing

/// What a probe corpus of leaking and safe shapes found: the idioms of C handles and capture devices that the
/// first rules did not follow.
@Suite struct ProbeGapsTests {
    private func found(_ source: String, _ rule: RuleID) -> [Finding] { analyze(source, rules: [rule]) }

    // MARK: - leak-on-exit

    @Test(arguments: [
        "let f = fopen(path, \"r\")\nguard f != nil else { return false }\nfclose(f)\nreturn true",
        "let f = fopen(path, \"r\")\nif f == nil { return false }\nfclose(f)\nreturn true",
        "let d = opendir(path)\nguard d != nil else { return false }\nclosedir(d)\nreturn true",
    ])
    func `a handle compared with nil is held only where it is not nil`(body: String) {
        #expect(found("func f(_ path: String) -> Bool {\n\(body)\n}", .leakOnExit).isEmpty)
    }

    @Test func `a handle that is not nil and is left open on a later path is still reported`() throws {
        let source = """
            func f(_ path: String) -> Bool {
                let f = fopen(path, "r")
                guard f != nil else { return false }
                guard path.count > 3 else { return false }
                fclose(f)
                return true
            }
            """
        let leak = try #require(found(source, .leakOnExit).first)
        #expect(leak.message.contains("returns at line 4"))
    }

    @Test func `a descriptor assigned to a member without self is stored, not leaked`() {
        let source = """
            final class Holder {
                var fd: Int32 = -1
                func open(_ path: String) { fd = Glibc.open(path, O_RDONLY) }
            }
            """
        #expect(found(source, .leakOnExit).isEmpty)
    }

    @Test func `a descriptor assigned to a local declared earlier and left open is reported`() {
        let source = """
            func f(_ path: String) throws {
                var fd: Int32 = -1
                fd = open(path, O_RDONLY)
                try mayThrow()
                close(fd)
            }
            """
        #expect(found(source, .leakOnExit).count == 1)
    }

    @Test func `a device locked through an optional receiver and left locked on a return is reported`() throws {
        let source = """
            func torch() throws {
                try device?.lockForConfiguration()
                if session.isRunning { return }
                device?.unlockForConfiguration()
            }
            """
        let leak = try #require(found(source, .leakOnExit).first)
        #expect(leak.message.contains("`device`") && leak.message.contains("returns at line 3"))
    }

    @Test func `a device locked through an optional receiver and released on every path is fine`() {
        let source = """
            func torch() throws {
                try device?.lockForConfiguration()
                defer { device?.unlockForConfiguration() }
                try mayThrow()
            }
            """
        #expect(found(source, .leakOnExit).isEmpty)
    }

    // MARK: - replace-not-durable

    @Test func `replaceItemAt over unflushed bytes is a rename that is not durable`() throws {
        let source = """
            func save(_ data: Data, _ tmp: URL, _ dst: URL) throws {
                try data.write(to: tmp)
                _ = try FileManager.default.replaceItemAt(dst, withItemAt: tmp)
            }
            """
        let leak = try #require(found(source, .replaceNotDurable).first)
        #expect(leak.line == 3)
    }

    @Test func `replaceItemAt after a flush and followed by a directory flush is durable`() {
        let source = """
            func save(_ data: Data, _ fd: Int32, _ tmp: URL, _ dst: URL, _ dir: Int32) throws {
                fsync(fd)
                _ = try FileManager.default.replaceItemAt(dst, withItemAt: tmp)
                fsync(dir)
            }
            """
        #expect(found(source, .replaceNotDurable).isEmpty)
    }

    @Test func `a method of the program's own that is called replaceItem is not a rename`() {
        let source = """
            func update(_ session: Session) {
                replaceItem(withId: session.id, with: session)
            }
            """
        #expect(found(source, .replaceNotDurable).isEmpty)
    }

    @Test func `the older replaceItem(at:withItemAt:) over unflushed bytes is a rename that is not durable`() {
        let source = """
            func save(_ data: Data, _ tmp: URL, _ dst: URL) throws {
                try data.write(to: tmp)
                try FileManager.default.replaceItem(at: dst, withItemAt: tmp, backupItemName: nil, options: [], resultingItemURL: nil)
            }
            """
        #expect(found(source, .replaceNotDurable).count >= 1)
    }

    // MARK: - cut-then-decode

    @Test func `a utf16 view cut at a count and turned back into a string is reported`() throws {
        let source = "func f(_ s: String) -> String? { String(s.utf16.prefix(20)) }"
        #expect(found(source, .cutThenDecode).count == 1)
    }

    @Test(arguments: [
        "var end = min(100, data.count)\nwhile end > 0, data[end] & 0b1100_0000 == 0b1000_0000 { end -= 1 }\nreturn String(decoding: data.prefix(end), as: UTF8.self)",
        "var end = min(100, data.count)\nwhile end > 0, (data[end] & 0xC0) == 0x80 { end -= 1 }\nreturn String(decoding: data.prefix(end), as: UTF8.self)",
        "var end = min(100, data.count)\nwhile end > 0 && data[end] & 0xC0 == 0x80 { end -= 1 }\nreturn String(decoding: data.prefix(end), as: UTF8.self)",
    ])
    func `a cut moved back to a character boundary first is the fix, not the bug`(body: String) {
        #expect(found("func f(_ data: Data) -> String {\n\(body)\n}", .cutThenDecode).isEmpty)
    }

    // MARK: - cut-then-decode: bounds that are not counts

    @Test(arguments: [
        "guard let tab = record.firstIndex(of: 9) else { return nil }\nreturn String(decoding: record[record.index(after: tab)...], as: UTF8.self)",
        "guard let colon = record.firstIndex(of: UInt8(ascii: \":\")) else { return nil }\nreturn String(decoding: record[..<colon], as: UTF8.self)",
        "let newline = record.lastIndex(of: 10) ?? record.endIndex\nreturn String(decoding: record[..<newline], as: UTF8.self)",
        "if let space = record.firstIndex(where: { $0 == 32 }) { return String(decoding: record[space...], as: UTF8.self) }\nreturn nil",
    ])
    func `a slice that starts or ends where a scan found an ASCII delimiter is cut at a boundary`(body: String) {
        #expect(found("func f(_ record: Data) -> String? {\n\(body)\n}", .cutThenDecode).isEmpty)
    }

    @Test func `a slice cut at a count beside a scan for a delimiter is still reported`() {
        let source = """
            func f(_ record: Data) -> String? {
                guard let tab = record.firstIndex(of: 9) else { return nil }
                _ = tab
                return String(decoding: record[..<limit], as: UTF8.self)
            }
            """
        #expect(found(source, .cutThenDecode).count == 1)
    }

    @Test(arguments: [
        "let body = data.starts(with: byteOrderMark) ? data.dropFirst(byteOrderMark.count) : data\nreturn String(decoding: body, as: UTF8.self)",
        "var body = data\nif body.starts(with: Self.bom) { body = body.dropFirst(Self.bom.count) }\nreturn String(decoding: body, as: UTF8.self)",
        "if text.hasPrefix(marker) { return String(decoding: data.dropFirst(marker.count), as: UTF8.self) }\nreturn \"\"",
    ])
    func `dropping a marker that was just matched removes whole characters`(body: String) {
        #expect(found("func f(_ data: Data) -> String {\n\(body)\n}", .cutThenDecode).isEmpty)
    }

    @Test func `dropping a count that nothing matched is still reported`() {
        let source = "func f(_ data: Data, _ n: Int) -> String { String(decoding: data.dropFirst(n), as: UTF8.self) }"
        #expect(found(source, .cutThenDecode).count == 1)
    }

    @Test(arguments: [
        "let count = read(fd, &buffer, buffer.count)\nguard count > 0 else { return \"\" }\nreturn String(decoding: buffer.prefix(count), as: UTF8.self)",
        "let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))\nreturn String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)",
        "let received = recv(fd, &buffer, buffer.count, 0)\nreturn String(decoding: buffer[..<received], as: UTF8.self)",
        "let n = try await read(fd, into: &buffer)\nreturn String(decoding: buffer.prefix(n), as: UTF8.self)",
    ])
    func `the length a call returned for the bytes it wrote is where they end, not a cut`(body: String) {
        #expect(
            found("func f(_ fd: Int32, _ pid: Int32, _ buffer: inout [UInt8]) -> String {\n\(body)\n}", .cutThenDecode)
                .isEmpty
        )
    }

    @Test func `a limit the program computed is still a cut`() {
        let source = """
            func f(_ buffer: [UInt8]) -> String {
                let limit = computeLimit()
                return String(decoding: buffer.prefix(limit), as: UTF8.self)
            }
            """
        #expect(found(source, .cutThenDecode).count == 1)
    }

    // MARK: - leak-on-exit: a wrapper that releases itself

    @Test func `a lock object returned by a function of the corpus and let go by its own method is not leaked`() {
        // ask's CredentialFile.settleSecrets(): takeLock() returns the descriptor's wrapper, which release() closes.
        let source = """
            func settle() throws {
                let lock = try takeLock()
                defer { lock.release() }
                try mayThrow()
            }
            """
        #expect(analyze(source, rules: [.leakOnExit], acquirers: ["takeLock"]).isEmpty)
    }

    @Test func `a handle returned by a function of the corpus and never let go is still reported`() {
        let source = """
            func settle() throws {
                let fd = try takeDescriptor()
                try mayThrow()
            }
            """
        #expect(analyze(source, rules: [.leakOnExit], acquirers: ["takeDescriptor"]).count == 1)
    }
}
