import SwiftSyntax

/// A call and what a rule asks about it.
struct CallSite {
    let node: FunctionCallExprSyntax

    /// The callee as written, without spaces: `Darwin.open`, `descriptor.close`.
    var callee: String { node.calledExpression.trimmedDescription.filter { !$0.isWhitespace } }

    /// The part after the last `.`.
    var last: String { callee.split(separator: ".").last.map(String.init) ?? callee }

    /// The part before the last `.`, empty for a bare call.
    var base: String {
        guard let dot = callee.lastIndex(of: ".") else { return "" }
        return String(callee[..<dot])
    }

    var arguments: [(label: String?, expression: ExprSyntax)] {
        node.arguments.map { ($0.label?.text, $0.expression) }
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
