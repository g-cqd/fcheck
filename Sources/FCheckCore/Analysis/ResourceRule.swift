import ControlFlow
import ProjectModel
import SwiftSyntax

/// `leak-on-exit`: a handle acquired in a function is closed, handed on or returned on every path out of it.
///
/// The paths are those of the control-flow graph: normal ends, `return`, `throw`, a `try` that throws, and the
/// `defer`s each of them runs. A handle is *held* from its acquisition until a release (`close(v)`, `v.close()`),
/// a hand-on (passed to a call that is not a plain system call on it, stored, returned) or, for a descriptor
/// that is only valid when non-negative, a check that shows it failed.
struct ResourceRule {
    /// A kind of handle.
    struct Kind {
        let label: String
        /// Callee texts that acquire, matched whole.
        let acquire: Set<String>
        /// Simple names of corpus functions that return a handle they acquired.
        let acquireByName: Set<String>
        let release: Set<String>
        let releaseMethods: Set<String>
    }

    /// A held handle: where it was acquired, under what name.
    struct Held: Hashable {
        let name: String
        let site: Int
        let kind: Int
    }

    /// System calls and helpers that use a descriptor and do not take it over.
    static let nonOwning: Set<String> = [
        "read", "write", "pread", "pwrite", "readv", "writev", "fstat", "fcntl", "flock", "lseek", "fsync", "fdatasync",
        "ftruncate", "fchmod", "fchown", "mmap", "ioctl", "poll", "seek", "writeAll", "sync", "preallocate", "isatty",
        "print", "String", "describing", "dump", "kevent", "readdir", "rewinddir", "fileno", "fputs", "fprintf",
        "fread",
        "fwrite", "fflush", "fseek", "ftell", "feof", "ferror", "getc", "putc", "send", "recv", "bind", "listen",
        "setsockopt", "getsockopt", "shutdown", "connect", "fstatfs", "futimens", "fcntl",
    ]

    /// A call named like this uses a handle without taking it over.
    static let nonOwningPrefixes = [
        "flush", "sync", "read", "write", "pread", "pwrite", "seek", "stat", "fstat", "check", "validate", "assert",
        "log", "print", "dump", "describe", "trace", "debug", "is", "has", "lock", "unlock",
    ]

    static func isNonOwning(_ name: String) -> Bool {
        nonOwning.contains(name) || nonOwningPrefixes.contains { name.hasPrefix($0) }
    }

    static let defaults: [Configuration.Resource] = [
        Configuration.Resource(
            label: "file descriptor",
            acquire: [
                "open", "Darwin.open", "Glibc.open", "FileDescriptor.open", "System.FileDescriptor.open", "openat",
                "dup", "Darwin.dup", "dup2", "socket", "Darwin.socket", "accept", "mkstemp", "shm_open", "pipe",
            ], release: ["close", "Darwin.close", "Glibc.close"], negativeIsInvalid: true),
        Configuration.Resource(
            label: "directory stream", acquire: ["opendir", "Darwin.opendir", "fdopendir"],
            release: ["closedir", "Darwin.closedir"]),
        Configuration.Resource(
            label: "file stream", acquire: ["fopen", "Darwin.fopen", "fdopen", "tmpfile"],
            release: ["fclose", "Darwin.fclose"]),
    ]

    /// What the analysis found in one function.
    struct Outcome {
        var findings: [Finding] = []
        /// Whether the function returns a handle it acquired, which makes its callers acquirers.
        var returnsHandle = false
    }

    /// The fewest arguments a call needs to be the C function of that name, so `open(&state)` in a type that
    /// declares its own `open` is not taken for `open(2)`.
    static let minimumArguments: [String: Int] = [
        "open": 2, "openat": 3, "dup": 1, "dup2": 2, "socket": 3, "accept": 3, "mkstemp": 1, "shm_open": 3, "pipe": 1,
        "opendir": 1, "fdopendir": 1, "fopen": 2, "fdopen": 2, "tmpfile": 0,
    ]

    let kinds: [Kind]
    let declared: Set<String>
    let severity: Severity
    let negativeIsInvalid: Set<String>

