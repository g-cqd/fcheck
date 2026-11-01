import ProjectModel
import SwiftSyntax

/// `cut-then-decode`: `String(decoding: <bytes cut at a count>, as: UTF8.self)`, which turns a split character into
/// U+FFFD; `String(data:encoding: .utf8)`, `String(bytes:encoding: .utf8)` and `String(<utf8 or utf16 view cut>)`, which
/// return nil instead, so the whole text is lost (analyzerkit roadmap 0066).
///
/// The bytes are followed one hop at a time from the decoded expression to where they were made: a local or a
/// member of the same type, assigned an expression that takes a `prefix(n)` or `suffix(n)`. A value that passed through any other call is left alone, since that call may move the cut to a
/// boundary, and so is a function that handles UTF-8 boundaries itself (it names a continuation-byte mask, or validates).
/// A range slice is not followed: its bounds are usually where a scan stopped, not a count.
struct DecodeCutRule {
    private static let cuts: Set<String> = ["prefix", "suffix", "dropFirst", "dropLast"]
    private static let boundaryHandling = [
        "0x80", "0xC0", "0xBF", "0b10", "isContinuation", "unicodeScalars", "validatingUTF8", "String(validating",
    ]
    private static let maximumHops = 3

    /// What the function says about where its cuts fall.
    struct Boundaries {
        /// Variables a scan for a delimiter gave: `tab` in `guard let tab = record.firstIndex(of: 9)`. A slice that
        /// starts or stops at one is cut where the delimiter is, an ASCII byte, which no character straddles.
        var searched: Set<String> = []
        /// Variables that hold the length a call wrote into a buffer (`count` in `let count = read(fd, &buffer, size)`):
        /// the bytes end there, they were not cut.
        var filled: Set<String> = []
        /// What the function compared a prefix or a suffix with (`byteOrderMark` in `starts(with: byteOrderMark)`): removing
        /// as many bytes as it has removes the whole marker.
        var matched: Set<String> = []

        static func of(_ statements: some SyntaxProtocol) -> Boundaries {
            let finder = BoundaryFinder()
            finder.walk(statements)
            return Boundaries(searched: finder.searched, filled: finder.filled, matched: finder.matched)
        }
    }

    let severity: Severity

    init(configuration: Configuration) {
        severity = configuration.severity(of: .cutThenDecode)
    }

    func analyze(_ unit: FunctionUnit, definitions: MemberDefinitions) -> [Finding] {
        let decodes = CallFinder.calls(in: unit.statements).compactMap { call in Self.form(of: call).map { (call, $0) }
        }
        guard !decodes.isEmpty else { return [] }
        let text = unit.statements.description
        if Self.boundaryHandling.contains(where: text.contains) { return [] }
        let boundaries = Boundaries.of(unit.statements)
        let locals = Self.table(AssignmentFinder.assignments(in: unit.statements))
        let members = unit.typeName.flatMap { definitions.byType[$0] } ?? [:]

        var findings: [Finding] = []
        for (decode, form) in decodes {
            guard let argument = decode.arguments.first?.expression,
                let cut = cut(
                    in: argument,
                    locals: locals,
                    members: members,
                    boundaries: boundaries,
                    unit: unit,
                    hops: 0
                )
            else { continue }
            let line = unit.line(of: decode.node)
            findings.append(
                Finding(
                    rule: .cutThenDecode,
                    severity: severity,
                    path: unit.path,
                    line: line,
                    column: unit.column(of: decode.node),
                    function: unit.name,
                    message: form.message(operation: cut.operation, line: cut.line),
                    witness: [
                        Finding.Step(line: cut.line, text: cut.text),
                        Finding.Step(
                            line: line,
                            text: decode.node.trimmedDescription.split(separator: "\n").first.map(String.init) ?? ""
                        ),
                    ]
                )
            )
        }
        return findings
    }

    /// How a decode of cut bytes fails.
    private enum Form {
        /// `String(decoding:as: UTF8.self)`: the split character becomes U+FFFD.
        case replacing
        /// `String(data:encoding:)` or `String(bytes:encoding:)` with `.utf8`: nil.
        case optional(label: String)
        /// `String(<view>)` of a cut `utf8` or `utf16` view: nil.
        case view(encoding: String)

        func message(operation: String, line: Int) -> String {
            switch self {
            case .replacing:
                "`String(decoding:)` of bytes cut by `\(operation)` at line \(line): a character that straddles the cut becomes U+FFFD"
            case .optional(let label):
                "`String(\(label):encoding:)` of bytes cut by `\(operation)` at line \(line): a character that straddles the cut makes it nil, and the whole text is lost"
            case .view(let encoding):
                "`String(_:)` of \(encoding) code units cut by `\(operation)` at line \(line): a character split at the cut makes it nil, and the whole text is lost"
            }
        }
    }

