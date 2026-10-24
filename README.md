# fcheck

Checks that Swift code keeps its obligations on **every path out of a function**, including the paths a `try` and a
`defer` take. It answers a question the compiler, SwiftLint, swift-format, arcleak, deadwood and dolly do not: not
whether code is well formed, unused, leaking references or copied, but whether a function that opens something closes it
when a later step throws, whether a file replacement is durable, whether text is cut inside a character.

| Rule | Obligation | Shape |
| --- | --- | --- |
| `leak-on-exit` | a descriptor or handle (`open`, `FileDescriptor.open`, `socket`, `opendir`, `fopen`, and any function of the corpus that returns one) is closed, handed on or returned on every path out | pairing |
| `replace-not-durable` | a `rename` over a file comes after a flush of the bytes written and before a flush of the directory | ordering |
| `cut-then-decode` | `String(decoding: bytes.prefix(n), as: UTF8.self)` does not split a character at the cut | bounds |

Every finding carries the path through the function that breaks the obligation, as the lines it passes, and says how sure
it is (`L0`: path analysis on the function's control-flow graph; exact for the paths it models, silent about the rest).
SARIF output carries the path as a code flow.

```sh
fcheck analyze Sources                      # xcode-style diagnostics, notes for the witness path
fcheck analyze Sources --format sarif --strict
fcheck analyze Sources --rules leak-on-exit,replace-not-durable
fcheck rules                                # the catalogue
fcheck explain replace-not-durable          # the obligation and the usual fix
```

`--baseline FILE` and `--write-baseline FILE` adopt a rule on code that already breaks it; `--only FILE` and `--only-from`
report one file of a corpus that is still analysed whole; `--relative-to DIR` shortens paths; `--cache-path` and
`--no-cache` control the per-file cache, which is keyed by content, the configuration and the build of the tool. Flags,
exit codes (`0`; `1` with `--strict` on a warning or error; `64` for usage) and the report schema are the ones arcleak,
dolly and deadwood use.

## Configuration

`.fcheck.json`, or `--config FILE`:

```json
{ "disable": ["cut-then-decode"],
  "severity": { "leak-on-exit": "error" },
  "resources": [ { "label": "socket", "acquire": ["makeSocket"], "release": ["destroy"] } ],
  "flush": ["persist"],
  "exclude": ["/Generated/"],
  "includeTests": false }
```

A name the file does not know, or JSON that does not parse, fails the run; it never quietly turns a rule off. Test and
generated files are not analysed unless `includeTests` or `--include-tests` says so.

## Suppression

```swift
// @fc:accept leak-on-exit -- the caller closes it        this line and the next
// @fc:accept:this   // @fc:accept:next   // @fc:disable [rules] … // @fc:enable
```

`@fcheck:` is the long form. A directive that names only rules this version does not know suppresses nothing.

## What it found in ask

Run on ask at `9f5b040`, before its maintainers fixed what a model of the code had found:

- `SessionFile.begin` does not close the descriptor `writeExclusively` returns when `SessionLock.adopt` throws (leak-on-exit,
  found through the helper, which the tool learned acquires);
- `Compaction.clipped` and `OutputBuffer.text` cut bytes and decode them (cut-then-decode), both confirmed faults;
- `ProjectTrust.save` renames bytes it never flushed, and `AtomicFile.replace` does not flush the directory after its
  rename, in the store that holds a single-use token (replace-not-durable); both are still open on ask's `main`.

On ask's `main` it reports those two and nothing else. On arcleak, dolly, deadwood, analyzerkit, modeler, aemi, AemiJSON and
Keystone it reports nothing; on TerminalKit it reports one handled case (`PackedCell.character`, a prefix of a value's own
bytes), which a `// @fc:accept` would record.

## Limits

Syntactic: it has no types. A handle is recognised by the name of the call that acquires it, so a project's own
acquirer is found only when a function of the corpus returns what it acquired, or is named under `resources`. Handing a
handle to any call that is not a plain system call on it counts as handing it on, which favours silence over noise. A
value that went through another call before it was decoded is not followed. Closures and nested functions are not
entered as part of the function that contains them. `try?` results are followed only through `if let` and `guard let`.
The obligations that need an interleaving or arithmetic (`check-then-act`, `continuation-once`, `arith-trap`) are not built;
see `modeler`'s `docs/PROPOSAL-fcheck.md` for the plan.

## Develop

```sh
swift build --build-tests
swift test --skip-build
```

Swift 6.4, strict concurrency and strict memory safety, warnings as errors. The control-flow graph and its dataflow
solver are analyzerkit's `ControlFlow`; the corpus scan, the cache and the SARIF helpers are `SourceCorpus`, `CorpusScan`
and `ReportSupport`.
