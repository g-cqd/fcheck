internal import SourceCorpus

extension Finding {
    /// A hash that identifies the finding across runs and machines: the rule, the path relative to the repository
    /// (or the absolute path outside one), the function and the message. Not the line, so moving code does not make
    /// a baselined finding new.
    public func fingerprint(root: String?) -> String {
        let shown = root.map { RepositoryRoot.relativize(path, to: $0) } ?? path
        return ContentFingerprint.of(Array("\(rule.rawValue)|\(shown)|\(function)|\(message)".utf8))
    }
}
