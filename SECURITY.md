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
