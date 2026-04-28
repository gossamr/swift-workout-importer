//
//  FitNotesCSVImporter.swift
//  WorkoutImporter
//
//  FitNotes (https://www.fitnotesapp.com) workout-history CSV → ParsedImportPayload.
//
//  "FitNotes" is a trademark of its respective owner (Android: James Gay;
//  iOS: Ginger Technologies Pte Ltd). This file is not affiliated with,
//  endorsed by, or sponsored by either FitNotes app vendor. It parses CSV
//  files exported by users through FitNotes's official "Export Workouts
//  to CSV" feature.
//
//  FitNotes format (one row per set, 11 columns):
//      Date, Exercise, Category, Weight (kg), Weight (lbs), Reps,
//      Distance, Distance Unit, Time, Notes, Kind
//
//  Notes:
//   - Weight columns are mutually exclusive in practice — the user's app
//     pref dictates which one is populated. We read kg first; if empty,
//     we read lbs. Both empty → bodyweight (`weight: nil`). Both
//     populated → choose kg, append a deduped warning per file. Note
//     the column header is "lbs" but our canonical vocabulary is "lb".
//   - Distance carries an explicit unit per row (m, km, cm, in, ft, yd,
//     mi). Unknown unit → `distance: nil` + a deduped warning per
//     unique unknown unit. Conversion to meters happens at the IR boundary.
//   - `Time` is `HH:MM:ss` or `MM:ss` (per-set duration, not rest). We
//     count colons to disambiguate. Malformed → nil + warning.
//   - `Kind` encodes which fields are present ("wr", "dt", ...) but the
//     data columns are authoritative. The parser ignores `Kind`; only
//     `detect()` uses it as a fingerprint.
//   - FitNotes carries no warmup flag, no superset_id, no RPE — `setType`,
//     `supersetId`, and `rpe` are always `nil` on FitNotes payloads.
//   - FitNotes carries no time-of-day signal. `startTime` is local
//     midnight on the row's date; `endTime` is always nil.
//
//  Grouping: rows with the same `(Date, Category)` form one
//  ParsedSession (preserving first-seen order). Empty Category is its own
//  bucket — empty rows on a date do NOT merge with non-empty Category
//  rows on the same date. Within a session, rows with the same
//  `Exercise` form one ParsedExercise (preserving first-seen order).
//
//  Created by gossamr on 04/27/26.
//

import Foundation
import UniformTypeIdentifiers

/// Errors thrown by `FitNotesCSVImporter.parse(url:)`. Per-row issues
/// (unknown distance units, unparseable times, both weight columns
/// populated) are appended to `ParsedImportPayload.warnings` instead.
public enum FitNotesCSVImporterError: Error {
    /// Header was missing one or more of the required columns.
    case missingRequiredColumns([String])
    /// File parsed cleanly but contained zero data rows.
    case noRows
}

/// Parses workout-history CSVs exported by FitNotes
/// (https://www.fitnotesapp.com). See the file header for trademark and
/// IP posture.
public struct FitNotesCSVImporter: WorkoutImportSource {
    public static let sourceApp: ImportSourceApp = .fitnotes
    public static let supportedContentTypes: [UTType] = [.commaSeparatedText]

    /// Distance unit values FitNotes emits. Unknown values coerce distance
    /// to nil with a deduplicated warning per unique unknown value.
    public static let recognizedDistanceUnits: Set<String> =
        ["m", "km", "cm", "in", "ft", "yd", "mi"]

    private static let requiredColumns = ["Date", "Exercise", "Reps"]

    public static func detect(url: URL) throws -> Bool {
        // Cheap header sniff. Treat any read failure as "not ours". The
        // `Kind` column is the strongest tell — neither Strong nor Hevy
        // emits it.
        guard let rows = try? CSVReader.rows(from: url),
              let header = rows.first else { return false }
        let keys = Set(header.map { $0.trimmingCharacters(in: .whitespaces) })
        let hasKey = keys.contains("Date") && keys.contains("Exercise") && keys.contains("Kind")
        let hasWeightCol = keys.contains("Weight (kg)") || keys.contains("Weight (lbs)")
        return hasKey && hasWeightCol
    }

