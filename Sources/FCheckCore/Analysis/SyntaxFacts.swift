import SwiftSyntax

/// A call and what a rule asks about it.
///
/// The names are read from the called expression's tokens once, when the call is found, so a chain of calls costs one
/// step per link. (They were the source text of the whole called expression, recomputed on every question: a SwiftUI
/// chain re-read everything before each link, which grew with the square of its length.)
struct CallSite {
    let node: FunctionCallExprSyntax

    /// The callee when it is a dotted name, as written without spaces: `open`, `Darwin.open`, `descriptor.close`,
    /// `.init`. Empty for any other called expression (a call's result, a subscript, a closure, `x?`), which no
    /// configured name matches.
    let callee: String

    /// The callee's last name: `close` in `descriptor.close`, and the member's name even when what precedes it is not a
    /// dotted name (`close` in `make().close`). Empty when the called expression has no name.
    let last: String

    /// The part of a dotted callee before its last name, empty for a bare call or when the callee is not dotted.
    let base: String

    init(node: FunctionCallExprSyntax) {
        self.node = node
        let called = node.calledExpression
        if let names = Self.dottedNames(called) {
            callee = names.joined(separator: ".")
            last = names.last ?? ""
            base = names.dropLast().joined(separator: ".")
        } else {
            callee = ""
            last = called.as(MemberAccessExprSyntax.self)?.declName.baseName.text ?? ""
            base = ""
        }
    }

    var arguments: [(label: String?, expression: ExprSyntax)] {
        node.arguments.map { ($0.label?.text, $0.expression) }
    }

    /// `a.b.c` as `["a", "b", "c"]`, `.c` as `["", "c"]`, or nil when the expression is not made of names alone. It
    /// stops at the first part that is not a name, so it never walks into the rest of a chain.
    private static func dottedNames(_ expression: ExprSyntax) -> [String]? {
        if let reference = expression.as(DeclReferenceExprSyntax.self) { return [reference.baseName.text] }
        if expression.is(SuperExprSyntax.self) { return ["super"] }
        if let specialized = expression.as(GenericSpecializationExprSyntax.self),
            let reference = specialized.expression.as(DeclReferenceExprSyntax.self)
        {
            return [
                reference.baseName.text
                    + specialized.genericArgumentClause.trimmedDescription.filter { !$0.isWhitespace }
            ]
        }
        guard let access = expression.as(MemberAccessExprSyntax.self) else { return nil }
        let name = access.declName.baseName.text
        guard let base = access.base else { return ["", name] }
        return dottedNames(base).map { $0 + [name] }
    }
}

/// Every call in a syntax subtree, closures included and nested functions not, in source order.
final class CallFinder: SyntaxVisitor {
    private(set) var calls: [CallSite] = []

    init() { super.init(viewMode: .sourceAccurate) }

    static func calls(in syntax: some SyntaxProtocol) -> [CallSite] {
        let finder = CallFinder()
        finder.walk(syntax)
        return finder.calls
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        calls.append(CallSite(node: node))
        return .visitChildren
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
}

/// What each name is assigned in a body: `let a = e`, `a = e`, `a += e`, `a.append(e)`, `a.append(contentsOf: e)`.
final class AssignmentFinder: SyntaxVisitor {
    private(set) var found: [(String, ExprSyntax)] = []

    init() { super.init(viewMode: .sourceAccurate) }

    static func assignments(in body: some SyntaxProtocol) -> [(String, ExprSyntax)] {
        let finder = AssignmentFinder()
        finder.walk(body)
        return finder.found
    }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        for binding in node.bindings {
            if let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                let value = binding.initializer?.value
            {
                found.append((name, value))
            }
        }
        return .visitChildren
    }

    override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
        let elements = Array(node.elements)
        guard elements.count >= 3, let target = SyntaxFacts.memberOrLocal(elements[0]),
            elements[1].is(AssignmentExprSyntax.self)
                || (elements[1].as(BinaryOperatorExprSyntax.self)?.operator.text == "+=")
        else { return .visitChildren }
        found.append((target, elements.count == 3 ? elements[2] : ExprSyntax(node)))
        return .visitChildren
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if let access = node.calledExpression.as(MemberAccessExprSyntax.self), let base = access.base,
            ["append", "insert"].contains(access.declName.baseName.text), let target = SyntaxFacts.memberOrLocal(base),
            let first = node.arguments.first
        {
            found.append((target, first.expression))
        }
        return .visitChildren
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
}

enum SyntaxFacts {
    /// `expression` without the `try`, `await`, `unsafe` and parentheses around it.
    static func stripped(_ expression: ExprSyntax) -> ExprSyntax {
        var current = expression
        while true {
            if let wrapped = current.as(TryExprSyntax.self) {
                current = wrapped.expression
            } else if let wrapped = current.as(AwaitExprSyntax.self) {
                current = wrapped.expression
            } else if let wrapped = current.as(UnsafeExprSyntax.self) {
                current = wrapped.expression
            } else if let tuple = current.as(TupleExprSyntax.self), tuple.elements.count == 1,
                let only = tuple.elements.first, only.label == nil
            {
                current = only.expression
            } else {
                return current
            }
        }
    }

    /// The name when `expression` is a bare identifier, possibly `&name`, `try name` or `(name)`.
    static func bareName(_ expression: ExprSyntax) -> String? {
        var current = stripped(expression)
        if let inOut = current.as(InOutExprSyntax.self) { current = stripped(inOut.expression) }
        return current.as(DeclReferenceExprSyntax.self)?.baseName.text
    }

    /// The name an assignment target ultimately names: `name` or `self.name`.
    static func memberOrLocal(_ expression: ExprSyntax) -> String? {
        if let reference = expression.as(DeclReferenceExprSyntax.self) { return reference.baseName.text }
        if let access = expression.as(MemberAccessExprSyntax.self),
            access.base?.as(DeclReferenceExprSyntax.self)?.baseName.text == "self"
        {
            return access.declName.baseName.text
        }
        return nil
    }
}

/// The last name of every call in a file, sorted and unique, read from the called expression's last token.
final class CalledNames: SyntaxVisitor {
    private var names: Set<String> = []

    static func of(_ tree: some SyntaxProtocol) -> [String] {
        let visitor = CalledNames(viewMode: .sourceAccurate)
        visitor.walk(tree)
        return visitor.names.sorted()
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        let called = node.calledExpression
        if let reference = called.as(DeclReferenceExprSyntax.self) {
            names.insert(reference.baseName.text)
        } else if let access = called.as(MemberAccessExprSyntax.self) {
            names.insert(access.declName.baseName.text)
        } else if let specialized = called.as(GenericSpecializationExprSyntax.self),
            let reference = specialized.expression.as(DeclReferenceExprSyntax.self)
        {
            names.insert(reference.baseName.text)
        }
        return .visitChildren
    }
}
