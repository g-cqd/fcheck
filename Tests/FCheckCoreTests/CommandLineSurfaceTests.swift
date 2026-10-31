import Foundation
import Testing

/// fcheck's analysing command on analyzerkit's shared option groups (analyzerkit ADR-0019, roadmap 0021): every
/// option of the Input, Output, Rules and Cache groups works, and the old spellings still do, with a note.
@Suite(.serialized) struct CommandLineSurfaceTests {
    private static let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    /// One leak-on-exit warning per file.
    private static func leak(_ name: String) -> String {
        "func \(name)(_ p: String) throws {\n    let d = open(p, 0)\n    try work()\n    close(d)\n}\n"
    }

    struct Run {
        let status: Int32
        let output: String
        let errors: String
    }

    private static func executable() throws -> URL {
        let build = packageRoot.appending(path: ".build")
        let candidates = ["debug", "release"].map { build.appending(path: "\($0)/fcheck") }
            .filter { FileManager.default.isExecutableFile(atPath: $0.path) }
        func modified(_ url: URL) -> Date {
            (try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path))?[.modificationDate]
                as? Date ?? .distantPast
        }
        return try #require(candidates.max { modified($0) < modified($1) }, "build fcheck first")
    }

    private static func run(_ arguments: [String], in root: URL) throws -> Run {
        let process = Process()
        process.executableURL = try executable()
        process.arguments = arguments
        process.currentDirectoryURL = root
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let out = output.fileHandleForReading.readDataToEndOfFile()
        let err = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(
            status: process.terminationStatus, output: String(decoding: out, as: UTF8.self),
            errors: String(decoding: err, as: UTF8.self))
    }

    /// A repository root holding `files`.
    private static func workspace(_ files: [String: String], _ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "fcheck-cli-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("gitdir: none\n".utf8).write(to: root.appending(path: ".git"))
        for (name, text) in files {
            let url = root.appending(path: name)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        try body(root)
    }

    @Test func `the help lists every shared option`() throws {
        try Self.workspace([:]) { root in
            let help = try Self.run(["analyze", "--help"], in: root).output
            for option in [
                "--config", "--exclude-path", "--include-regions", "--exclude-regions", "--define", "--only",
                "--only-from", "--format", "--relative-to", "--strict", "--baseline", "--write-baseline",
                "--report-new-since", "--verbose", "--quiet", "--timings", "--rules", "--cache-path", "--no-cache",
            ] {
                #expect(help.contains(option), "missing \(option)")
            }
            #expect(!help.contains("--include-tests"), "a deprecated alias is hidden")
        }
    }

    /// ADR-0019: each tool pins its own help. Recorded from the migrated build; regenerate only for a deliberate change.
    @Test func `the help is the recorded one`() throws {
        try Self.workspace([:]) { root in
            let golden = Self.packageRoot.appending(path: "Tests/FCheckCoreTests/Goldens/help-analyze.txt")
            let recorded = try String(contentsOf: golden, encoding: .utf8)
            let help = try Self.run(["analyze", "--help"], in: root).output
            #expect(help == recorded, "help differs from Goldens/help-analyze.txt")
        }
    }

    @Test func `exclude-path leaves a file out`() throws {
        try Self.workspace(["Sources/A.swift": Self.leak("a"), "Sources/B.swift": Self.leak("b")]) { root in
            let run = try Self.run(["analyze", ".", "--no-cache", "--exclude-path", "B.swift"], in: root)
            #expect(run.output.contains("A.swift"))
            #expect(!run.output.contains("B.swift"))
        }
    }

    @Test func `include-tests still works, says it is deprecated, and equals include-regions test,generated`() throws {
        try Self.workspace(["Sources/A.swift": Self.leak("a"), "Tests/ATests.swift": Self.leak("t")]) { root in
            let old = try Self.run(["analyze", ".", "--no-cache", "--include-tests"], in: root)
            let new = try Self.run(["analyze", ".", "--no-cache", "--include-regions", "test,generated"], in: root)
            let none = try Self.run(["analyze", ".", "--no-cache"], in: root)
            #expect(old.output.contains("ATests.swift"))
            #expect(old.output == new.output)
            #expect(!none.output.contains("ATests.swift"))
            #expect(
                old.errors.contains("fcheck: note: --include-tests is deprecated; use --include-regions test,generated")
            )
            #expect(!new.errors.contains("deprecated"))
        }
    }

    @Test func `exclude-regions wins over include-regions`() throws {
        try Self.workspace(["Sources/A.swift": Self.leak("a"), "Tests/ATests.swift": Self.leak("t")]) { root in
            let run = try Self.run(
                ["analyze", ".", "--no-cache", "--include-regions", "all", "--exclude-regions", "test"], in: root)
            #expect(!run.output.contains("ATests.swift"))
        }
    }

    @Test func `an unknown region is a usage error`() throws {
        try Self.workspace(["Sources/A.swift": Self.leak("a")]) { root in
            let run = try Self.run(["analyze", ".", "--no-cache", "--include-regions", "tests"], in: root)
            #expect(run.status == 64)
        }
    }

    @Test func `quiet prints nothing on stderr, verbose says where the configuration came from`() throws {
        try Self.workspace(["Sources/A.swift": Self.leak("a")]) { root in
            let quiet = try Self.run(["analyze", ".", "--no-cache", "--quiet"], in: root)
            #expect(quiet.errors.isEmpty)
            #expect(quiet.output.contains("A.swift"))
            let verbose = try Self.run(["analyze", ".", "--no-cache", "--verbose"], in: root)
            #expect(verbose.errors.contains("fcheck: configuration: no file found; built-in defaults"))
        }
    }

    @Test func `timings adds the phases to the JSON report`() throws {
        try Self.workspace(["Sources/A.swift": Self.leak("a")]) { root in
            let run = try Self.run(["analyze", ".", "--no-cache", "--format", "json", "--timings"], in: root)
            #expect(run.output.contains("\"timings\""))
            let plain = try Self.run(["analyze", ".", "--no-cache", "--format", "json"], in: root)
            #expect(!plain.output.contains("\"timings\""))
        }
    }

    @Test func `define reads only the active clauses, with no note`() throws {
        let gated = "import Darwin\n#if FEATURE\nfunc f() { let fd = open(\"a\", O_RDONLY); print(fd) }\n#endif\n"
        try Self.workspace(["Sources/A.swift": gated]) { root in
            let feature = try Self.run(["analyze", ".", "--no-cache", "--define", "FEATURE"], in: root)
            #expect(feature.output.contains("leak-on-exit"))
            #expect(!feature.errors.contains("no effect"))
            let other = try Self.run(["analyze", ".", "--no-cache", "--define", "OTHER"], in: root)
            #expect(other.status == 0 && !other.output.contains("leak-on-exit"))
        }
    }

    /// The base branch's baseline holds A's finding; the change adds B's and touches only C.
    @Test func `report-new-since reports out-of-scope findings the base baseline lacks`() throws {
        try Self.workspace([
            "Sources/A.swift": Self.leak("a"), "Sources/C.swift": "let c = 1\n",
        ]) { root in
            #expect(
                try Self.run(["analyze", ".", "--no-cache", "--write-baseline", "base.json"], in: root).status == 0)
            try Data(Self.leak("b").utf8).write(to: root.appending(path: "Sources/B.swift"))
            let run = try Self.run(
                ["analyze", ".", "--no-cache", "--only", "Sources/C.swift", "--report-new-since", "base.json"], in: root
            )
            #expect(run.output.contains("B.swift"))
            #expect(!run.output.contains("A.swift"))
            #expect(run.errors.contains("1 finding(s) outside --only are new since base.json"))
            let unscoped = try Self.run(["analyze", ".", "--no-cache", "--report-new-since", "base.json"], in: root)
            #expect(unscoped.status == 64)
        }
    }

    @Test func `rules with an id explains the rule, as explain does`() throws {
        try Self.workspace([:]) { root in
            let rules = try Self.run(["rules", "leak-on-exit"], in: root)
            let explain = try Self.run(["explain", "leak-on-exit"], in: root)
            #expect(rules.status == 0)
            #expect(rules.output == explain.output)
        }
    }

    /// `--cache-path` names the cache's root directory (analyzerkit ADR-0011); a second run reuses every file.
    @Test func `a cache under cache-path is reused`() throws {
        try Self.workspace(["Sources/A.swift": Self.leak("a"), "Sources/B.swift": "let b = 1\n"]) { root in
            let cache = root.appending(path: "cache").path
            _ = try Self.run(["analyze", ".", "--cache-path", cache], in: root)
            let warm = try Self.run(["analyze", ".", "--cache-path", cache], in: root)
            #expect(warm.errors.contains("cache: 2 reused, 0 parsed"))
        }
    }
}
