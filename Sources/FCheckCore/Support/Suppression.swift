import Suppression
import SwiftSyntax

/// One parsed `@fc:` or `@fcheck:` comment.
///
/// ```
/// // @fc:accept [rules] [-- reason]        this line and the next
/// // @fc:accept:this [rules] [-- reason]   this line only
/// // @fc:accept:next [rules] [-- reason]   the next line only
/// // @fc:disable [rules]                   from here to `enable`, or to the end of the file
/// // @fc:enable [rules]
/// ```
/// Rules are separated by commas or spaces; none, or `all`, means every rule. A directive that names only rules
/// this version does not know suppresses nothing.
public struct Directive: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case accept, acceptThis, acceptNext, disable, enable
    }

    /// Empty means every rule.
    public let rules: [RuleID]
    public let kind: Kind
    public let line: Int
    public let reason: String?

    public init(rules: [RuleID], kind: Kind, line: Int, reason: String?) {
        self.rules = rules
        self.kind = kind
        self.line = line
        self.reason = reason
    }

    func covers(_ rule: RuleID) -> Bool { rules.isEmpty || rules.contains(rule) }

    static let namespaces = ["fc:", "fcheck:"]

    /// The directive in `comment`, or nil when it is not one.
    static func parse(comment: String, line: Int) -> Directive? {
        guard let directive = grammar.parse(comment: comment, line: line, rule: RuleID.init(rawValue:)) else {
            return nil
        }
        return Self(
            rules: directive.rules, kind: Kind(shared: directive.kind), line: directive.line, reason: directive.reason)
    }

    private static let grammar = DirectiveGrammar(namespaces: namespaces)

    /// Every directive in comments, after analyzerkit's byte pre-filter, in source order.
    static func scan(_ tree: SourceFileSyntax, converter: SourceLocationConverter) -> [Directive] {
        grammar.scan(tree: tree, converter: converter, parse: parse)
    }

    fileprivate var shared: Suppression.Directive<RuleID> {
        Suppression.Directive(rules: rules, kind: kind.shared, line: line, reason: reason)
    }
}

extension Directive.Kind {
    fileprivate init(shared: DirectiveKind) {
        switch shared {
        case .accept: self = .accept
        case .acceptThis: self = .acceptThis
        case .acceptNext: self = .acceptNext
        case .regionDisable: self = .disable
        case .regionEnable: self = .enable
        }
    }
    fileprivate var shared: DirectiveKind {
        switch self {
        case .accept: .accept
        case .acceptThis: .acceptThis
        case .acceptNext: .acceptNext
        case .disable: .regionDisable
        case .enable: .regionEnable
        }
    }
}

/// Wire-compatible facade over analyzerkit's shared line/region suppression table.
public struct SuppressionTable: Sendable {
    private let table: Suppression.SuppressionTable<RuleID>
    public init(directives: [Directive]) {
        table = Suppression.SuppressionTable(directives: directives.map(\.shared))
    }
    /// nil: not suppressed; .some(nil): suppressed without a reason; .some(reason): suppressed with a reason.
    public func suppression(of rule: RuleID, at line: Int) -> String?? {
        table.suppression(for: rule, line: line)
    }
}
