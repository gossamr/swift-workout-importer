//
//  StrongCSVImporter.swift
//  WorkoutImporter
//
//  Strong (https://www.strong.app) workout-history CSV → ParsedImportPayload.
//
//  "Strong" is a trademark of Strong Fitness PTE. Ltd. This file is not
//  affiliated with, endorsed by, or sponsored by Strong Fitness PTE. Ltd.
//  It parses CSV files exported by users through Strong's official export
//  feature; it does not access Strong's servers, decompile Strong's app,
//  or reproduce any of Strong's proprietary content.
//
//  Strong format (one row per set):
//      Date, Workout Name, Duration, Exercise Name, Set Order,
//      Weight, Reps, Distance, Seconds, Notes, Workout #
//
//  Notes:
//   - Units are NOT in the export — caller passes `defaultWeightUnit`
//     (one of "kg" or "lb").
//   - Distance unit is also missing — we assume meters and emit a warning.
//     (Strong rarely exports distance for lifting workouts.)
//   - Strong has no warmup flag, no superset_id, no RPE in CSV exports —
//     `setType` is always nil in the resulting `ParsedSet`.
//
//  Grouping: rows with the same `(Date, Workout Name)` form one
//  ParsedSession; within a session, rows with the same `Exercise Name`
//  form one ParsedExercise (preserving first-seen order).
//
//  Created by gossamr on 04/27/26.
//

import Foundation
import UniformTypeIdentifiers

/// Errors thrown by `StrongCSVImporter.parse(url:)`. Per-row issues
/// (skipped sessions, distance-unit assumptions) are appended to
/// `ParsedImportPayload.warnings` instead of thrown.
public enum StrongCSVImporterError: Error {
    /// Header was missing one or more of the required columns.
    case missingRequiredColumns([String])
    /// File parsed cleanly but contained zero data rows.
    case noRows
    /// A date string did not match any of the supported formats. Currently
    /// unused — date-parse failures land in `warnings` and skip the session.
    case unparseableDate(String)
    /// The `defaultWeightUnit` argument was not in `acceptedWeightUnits`.
    case invalidWeightUnit(String)
}

/// Parses workout-history CSVs exported by Strong (https://www.strong.app).
/// See the file header for trademark and IP posture.
public struct StrongCSVImporter: WorkoutImportSource {
    public static let sourceApp: ImportSourceApp = .strong
    public static let supportedContentTypes: [UTType] = [.commaSeparatedText]

    /// Canonical weight unit values accepted by `parse(url:defaultWeightUnit:)`.
    /// Must match the `weightUnit` vocabulary documented on `ParsedSet`.
    public static let acceptedWeightUnits: Set<String> = ["kg", "lb"]

    // We don't depend on the Workout-number column (its name varies across
    // Strong versions: "Workout #" vs "Workout No"), so it's not required.
    private static let requiredColumns = [
        "Date", "Workout Name", "Exercise Name", "Set Order"
    ]

    public static func detect(url: URL) throws -> Bool {
        // Cheap header sniff. Treat any read failure as "not ours".
        guard let rows = try? CSVReader.rows(from: url),
              let header = rows.first else { return false }
        let keys = Set(header.map { $0.trimmingCharacters(in: .whitespaces) })
        return requiredColumns.allSatisfy(keys.contains)
            && (keys.contains("Weight") || keys.contains("Reps"))
    }

    public static func parse(url: URL) throws -> ParsedImportPayload {
        return try parse(url: url, defaultWeightUnit: "lb")
    }

