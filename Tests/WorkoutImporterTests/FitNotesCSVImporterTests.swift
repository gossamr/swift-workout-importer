//
//  FitNotesCSVImporterTests.swift
//  WorkoutImporterTests
//
//  Covers:
//   - End-to-end parse on a representative FitNotes export shape with
//     multi-session data, mixed kg/lb weights, bodyweight, distance with
//     varied units, and timed sets.
//   - Distance unit conversion for every recognized unit.
//   - Unknown distance unit dedup and warning surface.
//   - Time parsing for both `MM:ss` and `HH:MM:ss`.
//   - Strict date parser.
//   - Both-weight-columns-populated tiebreak with deduped warning.
//   - CSVReader RFC4180 edge cases on a FitNotes-shaped fixture.
//   - Required-column validation, detect heuristics, empty-file error.
//   - Session grouping by `(Date, Category)` including the empty-Category
//     fallback to a "Session" title.
//   - Category-in-notes prepending and adjacent-line dedup.
//
//  Created by gossamr on 04/27/26.
//

import Testing
import Foundation
@testable import WorkoutImporter

@Suite
struct FitNotesCSVImporterTests {

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

    private func writeTempCSV(_ contents: String, name: String = "fixture.csv") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FitNotesCSVImporterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - End-to-end parse