    public static func parse(url: URL) throws -> ParsedImportPayload {
        let dictRows = try CSVReader.dictRows(from: url)
        guard !dictRows.isEmpty else { throw FitNotesCSVImporterError.noRows }

        // Validate required columns.
        let presentKeys: Set<String> = dictRows.first.map { Set($0.keys) } ?? []
        let missing = requiredColumns.filter { !presentKeys.contains($0) }
        if !missing.isEmpty {
            throw FitNotesCSVImporterError.missingRequiredColumns(missing)
        }

        var warnings: [ImportWarning] = []
        var unknownDistanceUnitsSeen: Set<String> = []
        var unparseableTimesSeen: Set<String> = []
        var bothWeightsWarningEmitted = false

        // Group rows by (Date, Category) preserving first-seen order. Empty
        // Category is its own bucket — we don't merge it with non-empty
        // Categories on the same date.
        var sessionOrder: [String] = []
        var sessionRows: [String: [[String: String]]] = [:]

        for row in dictRows {
            let dateRaw = row["Date"]?.trimmingCharacters(in: .whitespaces) ?? ""
            let categoryRaw = row["Category"]?.trimmingCharacters(in: .whitespaces) ?? ""
            // Skip rows missing the date entirely (e.g. trailing blank line).
            if dateRaw.isEmpty { continue }
            let key = dateRaw + "|" + categoryRaw
            if sessionRows[key] == nil {
                sessionOrder.append(key)
                sessionRows[key] = []
            }
            sessionRows[key]?.append(row)
        }

        var sessions: [ParsedSession] = []
        for key in sessionOrder {
            guard let rows = sessionRows[key], let first = rows.first else { continue }
            let dateRaw = first["Date"]?.trimmingCharacters(in: .whitespaces) ?? ""
            let categoryRaw = first["Category"]?.trimmingCharacters(in: .whitespaces) ?? ""

            guard let startTime = parseDate(dateRaw) else {
                warnings.append(.unparseableSessionDate(sessionName: nil, raw: dateRaw))
                continue
            }

            // Title: Category if non-empty, else "Session".
            let title = categoryRaw.isEmpty ? "Session" : categoryRaw

            // Group by Exercise preserving first-seen order.
            var exOrder: [String] = []
            var exRows: [String: [[String: String]]] = [:]
            for row in rows {
                let ex = row["Exercise"]?.trimmingCharacters(in: .whitespaces) ?? ""
                if ex.isEmpty { continue }
                if exRows[ex] == nil { exOrder.append(ex); exRows[ex] = [] }
                exRows[ex]?.append(row)
            }

            var exercises: [ParsedExercise] = []
            for exName in exOrder {
                guard let setRows = exRows[exName] else { continue }
                let hint = NameNormalizer.extractEquipmentHint(exName)
                let normalized = NameNormalizer.normalize(exName)

                var sets: [ParsedSet] = []
                // Per-row note bodies in row order (the user's `Notes` cell
                // contents). Adjacent identical entries collapse on join so
                // a copy-pasted note repeated across every set lands once.
                var rowNotes: [String] = []
                // Set of Category values seen on rows of this exercise. We
                // emit each distinct category as a single labeled line
                // ahead of the row notes, regardless of how many rows
                // carried it (the common case is "all rows on one
                // exercise share one category" → one labeled line).
                var seenCategories: [String] = []
                var setIndex = 0

                for row in setRows {
                    setIndex += 1

                    // Weight: prefer kg, fall back to lbs. Both populated →
                    // pick kg + a deduped warning per file.
                    let kgRaw = parseDouble(row["Weight (kg)"])
                    let lbsRaw = parseDouble(row["Weight (lbs)"])
                    let weight: Double?
                    let weightUnit: String?
                    if let kg = kgRaw, lbsRaw != nil {
                        if !bothWeightsWarningEmitted {
                            warnings.append(.ambiguousWeightUnitsChoseKg)
                            bothWeightsWarningEmitted = true
                        }
                        weight = kg
                        weightUnit = "kg"
                    } else if let kg = kgRaw {
                        weight = kg
                        weightUnit = "kg"
                    } else if let lbs = lbsRaw {
                        weight = lbs
                        weightUnit = "lb"
                    } else {
                        weight = nil
                        weightUnit = nil
                    }

                    let reps = parseInt(row["Reps"])

                    // Distance: convert to meters at the IR boundary using
                    // the unit column. Unknown unit → nil + deduped warning
                    // per unique unknown unit per file.
                    let distanceRaw = parseDouble(row["Distance"])
                    let distanceUnitRaw = row["Distance Unit"]?.trimmingCharacters(in: .whitespaces) ?? ""
                    let distance: Double?
                    if let d = distanceRaw, !distanceUnitRaw.isEmpty {
                        if let factor = metersFactor(for: distanceUnitRaw) {
                            distance = d * factor
                        } else {
                            distance = nil
                            if !unknownDistanceUnitsSeen.contains(distanceUnitRaw) {
                                unknownDistanceUnitsSeen.insert(distanceUnitRaw)
                                warnings.append(.unknownDistanceUnit(raw: distanceUnitRaw))
                            }
                        }
                    } else {
                        distance = nil
                    }

                    // Time: per-set duration. "HH:MM:ss" (2 colons) or
                    // "MM:ss" (1 colon). Empty silently nils. Malformed →
                    // nil + deduped warning per unique malformed value.
                    let timeRaw = row["Time"]?.trimmingCharacters(in: .whitespaces) ?? ""
                    let durationSeconds: Int?
                    if timeRaw.isEmpty {
                        durationSeconds = nil
                    } else if let parsed = parseTimeSeconds(timeRaw) {
                        durationSeconds = parsed
                    } else {
                        durationSeconds = nil
                        if !unparseableTimesSeen.contains(timeRaw) {
                            unparseableTimesSeen.insert(timeRaw)
                            warnings.append(.unparseableTime(raw: timeRaw))
                        }
                    }

                    // Track the row's Category for the labeled line emitted
                    // once below. We pull it from the row directly (rather
                    // than reusing the session's `categoryRaw`) so an
                    // exercise that somehow spans multiple categories on
                    // the same date — defensive — still surfaces them all.
                    let rowCategory = row["Category"]?.trimmingCharacters(in: .whitespaces) ?? ""
                    if !rowCategory.isEmpty && !seenCategories.contains(rowCategory) {
                        seenCategories.append(rowCategory)
                    }
                    let rowNote = row["Notes"] ?? ""
                    if !rowNote.isEmpty {
                        rowNotes.append(rowNote)
                    }

                    sets.append(ParsedSet(
                        setIndex: setIndex,
                        setType: nil,             // FitNotes has no warmup/dropset flag
                        reps: reps,
                        weight: weight,
                        weightUnit: weightUnit,
                        distance: distance,
                        durationSeconds: durationSeconds,
                        rpe: nil                  // FitNotes has no RPE column
                    ))
                }

                // Compose: one "Category: <name>" line per distinct category
                // (typically one), then per-row Notes bodies in row order.
                // Adjacent identical row-notes collapse so a copy-pasted
                // note repeated across every set lands once; non-adjacent
                // duplicates are preserved verbatim — that's a real signal,
                // however unlikely.
                var lines: [String] = []
                for cat in seenCategories {
                    lines.append("Category: \(cat)")
                }
                for note in rowNotes {
                    if lines.last != note {
                        lines.append(note)
                    }
                }
                let combinedNotes: String? = lines.isEmpty ? nil : lines.joined(separator: "\n")

                exercises.append(ParsedExercise(
                    sourceName: exName,
                    normalizedName: normalized,
                    equipmentHint: hint,
                    supersetId: nil,
                    notes: combinedNotes,
                    sets: sets
                ))
            }

            sessions.append(ParsedSession(
                title: title,
                startTime: startTime,
                endTime: nil,           // FitNotes has no workout-duration signal
                notes: nil,
                exercises: exercises
            ))
        }

        return ParsedImportPayload(
            sourceApp: .fitnotes,
            sourceFilename: url.lastPathComponent,
            sessions: sessions,
            warnings: warnings
        )
    }

