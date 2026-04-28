# Contributing

Thanks for considering a contribution. This package parses workout-history
CSV exports from third-party tracker apps. The bar for contributions is
shaped by two unusual constraints: **legal posture** (we ship as MIT
under specific IP assumptions) and **architectural discipline** (the IR
must stay vendor-neutral so parsers compose).

## Before you start

For non-trivial changes, open an issue first and confirm scope. Bug
fixes and small improvements are welcome without prior discussion.

## What we accept

- New parsers conforming to `WorkoutImportSource`, provided the source
  app exposes a sanctioned user-facing export feature (see "Legal
  posture" below).
- Bug fixes in existing parsers, the IR, `CSVReader`, or
  `NameNormalizer`.
- Improved test coverage — especially edge cases drawn from real-world
  exports you've encountered.
- Documentation improvements.

## What we don't accept

- Decompilation, reverse-engineering, or any work derived from
  unpacking a vendor binary.
- Parsers for export paths the source app's TOS does not sanction.
  See the README's "Not currently planned" section for the canonical
  example (Jefit).
- Bundled vendor exercise catalogs or other proprietary content
  extracted from any source app's database.
- Real exports from your own (or anyone else's) account, even
  anonymized — see "Test fixtures" below.

## Legal posture

Every parser ships under three commitments:

1. It operates only on files the user exported themselves through the
   source app's official "Export" UI.
2. It does not access vendor servers, decompile vendor binaries, or
   reproduce vendor proprietary content.
3. The source app's name appears in code/docs solely to identify what
   format is being parsed (nominative fair use).

A new parser must preserve all three. If the source format requires
reverse-engineering or there's no sanctioned export path, the parser
is not a candidate for this package even if technically possible.

## Adding a new parser

1. **Add a case** to `ImportSourceApp` with a `displayName`.
2. **Implement** a new struct in `Sources/WorkoutImporter/Parsers/`
   conforming to `WorkoutImportSource`. Use `StrongCSVImporter` and
   `HevyCSVImporter` as templates — same docblock structure, same
   error-enum pattern, helpers at the bottom.
3. **Reuse** `CSVReader` for parsing and `NameNormalizer` for
   exercise-name normalization + equipment-hint extraction. Don't
   duplicate that logic.
4. **Validate** any string you emit into the IR against the canonical
   vocabulary documented on `ParsedSet` / `ParsedExercise`. Unknown
   source values coerce to `nil` and append a single deduplicated
   warning per unique unknown value.
5. **Add a trademark disclaimer** at the top of the parser file
   (4–6 lines): name the trademark holder, state no affiliation, name
   the sanctioned export path, repeat the no-server-access /
   no-decompilation posture.
6. **Tests + fixtures** — see below. Coverage parity with the existing
   parsers is the bar.
7. **Update the README** — flip the Status entry, add a schema-notes
   subsection paralleling Strong/Hevy/FitNotes, update the canonical
   vocabularies table if you introduce a new vocabulary.

## Test fixtures

**All fixture CSVs must be hand-crafted from publicly documented schema,
not exported from your own account.** This is the single hard rule.
Reasons:

- Most source-app TOSes restrict redistribution of "documents or
  information from this Application" beyond a single personal copy.
  Committing a real export breaches the user-side TOS even when
  anonymized.
- Hand-crafted fixtures stay focused on the assertions a test actually
  exercises. Real exports are noisy.

Fixture conventions:

- One "happy path" file (~10–20 rows) covering the common case.
- One "edge cases" file with BOM, multiline quoted notes, embedded
  commas in notes, blank cells in optional columns, and any vocabulary
  edges the parser handles (e.g. all recognized distance units).
- Verify any UTF-8 BOM with `od -c` after writing — text editors will
  silently strip it.

## Testing

```sh
swift test
```

CI runs on macOS 15 (Xcode 16). The package manifest is at `swift-tools-version: 5.10`; Xcode 16 builds
it without Swift 6 language mode. CI must pass before a PR can merge. Tests use Swift Testing (`import Testing`,
`@Suite`, `@Test`, `#expect`) — not XCTest.

## Style

- Public symbols carry docstrings. Type-level docstrings cover their
  fields; bare `public var`s and `public func`s get their own.
- File header comments explain why the file exists, not what each line
  does.
- No emojis in code or docstrings.
- Match existing patterns: error enum + struct + helpers-at-bottom.
- New parsers should mirror the structure of `HevyCSVImporter.swift`
  closely.

## Pull requests

- Reference the issue you're addressing in the PR description.
- Update `CHANGELOG.md` under an `[Unreleased]` section (add the
  section if it doesn't yet exist).
- Keep PRs focused — a parser PR should not also refactor the IR.
- Reviews happen on an as-we-feel-like-it basis. PRs may sit
  indefinitely; that's not a comment on quality. If a fix is urgent
  for you, fork the package and apply it locally.

## Code of Conduct

By participating, you agree to abide by the project's Code of Conduct
(see `CODE_OF_CONDUCT.md` once it lands, or default to the
[Contributor Covenant](https://www.contributor-covenant.org/) until
then).

## License

By contributing, you agree that your contributions will be licensed
under the project's MIT License.
