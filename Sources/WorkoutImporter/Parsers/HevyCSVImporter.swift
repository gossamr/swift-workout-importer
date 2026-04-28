//
//  HevyCSVImporter.swift
//  WorkoutImporter
//
//  Hevy (https://www.hevyapp.com) workout-history CSV → ParsedImportPayload.
//
//  "Hevy" is a trademark of Hevy Studios S.L. This file is not affiliated
//  with, endorsed by, or sponsored by Hevy Studios S.L. It parses CSV
//  files exported by users through Hevy's official export feature; it
//  does not access Hevy's servers, decompile Hevy's app, or reproduce
//  any of Hevy's proprietary content. The single-copy-for-personal-use
//  carve-out in Hevy's TOS covers a user's own export.
//
//  Hevy format (one row per set, 14 columns):
//      title, start_time, end_time, description, exercise_title,
//      superset_id, exercise_notes, set_index, set_type,
//      <weight_lbs|weight_kg>, reps, <distance_miles|distance_km>,
//      duration_seconds, rpe
//
//  Notes:
//   - Hevy templates the weight/distance unit into the column header based
//     on the user's app setting: kg-mode exports `weight_kg` + `distance_km`;
//     lb-mode exports `weight_lbs` + `distance_miles`. The parser detects
//     whichever pair is present and emits the matching `weightUnit` string
//     ("kg" or "lb"). Distance is always converted to meters at the IR
//     boundary (1 mi = 1609.344 m exact; 1 km = 1000 m exact).
//   - `set_type` is passed through verbatim from Hevy's vocabulary
//     ("normal" | "warmup" | "drop_set" | "failure"). Unknown non-empty
//     values are coerced to nil and a single deduped warning is emitted
//     per unique unknown value.
//   - `set_index` is 0-indexed in Hevy and copied verbatim — downstream
//     consumers use it as a sort key, not a 1-indexed display value.
//   - When the same `exercise_title` appears in one session with `set_index`
//     that resets (e.g. 0,1,2,0,1,2), it is split into multiple
//     `ParsedExercise` entries — one per monotonic run. Hevy has no native
//     unilateral-side support; users log the exercise twice as a workaround.
//     We surface this honestly rather than fabricating left/right metadata.
//     A warning is emitted per unique repeated title.
//   - `rpe` is empty when the user hasn't enabled RPE tracking; pass-through.
//
//  Grouping: rows with the same `(title, start_time)` form one
//  ParsedSession; within a session, rows with the same `exercise_title`
//  form one ParsedExercise (preserving first-seen order). Sets are
//  defensively sorted by `set_index` ascending.
//
//  Created by gossamr on 04/27/26.
//

import Foundation
import UniformTypeIdentifiers

/// Errors thrown by `HevyCSVImporter.parse(url:)`. Per-row issues (unknown
/// `set_type`, unparseable timestamps) are appended to
/// `ParsedImportPayload.warnings` instead of thrown.
public enum HevyCSVImporterError: Error {
    /// Header was missing one or more of the required columns.
    case missingRequiredColumns([String])
    /// File parsed cleanly but contained zero data rows.
    case noRows
}

/// Parses workout-history CSVs exported by Hevy (https://www.hevyapp.com).
/// See the file header for trademark and IP posture.
public struct HevyCSVImporter: WorkoutImportSource {
    public static let sourceApp: ImportSourceApp = .hevy
    public static let supportedContentTypes: [UTType] = [.commaSeparatedText]

    /// Canonical `set_type` values Hevy emits. Anything outside this set is
    /// coerced to `nil` on `ParsedSet.setType` with a deduped warning.
    public static let canonicalSetTypes: Set<String> = ["normal", "warmup", "drop_set", "failure"]

    /// Conversion factor: 1 mile = 1609.344 meters (international mile, exact).
    public static let metersPerMile: Double = 1_609.344

    /// Conversion factor: 1 kilometer = 1000 meters (exact).
    public static let metersPerKilometer: Double = 1_000

    private static let requiredColumns = [
        "title", "start_time", "exercise_title", "set_index"
    ]

