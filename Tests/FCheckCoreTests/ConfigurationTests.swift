import FCheckCore
import Foundation
import ProjectModel
import Testing

@Suite struct ConfigurationTests {
    private func load(_ json: String?) throws -> Configuration {
        let path = FileManager.default.temporaryDirectory.appending(path: "fcheck-config-\(UUID().uuidString).json")
            .path
        defer { try? FileManager.default.removeItem(atPath: path) }
        if let json { try json.write(toFile: path, atomically: true, encoding: .utf8) }
        return try Configuration.load(from: path)
    }

    @Test func `no file is the default and an empty object is too`() throws {
        #expect(try load(nil) == .default)
        // A loaded file records where it lives, the root of its globs; its content is the default.
        var empty = try load("{}")
        #expect(empty.root == FileManager.default.temporaryDirectory.path.replacing(/\/$/, with: ""))
        empty.root = nil
        #expect(empty == .default)
    }

    @Test func `every field is read`() throws {
        let configuration = try load(
            """
            { "disable": ["cut-then-decode"], "severity": { "leak-on-exit": "error" },
              "resources": [ { "label": "s", "acquire": ["a"], "release": ["r"], "negativeIsInvalid": true } ],
              "flush": ["persist"], "exclude": ["/Gen/"], "includeTests": true }
            """)
        #expect(configuration.disable == [.cutThenDecode] && configuration.severity[.leakOnExit] == .error)
        #expect(configuration.resources == [.init(label: "s", acquire: ["a"], release: ["r"], negativeIsInvalid: true)])
        #expect(configuration.flush == ["persist"] && configuration.exclude == ["/Gen/"] && configuration.includeTests)
    }

    @Test func `a rule name that does not exist, or bad JSON, fails instead of turning a rule off`() {
        #expect(throws: Configuration.Failure.self) { try load("{ \"severity\": { \"leak\": \"error\" } }") }
        #expect(throws: Configuration.Failure.self) { try load("{ nope") }
    }

    @Test func `a changed configuration changes the cache salt`() {
        #expect(Configuration.default.salt == Configuration().salt)
        #expect(Configuration.default.salt != Configuration(flush: ["x"]).salt)
    }

    /// Regions choose which files are reported, not what a file's facts are, so a cache written under one selection
    /// serves another (analyzerkit roadmap 0021): files a region left out were never cached, and are parsed when asked for.
    @Test func `the region selection does not change the cache salt`() {
        #expect(Configuration.default.salt == Configuration(includeTests: true).salt)
    }

    @Test func `a severity from the configuration is the finding's severity`() {
        let source = "func f() throws {\n let d = open(p, 0)\n try work()\n}"
        let error = analyze(source, rules: [.leakOnExit], configuration: Configuration(severity: [.leakOnExit: .error]))
        #expect(error.first?.severity == .error)
        #expect(analyze(source, rules: [.leakOnExit]).first?.severity == .warning)
    }

    @Test func `a disabled rule reports nothing`() {
        let source = "func f() throws {\n let d = open(p, 0)\n try work()\n}"
        #expect(analyze(source, configuration: Configuration(disable: [.leakOnExit])).isEmpty)
    }
}
