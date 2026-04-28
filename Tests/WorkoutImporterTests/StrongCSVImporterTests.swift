//
//  StrongCSVImporterTests.swift
//  WorkoutImporterTests
//
//  Covers:
//   - CSVReader RFC4180 conformance (BOM, multiline quoted notes,
//     embedded commas, blank columns).
//   - StrongCSVImporter session/exercise grouping and equipment-hint
//     surfacing on the resulting IR.
//
//  Equipment-hint extraction itself is exhaustively tested in
//  NameNormalizerTests — this suite just spot-checks the wiring.
//
//  Created by gossamr on 04/27/26.
//

import Testing
import Foundation
@testable import WorkoutImporter

@Suite
struct StrongCSVImporterTests {

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

    @Test func parsesAcaylorShapeFixture() throws {
        let url = try fixtureURL("strong-example")
        let payload = try StrongCSVImporter.parse(url: url, defaultWeightUnit: "lb")

        #expect(payload.sourceApp == .strong)
        #expect(payload.sourceFilename == "strong-example.csv")
        // 3 distinct (Date, Workout Name) pairs in the fixture.
        #expect(payload.sessions.count == 3)

        // First session: 4 sets of Squat (Barbell) + 3 sets of Lunge (Dumbbell).
        let s0 = payload.sessions[0]
        #expect(s0.title == "Friday-lower-squats")
        #expect(s0.exercises.count == 2)
        #expect(s0.exercises[0].sourceName == "Squat (Barbell)")
        #expect(s0.exercises[0].sets.count == 4)
        #expect(s0.exercises[0].equipmentHint == "barbell")
        #expect(s0.exercises[1].sourceName == "Lunge (Dumbbell)")
        #expect(s0.exercises[1].sets.count == 3)
        #expect(s0.exercises[1].equipmentHint == "dumbbell")

        // Duration "15:30" parsed as h*3600+m*60. 15:30 → 55800s.
        #expect(s0.endTime != nil)
        if let end = s0.endTime {
            #expect(abs(end.timeIntervalSince(s0.startTime) - Double(15 * 3600 + 30 * 60)) < 1)
        }

        // Strong has no set_type column → setType always nil.
        #expect(s0.exercises[0].sets.allSatisfy { $0.setType == nil })

        // weight=0 rows produce nil weight (the parser drops zero weight).
        let s1 = payload.sessions[1]
        let chinUp = s1.exercises.first { $0.sourceName == "Chin Up" }
        #expect(chinUp != nil)
        #expect(chinUp?.equipmentHint == nil, "Exercises with no parens should produce no hint")
        #expect(chinUp?.sets.first?.weight == nil)
        #expect(chinUp?.sets.first?.reps == 8)

        // Smith Machine wins over the bare "Machine" hint.
        let s2 = payload.sessions[2]
        #expect(s2.exercises.first?.equipmentHint == "smith")
    }

    // MARK: - CSVReader RFC4180 edge cases

    @Test func parsesEdgeCaseFixtureWithBOMMultilineAndEmbeddedCommas() throws {
        let url = try fixtureURL("strong-edge-cases")
        let payload = try StrongCSVImporter.parse(url: url, defaultWeightUnit: "kg")

        // BOM should not corrupt the first column header — date parses.
        #expect(payload.sessions.count == 1)
        let session = payload.sessions[0]
        #expect(session.title == "Edge-case-day")

        // 3 distinct exercises (Squat, Deadlift, Running).
        #expect(session.exercises.count == 3)

        // Squat: 2 sets, notes from each row joined.
        let squat = session.exercises[0]
        #expect(squat.sourceName == "Squat (Barbell)")
        #expect(squat.sets.count == 2)
        #expect(squat.notes != nil)
        // Embedded comma in note ("Felt great, RPE 7") survived.
        #expect(squat.notes?.contains("Felt great, RPE 7") == true)
        // Multi-line note survived.
        #expect(squat.notes?.contains("Line two of note") == true)
        #expect(squat.notes?.contains("Line three") == true)

        // Deadlift: row 1 has blank notes, row 2 has "PR! New best, very happy".
        let deadlift = session.exercises[1]
        #expect(deadlift.sets.count == 2)
        #expect(deadlift.notes?.contains("PR! New best, very happy") == true)

        // Running: distance present → distance warning emitted exactly once.
        let running = session.exercises[2]
        #expect(running.sets.first?.distance == 5000.0)
        #expect(running.sets.first?.durationSeconds == 1500)
        #expect(payload.warnings.contains { if case .assumedDistanceUnit = $0 { true } else { false } })
    }

    // MARK: - Validation

    @Test func parseRejectsUnknownDefaultWeightUnit() throws {
        let url = try fixtureURL("strong-example")
        do {
            _ = try StrongCSVImporter.parse(url: url, defaultWeightUnit: "stones")
            Issue.record("Expected invalidWeightUnit error")
        } catch StrongCSVImporterError.invalidWeightUnit(let bad) {
            #expect(bad == "stones")
        } catch {
            Issue.record("Wrong error: \(error)")
        }
    }

    @Test func acceptedWeightUnitsVocabulary() {
        // Pin the canonical vocabulary so a future expansion is a deliberate change.
        #expect(StrongCSVImporter.acceptedWeightUnits == ["kg", "lb"])
    }

    // MARK: - Date parsing both formats

    @Test func dateParsingAcceptsBothFormats() {
        #expect(StrongCSVImporter.parseDate("2024-11-02") != nil)
        #expect(StrongCSVImporter.parseDate("11/02/2024") != nil)
        #expect(StrongCSVImporter.parseDate("not-a-date") == nil)
    }

    // MARK: - Duration parsing

    @Test func durationHHMMParsing() {
        #expect(StrongCSVImporter.parseDurationHHMM("15:30") == 15 * 3600 + 30 * 60)
        #expect(StrongCSVImporter.parseDurationHHMM("00:45") == 45 * 60)
        #expect(StrongCSVImporter.parseDurationHHMM("") == nil)
        #expect(StrongCSVImporter.parseDurationHHMM("garbage") == nil)
    }

    // MARK: - CSVReader directly

    @Test func csvReaderHandlesQuotedFieldsAndEscapes() {
        let input = """
        a,b,c
        1,"two, with comma",3
        4,"line one\nline two",6
        7,"with \"\"escaped\"\" quotes",9
        """
        let rows = CSVReader.parse(input)
        #expect(rows.count == 4)
        #expect(rows[0] == ["a", "b", "c"])
        #expect(rows[1] == ["1", "two, with comma", "3"])
        #expect(rows[2] == ["4", "line one\nline two", "6"])
        #expect(rows[3] == ["7", "with \"escaped\" quotes", "9"])
    }

    @Test func csvReaderStripsBOM() {
        let input = "\u{FEFF}a,b\n1,2\n"
        let rows = CSVReader.parse(input)
        #expect(rows.count == 2)
        #expect(rows[0] == ["a", "b"])
        #expect(rows[1] == ["1", "2"])
    }

    @Test func csvReaderHandlesCRLF() {
        let input = "a,b\r\n1,2\r\n3,4\r\n"
        let rows = CSVReader.parse(input)
        #expect(rows.count == 3)
        #expect(rows[0] == ["a", "b"])
        #expect(rows[2] == ["3", "4"])
    }
}
