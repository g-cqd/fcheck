public import ProjectModel

/// A rule fcheck can report.
public enum RuleID: String, CaseIterable, Codable, Sendable {
    /// A handle that is acquired and not released, handed on or returned on some path out of the function.
    case leakOnExit = "leak-on-exit"
    /// A file replaced by a rename without its bytes, or its directory, having been flushed.
    case replaceNotDurable = "replace-not-durable"
    /// Bytes cut at a count and decoded as text, which splits a character that straddles the cut.
    case cutThenDecode = "cut-then-decode"

    /// The obligation's shape: what kind of promise the rule checks.
    public var shape: String {
        switch self {
        case .leakOnExit: "pairing"
        case .replaceNotDurable: "ordering"
        case .cutThenDecode: "bounds"
        }
    }

    /// How sure a finding is. L0 is path analysis on the function's control-flow graph, with no solver: exact for
    /// the paths it models, silent about the rest.
    public var evidence: String { "L0" }

    public var defaultSeverity: Severity { .warning }

    public var summary: String {
        switch self {
        case .leakOnExit: "a descriptor or handle is not closed, handed on or returned on some path out of the function"
        case .replaceNotDurable: "a rename replaces a file whose bytes, or whose directory, were not flushed"
        case .cutThenDecode: "bytes cut at a count are decoded as text, splitting a character that straddles the cut"
        }
    }

    /// What the rule says and how to satisfy it, for `fcheck explain`.
    public var explanation: String {
        switch self {
        case .leakOnExit:
            """
            When a function acquires a handle it must, on every path out (return, throw, end of body), close it, hand it \
            to something that owns it, or return it. The paths include the ones a `try` takes when it throws and the \
            ones a `defer` runs on.

            Acquisitions are `open`, `FileDescriptor.open`, `socket`, `dup`, `opendir`, `fopen` and the like, and any \
            function of the corpus that returns one. Handing on is passing the handle to a call that is not a plain \
            system call on it, storing it, or returning it. Add to the list in `.fcheck.json` under `resources`.

            A pair begun on a receiver or an argument is ended the same way, by its release only: \
            `session.beginConfiguration()` by `commitConfiguration()`, `device.lockForConfiguration()` by \
            `unlockForConfiguration()`, `CVPixelBufferLockBaseAddress(b, …)` by `CVPixelBufferUnlockBaseAddress(b, …)`. \
            Passing the receiver to a call does not end it. Configure more with `"holds": "receiver"` or \
            `"firstArgument"`. Fix: end it in a `defer` right after it begins.

            Fix: close it in a `defer` placed right after the acquisition, or close it in the branch that fails.
            """
        case .replaceNotDurable:
            """
            Replacing a file atomically is four steps in an order: write the new bytes, flush them, rename over the \
            old file, flush the directory. A rename of unflushed bytes can leave an empty or partial file after a crash. \
            A rename not followed by a directory flush can bring the old file back, which matters most where the file \
            holds a single-use token.

            A flush is `fsync`, `fdatasync`, `fcntl(_, F_FULLFSYNC)`, a `sync` method, or any call whose name contains \
            `flush`. Add names under `flush` in `.fcheck.json`.

            Fix: flush the descriptor before the rename, and the directory after it, or call the helper that does.
            """
        case .cutThenDecode:
            """
            `String(decoding: bytes.prefix(n), as: UTF8.self)` replaces an incomplete character at the cut with U+FFFD, \
            so valid text printed by a program is shown to a reader with replacement characters in it. The same holds for \
            a suffix and for any slice whose bounds are counts of bytes. `String(data:encoding: .utf8)`, \
            `String(bytes:encoding: .utf8)` and `String(s.utf16.prefix(n))` of such a cut return nil instead, so the \
            whole text is lost, usually behind a `?? ""`.

            Fix: move the cut back to a character boundary (a byte that is not `0b10xxxxxx`), or decode the whole \
            buffer and cut the string.
            """
        }
    }
}