    /// Parse with an explicit assumed weight unit. Strong's export omits
    /// the unit entirely. Throws `invalidWeightUnit` if `defaultWeightUnit`
    /// is not in `acceptedWeightUnits`.
    public static func parse(url: URL, defaultWeightUnit: String) throws -> ParsedImportPayload {
        guard acceptedWeightUnits.contains(defaultWeightUnit) else {
            throw StrongCSVImporterError.invalidWeightUnit(defaultWeightUnit)
        }

        let dictRows = try CSVReader.dictRows(from: url)
        guard !dictRows.isEmpty else { throw StrongCSVImporterError.noRows }

        // Validate required columns.
        let presentKeys: Set<String> = dictRows.first.map { Set($0.keys) } ?? []
        let missing = requiredColumns.filter { !presentKeys.contains($0) }
        if !missing.isEmpty {
            throw StrongCSVImporterError.missingRequiredColumns(missing)
        }

        var warnings: [ImportWarning] = []
        var distanceWarningEmitted = false

        // Group by (date, workout name) preserving first-seen order.
        var sessionOrder: [String] = []
        var sessionRows: [String: [[String: String]]] = [:]

        for row in dictRows {
            let dateRaw = row["Date"]?.trimmingCharacters(in: .whitespaces) ?? ""
            let nameRaw = row["Workout Name"]?.trimmingCharacters(in: .whitespaces) ?? ""
            // Skip rows missing the grouping key (e.g. trailing blank line).
            if dateRaw.isEmpty && nameRaw.isEmpty { continue }
            let key = dateRaw + "|" + nameRaw
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
            let nameRaw = first["Workout Name"]?.trimmingCharacters(in: .whitespaces) ?? ""

            guard let startTime = parseDate(dateRaw) else {
                warnings.append(.unparseableSessionDate(
                    sessionName: nameRaw.isEmpty ? nil : nameRaw,
                    raw: dateRaw))
                continue
            }

            // Duration column is "HH:mm" (or empty). Use it to derive endTime.
            var endTime: Date? = nil
            if let durationRaw = first["Duration"]?.trimmingCharacters(in: .whitespaces),
               !durationRaw.isEmpty,
               let seconds = parseDurationHHMM(durationRaw) {
                endTime = startTime.addingTimeInterval(TimeInterval(seconds))
            }

            // Group exercise rows by Exercise Name preserving first-seen order.
            var exOrder: [String] = []
            var exRows: [String: [[String: String]]] = [:]
            for row in rows {
                let ex = row["Exercise Name"]?.trimmingCharacters(in: .whitespaces) ?? ""
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
                var exerciseNotes: [String] = []

                for row in setRows {
                    let setIndex = Int(row["Set Order"]?.trimmingCharacters(in: .whitespaces) ?? "") ?? (sets.count + 1)
                    let reps = nonZeroInt(row["Reps"])
                    let weight = nonZeroDouble(row["Weight"])
                    let weightUnit: String? = (weight != nil) ? defaultWeightUnit : nil

                    let distanceRaw = nonZeroDouble(row["Distance"])
                    if distanceRaw != nil && !distanceWarningEmitted {
                        warnings.append(.assumedDistanceUnit(unit: "meters"))
                        distanceWarningEmitted = true
                    }
                    let distance = distanceRaw // already meters per assumption

                    let durationSeconds = nonZeroInt(row["Seconds"])
                    let setNote = row["Notes"]?.trimmingCharacters(in: .whitespaces) ?? ""
                    if !setNote.isEmpty { exerciseNotes.append(setNote) }

                    sets.append(ParsedSet(
                        setIndex: setIndex,
                        setType: nil,                // Strong has no set_type column
                        reps: reps,
                        weight: weight,
                        weightUnit: weightUnit,
                        distance: distance,
                        durationSeconds: durationSeconds,
                        rpe: nil
                    ))
                }

                // Stable order by setIndex.
                sets.sort { $0.setIndex < $1.setIndex }

                let combinedNotes: String? = exerciseNotes.isEmpty ? nil : exerciseNotes.joined(separator: "\n")
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
                title: nameRaw,
                startTime: startTime,
                endTime: endTime,
                notes: nil,
                exercises: exercises
            ))
        }

        return ParsedImportPayload(
            sourceApp: .strong,
            sourceFilename: url.lastPathComponent,
            sessions: sessions,
            warnings: warnings
        )
    }

    // MARK: - Helpers

    /// Strong dates are typically `yyyy-MM-dd`; older exports occasionally
    /// use `MM/dd/yyyy`. Both are interpreted at local midnight.
    public static func parseDate(_ raw: String) -> Date? {
        let formats = ["yyyy-MM-dd", "MM/dd/yyyy"]
        for fmt in formats {
            let f = DateFormatter()
            f.dateFormat = fmt
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone.current
            if let d = f.date(from: raw) { return d }
        }
        return nil
    }

    /// "HH:mm" → total seconds. Returns nil for malformed input.
    public static func parseDurationHHMM(_ raw: String) -> Int? {
        let parts = raw.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        return h * 3600 + m * 60
    }

    private static func nonZeroInt(_ raw: String?) -> Int? {
        guard let s = raw?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        guard let v = Int(s) else { return nil }
        return v == 0 ? nil : v
    }

    private static func nonZeroDouble(_ raw: String?) -> Double? {
        guard let s = raw?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        guard let v = Double(s) else { return nil }
        return v == 0 ? nil : v
    }
}
