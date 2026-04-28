# Security policy

## Reporting a vulnerability

Please report security issues privately rather than opening a public
GitHub issue.

**Preferred channel:** open a [GitHub Security
Advisory](https://github.com/gossamr/swift-workout-importer/security/advisories/new)
(this stays private until we've coordinated a fix).

Please include:

- The package version (or commit SHA) you're reporting against.
- A description of the issue and its impact.
- A minimal reproduction (input file or test case if applicable).

This project is offered as-is and is not actively maintained on a
schedule. Reports will be looked at when the maintainers get to them;
no specific response time is promised. If you need an urgent fix,
forking and applying it yourself is faster than waiting.

## Scope

This package parses CSV files. The realistic threat surface is:

- **Resource exhaustion** from pathological input (very large rows,
  deeply nested or unbalanced quotes, etc.). `CSVReader` is a single
  pass with bounded per-character work; we still want to know about
  inputs that cause unbounded memory or CPU growth.
- **Logic errors** that misattribute data across rows (e.g. set bleed
  between exercises, weight-unit confusion). These can cascade into
  consumer apps and produce wrong stored history.

Out of scope:

- Issues in the source apps themselves (Strong, Hevy, FitNotes). Report
  those to the respective vendors.
- Issues in consumer apps that use this package. Report those to the
  consumer app maintainer.

## Supported versions

Pre-1.0 (`0.x.y`): only the latest minor version receives security
fixes. We will publish a note in `CHANGELOG.md` when a security-relevant
fix lands.

Post-1.0: TBD.
