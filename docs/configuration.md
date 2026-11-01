# Configuration

fcheck reads `.fcheck.json`, or an `"fcheck"` section of the shared `.swift-analyzers.json`
([how files are found and merged](https://github.com/g-cqd/analyzerkit/blob/main/docs/analyzer-contract.md#configuration)).

```json
{
  "disable": ["cut-then-decode"],
  "severity": { "leak-on-exit": "error" },
  "resources": [
    { "label": "socket", "acquire": ["makeSocket"], "release": ["destroy"] }
  ],
  "flush": ["persist"],
  "exclude": ["/Generated/"]
}
```

A rule name the file does not know, or JSON that does not parse, fails the run. It never quietly turns a rule off.

| Key | |
| --- | --- |
| `disable` | Rules to turn off. |
| `severity` | A severity (`note`, `warning`, `error`) per rule. |
| `resources` | Your own acquire and release functions for `leak-on-exit`. |
| `flush` | Names of your own flush functions, for `replace-not-durable`. |
| `exclude` | Paths to leave out. |
| `includeRegions`, `excludeRegions` | Which code besides production is analyzed; shared, see [regions](https://github.com/g-cqd/analyzerkit/blob/main/docs/analyzer-contract.md#regions). Only production code is analyzed by default. |

## Your own resources

`holds` says what the acquiring call makes held:

| `holds` | The held thing is | Released by |
| --- | --- | --- |
| `result` (default) | the value the call returns | a release call or method on it, or handing it on by passing, storing or returning it |
| `receiver` | the name the call is made on (`x.begin()` … `x.end()`); give `acquire` and `release` as method names | its release only |
| `firstArgument` | the first argument (`lock(x, …)` … `unlock(x, …)`) | its release only |

A pair is followed only when its opening call is a statement of its own: code that checks the result handles a failure the rule
cannot tie to the release. A receiver reached through another value (`camera.session`) is not followed.

## Suppression

```swift
// @fc:accept leak-on-exit -- the caller closes it    (this line and the next)
// @fc:accept:this
// @fc:accept:next
// @fc:disable leak-on-exit
// @fc:enable
```

`@fcheck:` is the long form. A directive that names only rules fcheck does not know suppresses nothing.
