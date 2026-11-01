# fcheck

Checks that Swift code keeps its obligations on **every path out of a function**, including the paths a `try` and a `defer` take.
The compiler, SwiftLint and the other analyzers ask whether code is well formed, unused, leaking references or copied. fcheck asks
whether a function that opens something closes it when a later step throws, whether replacing a file is durable, and whether text
is cut inside a character.

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

## What it checks

| Rule | The obligation |
| --- | --- |
| `leak-on-exit` | A descriptor or handle is closed, handed on or returned on every path out; a begun pair is ended. |
| `replace-not-durable` | A `rename` over a file comes after a flush of the bytes and before a flush of the directory. |
| `cut-then-decode` | Bytes cut at a count are not decoded in a way that splits a character. |

Every finding carries the path through the function that breaks the obligation, and says how sure it is. See [Rules](docs/rules.md).

## Install

Download an archive from the [releases](https://github.com/g-cqd/fcheck/releases), or build with Swift 6.4 on macOS 15 or later,
or Linux:

```sh
swift build -c release
cp .build/release/fcheck /usr/local/bin/
```

## Use

```sh
fcheck analyze Sources                       # diagnostics in Xcode's format, with the witness path as notes
fcheck analyze Sources --format sarif --strict
fcheck analyze Sources --rules leak-on-exit,replace-not-durable
fcheck explain replace-not-durable           # the obligation and the usual fix
```

`--baseline` and `--write-baseline` adopt a rule on code that already breaks it. `--only` and `--only-from` report some files of a
corpus that is still analyzed whole. Exit codes and reports are those of [the other analyzers](docs/README.md).

## Learn more

[User guide](docs/README.md): rules, configuration, suppression.

fcheck is one of a family of analyzers with the same options and reports:
[arcleak](https://github.com/g-cqd/arcleak), [deadwood](https://github.com/g-cqd/deadwood), [dolly](https://github.com/g-cqd/dolly)
and [modeler](https://github.com/g-cqd/modeler).

[MIT](LICENSE)
