public import ArgumentParser
import FCheckCore
import SystemPackage

/// Writes `text` to a descriptor, so stdout carries only the report.
func write(_ text: String, to descriptor: FileDescriptor) {
    _ = try? descriptor.writeAll(text.utf8)
}

@main
struct FCheckCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: ToolInfo.name,
        abstract:
            "Checks that Swift code keeps its obligations on every path: handles closed, files replaced durably, text not cut.",
        version: ToolInfo.version,
        subcommands: [Analyze.self, Rules.self, Explain.self],
        defaultSubcommand: Analyze.self
    )
}

extension OutputFormat: ExpressibleByArgument {}