    public static func detect(url: URL) throws -> Bool {
        // Cheap header sniff. Treat any read failure as "not ours". The
        // unit-templated weight column (`weight_lbs` for lb-mode users,
        // `weight_kg` for kg-mode) is the giveaway that this is Hevy and
        // not Strong (Strong's column is just `Weight`). Either is fine.
        guard let rows = try? CSVReader.rows(from: url),
              let header = rows.first else { return false }
        let keys = Set(header.map { $0.trimmingCharacters(in: .whitespaces) })
        let baseKeys = ["title", "start_time", "exercise_title", "set_index"]
        let weightOK = keys.contains("weight_lbs") || keys.contains("weight_kg")
        return baseKeys.allSatisfy(keys.contains) && weightOK
    }

    public static func parse(url: URL) throws -> ParsedImportPayload {
        let dictRows = try CSVReader.dictRows(from: url)
        guard !dictRows.isEmpty else { throw HevyCSVImporterError.noRows }

        // Validate required columns.
        let presentKeys: Set<String> = dictRows.first.map { Set($0.keys) } ?? []
        let missing = requiredColumns.filter { !presentKeys.contains($0) }
        if !missing.isEmpty {
            throw HevyCSVImporterError.missingRequiredColumns(missing)
        }

        // Pick the weight + distance columns based on what the export
        // actually carries. Hevy templates the unit into the column name
        // (`weight_kg` vs `weight_lbs`, `distance_km` vs `distance_miles`)
        // and emits exactly one of each. If neither weight column is
        // present the parse continues with weight=nil for every set
        // (only reps/duration/distance survive); detect() should normally
        // catch this case earlier.
        let weightColumn: String?
        let weightUnit: String
        if presentKeys.contains("weight_kg") {
            weightColumn = "weight_kg"
            weightUnit = "kg"
        } else if presentKeys.contains("weight_lbs") {
            weightColumn = "weight_lbs"
            weightUnit = "lb"
        } else {
            weightColumn = nil
            weightUnit = "lb"  // unused
        }

        let distanceColumn: String?
        let distanceFactor: Double
        if presentKeys.contains("distance_km") {
            distanceColumn = "distance_km"
            distanceFactor = metersPerKilometer
        } else if presentKeys.contains("distance_miles") {
            distanceColumn = "distance_miles"
            distanceFactor = metersPerMile
        } else {
            distanceColumn = nil
            distanceFactor = 0  // unused
        }

        var warnings: [ImportWarning] = []
        // Dedup unknown set_type warnings: emit one per unique unknown value.
        var unknownSetTypesSeen: Set<String> = []
        // Aggregate hits across the whole file so we can emit one summary 
        // warning listing the affected exercises (rather than one warning
        // per session × name. Keyed by `exercise_title`, value is the number
        // of sessions in which the split fired for that name.
        var repeatedExerciseSessionCounts: [String: Int] = [:]

        // Group by (title, start_time) preserving first-seen order.
        var sessionOrder: [String] = []
        var sessionRows: [String: [[String: String]]] = [:]

        for row in dictRows {
            let titleRaw = row["title"]?.trimmingCharacters(in: .whitespaces) ?? ""
            let startRaw = row["start_time"]?.trimmingCharacters(in: .whitespaces) ?? ""
            // Skip rows missing the grouping key (e.g. trailing blank line).
            if titleRaw.isEmpty && startRaw.isEmpty { continue }
            let key = titleRaw + "|" + startRaw
            if sessionRows[key] == nil {
                sessionOrder.append(key)
                sessionRows[key] = []
            }
            sessionRows[key]?.append(row)
        }

        var sessions: [ParsedSession] = []
        for key in sessionOrder {
            guard let rows = sessionRows[key], let first = rows.first else { continue }
            let titleRaw = first["title"]?.trimmingCharacters(in: .whitespaces) ?? ""
            let startRaw = first["start_time"]?.trimmingCharacters(in: .whitespaces) ?? ""

            guard let startTime = parseDate(startRaw) else {
                warnings.append(.unparseableSessionDate(
                    sessionName: titleRaw.isEmpty ? nil : titleRaw,
                    raw: startRaw))
                continue
            }

            // end_time is optional; absent or unparseable → nil.
            var endTime: Date? = nil
            if let endRaw = first["end_time"]?.trimmingCharacters(in: .whitespaces),
               !endRaw.isEmpty,
               let parsed = parseDate(endRaw) {
                endTime = parsed
            }

            // Hevy repeats `description` on every row of the session — take
            // the first row's value verbatim. Note: not trimmed because
            // multi-line descriptions carry meaningful internal whitespace.
            let descriptionRaw = first["description"] ?? ""
            let sessionNotes: String? = descriptionRaw.isEmpty ? nil : descriptionRaw

            // Group by exercise_title preserving first-seen order.
            var exOrder: [String] = []
            var exRows: [String: [[String: String]]] = [:]
            for row in rows {
                let ex = row["exercise_title"]?.trimmingCharacters(in: .whitespaces) ?? ""
                if ex.isEmpty { continue }
                if exRows[ex] == nil { exOrder.append(ex); exRows[ex] = [] }
                exRows[ex]?.append(row)
            }

            var exercises: [ParsedExercise] = []
            for exName in exOrder {
                guard let setRows = exRows[exName] else { continue }
                let hint = NameNormalizer.extractEquipmentHint(exName)
                let normalized = NameNormalizer.normalize(exName)

                // superset_id: take the first non-empty value across set rows.
                // Hevy repeats it on every row of the exercise; defensive in
                // case any row is blank.
                var supersetId: String? = nil
                for row in setRows {
                    let raw = row["superset_id"]?.trimmingCharacters(in: .whitespaces) ?? ""
                    if !raw.isEmpty { supersetId = raw; break }
                }

                // exercise_notes: Hevy repeats the same string on every row
                // of an exercise. De-duplicate while preserving first-seen
                // order — different non-empty strings (rare) all appear.
                var notesSeen: Set<String> = []
                var notesOrdered: [String] = []
                for row in setRows {
                    let raw = row["exercise_notes"] ?? ""
                    if raw.isEmpty { continue }
                    if !notesSeen.contains(raw) {
                        notesSeen.insert(raw)
                        notesOrdered.append(raw)
                    }
                }
                let combinedNotes: String? = notesOrdered.isEmpty ? nil : notesOrdered.joined(separator: "\n")

                // Build sets in source order so we can detect set_index resets
                // (Hevy emits a separate run per repeated entry; see file-
                // header note on the unilateral workaround).
                var sets: [ParsedSet] = []
                for row in setRows {
                    // set_index: copy verbatim; fall back to current count if
                    // absent or non-numeric (defensive — Hevy always emits it).
                    let setIndex = Int(row["set_index"]?.trimmingCharacters(in: .whitespaces) ?? "") ?? sets.count

                    // set_type: validate against canonical vocabulary.
                    let setTypeRaw = row["set_type"]?.trimmingCharacters(in: .whitespaces) ?? ""
                    let setType: String?
                    if setTypeRaw.isEmpty {
                        setType = nil
                    } else if canonicalSetTypes.contains(setTypeRaw) {
                        setType = setTypeRaw
                    } else {
                        setType = nil
                        if !unknownSetTypesSeen.contains(setTypeRaw) {
                            unknownSetTypesSeen.insert(setTypeRaw)
                            warnings.append(.unknownSetType(
                                raw: setTypeRaw,
                                sessionName: titleRaw.isEmpty ? nil : titleRaw))
                        }
                    }

                    let weight = weightColumn.flatMap { parseDouble(row[$0]) }
                    let weightUnitStr: String? = (weight != nil) ? weightUnit : nil
                    let reps = parseInt(row["reps"])

                    // <distance_km|distance_miles> → meters at IR boundary.
                    let distance: Double? = distanceColumn.flatMap { col in
                        parseDouble(row[col]).map { $0 * distanceFactor }
                    }

                    let durationSeconds = parseInt(row["duration_seconds"])
                    let rpe = parseDouble(row["rpe"])

                    sets.append(ParsedSet(
                        setIndex: setIndex,
                        setType: setType,
                        reps: reps,
                        weight: weight,
                        weightUnit: weightUnitStr,
                        distance: distance,
                        durationSeconds: durationSeconds,
                        rpe: rpe
                    ))
                }

                // Split into monotonic runs of set_index. A run ends when the
                // next row's set_index is <= the previous row's, indicating a
                // re-log of the same exercise within the session — Hevy's
                // de-facto unilateral workaround. Each run becomes a separate
                // ParsedExercise so the committer doesn't see duplicate
                // setIndex values.
                //
                // ASSUMPTION (pending broader empirical verification): in real
                // Hevy exports, repeated `(session, exercise_title)` rows are
                // always grouped as adjacent monotonic runs (e.g. 0,1,2,0,1,2),
                // never interleaved (e.g. 0,0,1,1,2,2). The user-supplied
                // Clamshell sample confirms the run-based shape; second-side
                // ordering (left vs right) is NOT carried by the export, so
                // we don't fabricate it. If a future export shows interleaved
                // shape, the splitter falls back to one ParsedExercise (no
                // resets detected) and the committer's duplicate-setIndex
                // path applies.
                let runs = splitMonotonicRuns(sets)
                if runs.count > 1 {
                    repeatedExerciseSessionCounts[exName, default: 0] += 1
                }
                for runSets in runs {
                    var sortedRun = runSets
                    sortedRun.sort { $0.setIndex < $1.setIndex }
                    exercises.append(ParsedExercise(
                        sourceName: exName,
                        normalizedName: normalized,
                        equipmentHint: hint,
                        supersetId: supersetId,
                        notes: combinedNotes,
                        sets: sortedRun
                    ))
                }
            }

            sessions.append(ParsedSession(
                title: titleRaw,
                startTime: startTime,
                endTime: endTime,
                notes: sessionNotes,
                exercises: exercises
            ))
        }

        // One summary warning for all repeated-exercise splits across the
        // whole file. Sorted alphabetically by exercise name so the entry
        // order is stable across re-parses.
        if !repeatedExerciseSessionCounts.isEmpty {
            let entries = repeatedExerciseSessionCounts.keys.sorted().map { name in
                ImportWarning.MultiPassEntry(
                    exerciseName: name,
                    sessionCount: repeatedExerciseSessionCounts[name] ?? 0)
            }
            warnings.append(.multipleLoggingPasses(entries: entries))
        }

        return ParsedImportPayload(
            sourceApp: .hevy,
            sourceFilename: url.lastPathComponent,
            sessions: sessions,
            warnings: warnings
        )
    }

