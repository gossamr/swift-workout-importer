# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-04-28

### Added

- **Strong** CSV importer (`StrongCSVImporter`) — parses one-row-per-set
  exports, derives session `endTime` from the `Duration` column,
  validates a caller-provided `defaultWeightUnit` against the canonical
  `{"kg", "lb"}` vocabulary.
- **Hevy** CSV importer (`HevyCSVImporter`) — handles `set_type` /
  `superset_id` / `rpe`; auto-detects `weight_lbs`+`distance_miles`
  (lb-mode exports) vs `weight_kg`+`distance_km` (kg-mode exports) and
  emits the matching `weightUnit`; converts distance to meters at the
  IR boundary. Splits repeated exercises within a session (`set_index`
  resets, e.g. `0,1,2,0,1,2` — Hevy's de-facto unilateral workaround)
  into separate `ParsedExercise` entries, with one deduped per-file
  summary warning naming affected exercises. Dedup'd warnings on
  unknown `set_type` values.
- **FitNotes** CSV importer (`FitNotesCSVImporter`) — supports both
  `Weight (kg)` and `Weight (lbs)` columns, all seven `Distance Unit`
  values (`m`, `km`, `cm`, `in`, `ft`, `yd`, `mi`), `MM:ss` /
  `HH:MM:ss` time parsing, `(Date, Category)` session grouping.
- **Vendor-neutral IR** (`ParsedImportPayload`, `ParsedSession`,
  `ParsedExercise`, `ParsedSet`) — `Codable`, `Sendable`, string-based
  vocabularies for `weightUnit` / `equipmentHint` / `setType` so
  consumers map to their own typed unit systems.
- **`CSVReader`** — RFC4180 reader with BOM, CRLF/LF, multiline-quoted,
  and `""`-escape support. No external dependencies.
- **`NameNormalizer`** — exercise-name canonicalization plus
  equipment-hint extraction recognizing both Strong-style parens forms
  (`Squat (Barbell)`) and Hevy-style prefix forms
  (`Incline Dumbbell Bench Press`). Parens content is preserved as
  tokens so source-app disambiguators stay visible to downstream
  matching. Ships a synonym vocabulary with multi-word phrase rewrites
  sourced from Nuzzo's JSCR 2017 / 2021 nomenclature audits
  (arm/heel/knee curl, military/shoulder press → overhead press),
  compound-word collapses (push/pull/chin/sit + up → one word), and
  singular/plural + direction folds (biceps→bicep, triceps→tricep,
  forward→front). Common slang aliases included.
- **`WorkoutImportSource`** protocol — vendor-neutral parser contract
  for adding new importers.

[0.1.0]: https://github.com/gossamr/swift-workout-importer/releases/tag/0.1.0