    init(configuration: Configuration, acquirers: Set<String>, declared: Set<String> = []) {
        self.declared = declared
        var all = Self.defaults + configuration.resources
        var negative: Set<String> = []
        for resource in all where resource.negativeIsInvalid { negative.formUnion(resource.acquire) }
        // Functions of the corpus that return a handle acquire like the system calls do, and release like a descriptor.
        if !acquirers.isEmpty {
            all.append(
                Configuration.Resource(
                    label: "handle", acquire: [], release: ["close", "Darwin.close", "Glibc.close"]))
        }
        kinds = all.enumerated().map { index, resource in
            Kind(
                label: resource.label, acquire: Set(resource.acquire),
                acquireByName: index == all.count - 1 && !acquirers.isEmpty ? acquirers : [],
                release: Set(resource.release),
                releaseMethods: Set(resource.release.map { $0.split(separator: ".").last.map(String.init) ?? $0 }))
        }
        severity = configuration.severity(of: .leakOnExit)
        negativeIsInvalid = negative
    }

    // MARK: - Analysis

    func analyze(_ unit: FunctionUnit) -> Outcome {
        guard CallFinder.calls(in: unit.statements).contains(where: { acquiredKind(of: $0) != nil }) else {
            return Outcome()
        }
        let graph = ControlFlowGraph.build(statements: unit.statements, converter: unit.converter)
        let infos = graph.nodes.map { info(for: $0) }
        let states = graph.solve(
            initial: Set<Held>(), join: { $0.union($1) },
            transfer: { node, edge, state in transfer(node, edge, state, infos[node.id]) })

        var outcome = Outcome()
        var reported: Set<Int> = []
        for exit in preferredExits(graph) {
            guard let held = states[exit] else { continue }
            for leaked in held.sorted(by: { $0.site < $1.site }) where reported.insert(leaked.site).inserted {
                outcome.findings.append(finding(for: leaked, exit: exit, graph: graph, states: states, unit: unit))
            }
        }
        outcome.returnsHandle = graph.nodes.contains { node in
            guard let value = (node.syntax?.as(ReturnStmtSyntax.self))?.expression else { return false }
            if let name = SyntaxFacts.bareName(value) {
                return states[node.id]?.contains(where: { $0.name == name }) == true
            }
            guard let call = SyntaxFacts.stripped(value).as(FunctionCallExprSyntax.self) else { return false }
            return acquiredKind(of: CallSite(node: call)) != nil
        }
        return outcome
    }

    /// Exits in the order a leak is reported by: a throw first, since it is the path nobody wrote a close on.
    private func preferredExits(_ graph: ControlFlowGraph) -> [Int] {
        let order: [ControlFlowGraph.ExitKind] = [.threw, .returned, .fellOff]
        return order.compactMap { kind in
            graph.nodes.first { if case .exit(let found) = $0.kind { found == kind } else { false } }?.id
        }
    }

    // MARK: - Events

    fileprivate struct Acquisition {
        let name: String
        let kind: Int
        /// Acquired only when an `if let` or `guard let` binding succeeds.
        let viaBinding: Bool
    }

    private struct NodeInfo {
        var acquisitions: [Acquisition] = []
        var released: Set<String> = []
        var transferred: Set<String> = []
        /// `(name, validWhenTrue)` for comparisons of a descriptor with 0 or -1.
        var checks: [(name: String, validWhenTrue: Bool)] = []
    }

    private func info(for node: ControlFlowGraph.Node) -> NodeInfo {
        guard let syntax = node.syntax else { return NodeInfo() }
        var info = NodeInfo()
        let uses = UseClassifier(kinds: kinds)
        uses.walk(syntax)
        info.released = uses.released
        info.transferred = uses.transferred
        if node.kind == .condition, let conditions = syntax.as(ConditionElementListSyntax.self) {
            for element in conditions {
                switch element.condition {
                case .optionalBinding(let binding):
                    if let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                        let value = binding.initializer?.value, let kind = acquiredKindOfExpression(value)
                    {
                        info.acquisitions.append(Acquisition(name: name, kind: kind, viaBinding: true))
                    }
                case .expression(let expression):
                    if let check = Self.check(in: expression) { info.checks.append(check) }
                default:
                    break
                }
            }
        } else {
            let finder = AcquisitionFinder(rule: self)
            finder.walk(syntax)
            info.acquisitions = finder.found
        }
        return info
    }

