//
//  HevyCSVImporterTests.swift
//  WorkoutImporterTests
//
//  Covers:
//   - End-to-end parse on a representative Hevy export shape (sessions,
//     supersets, set types, RPE, distance/duration).
//   - Dedup of unknown `set_type` warnings.
//   - CSVReader RFC4180 edge cases on Hevy fixtures (BOM, multiline
//     description, embedded commas, all-empty marker set).
//   - Date parsing for "d MMM yyyy, HH:mm" with both padded and
//     unpadded day-of-month.
//   - Mile→meter conversion at the IR boundary.
//   - Required-column validation, detect heuristics, and empty-file error.
//
//  Created by gossamr on 04/27/26.
//

import Testing
import Foundation
@testable import WorkoutImporter

@Suite
struct HevyCSVImporterTests {

    private func fixtureURL(_ name: String) throws -> URL {
        if let url = Bundle.module.url(forResource: name, withExtension: "csv", subdirectory: "Fixtures") {
            return url
        }
        if let url = Bundle.module.url(forResource: name, withExtension: "csv") {
            return url
        }
        struct FixtureMissing: Error { let name: String }
        throw FixtureMissing(name: name)
    }

    // MARK: - End-to-end parse

    @Test func parsesExampleFixture() throws {
        let url = try fixtureURL("hevy-example")
        let payload = try HevyCSVImporter.parse(url: url)

        #expect(payload.sourceApp == .hevy)
        #expect(payload.sourceFilename == "hevy-example.csv")
        // Two distinct (title, start_time) pairs in the fixture.
        #expect(payload.sessions.count == 2)

        // Session 1: Thursday- Upper Reps with 3 exercises.
        let s0 = payload.sessions[0]
        #expect(s0.title == "Thursday- Upper Reps")
        #expect(s0.notes == "Upper body reps day")
        #expect(s0.endTime != nil)
        #expect(s0.exercises.count == 3)

        // Incline Bench Press (Barbell): 4 sets — warmup, normal, normal, drop_set.
        let bench = s0.exercises[0]
        #expect(bench.sourceName == "Incline Bench Press (Barbell)")
        #expect(bench.equipmentHint == "barbell")
        #expect(bench.supersetId == nil)
        #expect(bench.notes == "Pause at bottom") // dedup'd from 4 identical rows
        #expect(bench.sets.count == 4)
        #expect(bench.sets[0].setType == "warmup")
        #expect(bench.sets[1].setType == "normal")
        #expect(bench.sets[2].setType == "normal")
        #expect(bench.sets[3].setType == "drop_set")
        // weight_lbs always emits weightUnit "lb" when weight is present.
        #expect(bench.sets.allSatisfy { $0.weightUnit == "lb" })
        #expect(bench.sets[0].weight == 45)
        #expect(bench.sets[1].weight == 135)
        // setIndex copied verbatim (0-indexed in Hevy).
        #expect(bench.sets[0].setIndex == 0)
        #expect(bench.sets[3].setIndex == 3)
        // RPE: present on set index 1, nil elsewhere.
        #expect(bench.sets[1].rpe == 8)
        #expect(bench.sets[0].rpe == nil)
        #expect(bench.sets[2].rpe == nil)
        #expect(bench.sets[3].rpe == nil)

        // Band Pullaparts: bodyweight (no weight column), 3 sets, superset_id=1.
        let band = s0.exercises[1]
        #expect(band.sourceName == "Band Pullaparts")
        #expect(band.supersetId == "1")
        #expect(band.sets.count == 3)
        #expect(band.sets.allSatisfy { $0.weight == nil && $0.weightUnit == nil })
        #expect(band.sets.allSatisfy { $0.reps == 20 })

        // Triceps Pushdown (Cable): superset_id=1, 3 sets.
        let triceps = s0.exercises[2]
        #expect(triceps.supersetId == "1")
        #expect(triceps.equipmentHint == "cable")
        #expect(triceps.sets.count == 3)

        // Session 2: Sunday Run — distance/duration, no weight/reps.
        let s1 = payload.sessions[1]
        #expect(s1.title == "Sunday Run")
        #expect(s1.exercises.count == 1)
        let run = s1.exercises[0]
        #expect(run.sourceName == "Running")
        #expect(run.sets.count == 1)
        let runSet = run.sets[0]
        #expect(runSet.weight == nil)
        #expect(runSet.weightUnit == nil)
        #expect(runSet.reps == nil)
        // 1 mile → 1609.344 meters.
        #expect(runSet.distance != nil)
        if let d = runSet.distance {
            #expect(abs(d - 1609.344) < 0.001)
        }
        #expect(runSet.durationSeconds == 540)
    }

