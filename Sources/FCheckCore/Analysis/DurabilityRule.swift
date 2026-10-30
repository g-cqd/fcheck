import ControlFlow
import ProjectModel
import SwiftSyntax

/// `replace-not-durable`: replacing a file by `rename` is write, flush, rename, flush the directory.
///
/// Two ways to break the order are reported, each once per `rename`: bytes written on some path to the rename
/// and not flushed before it, and a path from the rename to a normal end of the function with no flush after it.
/// Flushes are typed by what they flush (roadmap 0025, F5). Any flush settles written bytes; only a flush of the
/// directory settles a rename. A directory flush is `fsync`, `fdatasync` or `fcntl(_, F_FULLFSYNC)` on a descriptor
/// opened with `O_DIRECTORY`, on a path that names a directory (`dir`, `deletingLastPathComponent`, `dirname`), or
/// itself named so (`dir`, `dirFD`, `directoryDescriptor`), or
/// a call whose name has a flush word and a directory word (`flushDirectory(of:)`, `syncParentDirectory`), or `flush`
/// or `sync` given, or called on, a descriptor named like that (`flush(directory)`, `parentDir.sync()`). The same
/// calls on another descriptor, and a call named exactly `flush` or `sync`, flush a file. A name in the configuration
/// counts as both.
struct DurabilityRule {
    private static let renames: Set<String> = [
        "rename", "Darwin.rename", "Glibc.rename", "renamex_np", "Darwin.renamex_np", "renameat", "Darwin.renameat",
    ]
    private static let writes: Set<String> = [
        "write", "writeAll", "pwrite", "pwritev", "writev", "createFile", "fwrite", "fputs",
    ]
    private static let descriptorFlushes: Set<String> = ["fsync", "fdatasync"]
    private static let fileFlushes: Set<String> = ["flush", "sync"]

    private enum Event {
        case write
        /// `directory` when the flush also settles a rename.
        case flush(directory: Bool)
        /// `successOn` is the edge the rename is known to have worked on, or nil for any normal edge.
        case rename(successOn: ControlFlowGraph.EdgeKind?)
    }

    private struct State: Equatable {
        /// The node that wrote bytes not flushed since, on some path.
        var dirty: Int?
        /// The node of a rename whose directory is not flushed since, on some path.
        var pending: Int?
    }

    let severity: Severity
    let extraFlush: Set<String>

    init(configuration: Configuration) {
        severity = configuration.severity(of: .replaceNotDurable)
        extraFlush = Set(configuration.flush)
    }

    func analyze(_ unit: FunctionUnit) -> [Finding] {
        guard CallFinder.calls(in: unit.statements).contains(where: { Self.renames.contains($0.callee) }) else {
            return []
        }
        let graph = ControlFlowGraph.build(statements: unit.statements, converter: unit.converter)
        let directories = Self.directoryDescriptors(in: unit.statements)
        let events = graph.nodes.map { eventsOf($0, directories: directories) }
        let states = graph.solve(
            initial: State(), join: Self.join,
            transfer: { node, edge, state in Self.apply(events[node.id], node: node, edge: edge, state) })

        var findings: [Finding] = []
        for node in graph.nodes where events[node.id].contains(where: { if case .rename = $0 { true } else { false } })
        {
            guard let entry = states[node.id] else { continue }
            if let written = dirtyAtRename(events[node.id], entry: entry, node: node) {
                findings.append(unflushed(rename: node, written: written, graph: graph, unit: unit))
            }
        }
        for exit in graph.nodes where exit.kind == .exit(.returned) || exit.kind == .exit(.fellOff) {
            guard let pending = states[exit.id]?.pending else { continue }
            findings.append(
                directoryNotFlushed(rename: pending, exit: exit.id, graph: graph, states: states, unit: unit))
        }
        return findings
    }

    // MARK: - Events

    private func eventsOf(_ node: ControlFlowGraph.Node, directories: Set<String>) -> [Event] {
        guard let syntax = node.syntax else { return [] }
        var events: [Event] = []
        for call in CallFinder.calls(in: syntax).sorted(by: { $0.node.endPosition < $1.node.endPosition }) {
            if Self.renames.contains(call.callee) {
                events.append(.rename(successOn: node.kind == .condition ? Self.successEdge(of: call) : nil))
            } else if let directory = flushTarget(call, directories: directories) {
                events.append(.flush(directory: directory))
            } else if Self.writes.contains(call.last) {
                events.append(.write)
            }
        }
        return events
    }

    /// Whether `call` flushes a directory (true), only a file (false), or nothing (nil).
    private func flushTarget(_ call: CallSite, directories: Set<String>) -> Bool? {
        if extraFlush.contains(call.callee) || extraFlush.contains(call.last) { return true }
        if Self.descriptorFlushes.contains(call.last)
            || (call.last == "fcntl" && call.node.arguments.trimmedDescription.contains("F_FULLFSYNC"))
        {
            guard let descriptor = call.node.arguments.first?.expression else { return false }
            if let name = SyntaxFacts.bareName(descriptor) {
                return directories.contains(name) || Self.words(name).contains { $0.hasPrefix("dir") }
            }
            if let opened = SyntaxFacts.stripped(descriptor).as(FunctionCallExprSyntax.self) {
                return Self.opensDirectory(opened)
            }
            return false
        }
        let words = Self.words(call.last)
        if words.contains(where: { ["flush", "sync", "fsync"].contains($0) }),
            words.contains(where: { $0.hasPrefix("dir") })
        {
            return true
        }
        guard Self.fileFlushes.contains(call.last) else { return nil }
        // `flush(directory)`, `parentDir.sync()`: the descriptor or the receiver is named like a directory.
        let target = call.node.arguments.first.flatMap { SyntaxFacts.bareName($0.expression) } ?? call.base
        return directories.contains(target) || Self.words(target).contains { $0.hasPrefix("dir") }
    }

