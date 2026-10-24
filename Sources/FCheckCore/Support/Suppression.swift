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
        var text = Substring(comment)
        for prefix in ["//", "/*"] where text.hasPrefix(prefix) { text = text.dropFirst(2) }
        if text.hasSuffix("*/") { text = text.dropLast(2) }
        text = text.drop(while: \.isWhitespace)
        while text.last?.isWhitespace == true { text = text.dropLast() }
        guard text.hasPrefix("@") else { return nil }
        text = text.dropFirst()
        guard let namespace = namespaces.first(where: { text.hasPrefix($0) }) else { return nil }
        text = text.dropFirst(namespace.count)

        var reason: String?
        if let range = text.firstRange(of: "--") {
            var tail = text[range.upperBound...].drop(while: \.isWhitespace)
            while tail.last?.isWhitespace == true { tail = tail.dropLast() }
            reason = String(tail)
            text = text[..<range.lowerBound]
        }
        let parts = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let verb = parts.first else { return nil }
        let kind: Kind
        switch verb {
        case "accept": kind = .accept
        case "accept:this": kind = .acceptThis
        case "accept:next": kind = .acceptNext
        case "disable": kind = .disable
        case "enable": kind = .enable
        default: return nil
        }
        let words = parts.dropFirst().flatMap { $0.split(separator: ",").map(String.init) }
        if words.isEmpty || words.contains("all") {
            return Directive(rules: [], kind: kind, line: line, reason: reason)
        }
        let rules = words.compactMap(RuleID.init(rawValue:))
        guard !rules.isEmpty else { return nil }
        return Directive(rules: rules, kind: kind, line: line, reason: reason)
    }

    /// Every directive in the comments of `tree`, in source order.
    static func scan(_ tree: SourceFileSyntax, converter: SourceLocationConverter) -> [Directive] {
        var found: [Directive] = []
        for token in tree.tokens(viewMode: .sourceAccurate) {
            var offset = token.position
            for piece in token.leadingTrivia {
                collect(piece, at: offset, converter, into: &found)
                offset = offset.advanced(by: piece.sourceLength.utf8Length)
            }
            offset = token.endPositionBeforeTrailingTrivia
            for piece in token.trailingTrivia {
                collect(piece, at: offset, converter, into: &found)
                offset = offset.advanced(by: piece.sourceLength.utf8Length)
            }
        }
        return found
    }

    private static func collect(
        _ piece: TriviaPiece, at offset: AbsolutePosition, _ converter: SourceLocationConverter,
        into found: inout [Directive]
    ) {
        let text: String
        switch piece {
        case .lineComment(let comment), .blockComment(let comment), .docLineComment(let comment),
            .docBlockComment(let comment):
            text = comment
        default:
            return
        }
        if let directive = parse(comment: text, line: converter.location(for: offset).line) { found.append(directive) }
    }
}

/// Answers whether a finding is suppressed, for one file's directives.
public struct SuppressionTable: Sendable {
    private let directives: [Directive]

    public init(directives: [Directive]) {
        self.directives = directives.sorted { $0.line < $1.line }
    }

    /// The reason of the directive that suppresses `rule` at `line` (`.some(nil)` when it gave none); nil when the
    /// finding stands.
    public func suppression(of rule: RuleID, at line: Int) -> String?? {
        var disabled = false
        var disabledReason: String?
        for directive in directives where directive.covers(rule) {
            switch directive.kind {
            case .acceptThis where directive.line == line: return .some(directive.reason)
            case .acceptNext where directive.line == line - 1: return .some(directive.reason)
            case .accept where directive.line == line || directive.line == line - 1: return .some(directive.reason)
            case .disable where directive.line <= line:
                disabled = true
                disabledReason = directive.reason
            case .enable where directive.line <= line:
                disabled = false
                disabledReason = nil
            default: break
            }
        }
        return disabled ? .some(disabledReason) : nil
    }
}