    private static func form(of call: CallSite) -> Form? {
        guard call.callee == "String" else { return nil }
        let arguments = call.arguments
        if arguments.count >= 2, arguments[0].label == "decoding", arguments[1].label == "as",
            arguments[1].expression.trimmedDescription.contains("UTF8")
        {
            return .replacing
        }
        if arguments.count == 2, let label = arguments[0].label, ["data", "bytes"].contains(label),
            arguments[1].label == "encoding", arguments[1].expression.trimmedDescription.hasSuffix("utf8")
        {
            return .optional(label: label)
        }
        if arguments.count == 1, arguments[0].label == nil {
            let text = arguments[0].expression.trimmedDescription
            if text.contains(".utf16") { return .view(encoding: "UTF-16") }
            if text.contains(".utf8") { return .view(encoding: "UTF-8") }
        }
        return nil
    }

    /// Calls that hand back the same bytes, or a view of them, so a cut inside them is still a cut.
    private static let transparent: Set<String> = [
        "Array", "ArraySlice", "ContiguousArray", "Data", "map", "filter", "reversed", "prefix", "suffix", "dropFirst",
        "dropLast", "lazy", "utf8", "bytes", "compactMap", "joined", "String", "Substring",
    ]

    private static func isTransparent(_ call: CallSite) -> Bool { transparent.contains(call.last) }

    private static func table(_ pairs: [(String, ExprSyntax)]) -> [String: [ExprSyntax]] {
        Dictionary(pairs.map { ($0.0, [$0.1]) }, uniquingKeysWith: +)
    }

    private struct Cut {
        let operation: String
        let line: Int
        let text: String
    }

    private func cut(
        in expression: ExprSyntax,
        locals: [String: [ExprSyntax]],
        members: [String: [MemberDefinitions.Definition]],
        boundaries: Boundaries,
        unit: FunctionUnit,
        hops: Int
    ) -> Cut? {
        let scan = CutScanner(boundaries: boundaries)
        // A value that went through a call that is not a view of the same bytes may have been cut at a boundary.
        if let call = SyntaxFacts.stripped(expression).as(FunctionCallExprSyntax.self),
            !Self.isTransparent(CallSite(node: call))
        {
            return nil
        }
        scan.walk(expression)
        if let operation = scan.operation {
            return Cut(
                operation: operation,
                line: unit.line(of: expression),
                text: expression.trimmedDescription.split(separator: "\n").first.map(String.init) ?? ""
            )
        }
        guard hops < Self.maximumHops else { return nil }
        for name in scan.names {
            for definition in locals[name] ?? [] {
                if let found = cut(
                    in: definition,
                    locals: locals,
                    members: members,
                    boundaries: boundaries,
                    unit: unit,
                    hops: hops + 1
                ) {
                    return found
                }
            }
            for definition in members[name] ?? [] {
                let inner = Self.table(AssignmentFinder.assignments(in: definition.statements))
                if let found = cut(
                    in: definition.expression,
                    locals: inner,
                    members: members,
                    boundaries: boundaries,
                    unit: unit,
                    hops: hops + 1
                ) {
                    return found
                }
            }
        }
        return nil
    }
}

/// What an expression cuts, and which names it reads.
private final class CutScanner: SyntaxVisitor {
    private(set) var operation: String?
    private(set) var names: [String] = []

    private let boundaries: DecodeCutRule.Boundaries

    init(boundaries: DecodeCutRule.Boundaries) {
        self.boundaries = boundaries
        super.init(viewMode: .sourceAccurate)
    }

    /// Whether `bound` mentions a variable a scan for a delimiter gave.
    private func isSearched(_ bound: ExprSyntax) -> Bool {
        let mentions = NameCollector()
        mentions.walk(bound)
        return !boundaries.searched.isDisjoint(with: mentions.names)
            || !boundaries.filled.isDisjoint(with: mentions.names)
    }

    /// Whether `argument` is, or converts, the length a call returned for the bytes it wrote.
    private func isFilledLength(_ argument: ExprSyntax) -> Bool {
        let mentions = NameCollector()
        mentions.walk(argument)
        return !boundaries.filled.isDisjoint(with: mentions.names)
    }

    /// `n.count` where `n` was matched as a prefix or suffix: the length of a marker that is there.
    private func isMatchedMarkerLength(_ argument: ExprSyntax) -> Bool {
        guard let access = argument.as(MemberAccessExprSyntax.self), access.declName.baseName.text == "count",
            let base = access.base
        else { return false }
        return boundaries.matched.contains(base.trimmedDescription.filter { !$0.isWhitespace })
    }