    /// The names a body assigns a descriptor of a directory to: `let d = open(p, O_DIRECTORY | …)`, or `open` of a path
    /// that names a directory.
    private static func directoryDescriptors(in body: CodeBlockItemListSyntax) -> Set<String> {
        var found: Set<String> = []
        for (name, value) in AssignmentFinder.assignments(in: body) {
            if let call = SyntaxFacts.stripped(value).as(FunctionCallExprSyntax.self), opensDirectory(call) {
                found.insert(name)
            }
        }
        return found
    }

    private static func opensDirectory(_ node: FunctionCallExprSyntax) -> Bool {
        let call = CallSite(node: node)
        guard ["open", "openat"].contains(call.last), let path = node.arguments.first?.expression else { return false }
        if node.arguments.dropFirst().contains(where: { $0.expression.trimmedDescription.contains("O_DIRECTORY") }) {
            return true
        }
        let text = path.trimmedDescription
        return text.lowercased().contains("dir") || text.contains("deletingLastPathComponent")
    }

    /// A name's camel-case words, lowercased: `syncParentDirectory` is `sync`, `parent`, `directory`.
    private static func words(_ name: String) -> [String] {
        var words: [String] = []
        var current = ""
        for character in name {
            if (character.isUppercase || character == "_") && !current.isEmpty {
                words.append(current)
                current = ""
            }
            if character != "_" { current.append(character.lowercased()) }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    /// The edge of a condition on which `rename(...) <op> <value>` has succeeded.
    private static func successEdge(of call: CallSite) -> ControlFlowGraph.EdgeKind? {
        guard
            let sequence = call.node.parent?.as(SequenceExprSyntax.self)
                ?? call.node.parent?.parent?.as(SequenceExprSyntax.self)
        else { return nil }
        let elements = Array(sequence.elements)
        guard elements.count == 3, let op = elements[1].as(BinaryOperatorExprSyntax.self)?.operator.text else {
            return nil
        }
        switch (op, elements[2].trimmedDescription) {
        case ("==", "0"), (">=", "0"): return .whenTrue
        case ("!=", "0"), ("<", "0"), ("==", "-1"): return .whenFalse
        default: return nil
        }
    }

    // MARK: - Dataflow

    private static func join(_ left: State, _ right: State) -> State {
        State(dirty: minimum(left.dirty, right.dirty), pending: minimum(left.pending, right.pending))
    }

    private static func minimum(_ left: Int?, _ right: Int?) -> Int? {
        switch (left, right) {
        case (let left?, let right?): Swift.min(left, right)
        case (let only?, nil), (nil, let only?): only
        case (nil, nil): nil
        }
    }

    private static func apply(
        _ events: [Event], node: ControlFlowGraph.Node, edge: ControlFlowGraph.Edge, _ state: State
    ) -> State {
        var next = state
        for event in events {
            switch event {
            case .write: next.dirty = next.dirty ?? node.id
            case .flush(let directory):
                next.dirty = nil
                if directory { next.pending = nil }
            case .rename(let successOn):
                let worked = edge.kind != .thrown && (successOn == nil || successOn == edge.kind)
                if worked { next.pending = minimum(next.pending, node.id) }
            }
        }
        return next
    }

    /// Replays a node's events up to its first rename, to see whether bytes are unflushed there.
    private func dirtyAtRename(_ events: [Event], entry: State, node: ControlFlowGraph.Node) -> Int? {
        var dirty = entry.dirty
        for event in events {
            switch event {
            case .write: dirty = dirty ?? node.id
            case .flush: dirty = nil
            case .rename: return dirty
            }
        }
        return nil
    }

    // MARK: - Reporting

    private func unflushed(rename: ControlFlowGraph.Node, written: Int, graph: ControlFlowGraph, unit: FunctionUnit)
        -> Finding
    {
        let route = graph.path(from: written, to: rename.id) ?? [written, rename.id]
        return Finding(
            rule: .replaceNotDurable, severity: severity, path: unit.path, line: rename.line,
            column: rename.syntax.map(unit.column(of:)) ?? 1, function: unit.name,
            message:
                "`rename` replaces its destination with bytes written at line \(graph.nodes[written].line) that are not flushed on this path: a crash can leave an empty or partial file",
            witness: steps(route, graph))
    }

    private func directoryNotFlushed(
        rename: Int, exit: Int, graph: ControlFlowGraph, states: [State?], unit: FunctionUnit
    ) -> Finding {
        let route = graph.path(from: rename, to: exit, allowing: { states[$0]?.pending == rename }) ?? [rename, exit]
        let ends = graph.nodes[exit].kind == .exit(.returned) ? "returns" : "ends"
        let at = route.dropLast().last.map { graph.nodes[$0].line } ?? 0
        let node = graph.nodes[rename]
        return Finding(
            rule: .replaceNotDurable, severity: severity, path: unit.path, line: node.line,
            column: node.syntax.map(unit.column(of:)) ?? 1, function: unit.name,
            message:
                "the directory is not flushed after this `rename` before the function \(ends)\(ends == "returns" ? " at line \(at)" : ""): a crash can bring the old file back",
            witness: steps(route, graph))
    }

    private func steps(_ route: [Int], _ graph: ControlFlowGraph) -> [Finding.Step] {
        route.compactMap { id in
            let node = graph.nodes[id]
            guard node.line > 0, !node.isDeferred, let syntax = node.syntax else { return nil }
            let line = syntax.trimmedDescription.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
            return Finding.Step(line: node.line, text: line.count > 100 ? String(line.prefix(100)) + "…" : line)
        }
    }
}
