# Privacy Policy

`fcheck` is an open-source Intra-procedural Swift obligation checker CLI for resource leaks, durable writes, and UTF-8 slicing, licensed under the MIT License.

## Offline Execution and Zero Network Access

- **100% offline:** `fcheck` makes **zero network connections** at runtime. It imports no networking frameworks and does not contact external APIs, license servers, or update endpoints.
- **No telemetry or analytics:** `fcheck` does not collect, store, or transmit usage telemetry, crash reports, source code snippets, or personal data.
- **No accounts or tracking:** `fcheck` requires no account, API key, or external service.

## Data Processed Locally

`fcheck` reads local source files, compiler index stores, and configuration/baseline files within the paths explicitly passed on the command line, and writes any requested reports or local caches solely to paths on the local filesystem controlled by the user or CI runner.

## GDPR and Enterprise Compliance

Because `fcheck` operates strictly offline on local inputs and transmits zero data off-host, no personal data or proprietary source code leaves the user's or organization's environment.

## Contact

For privacy or security inquiries, see [`SECURITY.md`](SECURITY.md).
