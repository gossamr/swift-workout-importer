# WorkoutImporter

[![Test](https://github.com/gossamr/swift-workout-importer/actions/workflows/test.yml/badge.svg)](https://github.com/gossamr/swift-workout-importer/actions/workflows/test.yml)
[![Swift 5.10](https://img.shields.io/badge/Swift-5.10-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-iOS%2017%20%7C%20macOS%2014-blue.svg)](https://swift.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![SwiftPM](https://img.shields.io/badge/SwiftPM-compatible-brightgreen.svg)](https://swift.org/package-manager/)

A Swift package that parses workout-history exports from popular tracker
apps into a vendor-neutral intermediate representation.

## Status

Currently supports:

- [x] Strong (CSV)
- [x] Hevy (CSV)
- [x] FitNotes (CSV)

Not currently planned:

- Jefit — Jefit's Terms of Use contain explicit no-reverse-engineering
  and no-derivative-works clauses with a "permit anyone else to" hook,
  and Jefit does not expose a sanctioned user-facing CSV export. Adding
  Jefit support would require either a written carve-out from Jefit, an
  official export feature, or clear precedent that processing
  user-extracted backup files falls outside the TOS. PRs that thread
  this needle are welcome; speculative implementations against the
  current TOS are not. Users wanting to migrate Jefit history can use
  third-party converters like `JeFit2Hevy` to convert through Hevy's
  format, which this package supports.

## Maintenance

Offered as-is. This is a hobby-scale project — updates land when the
maintainers feel like it, not on any schedule. Issues and pull
requests may sit indefinitely. If you need an actively-maintained
dependency with response-time guarantees, fork it.

## Requirements

- iOS 17 / macOS 14
- Swift 5.10

## Installation

Add as a Swift Package Manager dependency:

```swift
.package(url: "https://github.com/gossamr/swift-workout-importer.git", from: "0.1.0")
```

Then declare a target dependency on `WorkoutImporter`.

## What it does

Takes an export from a tracker app, validates the schema, groups
one-row-per-set data into `(session, exercise, set)` graphs, and hands
back a `ParsedImportPayload` of plain `Codable` structs. Downstream
consumers map exercise names to their own catalog and persist however
they like — this package never touches storage.

## Out of scope

- Match exercise names against a target catalog. Bring your own matcher.
- Persist anything. The output is in-memory `Codable` structs.
- Convert weight units. Each `ParsedSet` carries its source unit as a
  string (`weight: Double?, weightUnit: String?`); consumers map to their
  own typed unit system.
- Touch the network or any storage beyond reading the input file.

## Design principle

Most fields are plain `String` so consumers can map them into whatever
typed system they already have. Parsers validate their output against
documented canonical vocabularies, so consumers can rely on emitted
values without re-validating. The only typed field on the IR is
`ParsedImportPayload.sourceApp` since the package owns that concept.

## Usage

### Strong

Strong's CSV omits the weight unit, so the caller passes the assumed
unit (validated against `StrongCSVImporter.acceptedWeightUnits`):

```swift
import WorkoutImporter

let url: URL = ...
let payload = try StrongCSVImporter.parse(url: url, defaultWeightUnit: "lb")

for session in payload.sessions {
    print("\(session.title) — \(session.exercises.count) exercises")
    for exercise in session.exercises {
        print("  \(exercise.sourceName) [\(exercise.equipmentHint ?? "?")]"
              + " — \(exercise.sets.count) sets")
    }
}
```

### Hevy

Hevy's `weight_lbs` column is unambiguous, so no unit argument is needed:

```swift
let payload = try HevyCSVImporter.parse(url: url)
// Every set with a non-nil weight has weightUnit == "lb".
```

### Detection

Each parser exposes a cheap header sniff for routing:

```swift
if try StrongCSVImporter.detect(url: url) {
    // ...
} else if try HevyCSVImporter.detect(url: url) {
    // ...
} else if try FitNotesCSVImporter.detect(url: url) {
    // ...
}
```

### Per-row issues

Parse-time issues that don't prevent the file from being imported land
in `payload.warnings: [ImportWarning]` rather than thrown.
`ImportWarning` is an `enum` with associated values; cases:

| Case                            | Carries                                       |
| ------------------------------- | --------------------------------------------- |
| `.unparseableSessionDate`       | `sessionName: String?`, `raw: String`         |
| `.ambiguousWeightUnitsChoseKg`  | (no payload — FitNotes-specific)              |
| `.unknownDistanceUnit`          | `raw: String`                                 |
| `.unparseableTime`              | `raw: String`                                 |
| `.assumedDistanceUnit`          | `unit: String` (Strong-specific)              |
| `.unknownSetType`               | `raw: String`, `sessionName: String?`         |
| `.multipleLoggingPasses`        | `entries: [ImportWarning.MultiPassEntry]`     |

Callers format and localize the message; the importer doesn't produce
strings. Pattern-match with `if case`:

```swift
for warning in payload.warnings {
    switch warning {
    case let .unparseableSessionDate(name, raw):
        log.warn("Skipped session \(name ?? "?"): \(raw)")
    case let .multipleLoggingPasses(entries):
        log.info("Repeated within session: \(entries.map(\.exerciseName))")
    default:
        break
    }
}
```

### Errors

Each parser declares a typed error enum for unrecoverable conditions
(file unreadable, no rows, required columns missing, invalid caller
input). Per-row issues do not throw.

```swift
do {
    let payload = try StrongCSVImporter.parse(url: url, defaultWeightUnit: "lb")
} catch StrongCSVImporterError.missingRequiredColumns(let cols) {
    log.error("Bad Strong export: missing \(cols)")
} catch StrongCSVImporterError.noRows {
    log.error("Empty Strong export")
} catch StrongCSVImporterError.invalidWeightUnit(let unit) {
    log.error("Caller passed unsupported defaultWeightUnit: \(unit)")
}
```

## Canonical vocabularies

Parsers emit only values from these sets (or `nil`). Consumers can
exhaustively switch on these without a default-case fallback.

| Field                         | Vocabulary                                                                                           | Source                                            |
| ----------------------------- | ---------------------------------------------------------------------------------------------------- | ------------------------------------------------- |
| `ParsedSet.weightUnit`        | `"kg"`, `"lb"`                                                                                       | `StrongCSVImporter.acceptedWeightUnits`           |
| `ParsedExercise.equipmentHint`| `"barbell"`, `"dumbbell"`, `"kettlebell"`, `"cable"`, `"machine"`, `"smith"`, `"bodyweight"`, `"band"`, `"plate"` | `NameNormalizer.equipmentHints`                   |
| `ParsedSet.setType`           | `"normal"`, `"warmup"`, `"drop_set"`, `"failure"`                                                    | `HevyCSVImporter.canonicalSetTypes`               |
| `ParsedImportPayload.sourceApp` | `.strong`, `.hevy`, `.fitnotes` (typed enum — package owns this concept)                            | `ImportSourceApp`                                 |

Distance is always meters and duration is always seconds — no unit
field needed.

Unknown values from the source export coerce to `nil` and append a
deduplicated `ImportWarning` case to `payload.warnings`.

## Schema notes per app

### Strong

- One row per set. Exercise names are canonical with equipment in parens
  (`Squat (Barbell)`, `Bench Press (Smith Machine)`).
- No warmup flag, no superset, no RPE in the export — `setType`, `rpe`,
  and `supersetId` are always `nil` on Strong payloads.
- Weight unit is **not** carried in the export — caller passes
  `defaultWeightUnit`.
- `Duration` column is `HH:mm` workout-elapsed time, not a clock. The
  parser uses it to derive `endTime = startTime + duration` when
  present.
- The `Seconds` column is set duration (planks, runs, etc.) — not rest
  between sets. Strong tracks rest in-app but does not export it.

### Hevy

- One row per set. Hevy templates the unit into the weight/distance
  column header based on the user's app setting: `weight_lbs` +
  `distance_miles` for lb-mode, `weight_kg` + `distance_km` for kg-mode.
  The parser detects whichever pair is present and emits the matching
  `weightUnit` (`"lb"` or `"kg"`); distance always converts to meters
  at the IR boundary.
- `set_type` populates `setType` verbatim when in canonical vocabulary.
- `superset_id` populates `supersetId` (string) — exercises sharing a
  non-empty `supersetId` were performed as a superset.
- `rpe` optional, present only when the user enables RPE tracking.
- Timestamps are `d MMM yyyy, HH:mm` local time. Both unpadded
  (`28 Mar 2025`) and zero-padded (`01 Jan 2025`) day-of-month forms
  parse.
- `description` (workout-level) and `exercise_notes` (per-exercise) are
  repeated on every set row of their scope; the parser de-duplicates
  while preserving first-seen order.
- `duration_seconds` is per-set duration, not rest between sets. Hevy
  tracks rest in-app but does not export it.
- When the same `exercise_title` appears in one session with `set_index`
  resetting (e.g. `0,1,2,0,1,2`), the parser splits into separate
  `ParsedExercise` entries — one per monotonic run. Hevy has no native
  unilateral-side support; users log the exercise twice as a workaround.
  A single deduped `.multipleLoggingPasses` warning is emitted per file.

### FitNotes

- One row per set. Exercise names are free text — users type whatever
  they like, no canonical naming convention. Most rows yield no
  `equipmentHint` (the normalizer can still surface one when the user
  happens to type a Strong-style name like `Squat (Barbell)`).
- Two weight columns (`Weight (kg)` and `Weight (lbs)`) are mutually
  exclusive in practice depending on the user's app preference. The
  parser reads kg first, falls back to lbs, and emits `weightUnit:
  "kg"` or `"lb"` accordingly. Both empty → bodyweight (`weight: nil`,
  `weightUnit: nil`). Both populated → kg wins and a single
  `.ambiguousWeightUnitsChoseKg` warning is emitted per file. Note the
  column header is `lbs` but the canonical vocabulary string is `"lb"`.
- `Distance Unit` is one of `m`, `km`, `cm`, `in`, `ft`, `yd`, `mi` —
  the parser converts to meters at the IR boundary. Unknown units coerce
  distance to nil with a deduplicated `.unknownDistanceUnit` warning per
  unique unknown value.
- `Time` is per-set duration in `HH:MM:ss` (2 colons) or `MM:ss` (1
  colon). Unparseable values coerce to nil with a deduplicated
  `.unparseableTime` warning; empty values are silently nil.
- No warmup flag, no superset, no RPE in the export — `setType`,
  `supersetId`, and `rpe` are always `nil` on FitNotes payloads.
- Dates are strict `yyyy-MM-dd`. FitNotes carries no time-of-day signal,
  so `startTime` is local midnight on the row's date and `endTime` is
  always nil. Per-row `Time` is set duration, not session length —
  FitNotes does not export workout-level duration.
- Rest between sets is **not** exported by FitNotes (the app tracks it
  in-app only).
- Sessions are grouped by `(Date, Category)` preserving first-seen
  order. Empty Category is its own bucket — empty rows on a given date
  do not merge with non-empty Category rows on that date. Session title
  is the Category value when non-empty, else `"Session"`.
- The `Category` value is preserved into `ParsedExercise.notes` as a
  prepended `"Category: <name>"` line (deduped within an exercise). The
  free-text `Notes` column content is appended below it per row.
- The `Kind` column encodes which fields are present (`"wr"`, `"dt"`,
  ...). The parser ignores it — the data columns are authoritative.
  `detect()` uses `Kind` as a fingerprint since neither Strong nor Hevy
  emits that column.

## Public utilities

The package exposes a couple of helpers that consumers writing their own
matcher or extending the parser set may find useful:

- `CSVReader` — RFC4180 CSV parser. Handles BOM, CRLF/LF, embedded
  commas in quoted fields, multiline quoted fields, and `""`-escaped
  quotes. No external dependencies.
- `NameNormalizer` — exercise-name canonicalization. `normalize(_:)`
  folds case + diacritics, treats parens content as tokens (so
  `Bench Press (Barbell)` → `bench press barbell`), and applies a
  synonym vocabulary (Nuzzo JSCR 2017 / 2021 phrase rewrites,
  compound-word collapses, singular/plural folds). `tokens(_:)` returns
  the stopword-filtered token set; `extractEquipmentHint(_:)`
  recognizes both Strong-style parens (`Squat (Barbell)`) and Hevy-style
  prefix forms (`Incline Dumbbell Bench Press`) plus common slang
  aliases (`DB`, `EZ Bar`). `applySynonyms(tokens:)` is exposed for
  callers that tokenize without going through `normalize`.

## Implementing a new parser

Conform to `WorkoutImportSource`:

```swift
public protocol WorkoutImportSource {
    static var sourceApp: ImportSourceApp { get }
    static var supportedContentTypes: [UTType] { get }
    static func detect(url: URL) throws -> Bool
    static func parse(url: URL) throws -> ParsedImportPayload
}
```

`detect(url:)` should be a cheap header sniff that never throws on a
malformed-but-readable file. `parse(url:)` may throw on unrecoverable
errors (file unreadable, no rows, required columns missing); per-row
issues should be appended to `payload.warnings` as typed `ImportWarning`
cases instead.

When emitting `setType`, `weightUnit`, or `equipmentHint`, validate
against the canonical vocabulary above. Unknown source values should
coerce to `nil` and add a single deduplicated `ImportWarning` per
unique unknown value.

Add a new case to `ImportSourceApp` (a `String`-`RawRepresentable`
enum so `Codable` emits the lower-case raw value).

## Trademarks and disclaimer

"Strong" is a trademark of Strong Fitness PTE. Ltd. "Hevy" is a
trademark of Hevy Studios S.L. "FitNotes" is a trademark of its
respective owners (Android: James Gay; iOS: Ginger Technologies Pte
Ltd). All other trademarks referenced in this package or its
documentation are the property of their respective owners.

This package is not affiliated with, endorsed by, or sponsored by any
of the app's data it parses. It operates exclusively on files that the user
has exported themselves through each app's official export feature. It
does not access any vendor servers, decompile any vendor application,
or reproduce any vendor's proprietary content. App names appear in
type names, documentation, and identifiers solely to describe what
data format each parser handles (nominative fair use).

Each parser's source file repeats this disclaimer in its header for
clarity. Users of this package are responsible for ensuring they have
the right to use any data they pass to it (typically their own
exported training history).

## License

MIT — see [LICENSE](LICENSE).