    // MARK: - Helpers

    /// FitNotes dates are strict `yyyy-MM-dd`. Anything else returns nil;
    /// the caller appends a warning and skips the session.
    public static func parseDate(_ raw: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f.date(from: raw)
    }

    /// "HH:MM:ss" → total seconds (2 colons).
    /// "MM:ss"    → total seconds (1 colon).
    /// Anything else returns nil.
    public static func parseTimeSeconds(_ raw: String) -> Int? {
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        switch parts.count {
        case 2:
            guard let m = Int(parts[0]), let s = Int(parts[1]) else { return nil }
            return m * 60 + s
        case 3:
            guard let h = Int(parts[0]), let m = Int(parts[1]), let s = Int(parts[2]) else { return nil }
            return h * 3600 + m * 60 + s
        default:
            return nil
        }
    }

    /// Conversion factor (multiplier to meters) for a recognized FitNotes
    /// distance unit. Returns nil for unknown units.
    public static func metersFactor(for unit: String) -> Double? {
        switch unit {
        case "m":  return 1.0
        case "km": return 1000.0
        case "cm": return 0.01
        case "in": return 0.0254
        case "ft": return 0.3048
        case "yd": return 0.9144
        case "mi": return 1_609.344
        default:   return nil
        }
    }

    /// Trim and parse a non-empty cell as `Int`. Empty / non-numeric → nil.
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
