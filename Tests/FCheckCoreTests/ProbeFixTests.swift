import FCheckCore
import Foundation
import Testing

/// analyzerkit's `fcheck-probes.sh` F1–F5 as tests (roadmap 0025), with the verdicts the fixes give.
@Suite struct ProbeFixTests {
    private func leaks(_ source: String) -> [Finding] { analyze(source, rules: [.leakOnExit]) }
    private func durability(_ source: String) -> [Finding] { analyze(source, rules: [.replaceNotDurable]) }

    private func corpusLeaks(_ files: [String: String]) async throws -> [(function: String, line: Int)] {
        try await withCorpus(files) { root in
            let paths = files.keys.map { root + "/" + $0 }
            let report = try await Analyzer().analyze(paths: paths, cache: nil)
            return report.findings.filter { $0.rule == .leakOnExit }.map { ($0.function, $0.line) }
        }
    }

    /// F1: acquirers to a fixed point — `b()` returns what `a()` acquired, so a caller of `b()` acquires too.
    @Test func `a function returning an acquirer's result acquires, to any depth`() async throws {
        let found = try await corpusLeaks([
            "F1.swift":
                "import Darwin\nfunc a() -> Int32 { return open(\"x\", O_RDONLY) }\nfunc b() -> Int32 { return a() }\n"
                + "func direct() { let fd = a(); print(fd) }\nfunc twoLevels() { let fd = b(); print(fd) }\n"
        ])
        #expect(found.map(\.function).sorted() == ["direct()", "twoLevels()"], "\(found)")
    }

    /// F1b: an implicit return hands its handle on, so the function acquires.
    @Test func `an implicit return of an acquired handle makes the function an acquirer`() async throws {
        let found = try await corpusLeaks([
            "F1b.swift":
                "import Darwin\nfunc a() -> Int32 { open(\"x\", O_RDONLY) }\nfunc direct() { let fd = a(); print(fd) }\n"
        ])
        #expect(found.map(\.function) == ["direct()"], "\(found)")
    }

    /// F2: acquiring into a name that still holds a handle leaks the first one.
    @Test func `reassigning a held handle reports the first one`() throws {
        let found = leaks(
            "import Darwin\nfunc f() {\n    var fd = open(\"a\", O_RDONLY)\n    fd = open(\"b\", O_RDONLY)\n    close(fd)\n}\n"
        )
        let first = try #require(found.first)
        #expect(found.count == 1)
        #expect(first.line == 3 && first.message.contains("reassigned at line 4"), "\(first.message)")
    }

    /// F3: a non-owning prefix matches at a camel-case boundary, so `login` is not `log`.
    @Test func `prefixes match at a camel-case boundary`() {
        let found = leaks(
            "import Darwin\nfunc login(_ fd: Int32) {}\nfunc signin(_ fd: Int32) {}\n"
                + "func viaLogin() { let fd = open(\"a\", O_RDONLY); login(fd) }\n"
                + "func viaSignin() { let fd = open(\"a\", O_RDONLY); signin(fd) }\n"
                + "func viaLog() { let fd = open(\"a\", O_RDONLY); logState(fd) }\n")
        #expect(found.map(\.function) == ["viaLog()"], "\(found.map(\.function))")
    }

    /// F4: a corpus acquirer matches with its arity and, when the base's type is known, its type.
    @Test func `a method of another type with the acquirer's name acquires nothing`() async throws {
        let found = try await corpusLeaks([
            "F4.swift":
                "import Darwin\nstruct Store { func open() -> Int32 { return Darwin.open(\"x\", O_RDONLY) } }\n"
                + "struct Door { func open() -> Bool { return true } }\n"
                + "func enter(door: Door) { let ok = door.open(); print(ok) }\n"
                + "func load(store: Store) { let fd = store.open(); print(fd) }\n"
        ])
        #expect(found.map(\.function) == ["load(store:)"], "\(found)")
    }

    /// F5: after a rename only a flush of the directory counts: a call that merely contains `flush` does not, nor an
    /// `fsync` of the file's own descriptor.
    @Test func `only a directory flush settles a rename`() {
        let found = durability(
            "import Darwin\nfunc flushLogs() {}\nfunc save(_ fd: Int32) {\n    write(fd, \"x\", 1)\n    fsync(fd)\n"
                + "    rename(\"a.tmp\", \"a\")\n    flushLogs()\n}\nfunc saveFsyncFile(_ fd: Int32) {\n"
                + "    write(fd, \"x\", 1)\n    fsync(fd)\n    rename(\"a.tmp\", \"a\")\n    fsync(fd)\n}\n"
                + "func control(_ fd: Int32) {\n    write(fd, \"x\", 1)\n    fsync(fd)\n    rename(\"a.tmp\", \"a\")\n}\n"
        )
        #expect(found.map(\.function).sorted() == ["control(_:)", "save(_:)", "saveFsyncFile(_:)"])
    }

    @Test func `a descriptor opened on the directory, or a call naming the directory, flushes it`() {
        for flush in [
            "let dir = open(folder, O_RDONLY | O_DIRECTORY)\n    fsync(dir)\n    close(dir)",
            "let dir = open(url.deletingLastPathComponent().path, O_RDONLY)\n    fsync(dir)\n    close(dir)",
            "try flushDirectory(of: path)", "syncParentDirectory(path)", "_ = flush(directory)", "parentDir.sync()",
        ] {
            let found = durability(
                "import Darwin\nfunc save(_ fd: Int32) throws {\n    write(fd, \"x\", 1)\n    fsync(fd)\n"
                    + "    rename(\"a.tmp\", \"a\")\n    \(flush)\n}\n")
            #expect(found.isEmpty, "\(flush): \(found.map(\.message))")
        }
    }
}
