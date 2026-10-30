import ArgumentParser
import FCheckCore
import ProjectModel
import SystemPackage

struct Rules: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract:
            "The rules: id, shape, evidence level, severity, and what each checks; with an id, that rule explained.")

    @Argument(help: "A rule id: explain that rule, as `fcheck explain <id>` does.")
    var rule: String?

    func run() throws {
        if let rule {
            var explain = Explain()
            explain.rule = rule
            return try explain.run()
        }
        for rule in RuleID.allCases {
            write(
                "\(rule.rawValue)  [\(rule.shape), \(rule.evidence), \(rule.defaultSeverity.rawValue)]\n    \(rule.summary)\n",
                to: .standardOutput)
        }
    }
}

struct Explain: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "What a rule requires and how to satisfy it.")

    @Argument(help: "A rule id, from `fcheck rules`.")
    var rule: String = ""

    func run() throws {
        guard let found = RuleID(rawValue: rule) else {
            throw ValidationError("no rule named \(rule); `fcheck rules` lists them")
        }
        write(
            "\(found.rawValue)  [\(found.shape), \(found.evidence), \(found.defaultSeverity.rawValue)]\n\n\(found.explanation)\n",
            to: .standardOutput)
    }
}