    // MARK: - Helpers

    /// Hevy timestamps are `"d MMM yyyy, HH:mm"` in local time, e.g.
    /// `"28 Mar 2025, 17:29"`. The day-of-month has no leading zero in
    /// exports we've seen, but we accept zero-padded `"dd MMM"` too for
    /// robustness against future format tweaks.
    public static func parseDate(_ raw: String) -> Date? {
        let formats = ["d MMM yyyy, HH:mm", "dd MMM yyyy, HH:mm"]
        for fmt in formats {
            let f = DateFormatter()
            f.dateFormat = fmt
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone.current
            if let d = f.date(from: raw) { return d }
        }
        return nil
    }

    /// Convert miles to meters using the international mile (exact).
    public static func milesToMeters(_ miles: Double) -> Double {
        return miles * metersPerMile
    }

    /// Split a set sequence into runs of monotonically-increasing setIndex.
    /// A new run starts whenever a set's setIndex is <= the previous set's,
    /// indicating Hevy emitted a repeated entry (see file-header note on
    /// the unilateral workaround). Strictly-increasing runs (the bilateral
    /// case) return a single-element outer array.
    static func splitMonotonicRuns(_ sets: [ParsedSet]) -> [[ParsedSet]] {
        var runs: [[ParsedSet]] = []
        var current: [ParsedSet] = []
        var lastIndex: Int? = nil
        for set in sets {
            if let prev = lastIndex, set.setIndex <= prev {
                runs.append(current)
                current = []
            }
            current.append(set)
            lastIndex = set.setIndex
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    /// Trim and parse a non-empty cell as `Int`. Empty / non-numeric → nil.
    /// Unlike Strong's `nonZeroInt`, we keep zero values: a Hevy `0` reps
    /// row is rare but legitimate (e.g. a marker set), and Hevy's exports
    /// don't pad empty fields with `0` the way Strong does.
    private static func parseInt(_ raw: String?) -> Int? {
        guard let s = raw?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        return Int(s)
    }

    /// Trim and parse a non-empty cell as `Double`. Empty / non-numeric → nil.
    private static func parseDouble(_ raw: String?) -> Double? {
        guard let s = raw?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        return Double(s)
    }
}
