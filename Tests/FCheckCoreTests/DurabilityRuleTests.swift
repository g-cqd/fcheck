import FCheckCore
import Testing

@Suite struct DurabilityRuleTests {
    private func durability(_ source: String, configuration: Configuration = .default) -> [Finding] {
        analyze(source, rules: [.replaceNotDurable], configuration: configuration)
    }

    @Test func `write, flush, rename, flush the directory is clean`() {
        #expect(
            durability(
                """
                func replace(_ bytes: [UInt8]) throws {
                    let d = open(tmp, O_WRONLY | O_CREAT, 0o600)
                    _ = write(d, bytes, bytes.count)
                    fsync(d)
                    close(d)
                    guard rename(tmp, path) == 0 else { throw E() }
                    try flushDirectory(of: path)
                }
                """
            ).isEmpty)
    }

    @Test func `a rename of bytes that were written and not flushed is reported at the write`() throws {
        let found = try #require(
            durability(
                """
                func save(_ data: Data) throws {
                    FileManager.default.createFile(atPath: tmp, contents: data)
                    guard rename(tmp, path) == 0 else { throw E() }
                    try flushDirectory(of: path)
                }
                """
            ).first)
        #expect(found.line == 3 && found.message.contains("bytes written at line 2"))
        #expect(found.witness.map(\.line) == [2, 3])
    }

    @Test func `a rename with no flush of the directory after it is reported where the function ends`() throws {
        let found = try #require(
            durability(
                """
                func replace(_ bytes: [UInt8]) throws {
                    let d = open(tmp, O_WRONLY, 0)
                    _ = write(d, bytes, bytes.count)
                    fsync(d)
                    close(d)
                    guard rename(tmp, path) == 0 else { throw E() }
                }
                """
            ).first)
        #expect(found.line == 6 && found.message.contains("directory is not flushed") && found.message.contains("ends"))
    }

    @Test func `a function that only renames is held to the directory flush and not to the data flush`() {
        let found = durability("func move() throws {\n guard rename(a, b) == 0 else { throw E() }\n}")
        #expect(found.count == 1 && found[0].message.contains("directory"))
    }

    @Test func `a rename that failed is not followed by an obligation on the failing branch`() {
        #expect(
            durability(
                """
                func move() throws {
                    if rename(a, b) != 0 {
                        throw E()
                    }
                    fsync(dir)
                }
                """
            ).isEmpty)
    }

    @Test func `a rename that failed and returns owes nothing, and one that worked and returns does`() {
        #expect(durability("func move() {\n if rename(a, b) != 0 { return }\n fsync(dir)\n}").isEmpty)
        #expect(durability("func move() {\n if rename(a, b) == 0 { return }\n fsync(dir)\n}").count == 1)
    }

    @Test func `the flush on only one path leaves the other reported`() {
        let found = durability(
            """
            func move(_ strong: Bool) {
                _ = rename(a, b)
                if strong { fsync(dir) }
            }
            """)
        #expect(found.count == 1)
    }

    @Test func `F_FULLFSYNC, a sync method, and anything named flush count as flushes`() {
        for flush in ["fcntl(d, F_FULLFSYNC)", "file.sync(durability)", "try SessionFileIO.flush(d)", "flushAll()"] {
            #expect(
                durability(
                    "func f() throws {\n let d = open(a, 0, 0)\n write(d, b, 1)\n \(flush)\n guard rename(a, b) == 0 else { throw E() }\n \(flush)\n}"
                ).isEmpty,
                "\(flush)")
        }
    }

    @Test func `a name from the configuration counts`() {
        let source = "func f() {\n write(d, b, 1)\n persist(d)\n _ = rename(a, b)\n persist(dir)\n}"
        #expect(durability(source).count == 2)
        #expect(durability(source, configuration: Configuration(flush: ["persist"])).isEmpty)
    }

    @Test func `a method called rename is not the system call`() {
        #expect(durability("func f() {\n registry.rename(record, to: name)\n}").isEmpty)
    }

    @Test func `a later flush after a throwing step does not hide the path that skipped it`() {
        let found = durability(
            """
            func f() throws {
                write(d, b, 1)
                fsync(d)
                _ = rename(a, b)
                try other()
                fsync(dir)
            }
            """)
        // `other()` throwing leaves by the throw exit, which is not a normal end: nothing to report there.
        #expect(found.isEmpty)
    }
}
