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
}