    @Test func parsesExampleFixture() throws {
        let url = try fixtureURL("fitnotes-example")
        let payload = try FitNotesCSVImporter.parse(url: url)

        #expect(payload.sourceApp == .fitnotes)
        #expect(payload.sourceFilename == "fitnotes-example.csv")

        // 3 dates × multiple categories: (2024-11-02, Legs),
        // (2024-11-04, Chest), (2024-11-04, Cardio), (2024-11-06, Core),
        // (2024-11-06, Cardio) → 5 sessions.
        #expect(payload.sessions.count == 5)

        // Session 0: Legs on 2024-11-02 — 2 exercises, set counts 3 + 1.
        let s0 = payload.sessions[0]
        #expect(s0.title == "Legs")
        #expect(s0.exercises.count == 2)
        let squat = s0.exercises[0]
        #expect(squat.sourceName == "Squat (Barbell)")
        #expect(squat.equipmentHint == "barbell")
        #expect(squat.sets.count == 3)
        #expect(squat.sets[0].weight == 100)
        #expect(squat.sets[0].weightUnit == "kg")
        // setIndex starts at 1 within (date, category, exercise), preserves CSV order.
        #expect(squat.sets[0].setIndex == 1)
        #expect(squat.sets[2].setIndex == 3)
        let lunge = s0.exercises[1]
        #expect(lunge.sourceName == "Lunge (Dumbbell)")
        #expect(lunge.equipmentHint == "dumbbell")

        // Session 1: Chest on 2024-11-04 — bench (lb), chin-up (bodyweight).
        let s1 = payload.sessions[1]
        #expect(s1.title == "Chest")
        let bench = s1.exercises[0]
        #expect(bench.sourceName == "Bench Press (Barbell)")
        #expect(bench.sets[0].weight == 135)
        #expect(bench.sets[0].weightUnit == "lb")
        let chin = s1.exercises[1]
        #expect(chin.sourceName == "Chin Up")
        #expect(chin.sets.allSatisfy { $0.weight == nil && $0.weightUnit == nil })
        #expect(chin.sets[0].reps == 8)

        // Session 2: Cardio on 2024-11-04 — Running with mixed units.
        let s2 = payload.sessions[2]
        #expect(s2.title == "Cardio")
        let running = s2.exercises[0]
        #expect(running.sourceName == "Running")
        #expect(running.sets.count == 2)
        // mile→meters: 1 mi = 1609.344 m
        #expect(abs((running.sets[0].distance ?? -1) - 1609.344) < 0.001)
        #expect(running.sets[0].durationSeconds == 15 * 60)
        // km→meters: 5 km = 5000 m
        #expect(abs((running.sets[1].distance ?? -1) - 5000.0) < 0.001)
        #expect(running.sets[1].durationSeconds == 30 * 60)

        // startTime always midnight on the row's date, endTime always nil.
        #expect(s0.endTime == nil)
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute, .second], from: s0.startTime)
        #expect(comps.hour == 0 && comps.minute == 0 && comps.second == 0)

        // Plank: timed set, no weight/reps.
        let s3 = payload.sessions[3]
        #expect(s3.title == "Core")
        let plank = s3.exercises[0]
        #expect(plank.sets.count == 2)
        #expect(plank.sets[0].durationSeconds == 60)
        #expect(plank.sets[1].durationSeconds == 90)
        #expect(plank.sets.allSatisfy { $0.weight == nil && $0.reps == nil })
    }

    // MARK: - Distance unit conversions

    @Test func distanceUnitConversionsAllRecognizedUnits() {
        #expect(FitNotesCSVImporter.metersFactor(for: "m")  == 1.0)
        #expect(FitNotesCSVImporter.metersFactor(for: "km") == 1000.0)
        #expect(FitNotesCSVImporter.metersFactor(for: "cm") == 0.01)
        #expect(FitNotesCSVImporter.metersFactor(for: "in") == 0.0254)
        #expect(FitNotesCSVImporter.metersFactor(for: "ft") == 0.3048)
        #expect(FitNotesCSVImporter.metersFactor(for: "yd") == 0.9144)
        #expect(FitNotesCSVImporter.metersFactor(for: "mi") == 1_609.344)
        #expect(FitNotesCSVImporter.metersFactor(for: "parsec") == nil)
    }

    // MARK: - Unknown distance unit + dedup

    @Test func unknownDistanceUnitProducesNilAndDedupedWarning() throws {
        let csv = """
        Date,Exercise,Category,Weight (kg),Weight (lbs),Reps,Distance,Distance Unit,Time,Notes,Kind
        2024-11-02,Run,Cardio,,,,1,parsec,,,d
        2024-11-02,Run,Cardio,,,,2,parsec,,,d
        """
        let url = try writeTempCSV(csv)
        let payload = try FitNotesCSVImporter.parse(url: url)

        let run = payload.sessions[0].exercises[0]
        #expect(run.sets.allSatisfy { $0.distance == nil })

        let parsecWarnings = payload.warnings.filter {
            if case let .unknownDistanceUnit(raw) = $0 { return raw == "parsec" }
            return false
        }
        #expect(parsecWarnings.count == 1)
    }

    // MARK: - Time parsing

    @Test func timeParsing() {
        #expect(FitNotesCSVImporter.parseTimeSeconds("01:30") == 90)
        #expect(FitNotesCSVImporter.parseTimeSeconds("01:30:45") == 5445)
        #expect(FitNotesCSVImporter.parseTimeSeconds("99") == nil)
        #expect(FitNotesCSVImporter.parseTimeSeconds("garbage") == nil)
    }

    @Test func emptyTimeIsSilentlyNil() throws {
        let csv = """
        Date,Exercise,Category,Weight (kg),Weight (lbs),Reps,Distance,Distance Unit,Time,Notes,Kind
        2024-11-02,Squat,Legs,100,,5,,,,,wr
        """
        let url = try writeTempCSV(csv)
        let payload = try FitNotesCSVImporter.parse(url: url)
        let set = payload.sessions[0].exercises[0].sets[0]
        #expect(set.durationSeconds == nil)
        // No warning emitted for an empty Time cell.
        #expect(payload.warnings.allSatisfy {
            if case .unparseableTime = $0 { return false }
            return true
        })
    }

    @Test func malformedTimeWarnsOnce() throws {
        let csv = """
        Date,Exercise,Category,Weight (kg),Weight (lbs),Reps,Distance,Distance Unit,Time,Notes,Kind
        2024-11-02,Plank,Core,,,,,,99,,t
        """
        let url = try writeTempCSV(csv)
        let payload = try FitNotesCSVImporter.parse(url: url)
        #expect(payload.sessions[0].exercises[0].sets[0].durationSeconds == nil)
        let timeWarnings = payload.warnings.filter {
            if case let .unparseableTime(raw) = $0 { return raw == "99" }
            return false
        }
        #expect(timeWarnings.count == 1)
    }

    // MARK: - Date parsing strict

    @Test func dateParsingStrict() {
        #expect(FitNotesCSVImporter.parseDate("2024-11-02") != nil)
        #expect(FitNotesCSVImporter.parseDate("11/02/2024") == nil)
        #expect(FitNotesCSVImporter.parseDate("not-a-date") == nil)
        #expect(FitNotesCSVImporter.parseDate("") == nil)
    }

    // MARK: - Both weight columns populated

    @Test func bothWeightColumnsPopulatedPicksKgWithDedupedWarning() throws {
        let csv = """
        Date,Exercise,Category,Weight (kg),Weight (lbs),Reps,Distance,Distance Unit,Time,Notes,Kind
        2024-11-02,Squat,Legs,100,220,5,,,,,wr
        2024-11-02,Squat,Legs,102,225,5,,,,,wr
        """
        let url = try writeTempCSV(csv)
        let payload = try FitNotesCSVImporter.parse(url: url)
        let sets = payload.sessions[0].exercises[0].sets
        #expect(sets[0].weight == 100)
        #expect(sets[0].weightUnit == "kg")
        #expect(sets[1].weight == 102)
        #expect(sets[1].weightUnit == "kg")

        // Dedup: a single warning even though both rows had both columns populated.
        let bothWarnings = payload.warnings.filter {
            if case .ambiguousWeightUnitsChoseKg = $0 { return true }
            return false
        }
        #expect(bothWarnings.count == 1)
    }

    // MARK: - Edge cases (BOM, multiline notes, embedded commas, blanks)

    @Test func parsesEdgeCaseFixtureWithBOMMultilineAndEmbeddedCommas() throws {
        let url = try fixtureURL("fitnotes-edge-cases")
        let payload = try FitNotesCSVImporter.parse(url: url)

        // BOM should not corrupt the first column header — date parses,
        // session lands in the payload.
        #expect(payload.sessions.count >= 1)

        // Find the squat exercise; its notes should carry both the embedded
        // comma row and the multi-line row (deduped Category prefix).
        let allExercises = payload.sessions.flatMap { $0.exercises }
        let squat = allExercises.first { $0.sourceName == "Squat (Barbell)" }
        #expect(squat != nil)
        #expect(squat?.notes != nil)
        // Embedded comma in note survived the CSV parser (quoted field).
        #expect(squat?.notes?.contains("Felt great, RPE 7") == true)
        // Multi-line note survived verbatim across the line breaks inside the
        // quoted field.
        #expect(squat?.notes?.contains("Line two of note") == true)
        #expect(squat?.notes?.contains("Line three") == true)

        // "Walk Test" exercise: 7 rows, one per recognized distance unit, all
        // 1 unit. Expected meters: 1, 1000, 0.01, 0.0254, 0.3048, 0.9144, 1609.344.
        let walk = allExercises.first { $0.sourceName == "Walk Test" }
        #expect(walk != nil)
        let distances = walk?.sets.map { $0.distance ?? -1 } ?? []
        #expect(distances.count == 7)
        #expect(abs(distances[0] - 1.0) < 1e-9)
        #expect(abs(distances[1] - 1000.0) < 1e-9)
        #expect(abs(distances[2] - 0.01) < 1e-9)
        #expect(abs(distances[3] - 0.0254) < 1e-9)
        #expect(abs(distances[4] - 0.3048) < 1e-9)
        #expect(abs(distances[5] - 0.9144) < 1e-9)
        #expect(abs(distances[6] - 1609.344) < 1e-9)

        // "Bare Bones" row: every optional cell blank. Parser doesn't crash.
        let bare = allExercises.first { $0.sourceName == "Bare Bones" }
        #expect(bare != nil)
        #expect(bare?.sets.count == 1)
        let bareSet = bare?.sets[0]
        #expect(bareSet?.weight == nil)
        #expect(bareSet?.reps == nil)
        #expect(bareSet?.distance == nil)
        #expect(bareSet?.durationSeconds == nil)
    }

    // MARK: - Required column validation

    @Test func parseRejectsCSVMissingRequiredColumn() throws {
        // Required columns: Date, Exercise, Reps. Synthesize a CSV missing Reps.
        let csv = """
        Date,Exercise,Category,Weight (kg),Weight (lbs),Distance,Distance Unit,Time,Notes,Kind
        2024-11-02,Squat,Legs,100,,,,,,wr
        """
        let url = try writeTempCSV(csv)
        do {
            _ = try FitNotesCSVImporter.parse(url: url)
            Issue.record("Expected missingRequiredColumns error")
        } catch FitNotesCSVImporterError.missingRequiredColumns(let cols) {
            #expect(cols == ["Reps"])
        } catch {
            Issue.record("Wrong error: \(error)")
        }
    }

    // MARK: - Detect heuristics

    @Test func detectAcceptsFitNotesAndRejectsOthers() throws {
        let fitURL = try fixtureURL("fitnotes-example")
        #expect(try FitNotesCSVImporter.detect(url: fitURL) == true)

        let strongURL = try fixtureURL("strong-example")
        #expect(try FitNotesCSVImporter.detect(url: strongURL) == false)

        let hevyURL = try fixtureURL("hevy-example")
        #expect(try FitNotesCSVImporter.detect(url: hevyURL) == false)
    }

    // MARK: - Empty file

    @Test func parseThrowsNoRowsOnEmptyFile() throws {
        let url = try writeTempCSV("")
        do {
            _ = try FitNotesCSVImporter.parse(url: url)
            Issue.record("Expected noRows error")
        } catch FitNotesCSVImporterError.noRows {
            // expected
        } catch {
            Issue.record("Wrong error: \(error)")
        }
    }

    // MARK: - Vocabulary pin

    @Test func recognizedDistanceUnitsVocabulary() {
        // Pin the canonical vocabulary so a future expansion is a deliberate change.
        #expect(FitNotesCSVImporter.recognizedDistanceUnits == ["m", "km", "cm", "in", "ft", "yd", "mi"])
    }

    // MARK: - Session-title fallback (empty Category)

    @Test func emptyCategoryRowsCollapseIntoSessionTitled_Session() throws {
        let csv = """
        Date,Exercise,Category,Weight (kg),Weight (lbs),Reps,Distance,Distance Unit,Time,Notes,Kind
        2024-11-02,Squat,,100,,5,,,,,wr
        2024-11-02,Bench,,100,,5,,,,,wr
        """
        let url = try writeTempCSV(csv)
        let payload = try FitNotesCSVImporter.parse(url: url)
        #expect(payload.sessions.count == 1)
        #expect(payload.sessions[0].title == "Session")
        #expect(payload.sessions[0].exercises.count == 2)
    }

    // MARK: - (Date, Category) split

    @Test func mixedCategoriesOnSameDateSplitIntoMultipleSessions() throws {
        // Alternate "Legs" and "Cardio" rows on the same date — expect 2
        // sessions, with the right rows in each. First-seen order means
        // "Legs" appears first.
        let csv = """
        Date,Exercise,Category,Weight (kg),Weight (lbs),Reps,Distance,Distance Unit,Time,Notes,Kind
        2024-11-02,Squat,Legs,100,,5,,,,,wr
        2024-11-02,Run,Cardio,,,,1,km,05:00,,dt
        2024-11-02,Lunge,Legs,40,,10,,,,,wr
        2024-11-02,Run,Cardio,,,,2,km,10:00,,dt
        """
        let url = try writeTempCSV(csv)
        let payload = try FitNotesCSVImporter.parse(url: url)
        #expect(payload.sessions.count == 2)

        let legs = payload.sessions.first { $0.title == "Legs" }
        let cardio = payload.sessions.first { $0.title == "Cardio" }
        #expect(legs != nil)
        #expect(cardio != nil)

        // Legs has 2 exercises (Squat, Lunge).
        #expect(legs?.exercises.count == 2)
        #expect(legs?.exercises.contains { $0.sourceName == "Squat" } == true)
        #expect(legs?.exercises.contains { $0.sourceName == "Lunge" } == true)

        // Cardio has 1 exercise "Run" with 2 sets.
        #expect(cardio?.exercises.count == 1)
        #expect(cardio?.exercises.first?.sourceName == "Run")
        #expect(cardio?.exercises.first?.sets.count == 2)
    }

    // MARK: - Category prepended into per-exercise notes (with dedup)

    @Test func categoryAndNotesArePreservedInExerciseNotes() throws {
        let csv = """
        Date,Exercise,Category,Weight (kg),Weight (lbs),Reps,Distance,Distance Unit,Time,Notes,Kind
        2024-11-02,Squat,Legs,100,,5,,,,good session,wr
        2024-11-02,Squat,Legs,100,,5,,,,still good,wr
        """
        let url = try writeTempCSV(csv)
        let payload = try FitNotesCSVImporter.parse(url: url)

        let squat = payload.sessions[0].exercises[0]
        let notes = try #require(squat.notes)
        // The Category line is present.
        #expect(notes.contains("Category: Legs"))
        // Both per-row note bodies survive.
        #expect(notes.contains("good session"))
        #expect(notes.contains("still good"))
        // Dedup: only one "Category: Legs" copy across the two rows.
        let categoryOccurrences = notes.components(separatedBy: "Category: Legs").count - 1
        #expect(categoryOccurrences == 1)
    }
}
