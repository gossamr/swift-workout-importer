//
//  ImportWarning.swift
//  WorkoutImporter
//
//  Structured warnings emitted by the importers. Each warning is a typed 
//  value the consumer translates (and localizes) at the rendering boundary.
//
//  Created by gossamr on 05/10/26.
//

import Foundation

/// A non-fatal issue detected during parsing. Per-row issues that don't
/// prevent the file from being imported (skipped sessions, missing units,
/// ambiguous columns, unrecognized enum values, etc.) flow through here
/// rather than being thrown.
///
/// Cases carry the structured data the consumer needs to render a
/// localized message. The importer does not format strings.
public enum ImportWarning: Codable, Sendable, Hashable {

    /// A session row was skipped because its date column couldn't be
    /// parsed. `sessionName` is the source-app's title for the session
    /// (Strong's "Workout Name", Hevy's "title"); nil when the source
    /// format doesn't carry one (FitNotes groups by date alone).
    case unparseableSessionDate(sessionName: String?, raw: String)

    /// Both kg and lbs columns were populated for a weight cell; importer
    /// chose kg as the canonical unit. FitNotes-specific.
    case ambiguousWeightUnitsChoseKg

    /// A distance-unit token didn't match any recognized unit; the
    /// distance value on the affected rows was dropped to nil. Deduped
    /// per unique unrecognized value.
    case unknownDistanceUnit(raw: String)

    /// A time/duration value couldn't be parsed; duration dropped on the
    /// affected rows. Deduped per unique unparseable value.
    case unparseableTime(raw: String)

    /// The export format doesn't carry distance-unit info on rows; the
    /// importer defaulted to the named unit. Strong-specific.
    case assumedDistanceUnit(unit: String)

    /// A `set_type` value (or equivalent column) wasn't recognized; the
    /// row's set-type was coerced to nil. Deduped per unique value.
    case unknownSetType(raw: String, sessionName: String?)

    /// At least one exercise was logged across multiple distinct passes
    /// within the same session in the source file (i.e. interleaved
    /// across other exercises). The importer preserved the per-pass
    /// ordering as separate `ParsedExercise` entries because the source
    /// format doesn't carry side-info to merge them.
    case multipleLoggingPasses(entries: [MultiPassEntry])

    /// One row of `multipleLoggingPasses`: an exercise name and the
    /// number of sessions in which it exhibited multi-pass logging.
    public struct MultiPassEntry: Codable, Sendable, Hashable {
        public let exerciseName: String
        public let sessionCount: Int

        public init(exerciseName: String, sessionCount: Int) {
            self.exerciseName = exerciseName
            self.sessionCount = sessionCount
        }
    }
}
