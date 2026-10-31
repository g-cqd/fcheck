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
        let locals = Self.table(AssignmentFinder.assignments(in: unit.statements))
        let members = unit.typeName.flatMap { definitions.byType[$0] } ?? [:]

        var findings: [Finding] = []
        for (decode, form) in decodes {
            guard let argument = decode.arguments.first?.expression,
                let cut = cut(in: argument, locals: locals, members: members, unit: unit, hops: 0)
            else { continue }
            let line = unit.line(of: decode.node)
            findings.append(
                Finding(
                    rule: .cutThenDecode, severity: severity, path: unit.path, line: line,
                    column: unit.column(of: decode.node), function: unit.name,
                    message: form.message(operation: cut.operation, line: cut.line),
                    witness: [
                        Finding.Step(line: cut.line, text: cut.text),
                        Finding.Step(
                            line: line,
                            text: decode.node.trimmedDescription.split(separator: "\n").first.map(String.init) ?? ""),
                    ]))
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
        in expression: ExprSyntax, locals: [String: [ExprSyntax]], members: [String: [MemberDefinitions.Definition]],
        unit: FunctionUnit, hops: Int
    ) -> Cut? {
        let scan = CutScanner()
        // A value that went through a call that is not a view of the same bytes may have been cut at a boundary.
        if let call = SyntaxFacts.stripped(expression).as(FunctionCallExprSyntax.self),
            !Self.isTransparent(CallSite(node: call))
        {
            return nil
        }
        scan.walk(expression)
        if let operation = scan.operation {
            return Cut(
                operation: operation, line: unit.line(of: expression),
                text: expression.trimmedDescription.split(separator: "\n").first.map(String.init) ?? "")
        }
        guard hops < Self.maximumHops else { return nil }
        for name in scan.names {
            for definition in locals[name] ?? [] {
                if let found = cut(in: definition, locals: locals, members: members, unit: unit, hops: hops + 1) {
                    return found
                }
            }
            for definition in members[name] ?? [] {
                let inner = Self.table(AssignmentFinder.assignments(in: definition.statements))
                if let found = cut(
                    in: definition.expression, locals: inner, members: members, unit: unit, hops: hops + 1)
                {
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

    init() { super.init(viewMode: .sourceAccurate) }

    /// `prefix(n)` and `suffix(n)`: a window of n bytes. `prefix { … }` and `prefix(while:)` stop at a byte the caller
    /// chose, which is a boundary when it is a NUL or a newline, and `dropFirst` and `dropLast` usually remove a marker
    /// of known length, such as a byte-order mark.
    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if operation == nil, let access = node.calledExpression.as(MemberAccessExprSyntax.self) {
            let name = access.declName.baseName.text
            if ["prefix", "suffix"].contains(name),
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
            return !postfix.expression.is(IntegerLiteralExprSyntax.self)
        }
        if let prefix = expression.as(PrefixOperatorExprSyntax.self), ["..<", "..."].contains(prefix.operator.text) {
            return true
        }
        if let sequence = expression.as(SequenceExprSyntax.self) {
            let elements = Array(sequence.elements)
            if elements.count == 3,
                let firstInt = elements[0].as(IntegerLiteralExprSyntax.self), firstInt.literal.text == "0",
                let op = elements[1].as(BinaryOperatorExprSyntax.self)?.operator.text, ["..<", "..."].contains(op)
            {
                return true
            }
        }
        return false
    }

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        names.append(node.baseName.text)
        return .skipChildren
    }
}
