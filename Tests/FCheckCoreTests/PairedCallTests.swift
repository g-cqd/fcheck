import FCheckCore
import Foundation
import Testing

/// Calls paired on one receiver or on one argument, closed on every path out (analyzerkit roadmap 0063).
@Suite struct PairedCallTests {
    private func leaks(_ source: String, configuration: Configuration = .default) -> [Finding] {
        analyze(source, rules: [.leakOnExit], configuration: configuration)
    }

    @Test func `a configuration begun on a session and left open when a later try throws is reported`() throws {
        // maintastic's CaptureActor.configureSessionIfNeeded().
        let found = leaks(
            """
            func configure() throws {
                session.beginConfiguration()
                try addVideoInput(session: session, device: device)
                try addVideoOutput(session: session)
                session.commitConfiguration()
            }
            """)
        let only = try #require(found.first)
        #expect(found.count == 1)
        #expect(only.line == 2 && only.message.contains("`session`") && only.message.contains("throws at line 3"))
        #expect(only.message.contains("capture-session configuration"))
    }

    @Test(arguments: [
        "session.beginConfiguration()\ndefer { session.commitConfiguration() }\ntry addInput(session)",
        "self.session.beginConfiguration()\ndefer { self.session.commitConfiguration() }\ntry addInput(session)",
        "session.beginConfiguration()\naddInputWithoutThrowing(session)\nsession.commitConfiguration()",
    ])
    func `a configuration committed on every path, or with nothing that leaves between, is not`(body: String) {
        #expect(leaks("func configure() throws {\n\(body)\n}").isEmpty)
    }

    @Test func `a device lock that fails holds nothing, and one released on every path is fine`() throws {
        #expect(
            leaks(
                """
                func torch() throws {
                    try device.lockForConfiguration()
                    device.torchMode = .on
                    device.unlockForConfiguration()
                }
                """
            ).isEmpty)
        let found = try #require(
            leaks(
                """
                func zoom(_ factor: Double) throws {
                    try device.lockForConfiguration()
                    try device.setZoom(factor)
                    device.unlockForConfiguration()
                }
                """
            ).first)
        #expect(found.message.contains("capture-device configuration lock") && found.line == 2)
    }

    @Test func `a pixel buffer locked by its first argument is followed to its unlock`() throws {
        let found = try #require(
            leaks(
                """
                func draw(_ buffer: CVPixelBuffer) throws {
                    CVPixelBufferLockBaseAddress(buffer, [])
                    try render(into: buffer)
                    CVPixelBufferUnlockBaseAddress(buffer, [])
                }
                """
            ).first)
        #expect(found.message.contains("`buffer`") && found.message.contains("pixel-buffer"))
        #expect(
            leaks(
                """
                func draw(_ buffer: CVPixelBuffer) throws {
                    CVPixelBufferLockBaseAddress(buffer, .readOnly)
                    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
                    try render(into: buffer)
                }
                """
            ).isEmpty)
    }

    @Test func `a pair of the project is configured with holds receiver`() throws {
        let configuration = Configuration(
            resources: [.init(label: "batch", acquire: ["beginBatch"], release: ["endBatch"], holds: .receiver)])
        let source = "func f() throws {\n store.beginBatch()\n try work()\n store.endBatch()\n}"
        #expect(leaks(source).isEmpty)
        #expect(try #require(leaks(source, configuration: configuration).first).message.contains("batch"))
    }

    @Test func `a receiver reached through another value is left alone, since its release cannot be matched`() {
        #expect(
            leaks(
                "func f() throws {\n camera.session.beginConfiguration()\n try work()\n camera.session.commitConfiguration()\n}"
            ).isEmpty)
    }

    @Test func `holds reads from the configuration, result by default`() throws {
        let data = Data(#"{ "label": "b", "acquire": ["a"], "release": ["r"], "holds": "firstArgument" }"#.utf8)
        #expect(try JSONDecoder().decode(Configuration.Resource.self, from: data).holds == .firstArgument)
        let plain = Data(#"{ "label": "b", "acquire": ["a"], "release": ["r"] }"#.utf8)
        #expect(try JSONDecoder().decode(Configuration.Resource.self, from: plain).holds == .result)
    }
}
