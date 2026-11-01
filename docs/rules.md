# Rules

fcheck checks that a function keeps its obligations on every path out, including the paths a `try` and a `defer` take. Each finding
carries the path that breaks the obligation, as the lines it passes (SARIF output carries it as a code flow), and says how sure it
is. `L0` means path analysis on the function's control-flow graph: exact for the paths it models, silent about the rest.

`fcheck rules` lists the rules. `fcheck explain <rule>` (or `fcheck rules <rule>`) gives the obligation and the usual fix.

## `leak-on-exit`

A descriptor or handle is closed, handed on or returned on every path out. Handles come from `open`, `FileDescriptor.open`,
`socket`, `opendir`, `fopen`, and any function in the analyzed files that returns one. A pair begun on a receiver or an argument
(`session.beginConfiguration()`, `device.lockForConfiguration()`, `CVPixelBufferLockBaseAddress(b, …)`) is ended on every path out.

```swift
func size(of path: String) throws -> Int {
    let fd = open(path, O_RDONLY)
    try check(path)  // leak-on-exit: if this throws, `fd` is never closed
    var info = stat()
    fstat(fd, &info)
    close(fd)
    return Int(info.st_size)
}
```

## `replace-not-durable`

A `rename` over a file comes after a flush of the bytes written, and before a flush of the directory. Otherwise a crash can leave
the new name pointing at nothing.

## `cut-then-decode`

Bytes cut at a count are not decoded in a way that splits a character. `String(decoding: bytes.prefix(n), as: UTF8.self)` turns a
split character into U+FFFD. `String(data:encoding: .utf8)`, `String(bytes:encoding: .utf8)` and `String(s.utf16.prefix(n))` return
`nil` on a split character, losing the whole text.

## Limits

fcheck is syntactic and has no types.

- A handle is recognised by the name of the call that acquires it. A project's own acquirer is found when a function in the
  analyzed files returns what it acquired, or when it is declared under `resources`.
- Handing a handle to any call that is not a plain system call on it counts as handing it on. That favours silence over noise.
- A value that went through another call before it was decoded is not followed.
- Closures and nested functions are not entered as part of the function that contains them.
- `try?` results are followed only through `if let` and `guard let`.
