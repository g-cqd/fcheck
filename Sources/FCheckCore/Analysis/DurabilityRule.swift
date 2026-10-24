import ControlFlow
import ProjectModel
import SwiftSyntax

/// `replace-not-durable`: replacing a file by `rename` is write, flush, rename, flush the directory.
///
/// Two ways to break the order are reported, each once per `rename`: bytes written on some path to the rename
/// and not flushed before it, and a path from the rename to a normal end of the function with no flush after it.
/// A flush is `fsync`, `fdatasync`, `fcntl(_, F_FULLFSYNC)`, a `sync` method, a call with `flush` in its name, or a
/// name in the configuration.
struct DurabilityRule {
    private static let renames: Set<String> = [
        "rename", "Darwin.rename", "Glibc.rename", "renamex_np", "Darwin.renamex_np", "renameat", "Darwin.renameat",
    ]
    private static let writes: Set<String> = [
        "write", "writeAll", "pwrite", "pwritev", "writev", "createFile", "fwrite", "fputs",
    ]
    private static let flushes: Set<String> = ["fsync", "fdatasync", "sync", "F_FULLFSYNC"]

    private enum Event {
        case write
        case flush
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
        let events = graph.nodes.map { eventsOf($0) }
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

    private func eventsOf(_ node: ControlFlowGraph.Node) -> [Event] {
        guard let syntax = node.syntax else { return [] }
        var events: [Event] = []
        for call in CallFinder.calls(in: syntax).sorted(by: { $0.node.endPosition < $1.node.endPosition }) {
            if Self.renames.contains(call.callee) {
                events.append(.rename(successOn: node.kind == .condition ? Self.successEdge(of: call) : nil))
            } else if isFlush(call) {
                events.append(.flush)
            } else if Self.writes.contains(call.last) {
                events.append(.write)
            }
        }
        return events
    }

    private func isFlush(_ call: CallSite) -> Bool {
        if Self.flushes.contains(call.last) || extraFlush.contains(call.callee) || extraFlush.contains(call.last) {
            return true
        }
        if call.last.lowercased().contains("flush") { return true }
        return call.last == "fcntl" && call.node.arguments.trimmedDescription.contains("F_FULLFSYNC")
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
            case .flush:
                next.dirty = nil
                next.pending = nil
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
