import SwiftSyntax

/// One function, initializer or accessor body, with what a rule needs to report on it.
struct FunctionUnit {
    /// `Type.name(labels:)`, or `name(labels:)` outside a type.
    let name: String
    /// The name without the type or the labels, which is how callers name it.
    let simpleName: String
    let statements: CodeBlockItemListSyntax
    let converter: SourceLocationConverter
    let path: String
    /// The type that encloses the function, if any.
    let typeName: String?

    func line(of syntax: some SyntaxProtocol) -> Int {
        converter.location(for: syntax.positionAfterSkippingLeadingTrivia).line
    }

    func column(of syntax: some SyntaxProtocol) -> Int {
        converter.location(for: syntax.positionAfterSkippingLeadingTrivia).column
    }
}

/// What the members of each type are assigned in the type's own methods, for a rule that must follow a value from a
/// member back to where it was cut or filled.
struct MemberDefinitions {
    struct Definition {
        let expression: ExprSyntax
        /// The method the assignment is in, whose locals the expression may refer to.
        let statements: CodeBlockItemListSyntax
    }

    private(set) var byType: [String: [String: [Definition]]] = [:]

    mutating func add(_ definition: Definition, member: String, in type: String) {
        byType[type, default: [:]][member, default: []].append(definition)
    }
}

/// Finds every function body in a file.
final class UnitCollector: SyntaxVisitor {
    private(set) var units: [FunctionUnit] = []
    private(set) var definitions = MemberDefinitions()
    /// Every function name the file declares.
    private(set) var declared: Set<String> = []
    private var types: [String] = []
    private let converter: SourceLocationConverter
    private let path: String

    init(converter: SourceLocationConverter, path: String) {
        self.converter = converter
        self.path = path
        super.init(viewMode: .sourceAccurate)
    }

    static func collect(_ tree: SourceFileSyntax, converter: SourceLocationConverter, path: String)
        -> (units: [FunctionUnit], definitions: MemberDefinitions, declared: Set<String>)
    {
        let collector = UnitCollector(converter: converter, path: path)
        collector.walk(tree)
        return (collector.units, collector.definitions, collector.declared)
    }

    private func push(_ name: String) { types.append(name) }
    private func pop() { types.removeLast() }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        push(node.name.text); return .visitChildren
    }
    override func visitPost(_ node: StructDeclSyntax) { pop() }
    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        push(node.name.text); return .visitChildren
    }
    override func visitPost(_ node: ClassDeclSyntax) { pop() }
    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        push(node.name.text); return .visitChildren
    }
    override func visitPost(_ node: ActorDeclSyntax) { pop() }
    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        push(node.name.text); return .visitChildren
    }
    override func visitPost(_ node: EnumDeclSyntax) { pop() }
    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        push(node.extendedType.trimmedDescription)
        return .visitChildren
    }
    override func visitPost(_ node: ExtensionDeclSyntax) { pop() }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        let labels = node.signature.parameterClause.parameters.map { $0.firstName.text + ":" }.joined()
        declared.insert(node.name.text)
        add(node.name.text, labels: labels, statements: node.body?.statements)
        return .visitChildren
    }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        let labels = node.signature.parameterClause.parameters.map { $0.firstName.text + ":" }.joined()
        add("init", labels: labels, statements: node.body?.statements)
        return .visitChildren
    }

    override func visit(_ node: DeinitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        add("deinit", labels: "", statements: node.body?.statements)
        return .visitChildren
    }

    /// A computed property with only a getter has no `get` to visit: its statements are the accessor block.
    override func visit(_ node: PatternBindingSyntax) -> SyntaxVisitorContinueKind {
        if let name = node.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
            case .getter(let statements)? = node.accessorBlock?.accessors
        {
            add(name, labels: "", statements: statements, isProperty: true)
        }
        return .visitChildren
    }

    override func visit(_ node: AccessorDeclSyntax) -> SyntaxVisitorContinueKind {
        add(node.accessorSpecifier.text, labels: "", statements: node.body?.statements)
        return .visitChildren
    }

    private func add(_ name: String, labels: String, statements: CodeBlockItemListSyntax?, isProperty: Bool = false) {
        guard let statements else { return }
        let owner = types.last
        let full = (owner.map { $0 + "." } ?? "") + (isProperty ? name : "\(name)(\(labels))")
        units.append(
            FunctionUnit(
                name: full, simpleName: name, statements: statements, converter: converter, path: path, typeName: owner)
        )
        guard let owner else { return }
        for (member, expression) in AssignmentFinder.assignments(in: statements) {
            definitions.add(.init(expression: expression, statements: statements), member: member, in: owner)
        }
    }
}