    // MARK: - Superset linking

    @Test func supersetLinkingPropagatesIdToBothExercises() throws {
        let url = try fixtureURL("hevy-example")
        let payload = try HevyCSVImporter.parse(url: url)

        let s0 = payload.sessions[0]
        // Two exercises share superset_id=1 (Band Pullaparts + Triceps Pushdown).
        let supersetMembers = s0.exercises.filter { $0.supersetId == "1" }
        #expect(supersetMembers.count == 2)
        #expect(supersetMembers.contains { $0.sourceName == "Band Pullaparts" })
        #expect(supersetMembers.contains { $0.sourceName == "Triceps Pushdown (Cable)" })
    }

    // MARK: - Set-type validation + dedup

    @Test func unknownSetTypeCoercedToNilWithDedupedWarning() throws {
        let url = try fixtureURL("hevy-example")
        let payload = try HevyCSVImporter.parse(url: url)

        // The fixture has TWO rows with set_type="garbage" (one on Band
        // Pullaparts, one on Triceps Pushdown). We expect exactly ONE
        // warning, and both sets should carry setType: nil.
        let garbageWarnings = payload.warnings.filter {
            if case let .unknownSetType(raw, _) = $0 { return raw == "garbage" }
            return false
        }
        #expect(garbageWarnings.count == 1)

        let s0 = payload.sessions[0]
        let band = s0.exercises.first { $0.sourceName == "Band Pullaparts" }
        let triceps = s0.exercises.first { $0.sourceName == "Triceps Pushdown (Cable)" }
        #expect(band?.sets.last?.setType == nil)
        #expect(triceps?.sets[1].setType == nil)
    }

    // MARK: - Edge cases

    @Test func parsesEdgeCaseFixtureWithBOMMultilineAndEmbeddedCommas() throws {
        let url = try fixtureURL("hevy-edge-cases")
        let payload = try HevyCSVImporter.parse(url: url)

        // BOM should not corrupt the first column header — title parses.
        #expect(payload.sessions.count == 1)
        let session = payload.sessions[0]
        #expect(session.title == "Edge Day")

        // Multi-line description survived verbatim.
        #expect(session.notes != nil)
        #expect(session.notes?.contains("Multi-line description:") == true)
        #expect(session.notes?.contains("Line two of desc") == true)
        #expect(session.notes?.contains("Line three") == true)

        // Two exercises: Squat (with notes containing an embedded comma) + Plank.
        #expect(session.exercises.count == 2)
        let squat = session.exercises[0]
        #expect(squat.sourceName == "Squat (Barbell)")
        // Embedded comma in exercise_notes survived; dedup leaves one copy.
        #expect(squat.notes == "Felt great, RPE 7 today")
        #expect(squat.sets.count == 2)

        // Plank: first row is a "marker" with everything empty (including
        // set_type), second row records 60 seconds.
        let plank = session.exercises[1]
        #expect(plank.sets.count == 2)
        let marker = plank.sets[0]
        #expect(marker.setType == nil)
        #expect(marker.weight == nil)
        #expect(marker.reps == nil)
        #expect(marker.distance == nil)
        #expect(marker.durationSeconds == nil)
        #expect(marker.rpe == nil)
        let timed = plank.sets[1]
        #expect(timed.durationSeconds == 60)
        #expect(timed.setType == "normal")
    }

