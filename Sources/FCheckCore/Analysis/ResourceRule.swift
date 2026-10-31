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
        /// Corpus functions that return a handle they acquired, by simple name.
        let acquireByName: [String: [Acquirer]]
        let release: Set<String>
        let releaseMethods: Set<String>
        let holds: Configuration.Resource.Holds
    }

    /// A corpus function that returns a handle it acquired, from its ``FunctionUnit/acquirerKey``.
    struct Acquirer: Equatable {
        /// The enclosing type, nil outside a type or when the key gave none.
        let type: String?
        let arity: ClosedRange<Int>

        /// `Type.name#required-total`, `name#required-total`, or a bare name, which matches any call of that name.
        static func parse(_ key: String) -> (name: String, acquirer: Acquirer) {
            guard let hash = key.lastIndex(of: "#") else { return (key, Acquirer(type: nil, arity: 0...Int.max)) }
            let qualified = key[..<hash]
            let bounds = key[key.index(after: hash)...].split(separator: "-").compactMap { Int($0) }
            let arity = bounds.count == 2 && bounds[0] <= bounds[1] ? bounds[0]...bounds[1] : 0...Int.max
            guard let dot = qualified.lastIndex(of: ".") else {
                return (String(qualified), Acquirer(type: "", arity: arity))
            }
            return (
                String(qualified[qualified.index(after: dot)...]),
                Acquirer(type: String(qualified[..<dot]), arity: arity)
            )
        }

        /// Whether a call with `count` arguments on a base of type `base` (nil when unknown) can be this function.
        /// A type is required to match only when both are known; a free function (`type == ""`) is never a method.
        func accepts(count: Int, base: String?) -> Bool {
            guard arity.contains(count) else { return false }
            guard let base, let type else { return true }
            return !type.isEmpty && TypeScope.lastComponent(type) == TypeScope.lastComponent(base)
        }
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

    /// The name is in ``nonOwning`` or starts with a prefix at a camel-case boundary: `logState` and `isValid` do, `login`
    /// and `issue` do not (roadmap 0025, F3).
    static func isNonOwning(_ name: String) -> Bool {
        if nonOwning.contains(name) { return true }
        return nonOwningPrefixes.contains { prefix in
            guard name.hasPrefix(prefix) else { return false }
            guard let next = name.dropFirst(prefix.count).first else { return true }
            return next.isUppercase || next.isNumber || next == "_"
        }
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
        // AVCaptureSession: changes take effect at the outermost commit; one never committed leaves the session in
        // configuration, and the next begin nests inside it.
        Configuration.Resource(
            label: "capture-session configuration", acquire: ["beginConfiguration"],
            release: ["commitConfiguration"], holds: .receiver),
        // AVCaptureDevice: "you must call unlockForConfiguration()" once the lock was obtained.
        Configuration.Resource(
            label: "capture-device configuration lock", acquire: ["lockForConfiguration"],
            release: ["unlockForConfiguration"], holds: .receiver),
        Configuration.Resource(
            label: "pixel-buffer base-address lock", acquire: ["CVPixelBufferLockBaseAddress"],
            release: ["CVPixelBufferUnlockBaseAddress"], holds: .firstArgument),
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
    /// The types of the names in the function being analysed.
    private var scope = TypeScope()
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
        var byName: [String: [Acquirer]] = [:]
        for key in acquirers.sorted() {
            let (name, acquirer) = Acquirer.parse(key)
            byName[name, default: []].append(acquirer)
        }
        kinds = all.enumerated().map { index, resource in
            Kind(
                label: resource.label, acquire: Set(resource.acquire),
                acquireByName: index == all.count - 1 && !acquirers.isEmpty ? byName : [:],
                release: Set(resource.release),
                releaseMethods: Set(resource.release.map { $0.split(separator: ".").last.map(String.init) ?? $0 }),
                holds: resource.holds)
        }
        severity = configuration.severity(of: .leakOnExit)
        negativeIsInvalid = negative
    }

    // MARK: - Analysis

    func analyze(_ unit: FunctionUnit) -> Outcome {
        var scoped = self
        scoped.scope = TypeScope(unit)
        return scoped.analyzeInScope(unit)
    }

    private func analyzeInScope(_ unit: FunctionUnit) -> Outcome {
        guard
            CallFinder.calls(in: unit.statements).contains(where: {
                acquiredKind(of: $0) != nil || pairedAcquisition(of: $0) != nil
            })
        else {
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
        // Acquiring into a name that still holds a handle loses the first one (F2); a path to an exit was reported above.
        for node in graph.nodes where !infos[node.id].acquisitions.isEmpty {
            guard let entry = states[node.id] else { continue }
            let gone = infos[node.id].released.union(infos[node.id].transferred)
            for acquisition in infos[node.id].acquisitions
            where !acquisition.viaBinding && kinds[acquisition.kind].holds == .result {
                for lost in entry.sorted(by: { $0.site < $1.site })
                where lost.name == acquisition.name && lost.site != node.id && !gone.contains(lost.name)
                    && reported.insert(lost.site).inserted
                {
                    outcome.findings.append(
                        finding(for: lost, exit: node.id, graph: graph, states: states, unit: unit, reassigned: true))
                }
            }
        }
        outcome.returnsHandle = returnsHandle(graph, states: states, unit: unit)
        return outcome
    }

    /// A `return` of a held name or of an acquiring call, or a body that is one acquiring expression (F1b).
    private func returnsHandle(_ graph: ControlFlowGraph, states: [Set<Held>?], unit: FunctionUnit) -> Bool {
        if unit.statements.count == 1, case .expr(let value)? = unit.statements.first?.item,
            let call = SyntaxFacts.stripped(value).as(FunctionCallExprSyntax.self),
            acquiredKind(of: CallSite(node: call)) != nil
        {
            return true
        }
        return graph.nodes.contains { node in
            guard let value = (node.syntax?.as(ReturnStmtSyntax.self))?.expression else { return false }
            if let name = SyntaxFacts.bareName(value) {
                return states[node.id]?.contains(where: { $0.name == name && kinds[$0.kind].holds == .result }) == true
            }
            guard let call = SyntaxFacts.stripped(value).as(FunctionCallExprSyntax.self) else { return false }
            return acquiredKind(of: CallSite(node: call)) != nil
        }
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
        if !info.released.isEmpty || !info.transferred.isEmpty {
            // A pair is closed only by its release: passing the receiver or the argument on does not end it.
            next = next.filter { held in
                !info.released.contains(held.name)
                    && !(kinds[held.kind].holds == .result && info.transferred.contains(held.name))
            }
        }
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
            if let candidates = kind.acquireByName[call.last] {
                let count =
                    call.arguments.count + (call.node.trailingClosure == nil ? 0 : 1)
                    + call.node.additionalTrailingClosures.count
                let base = scope.type(of: call.base)
                if candidates.contains(where: { $0.accepts(count: count, base: base) }) { return index }
            }
            guard kind.holds == .result, kind.acquire.contains(call.callee) else { continue }
            if isLocalMethod(call) || call.arguments.count < (Self.minimumArguments[call.last] ?? 0) { continue }
            return index
        }
        return nil
    }

    /// The name a paired call makes held and its kind: the receiver of `x.begin()`, or the first argument of
    /// `lock(x, …)`, when it is a simple name (`self.` dropped). Nil for anything else, which no release could match.
    fileprivate func pairedAcquisition(of call: CallSite) -> (name: String, kind: Int)? {
        for (index, kind) in kinds.enumerated() {
            switch kind.holds {
            case .result:
                continue
            case .receiver:
                guard kind.acquire.contains(call.last), !call.base.isEmpty else { continue }
                let receiver = Self.simpleName(call.base)
                guard let receiver else { return nil }
                return (receiver, index)
            case .firstArgument:
                guard kind.acquire.contains(call.callee), let first = call.arguments.first,
                    let name = SyntaxFacts.bareName(Self.unwrapped(first.expression))
                else { continue }
                return (name, index)
            }
        }
        return nil
    }

    /// `x`, or `self.x` as `x`; nil for a dotted path through another value.
    static func simpleName(_ base: String) -> String? {
        let name = base.hasPrefix("self.") ? String(base.dropFirst(5)) : base
        return name.isEmpty || name.contains(".") ? nil : name
    }

    static func unwrapped(_ expression: ExprSyntax) -> ExprSyntax {
        if let forced = expression.as(ForceUnwrapExprSyntax.self) { return forced.expression }
        return expression
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

        override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
            // Only a pair whose result is discarded: code that checks the result handles a failure the rule cannot
            // correlate with the release, so it is left alone.
            if Self.isStatement(node), let paired = rule.pairedAcquisition(of: CallSite(node: node)) {
                found.append(Acquisition(name: paired.name, kind: paired.kind, viaBinding: false))
            }
            return .visitChildren
        }

        /// A call that is a statement of its own, behind `try` or `await` at most.
        private static func isStatement(_ node: FunctionCallExprSyntax) -> Bool {
            var current = Syntax(node)
            while let parent = current.parent, parent.is(TryExprSyntax.self) || parent.is(AwaitExprSyntax.self) {
                current = parent
            }
            return current.parent?.is(CodeBlockItemSyntax.self) == true
                || current.parent?.is(ExpressionStmtSyntax.self) == true
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
        for leaked: Held, exit: Int, graph: ControlFlowGraph, states: [Set<Held>?], unit: FunctionUnit,
        reassigned: Bool = false
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
        case _ where reassigned: how = "is reassigned at line \(graph.nodes[exit].line)"
        case .exit(.threw): how = "throws at line \(lastNode?.line ?? 0)"
        case .exit(.returned): how = "returns at line \(lastNode?.line ?? 0)"
        default: how = "reaches its end"
        }
        let label = kinds[leaked.kind].label
        if kinds[leaked.kind].holds != .result {
            return Finding(
                rule: .leakOnExit, severity: severity, path: unit.path, line: site.line,
                column: site.syntax.map(unit.column(of:)) ?? 1,
                function: unit.name,
                message: "the \(label) on `\(leaked.name)` begun here is not ended when the function \(how)",
                witness: steps)
        }
        return Finding(
            rule: .leakOnExit, severity: severity, path: unit.path, line: site.line,
            column: site.syntax.map(unit.column(of:)) ?? 1,
            function: unit.name,
            message:
                "the \(label) `\(leaked.name)` acquired here is not closed, handed on or returned when "
                + (reassigned ? "it \(how)" : "the function \(how)"),
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
                if let name = SyntaxFacts.bareName(ResourceRule.unwrapped(argument.expression)) {
                    released.insert(name)
                }
            }
        } else if releaseMethods.contains(call.last), let receiver = ResourceRule.simpleName(call.base) {
            released.insert(receiver)
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
