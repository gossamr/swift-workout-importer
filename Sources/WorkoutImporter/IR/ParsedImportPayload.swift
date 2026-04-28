//
//  ParsedImportPayload.swift
//  WorkoutImporter
//
//  Vendor-neutral intermediate representation for imported workout history.
//  Parsers (Strong, Hevy, ...) produce these structs; downstream consumers
//  match exercise names to their catalog and persist to their own store.
//
//  Design principle: most fields are plain `String` so consumers can map
//  them into whatever typed system they already have (e.g. their own
//  `WeightUnit` enum). Parsers validate that emitted strings come from a
//  documented vocabulary; consumers can rely on that without re-validating.
//  The only typed field is `sourceApp` since the SPM owns that concept.
//
//  Created by gossamr on 04/27/26.
//

import Foundation

/// Top-level result of parsing one export file. Encodable so callers can
/// snapshot it for crash diagnostics or write it to a debug bundle.
public struct ParsedImportPayload: Codable, Sendable {
    public let sourceApp: ImportSourceApp
    public let sourceFilename: String
    public let sessions: [ParsedSession]
    public let warnings: [ImportWarning]

    public init(sourceApp: ImportSourceApp,
                sourceFilename: String,
                sessions: [ParsedSession],
                warnings: [ImportWarning] = []) {
        self.sourceApp = sourceApp
        self.sourceFilename = sourceFilename
        self.sessions = sessions
        self.warnings = warnings
    }
}

/// One reconstructed workout. Strong groups by `(Date, Workout Name)`;
/// Hevy by `(title, start_time)`. Order within `sessions` is the order
/// sessions appeared in the export (typically chronological).
public struct ParsedSession: Codable, Sendable, Identifiable {
    public let id: UUID
    public let title: String
    public let startTime: Date
    public let endTime: Date?
    public let notes: String?
    public let exercises: [ParsedExercise]

    public init(id: UUID = UUID(),
                title: String,
                startTime: Date,
                endTime: Date? = nil,
                notes: String? = nil,
                exercises: [ParsedExercise]) {
        self.id = id
        self.title = title
        self.startTime = startTime
        self.endTime = endTime
        self.notes = notes
        self.exercises = exercises
    }
}

/// One exercise within a session. `sourceName` is verbatim from the export
/// (e.g. `"Squat (Barbell)"`); `normalizedName` is pre-folded so downstream
/// matchers can hash/compare cheaply without re-running the normalizer.
///
/// `equipmentHint` is one of the canonical strings emitted by
/// `NameNormalizer.extractEquipmentHint(_:)`:
///
///     "barbell" | "dumbbell" | "kettlebell" | "cable" | "machine"
///   | "smith"   | "bodyweight" | "band" | "plate"
///
/// or `nil` if no hint could be extracted. Consumers should treat unknown
/// values defensively, but parsers will not emit anything outside this set.
public struct ParsedExercise: Codable, Sendable, Identifiable {
    public let id: UUID
    public let sourceName: String
    public let normalizedName: String
    public let equipmentHint: String?
    public let supersetId: String?
    public let notes: String?
    public let sets: [ParsedSet]

    public init(id: UUID = UUID(),
                sourceName: String,
                normalizedName: String,
                equipmentHint: String? = nil,
                supersetId: String? = nil,
                notes: String? = nil,
                sets: [ParsedSet]) {
        self.id = id
        self.sourceName = sourceName
        self.normalizedName = normalizedName
        self.equipmentHint = equipmentHint
        self.supersetId = supersetId
        self.notes = notes
        self.sets = sets
    }
}

/// One set. Units stay as strings so consumers can map to their own typed
/// systems (e.g. `MyWeightUnit(rawValue: parsedSet.weightUnit ?? "")`).
///
/// Canonical vocabularies (parsers emit only these or `nil`):
///
/// `weightUnit`: `"kg" | "lb"`
///
/// `setType`: `"normal" | "warmup" | "drop_set" | "failure"` — Hevy passes
/// its `set_type` column through; Strong does not export this, so Strong
/// always emits `nil`.
///
/// `distance` is **always meters** (parsers convert at the boundary);
/// `durationSeconds` is **always seconds**.
public struct ParsedSet: Codable, Sendable {
    public let setIndex: Int
    public let setType: String?
    public let reps: Int?
    public let weight: Double?
    public let weightUnit: String?
    public let distance: Double?           // meters
    public let durationSeconds: Int?
    public let rpe: Double?

    public init(setIndex: Int,
                setType: String? = nil,
                reps: Int? = nil,
                weight: Double? = nil,
                weightUnit: String? = nil,
                distance: Double? = nil,
                durationSeconds: Int? = nil,
                rpe: Double? = nil) {
        self.setIndex = setIndex
        self.setType = setType
        self.reps = reps
        self.weight = weight
        self.weightUnit = weightUnit
        self.distance = distance
        self.durationSeconds = durationSeconds
        self.rpe = rpe
    }
}