    // MARK: - Date parsing

    @Test func dateParsingAcceptsBothPaddedAndUnpaddedDay() {
        // Single-digit day, no leading zero (typical Hevy export).
        #expect(HevyCSVImporter.parseDate("28 Mar 2025, 17:29") != nil)
        // Zero-padded day (defensive against future format tweaks).
        #expect(HevyCSVImporter.parseDate("01 Jan 2025, 09:00") != nil)
        // Truly malformed input.
        #expect(HevyCSVImporter.parseDate("garbage") == nil)
        #expect(HevyCSVImporter.parseDate("") == nil)
    }

    // MARK: - Distance conversion

    @Test func milesToMetersConversionMatchesInternationalMile() {
        #expect(abs(HevyCSVImporter.milesToMeters(1.0) - 1609.344) < 1e-9)
        #expect(abs(HevyCSVImporter.milesToMeters(0.5) - 804.672) < 1e-9)
        #expect(HevyCSVImporter.milesToMeters(0) == 0)
    }

    // MARK: - kg / km column variants

    @Test func parsesKgFixtureWithMatchingUnitAndKmDistance() throws {
        // Hevy templates the unit into the column header based on the user's
        // app setting. A kg-mode export uses `weight_kg` + `distance_km`;
        // the parser must pick up either pair and emit the matching unit.
        let url = try fixtureURL("hevy-kg-example")
        let payload = try HevyCSVImporter.parse(url: url)

        #expect(payload.sessions.count == 2)

        // Pull session: weights in kg, no distance.
        let pull = payload.sessions[0]
        #expect(pull.title == "Pull")
        #expect(pull.exercises.count == 2)
        let lat = pull.exercises[0]
        #expect(lat.sourceName == "Lat Pulldown (Cable)")
        #expect(lat.sets.count == 3)
        #expect(lat.sets.allSatisfy { $0.weightUnit == "kg" })
        #expect(lat.sets[0].weight == 27.2)
        #expect(lat.sets[2].weight == 31.8)
        #expect(lat.sets.allSatisfy { $0.distance == nil })

        // Cardio session: 5 km should land as 5000 meters at the IR boundary.
        let cardio = payload.sessions[1]
        #expect(cardio.exercises.count == 1)
        let run = cardio.exercises[0].sets[0]
        #expect(run.distance != nil)
        if let d = run.distance {
            #expect(abs(d - 5000.0) < 1e-9)
        }
        #expect(run.weight == nil)
        #expect(run.weightUnit == nil)
    }

    @Test func detectAcceptsBothLbAndKgHeaders() throws {
        let lbURL = try fixtureURL("hevy-example")
        #expect(try HevyCSVImporter.detect(url: lbURL) == true)

        let kgURL = try fixtureURL("hevy-kg-example")
        #expect(try HevyCSVImporter.detect(url: kgURL) == true)
    }

    @Test func kilometersToMetersConversionIsExact() {
        // 1 km = 1000 m exactly.
        #expect(HevyCSVImporter.metersPerKilometer == 1_000)
    }

    // MARK: - Repeated-exercise (Hevy unilateral workaround) handling

    @Test func splitMonotonicRunsSplitsOnReset() {
        // 0,1,2,0,1,2 → two runs of three.
        let sets: [ParsedSet] = (0..<6).map { i in
            ParsedSet(setIndex: i % 3, reps: 1)
        }
        let runs = HevyCSVImporter.splitMonotonicRuns(sets)
        #expect(runs.count == 2)
        #expect(runs[0].map(\.setIndex) == [0, 1, 2])
        #expect(runs[1].map(\.setIndex) == [0, 1, 2])
    }

