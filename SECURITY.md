# Security Policy

## Scope and Trust Model

`fcheck` is a local, offline-first Swift tool.

- **Zero network access:** `fcheck` makes no outbound network requests and collects no telemetry.
- **No project code execution by default:** source files, `Package.swift`, and Xcode projects are read as data via `swift-syntax` without executing user code or build plugins.
- **Bounded inputs and verified toolchains:** file reads are size-capped, directory snapshots refuse symlinks, and external toolchain libraries/binaries are verified via `BinaryTrustChecker`.

## Supported Versions

Security fixes land on `main` and the latest tagged release. Pin a specific tag or revision and verify release checksums in CI.

## Reporting a Vulnerability

Report security concerns privately through [GitHub Security Advisories](https://github.com/g-cqd/fcheck/security/advisories/new). Do not include sensitive source code or credentials in public issues.

## Response targets (best-effort, solo maintainer)

This project is maintained by a single developer on a best-effort basis; the targets below are realistic guidelines
rather than contractual SLAs:

| Milestone | Best-effort target |
| --- | --- |
| Private acknowledgement | Within **7–14 days** |
| Initial triage & severity confirmation | Within **30 days** |
| Fix & advisory — **Critical** | Within **30 days** (sooner when actively exploited) |
| Fix & advisory — **High** | Within **60–90 days** |
| Fix — **Medium / Low** | Next scheduled release, as time permits |

Security fixes in released versions are published with a GitHub Security Advisory (and CVE identifier where applicable)
and named in the release notes.
## Release Verification & Supply-Chain Integrity

All commits and release tags are signed with GPG key `9FE7C7E8522EE497` (fingerprint: `1BF1 901A 8C67 2E9B C12E 1B31 9FE7 C7E8 522E E497`).

Verify a downloaded release archive and tag before use:

```sh
# 1. Verify the signed Git tag
git tag -v <tag>

# 2. Verify the SHA-256 checksum
shasum -a 256 -c <archive>.sha256

# 3. Verify the GitHub SLSA build provenance attestation (requires gh CLI)
gh attestation verify <archive> --owner g-cqd
```
