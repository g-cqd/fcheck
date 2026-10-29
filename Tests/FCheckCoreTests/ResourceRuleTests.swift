import FCheckCore
import Foundation
import Testing

@Suite struct ResourceRuleTests {
    private func leaks(_ source: String, configuration: Configuration = .default) -> [Finding] {
        analyze(source, rules: [.leakOnExit], configuration: configuration)
    }

    @Test func `a descriptor still open when a later try throws is reported with the line it throws at`() throws {
        let found = try #require(
            leaks(
                """
                func f(_ p: String) throws {
                    let d = open(p, O_RDONLY)
                    guard d >= 0 else { throw E() }
                    try work()
                    close(d)
                }
                """
            ).first)
        #expect(found.rule == .leakOnExit && found.line == 2 && found.function == "f(_:)")
        #expect(found.message.contains("`d`") && found.message.contains("throws at line 4"))
        #expect(found.witness.map(\.line) == [2, 3, 4])
    }

    @Test func `a catch that binds the error catches every error, so nothing leaks on a throw it stops`() {
        let found = leaks(
            """
            func f(_ p: String) throws {
                let d = open(p, O_RDONLY)
                do { try work() } catch let error { print(error) }
                close(d)
            }
            """)
        #expect(found.isEmpty, "\(found.map(\.message))")
    }

    @Test func `a for try await loop throws from its head, so a descriptor open across it leaks`() throws {
        let found = try #require(
            leaks(
                """
                func f(_ p: String, _ s: AsyncThrowingStream<Int, any Error>) async throws {
                    let d = open(p, O_RDONLY)
                    for try await x in s { print(x) }
                    close(d)
                }
                """
            ).first)
        #expect(found.line == 2 && found.message.contains("throws at line 3"))
    }

    @Test func `a defer that closes it covers every path`() {
        #expect(
            leaks(
                """
                func f(_ p: String) throws {
                    let d = open(p, O_RDONLY)
                    guard d >= 0 else { throw E() }
                    defer { close(d) }
                    try work()
                }
                """
            ).isEmpty)
    }

    @Test func `a descriptor that failed to open is not held on the branch that checked it`() {
        #expect(
            leaks(
                """
                func f(_ p: String) -> Int32? {
                    let d = open(p, O_RDONLY)
                    if d < 0 { return nil }
                    defer { close(d) }
                    return 1
                }
                """
            ).isEmpty)
        #expect(
            leaks(
                """
                func f(_ p: String) -> Int32? {
                    let d = open(p, O_RDONLY)
                    if d == -1 { return nil }
                    return d
                }
                """
            ).isEmpty)
    }

    @Test func `a close on only one branch leaves the other leaking`() throws {
        let found = try #require(
            leaks(
                """
                func f(_ p: String, _ c: Bool) {
                    let d = open(p, O_RDONLY)
                    if c {
                        close(d)
                    }
                    other()
                }
                """
            ).first)
        #expect(found.message.contains("reaches its end"))
    }

    @Test func `closing in a catch that rethrows covers the throw`() {
        #expect(
            leaks(
                """
                func f(_ p: String) throws {
                    let d = open(p, O_RDONLY)
                    do { try work() } catch {
                        close(d)
                        throw error
                    }
                    close(d)
                }
                """
            ).isEmpty)
    }

    @Test func `closing with the method form, with try question mark, counts`() {
        #expect(
            leaks(
                """
                func f(_ p: FilePath) throws {
                    let d = try FileDescriptor.open(p, .readOnly)
                    do { try work() } catch {
                        _ = try? d.close()
                        throw error
                    }
                    try d.close()
                }
                """
            ).isEmpty)
    }

    @Test func `handing it to a call, storing it, or returning it ends the obligation`() {
        for use in ["return Box(d)", "self.fd = d", "register(d)", "return d", "return (d, 1)", "list.append(d)"] {
            #expect(
                leaks("func f(_ p: String) throws -> Any {\n let d = open(p, O_RDONLY)\n \(use)\n}").isEmpty, "\(use)")
        }
    }

    @Test func `a plain system call on it is a use, not a hand-on`() {
        #expect(
            leaks(
                """
                func f(_ p: String) {
                    let d = open(p, O_RDONLY)
                    var b = [UInt8](repeating: 0, count: 8)
                    _ = read(d, &b, 8)
                    flushAll(d)
                }
                """
            ).count == 1)
    }

    @Test func `a bare call to a method the file declares is not the system call`() {
        #expect(
            leaks(
                """
                struct S {
                    func open(_ state: inout Int) -> [Int] { [] }
                    func f() {
                        var state = 0
                        let opened = open(&state)
                        use(opened)
                    }
                }
                """
            ).isEmpty)
    }

    @Test func `a call with too few arguments is not open(2)`() {
        #expect(leaks("func f() {\n let x = open(&state)\n print(x)\n}").isEmpty)
    }

    @Test func `a binding that succeeds acquires and one that fails does not`() throws {
        let found = try #require(
            leaks(
                """
                func f(_ p: String) {
                    guard let d = try? FileDescriptor.open(p, .readOnly) else { return }
                    other()
                }
                """
            ).first)
        #expect(found.line == 2)
        #expect(
            leaks(
                """
                func f(_ p: String) {
                    guard let d = try? FileDescriptor.open(p, .readOnly) else { return }
                    defer { _ = try? d.close() }
                    other()
                }
                """
            ).isEmpty)
    }

    @Test func `an acquisition inside a closure the statement runs is the statement's`() throws {
        let found = try #require(
            leaks(
                """
                func f(_ p: FilePath) throws {
                    let d = try io(.open) { try FileDescriptor.open(p, .readOnly) }
                    try work()
                }
                """
            ).first)
        #expect(found.message.contains("`d`"))
    }

    @Test func `an acquisition whose own statement throws holds nothing on that path`() {
        #expect(
            leaks(
                """
                func f(_ p: FilePath) throws {
                    let d = try FileDescriptor.open(p, .readOnly)
                    defer { _ = try? d.close() }
                }
                """
            ).isEmpty)
    }

    @Test func `a resource of the project is configured by name`() throws {
        let configuration = Configuration(
            resources: [.init(label: "socket", acquire: ["makeSocket"], release: ["destroy"])])
        let source = "func f() throws {\n let s = makeSocket()\n try work()\n}"
        #expect(leaks(source).isEmpty)
        #expect(try #require(leaks(source, configuration: configuration).first).message.contains("socket"))
        #expect(
            leaks("func f() throws {\n let s = makeSocket()\n try work()\n destroy(s)\n}", configuration: configuration)
                .count == 1)
        #expect(leaks("func f() {\n let s = makeSocket()\n destroy(s)\n}", configuration: configuration).isEmpty)
    }

    @Test func `a function that returns what it acquired is an acquirer`() {
        let result = Analyzer().analyze(
            bytes: Array(
                "func make(_ p: String) -> Int32 {\n let d = open(p, O_RDONLY)\n return d\n}\nfunc plain() {}".utf8),
            path: "T.swift", acquirers: [])
        #expect(result.acquirers == ["make"])
        #expect(result.findings.isEmpty)
    }

    @Test func `a function returning an acquisition directly is an acquirer`() {
        let result = Analyzer().analyze(
            bytes: Array(
                "func make(_ p: FilePath) -> FileDescriptor? {\n return try? FileDescriptor.open(p, .readOnly)\n}".utf8),
            path: "T.swift", acquirers: [])
        #expect(result.acquirers == ["make"])
    }

    @Test func `callers of an acquirer in another file are held to the obligation`() async throws {
        let files = [
            "Helper.swift": "func makeHandle(_ p: String) -> Int32 {\n let d = open(p, O_RDONLY)\n return d\n}\n",
            "Leaky.swift": "func leaky() throws {\n let h = makeHandle(\"x\")\n try work()\n}\n",
            "Careful.swift":
                "func careful() throws {\n let h = makeHandle(\"x\")\n defer { close(h) }\n try work()\n}\n",
        ]
        try await withCorpus(files) { root in
            let report = try await Analyzer().analyze(
                paths: files.keys.map { root + "/" + $0 }, cacheURL: nil)
            #expect(report.findings.map { URL(fileURLWithPath: $0.path).lastPathComponent } == ["Leaky.swift"])
            #expect(report.findings.first?.function == "leaky()")
        }
    }

    @Test func `a loop that opens on every iteration and closes at the end of the body is clean`() {
        #expect(
            leaks(
                """
                func f(_ ps: [String]) {
                    for p in ps {
                        let d = open(p, O_RDONLY)
                        if d < 0 { continue }
                        close(d)
                    }
                }
                """
            ).isEmpty)
    }

    @Test func `an early return in a loop leaks what the iteration opened`() {
        #expect(
            leaks(
                """
                func f(_ ps: [String]) -> Bool {
                    for p in ps {
                        let d = open(p, O_RDONLY)
                        if d < 0 { continue }
                        if check(p) { return true }
                        close(d)
                    }
                    return false
                }
                """
            ).count == 1)
    }
}