    @Test func splitMonotonicRunsKeepsStrictlyIncreasingTogether() {
        // 0,1,2,3 → single run.
        let sets: [ParsedSet] = (0..<4).map { ParsedSet(setIndex: $0, reps: 1) }
        let runs = HevyCSVImporter.splitMonotonicRuns(sets)
        #expect(runs.count == 1)
        #expect(runs[0].count == 4)
    }

    @Test func splitMonotonicRunsTreatsRepeatedSameIndexAsReset() {
        // 0,0 → two runs (defensive: each repeat counts as a new entry).
        let sets: [ParsedSet] = [
            ParsedSet(setIndex: 0, reps: 1),
            ParsedSet(setIndex: 0, reps: 2),
        ]
        let runs = HevyCSVImporter.splitMonotonicRuns(sets)
        #expect(runs.count == 2)
    }

    @Test func repeatedExerciseSplitsIntoTwoParsedExercisesWithWarning() throws {
        // Real-world Hevy unilateral workaround: same exercise logged twice
        // in one session with set_index resetting (e.g. Clamshell 0,1,2,0,1,2).
        let url = try fixtureURL("hevy-repeated-exercise")
        let payload = try HevyCSVImporter.parse(url: url)

        #expect(payload.sessions.count == 1)
        let session = payload.sessions[0]
        // Six rows of "Clamshell" → two ParsedExercise entries (one per run).
        #expect(session.exercises.count == 2)
        #expect(session.exercises.allSatisfy { $0.sourceName == "Clamshell" })
        #expect(session.exercises[0].sets.count == 3)
        #expect(session.exercises[1].sets.count == 3)
        #expect(session.exercises[0].sets.map(\.setIndex) == [0, 1, 2])
        #expect(session.exercises[1].sets.map(\.setIndex) == [0, 1, 2])
        // Reps differ across the two passes per the fixture (12,12,6 vs 12,8,6).
        #expect(session.exercises[0].sets.map(\.reps) == [12, 12, 6])
        #expect(session.exercises[1].sets.map(\.reps) == [12, 8, 6])

        // A single summary warning surfaces affected exercises by name.
        let repeatWarnings = payload.warnings.filter {
            if case let .multipleLoggingPasses(entries) = $0 {
                return entries.contains { $0.exerciseName == "Clamshell" }
            }
            return false
        }
        #expect(repeatWarnings.count == 1)
    }