    /// `prefix(n)` and `suffix(n)`: a window of n bytes. `prefix { … }` and `prefix(while:)` stop at a byte the caller
    /// chose, which is a boundary when it is a NUL or a newline, and `dropFirst` and `dropLast` usually remove a marker
    /// of known length, such as a byte-order mark.
    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if operation == nil, let access = node.calledExpression.as(MemberAccessExprSyntax.self) {
            let name = access.declName.baseName.text
            if let first = node.arguments.first,
                isMatchedMarkerLength(first.expression) || isFilledLength(first.expression)
            {
                // Removes or keeps the marker the function just matched, or ends where the buffer's fill ends: whole characters.
            } else if ["prefix", "suffix"].contains(name),
                node.trailingClosure == nil, let first = node.arguments.first, first.label?.text != "while"
            {
                operation = name
            } else if ["dropFirst", "dropLast"].contains(name),
                node.trailingClosure == nil, let first = node.arguments.first,
                !first.expression.is(IntegerLiteralExprSyntax.self)
            {
                operation = name
            }
        }
        return .visitChildren
    }

    override func visit(_ node: SubscriptCallExprSyntax) -> SyntaxVisitorContinueKind {
        if operation == nil, let first = node.arguments.first?.expression, isCountSlice(first) {
            operation = "subscript"
        }
        return .visitChildren
    }

    /// Whether an expression is a range cut at a byte count: `n...`, `..<n`, `...n`, `0..<n`, or `0...n`.
    /// A two-sided range `s..<e` where `s` is not 0 is left alone (its bounds are usually where a scan stopped).
    private func isCountSlice(_ expression: ExprSyntax) -> Bool {
        if let postfix = expression.as(PostfixOperatorExprSyntax.self), postfix.operator.text == "..." {
            return !postfix.expression.is(IntegerLiteralExprSyntax.self) && !isSearched(postfix.expression)
        }
        if let prefix = expression.as(PrefixOperatorExprSyntax.self), ["..<", "..."].contains(prefix.operator.text) {
            return !isSearched(prefix.expression)
        }
        if let sequence = expression.as(SequenceExprSyntax.self) {
            let elements = Array(sequence.elements)
            if elements.count == 3,
                let firstInt = elements[0].as(IntegerLiteralExprSyntax.self), firstInt.literal.text == "0",
                let op = elements[1].as(BinaryOperatorExprSyntax.self)?.operator.text, ["..<", "..."].contains(op)
            {
                return !isSearched(elements[2])
            }
        }
        return false
    }

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        names.append(node.baseName.text)
        return .skipChildren
    }
}

/// The names an expression reads.
private final class NameCollector: SyntaxVisitor {
    private(set) var names: Set<String> = []

    init() { super.init(viewMode: .sourceAccurate) }

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        names.insert(node.baseName.text)
        return .skipChildren
    }
}

/// Where a function's cuts fall: the variables a delimiter scan gave, and the markers it matched.
private final class BoundaryFinder: SyntaxVisitor {
    private(set) var searched: Set<String> = []
    private(set) var filled: Set<String> = []
    private(set) var matched: Set<String> = []

    private static let scans: Set<String> = ["firstIndex", "lastIndex", "firstRange", "lastRange", "range"]
    private static let matches: Set<String> = ["starts", "hasPrefix", "hasSuffix"]
    private static let fillCalls: Set<String> = [
        "read", "pread", "recv", "recvfrom", "fread", "readlink", "proc_pidpath", "getcwd", "gethostname",
    ]

    init() { super.init(viewMode: .sourceAccurate) }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        for binding in node.bindings {
            if let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                let value = binding.initializer?.value
            {
                if Self.scans(value) { searched.insert(name) }
                if Self.fills(value) { filled.insert(name) }
            }
        }
        return .visitChildren
    }

    override func visit(_ node: OptionalBindingConditionSyntax) -> SyntaxVisitorContinueKind {
        if let name = node.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
            let value = node.initializer?.value, Self.scans(value)
        {
            searched.insert(name)
        }
        return .visitChildren
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        let call = CallSite(node: node)
        if Self.matches.contains(call.last), let first = node.arguments.first {
            matched.insert(first.expression.trimmedDescription.filter { !$0.isWhitespace })
        }
        return .visitChildren
    }

    /// Whether `expression` calls something that fills a buffer and returns how much.
    private static func fills(_ expression: ExprSyntax) -> Bool {
        CallFinder.calls(in: expression).contains { fillCalls.contains($0.last) }
    }

    /// Whether `expression` is, or calls, a search for a position.
    private static func scans(_ expression: ExprSyntax) -> Bool {
        CallFinder.calls(in: expression).contains { scans.contains($0.last) }
    }
}
