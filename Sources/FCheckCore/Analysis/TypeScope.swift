import SwiftSyntax

/// The types the names of one function have where the source says so: its parameters, `let x: T`, `let x = T(...)`,
/// `self` as the enclosing type, and a capitalised name as the type it names (roadmap 0025, F4).
struct TypeScope {
    private var types: [String: String] = [:]
    private var selfType: String?

    init() {}

    init(_ unit: FunctionUnit) {
        selfType = unit.typeName
        for parameter in unit.parameters {
            if let type = Self.normalized(parameter.type) { types[parameter.name] = type }
        }
        for (name, type) in Collector.locals(in: unit.statements) where types[name] == nil {
            types[name] = type
        }
    }

    /// The type of a call's base (`door`, `self`, `Store`), or nil when it is not known.
    func type(of base: String) -> String? {
        guard !base.isEmpty, !base.contains(".") else { return nil }
        if base == "self" { return selfType }
        if let known = types[base] { return known }
        return base.first?.isUppercase == true ? base : nil
    }

    static func lastComponent(_ type: String) -> Substring {
        type.split(separator: ".").last ?? Substring(type)
    }

    /// A nominal type's name without optionality, `some`/`any` or generic arguments; nil for tuples, functions,
    /// collections and other shapes.
    static func normalized(_ written: String) -> String? {
        var type = Substring(written)
        for prefix in ["inout ", "some ", "any ", "borrowing ", "consuming "] where type.hasPrefix(prefix) {
            type = type.dropFirst(prefix.count)
        }
        while let last = type.last, last == "?" || last == "!" { type = type.dropLast() }
        if let angle = type.firstIndex(of: "<") { type = type[..<angle] }
        guard let first = type.first, first.isLetter || first == "_",
            type.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." })
        else { return nil }
        return String(type)
    }

    /// `let x: T` and `let x = T(...)` in a body, nested functions and closures left out.
    private final class Collector: SyntaxVisitor {
        private(set) var found: [(String, String)] = []

        static func locals(in body: some SyntaxProtocol) -> [(String, String)] {
            let collector = Collector(viewMode: .sourceAccurate)
            collector.walk(body)
            return collector.found
        }

        override func visit(_ node: PatternBindingSyntax) -> SyntaxVisitorContinueKind {
            guard let name = node.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else {
                return .visitChildren
            }
            if let annotation = node.typeAnnotation, let type = TypeScope.normalized(annotation.type.trimmedDescription)
            {
                found.append((name, type))
            } else if let value = node.initializer?.value,
                let call = SyntaxFacts.stripped(value).as(FunctionCallExprSyntax.self),
                let reference = call.calledExpression.as(DeclReferenceExprSyntax.self),
                reference.baseName.text.first?.isUppercase == true
            {
                found.append((name, reference.baseName.text))
            }
            return .visitChildren
        }

        override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
        override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    }
}