    /// Pin the dedup behavior added to address the per-workout warning
    /// flood: when the same exercise is split across N sessions, the parser
    /// emits ONE summary warning naming the exercise (with a session count
    /// when N > 1), not N per-session warnings.
    @Test func repeatedExerciseAcrossSessionsEmitsOneSummaryWarning() throws {
        // Synthesize a minimal CSV: two sessions, each logging "Clamshell"
        // twice (set_index resets 0,1,0,1) and "Lateral Raise" three times
        // (0,1,0,1,0,1). Goal: ONE summary warning, not four (2×2 + 1×2).
        let csv = """
        title,start_time,end_time,description,exercise_title,superset_id,exercise_notes,set_index,set_type,weight_lbs,reps,distance_miles,duration_seconds,rpe
        "Day A","01 Jan 2025, 09:00","01 Jan 2025, 10:00","","Clamshell",,"",0,"normal",,12,,,
        "Day A","01 Jan 2025, 09:00","01 Jan 2025, 10:00","","Clamshell",,"",1,"normal",,12,,,
        "Day A","01 Jan 2025, 09:00","01 Jan 2025, 10:00","","Clamshell",,"",0,"normal",,10,,,
        "Day A","01 Jan 2025, 09:00","01 Jan 2025, 10:00","","Clamshell",,"",1,"normal",,10,,,
        "Day B","02 Jan 2025, 09:00","02 Jan 2025, 10:00","","Clamshell",,"",0,"normal",,12,,,
        "Day B","02 Jan 2025, 09:00","02 Jan 2025, 10:00","","Clamshell",,"",1,"normal",,12,,,
        "Day B","02 Jan 2025, 09:00","02 Jan 2025, 10:00","","Clamshell",,"",0,"normal",,8,,,
        "Day B","02 Jan 2025, 09:00","02 Jan 2025, 10:00","","Clamshell",,"",1,"normal",,8,,,
        "Day B","02 Jan 2025, 09:00","02 Jan 2025, 10:00","","Lateral Raise (Dumbbell)",,"",0,"normal",10,12,,,
        "Day B","02 Jan 2025, 09:00","02 Jan 2025, 10:00","","Lateral Raise (Dumbbell)",,"",1,"normal",10,12,,,
        "Day B","02 Jan 2025, 09:00","02 Jan 2025, 10:00","","Lateral Raise (Dumbbell)",,"",0,"normal",12,10,,,
        "Day B","02 Jan 2025, 09:00","02 Jan 2025, 10:00","","Lateral Raise (Dumbbell)",,"",1,"normal",12,10,,,
        """
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("hevy-repeat-dedup-\(UUID().uuidString).csv")
        try csv.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let payload = try HevyCSVImporter.parse(url: tmp)

        // Pre-fix this would be 3 warnings (Clamshell × 2 sessions + Lateral Raise × 1).
        // Post-fix: exactly 1 summary entry covering both names.
        let summary: [[ImportWarning.MultiPassEntry]] = payload.warnings.compactMap {
            if case let .multipleLoggingPasses(entries) = $0 { return entries }
            return nil
        }
        #expect(summary.count == 1)
        let entries = try #require(summary.first)
        let names = entries.map(\.exerciseName)
        #expect(names.contains("Clamshell"))
        #expect(names.contains("Lateral Raise (Dumbbell)"))
        // Clamshell hit in 2 sessions; Lateral Raise hit in 1.
        #expect(entries.first { $0.exerciseName == "Clamshell" }?.sessionCount == 2)
        #expect(entries.first { $0.exerciseName == "Lateral Raise (Dumbbell)" }?.sessionCount == 1)
    }

    // MARK: - Required-column validation

    @Test func parseRejectsCSVMissingRequiredColumn() throws {
        // Synthesize a CSV with `set_index` missing. Required columns per
        // the parser are: title, start_time, exercise_title, set_index.
        let csv = """
        title,start_time,exercise_title,set_type,weight_lbs,reps
        "Day","28 Mar 2025, 17:29","Squat (Barbell)","normal",135,5
        """
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("hevy-missing-col-\(UUID().uuidString).csv")
        try csv.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        do {
            _ = try HevyCSVImporter.parse(url: tmp)
            Issue.record("Expected missingRequiredColumns error")
        } catch HevyCSVImporterError.missingRequiredColumns(let cols) {
            #expect(cols == ["set_index"])
        } catch {
            Issue.record("Wrong error: \(error)")
        }
    }

    // MARK: - Detect heuristics

    @Test func detectAcceptsHevyAndRejectsStrong() throws {
        let hevyURL = try fixtureURL("hevy-example")
        #expect(try HevyCSVImporter.detect(url: hevyURL) == true)

        // Cross-check: Strong's CSV must NOT be claimed by Hevy's detect.
        let strongURL = try fixtureURL("strong-example")
        #expect(try HevyCSVImporter.detect(url: strongURL) == false)
    }

    // MARK: - Empty file

    @Test func parseThrowsNoRowsOnEmptyFile() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("hevy-empty-\(UUID().uuidString).csv")
        try "".write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        do {
            _ = try HevyCSVImporter.parse(url: tmp)
            Issue.record("Expected noRows error")
        } catch HevyCSVImporterError.noRows {
            // expected
        } catch {
            Issue.record("Wrong error: \(error)")
        }
    }

    // MARK: - Vocabulary pin

    @Test func canonicalSetTypesVocabulary() {
        // Pin the canonical vocabulary so a future expansion is a deliberate change.
        #expect(HevyCSVImporter.canonicalSetTypes == ["normal", "warmup", "drop_set", "failure"])
    }
}