    private func transfer(
        _ node: ControlFlowGraph.Node, _ edge: ControlFlowGraph.Edge, _ state: Set<Held>, _ info: NodeInfo
    ) -> Set<Held> {
        var next = state
        let gone = info.released.union(info.transferred)
        if !gone.isEmpty { next = next.filter { !gone.contains($0.name) } }
        if edge.kind != .thrown {
            for acquisition in info.acquisitions where !acquisition.viaBinding || edge.kind == .whenTrue {
                next = next.filter { $0.name != acquisition.name }
                next.insert(Held(name: acquisition.name, site: node.id, kind: acquisition.kind))
            }
        }
        for check in info.checks where (edge.kind == .whenTrue) != check.validWhenTrue {
            if edge.kind == .whenTrue || edge.kind == .whenFalse { next = next.filter { $0.name != check.name } }
        }
        return next
    }

    /// `name >= 0` and the like.
    private static func check(in expression: ExprSyntax) -> (name: String, validWhenTrue: Bool)? {
        guard let sequence = expression.as(SequenceExprSyntax.self) else { return nil }
        let elements = Array(sequence.elements)
        guard elements.count == 3, let name = SyntaxFacts.bareName(elements[0]),
            let op = elements[1].as(BinaryOperatorExprSyntax.self)?.operator.text,
            let value = literal(elements[2])
        else { return nil }
        switch (op, value) {
        case (">=", 0), (">", -1), ("!=", -1): return (name, true)
        case ("<", 0), ("==", -1), ("<=", -1): return (name, false)
        default: return nil
        }
    }

    private static func literal(_ expression: ExprSyntax) -> Int? {
        if let integer = expression.as(IntegerLiteralExprSyntax.self) { return Int(integer.literal.text) }
        if let prefix = expression.as(PrefixOperatorExprSyntax.self), prefix.operator.text == "-",
            let integer = prefix.expression.as(IntegerLiteralExprSyntax.self), let value = Int(integer.literal.text)
        {
            return -value
        }
        return nil
    }

    // MARK: - Acquisition

    fileprivate func acquiredKind(of call: CallSite) -> Int? {
        for (index, kind) in kinds.enumerated() {
            if kind.acquireByName.contains(call.last) { return index }
            guard kind.acquire.contains(call.callee) else { continue }
            if isLocalMethod(call) || call.arguments.count < (Self.minimumArguments[call.last] ?? 0) { continue }
            return index
        }
        return nil
    }

    /// A bare call to a name the file declares is that method, not the system call of the same name.
    private func isLocalMethod(_ call: CallSite) -> Bool {
        call.base.isEmpty && declared.contains(call.callee)
    }

    /// The kind of handle `expression` produces, when it is, or contains in a closure it runs, an acquiring call.
    fileprivate func acquiredKindOfExpression(_ expression: ExprSyntax) -> Int? {
        for call in CallFinder.calls(in: expression) {
            if let kind = acquiredKind(of: call) { return kind }
        }
        return nil
    }

    fileprivate final class AcquisitionFinder: SyntaxVisitor {
        private let rule: ResourceRule
        private(set) var found: [Acquisition] = []

        init(rule: ResourceRule) {
            self.rule = rule
            super.init(viewMode: .sourceAccurate)
        }

        override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
            for binding in node.bindings {
                guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                    let value = binding.initializer?.value, !Self.isOptionalTry(value),
                    let kind = rule.acquiredKindOfExpression(value)
                else { continue }
                found.append(Acquisition(name: name, kind: kind, viaBinding: false))
            }
            return .skipChildren
        }

        override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
            let elements = Array(node.elements)
            if elements.count >= 3, elements[1].is(AssignmentExprSyntax.self),
                let name = SyntaxFacts.bareName(elements[0]), !Self.isOptionalTry(elements[2]),
                let kind = rule.acquiredKindOfExpression(elements[2])
            {
                found.append(Acquisition(name: name, kind: kind, viaBinding: false))
            }
            return .skipChildren
        }

        /// `try?` makes the result optional, which this rule follows only through a binding.
        private static func isOptionalTry(_ expression: ExprSyntax) -> Bool {
            expression.as(TryExprSyntax.self)?.questionOrExclamationMark?.text == "?"
        }

        override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
        override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    }

    // MARK: - Reporting

    private func finding(
        for leaked: Held, exit: Int, graph: ControlFlowGraph, states: [Set<Held>?], unit: FunctionUnit
    ) -> Finding {
        let site = graph.nodes[leaked.site]
        // Leave the acquiring statement by an edge that completes it: its own throw edge is the one on which nothing was acquired.
        let held: (Int) -> Bool = { states[$0]?.contains(where: { $0.site == leaked.site }) == true }
        let route =
            site.successors.filter { $0.kind != .thrown }
            .compactMap { graph.path(from: $0.target, to: exit, allowing: held) }
            .min { $0.count < $1.count }
            .map { [leaked.site] + $0 } ?? [leaked.site, exit]
        let steps = route.compactMap { id -> Finding.Step? in
            let node = graph.nodes[id]
            guard node.line > 0, !node.isDeferred else { return nil }
            let text = node.syntax.map { Self.firstLine(of: $0) } ?? ""
            return Finding.Step(line: node.line, text: text)
        }
        let lastNode = route.dropLast().last.map { graph.nodes[$0] }
        let how: String
        switch graph.nodes[exit].kind {
        case .exit(.threw): how = "throws at line \(lastNode?.line ?? 0)"
        case .exit(.returned): how = "returns at line \(lastNode?.line ?? 0)"
        default: how = "reaches its end"
        }
        let label = kinds[leaked.kind].label
        return Finding(
            rule: .leakOnExit, severity: severity, path: unit.path, line: site.line,
            column: site.syntax.map(unit.column(of:)) ?? 1,
            function: unit.name,
            message:
                "the \(label) `\(leaked.name)` acquired here is not closed, handed on or returned when the function \(how)",
            witness: steps)
    }

    private static func firstLine(of syntax: Syntax) -> String {
        let line = syntax.trimmedDescription.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        return line.count > 100 ? String(line.prefix(100)) + "…" : line
    }
}

/// Which identifiers a syntax subtree releases and which it hands on.
final class UseClassifier: SyntaxVisitor {
    private let releaseCallees: Set<String>
    private let releaseMethods: Set<String>
    private(set) var released: Set<String> = []
    private(set) var transferred: Set<String> = []

    fileprivate init(kinds: [ResourceRule.Kind]) {
        releaseCallees = Set(kinds.flatMap(\.release))
        releaseMethods = Set(kinds.flatMap(\.releaseMethods))
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        let call = CallSite(node: node)
        if releaseCallees.contains(call.callee) {
            for argument in call.arguments {
                if let name = SyntaxFacts.bareName(argument.expression) { released.insert(name) }
            }
        } else if releaseMethods.contains(call.last), !call.base.isEmpty, !call.base.contains(".") {
            released.insert(call.base)
        } else if !ResourceRule.isNonOwning(call.last) {
            for argument in call.arguments {
                if let name = SyntaxFacts.bareName(argument.expression) { transferred.insert(name) }
            }
        }
        return .visitChildren
    }

    override func visit(_ node: ReturnStmtSyntax) -> SyntaxVisitorContinueKind {
        if let value = node.expression { handOn(value) }
        return .visitChildren
    }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        for binding in node.bindings { if let value = binding.initializer?.value { handOn(value) } }
        return .visitChildren
    }

    override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
        let elements = Array(node.elements)
        if elements.count == 3, elements[1].is(AssignmentExprSyntax.self) { handOn(elements[2]) }
        return .visitChildren
    }

    /// A bare identifier, or a tuple of them, stored or returned.
    private func handOn(_ expression: ExprSyntax) {
        let value = SyntaxFacts.stripped(expression)
        if let name = SyntaxFacts.bareName(value) {
            transferred.insert(name)
        } else if let tuple = value.as(TupleExprSyntax.self) {
            for element in tuple.elements { handOn(element.expression) }
        }
    }
}
