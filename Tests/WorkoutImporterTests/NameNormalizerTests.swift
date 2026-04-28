//
//  NameNormalizerTests.swift
//  WorkoutImporterTests
//
//  Created by gossamr on 04/27/26.
//

import Testing
import Foundation
@testable import WorkoutImporter

@Suite
struct NameNormalizerTests {

    // MARK: - normalize

    @Test func normalizePreservesParensContentAsTokens() {
        // Parens hold the equipment/variant disambiguator in source-app
        // names; their content survives as space-separated tokens after
        // the punctuation pass.
        #expect(NameNormalizer.normalize("Bench Press (Barbell)")
                == "bench press barbell")
    }

    @Test func normalizeKeepsBareParensContentWhenNothingPrecedes() {
        #expect(NameNormalizer.normalize("(only parens)") == "only parens")
    }

    @Test func normalizeLowercases() {
        #expect(NameNormalizer.normalize("BENCH PRESS") == "bench press")
    }

    @Test func normalizeFoldsDiacritics() {
        #expect(NameNormalizer.normalize("café") == "cafe")
    }

    @Test func normalizeCollapsesMultipleSpaces() {
        #expect(NameNormalizer.normalize("bench    press") == "bench press")
    }

    @Test func normalizeTrimsLeadingAndTrailingWhitespace() {
        #expect(NameNormalizer.normalize("   bench press   ") == "bench press")
    }

    @Test func normalizeReplacesHyphensWithSpaces() {
        // Strong's picker uses dashes to separate modifiers from the base
        // movement, e.g. "Bench Press - Wide Grip (Barbell)".
        #expect(NameNormalizer.normalize("Bench Press - Wide Grip (Barbell)")
                == "bench press wide grip barbell")
    }

    @Test func normalizeKeepsCommaSeparatedParensModifiers() {
        // Comma-separated tokens inside parens collapse to space-separated
        // tokens after the punctuation pass. The normalizer treats commas
        // the same as any other punctuation, so consumers comparing names
        // produced by name-generators that emit comma-listed modifiers
        // match cleanly.
        #expect(NameNormalizer.normalize("Foo (a, b, c)") == "foo a b c")
    }

    @Test func normalizeKeepsMultipleParensBlocks() {
        // Each block's content survives as tokens; ordering reflects
        // source order. Behavior is needed because the normalizer also
        // runs against template-side names that may carry multiple
        // parenthetical blocks.
        #expect(NameNormalizer.normalize("Foo (a) (b)") == "foo a b")
    }

    @Test func normalizeCollapsesEmptyParensCleanly() {
        // Empty parens contribute no tokens and leave no trailing whitespace.
        #expect(NameNormalizer.normalize("Squat ()") == "squat")
    }

    @Test func normalizePhraseSynonymFiresAcrossParensBoundary() {
        // Synonyms run on the joined token stream, so a multi-word phrase
        // whose words straddle a parens boundary still rewrites. Parens
        // are punctuation in the new contract, not a phrase barrier.
        #expect(NameNormalizer.normalize("Press (Shoulder Press)")
                == "press overhead press")
    }

    @Test func normalizeHandlesEmptyString() {
        #expect(NameNormalizer.normalize("") == "")
    }

    @Test func normalizeHandlesPunctuationSoup() {
        // Apostrophes and other punctuation should fold to spaces and collapse.
        #expect(NameNormalizer.normalize("Farmer's Walk") == "farmer s walk")
    }

    @Test func normalizePassesThroughNamesWithoutParens() {
        #expect(NameNormalizer.normalize("Bench Dip") == "bench dip")
    }

    // MARK: - tokens

    @Test func tokensBarbellBenchPress() {
        let tokens = NameNormalizer.tokens("Barbell Bench Press")
        #expect(tokens == ["barbell", "bench", "press"])
    }

    @Test func tokensDropStopwords() {
        // "the" is a stopword.
        let tokens = NameNormalizer.tokens("The Squat")
        #expect(tokens == ["squat"])
    }

    @Test func tokensEmptyInput() {
        #expect(NameNormalizer.tokens("") == [])
    }

    @Test func tokensKeepsParensContent() {
        // Parens content is the disambiguator and survives as tokens.
        let tokens = NameNormalizer.tokens("Bench Press (Barbell, Incline)")
        #expect(tokens == ["bench", "press", "barbell", "incline"])
    }

    @Test func tokensDeduplicatesRepeats() {
        let tokens = NameNormalizer.tokens("Press Press Press")
        #expect(tokens == ["press"])
    }

    // MARK: - extractEquipmentHint vocabulary pin

    @Test func equipmentHintsVocabulary() {
        // Pin the canonical vocabulary — `ParsedExercise.equipmentHint` doc
        // promises emitted values come from this set.
        #expect(NameNormalizer.equipmentHints == [
            "barbell", "dumbbell", "kettlebell", "cable", "machine",
            "smith", "bodyweight", "band", "plate"
        ])
    }

    // MARK: - extractEquipmentHint (parens form)

    @Test func extractHintBarbellInParens() {
        #expect(NameNormalizer.extractEquipmentHint("Squat (Barbell)") == "barbell")
    }

    @Test func extractHintDumbbellInParens() {
        #expect(NameNormalizer.extractEquipmentHint("Bench Press (Dumbbell)") == "dumbbell")
    }

    @Test func extractHintKettlebellInParens() {
        #expect(NameNormalizer.extractEquipmentHint("Swing (Kettlebell)") == "kettlebell")
    }

    @Test func extractHintCableInParens() {
        #expect(NameNormalizer.extractEquipmentHint("Row (Cable)") == "cable")
    }

    @Test func extractHintMachineInParens() {
        #expect(NameNormalizer.extractEquipmentHint("Hip Adductor (Machine)") == "machine")
    }

    @Test func extractHintSmithMachineInParens() {
        // "Smith Machine" must beat the bare "Machine" alternative.
        #expect(NameNormalizer.extractEquipmentHint("Bench Press (Smith Machine)") == "smith")
    }

    @Test func extractHintSmithMachineWithModifierInParens() {
        #expect(NameNormalizer.extractEquipmentHint("Bench Press (Smith Machine, Incline)") == "smith")
    }

    @Test func extractHintBodyweightInParens() {
        #expect(NameNormalizer.extractEquipmentHint("Squat (Bodyweight)") == "bodyweight")
    }

    @Test func extractHintBandInParens() {
        #expect(NameNormalizer.extractEquipmentHint("Pullapart (Band)") == "band")
    }

    @Test func extractHintPlateInParens() {
        #expect(NameNormalizer.extractEquipmentHint("Front Raise (Plate)") == "plate")
    }

    // MARK: - extractEquipmentHint (prefix form)

    @Test func extractHintBarbellPrefix() {
        #expect(NameNormalizer.extractEquipmentHint("Barbell Squat") == "barbell")
    }

    @Test func extractHintDumbbellPrefix() {
        // Hevy convention — prefix modifier with equipment in the middle.
        #expect(NameNormalizer.extractEquipmentHint("Incline Dumbbell Bench Press") == "dumbbell")
    }

    @Test func extractHintKettlebellPrefix() {
        #expect(NameNormalizer.extractEquipmentHint("Kettlebell Goblet Squat") == "kettlebell")
    }

    @Test func extractHintCablePrefix() {
        #expect(NameNormalizer.extractEquipmentHint("Cable Row") == "cable")
    }

    @Test func extractHintMachinePrefix() {
        #expect(NameNormalizer.extractEquipmentHint("Machine Chest Press") == "machine")
    }

    @Test func extractHintSmithMachinePrefix() {
        #expect(NameNormalizer.extractEquipmentHint("Smith Machine Bench Press") == "smith")
    }

    @Test func extractHintBodyweightPrefix() {
        #expect(NameNormalizer.extractEquipmentHint("Bodyweight Squat") == "bodyweight")
    }

    @Test func extractHintBandPrefix() {
        #expect(NameNormalizer.extractEquipmentHint("Band Pullaparts") == "band")
    }

    @Test func extractHintPlatePrefix() {
        #expect(NameNormalizer.extractEquipmentHint("Plate Front Raise") == "plate")
    }

    // MARK: - extractEquipmentHint (aliases)

    @Test func extractHintDBAliasInParens() {
        #expect(NameNormalizer.extractEquipmentHint("Bench Press (DB)") == "dumbbell")
    }

    @Test func extractHintDBAliasPrefix() {
        #expect(NameNormalizer.extractEquipmentHint("DB Bench Press") == "dumbbell")
    }

    @Test func extractHintEZBarAliasMapsToBarbell() {
        // "EZ Bar Curl" should resolve to a barbell hint.
        #expect(NameNormalizer.extractEquipmentHint("EZ Bar Curl") == "barbell")
    }

    @Test func extractHintPluralForms() {
        // Plurals/variants are accepted.
        #expect(NameNormalizer.extractEquipmentHint("Dumbbells Curl") == "dumbbell")
    }

    // MARK: - extractEquipmentHint (nil cases)

    @Test func extractHintChinUpReturnsNil() {
        #expect(NameNormalizer.extractEquipmentHint("Chin Up") == nil)
    }

    @Test func extractHintPlankReturnsNil() {
        #expect(NameNormalizer.extractEquipmentHint("Plank") == nil)
    }

    @Test func extractHintHipThrustWithoutEquipmentReturnsNil() {
        #expect(NameNormalizer.extractEquipmentHint("Hip Thrust") == nil)
    }

    // MARK: - Synonyms (phrase + token)
    //
    // Phrase rewrites sourced from Nuzzo's published-research nomenclature
    // audits (JSCR 2017, JSCR 2021). Per-token folds canonicalize
    // singular/plural anatomy and the forward/front direction synonym so
    // vendor names with either spelling compare equal.

    @Test func phraseSynonymArmCurl() {
        #expect(NameNormalizer.normalize("Arm Curl") == "bicep curl")
    }

    @Test func phraseSynonymHeelRaise() {
        #expect(NameNormalizer.normalize("Heel Raise") == "calf raise")
    }

    @Test func phraseSynonymKneeCurl() {
        #expect(NameNormalizer.normalize("Knee Curl") == "leg curl")
    }

    @Test func phraseSynonymMilitaryPress() {
        #expect(NameNormalizer.normalize("Military Press") == "overhead press")
    }

    @Test func phraseSynonymShoulderPress() {
        #expect(NameNormalizer.normalize("Shoulder Press") == "overhead press")
    }

    @Test func phraseSynonymSurvivesEquipmentPrefix() {
        #expect(NameNormalizer.normalize("Barbell Shoulder Press") == "barbell overhead press")
    }

    @Test func phraseSynonymDoesNotEatShoulderShrug() {
        // "shoulder shrug" must not match the "shoulder press" rewrite.
        #expect(NameNormalizer.normalize("Shoulder Shrug") == "shoulder shrug")
    }

    @Test func phraseSynonymDoesNotEatShoulderRaise() {
        #expect(NameNormalizer.normalize("Lateral Shoulder Raise") == "lateral shoulder raise")
    }

    @Test func tokenSynonymBicepsToBicep() {
        #expect(NameNormalizer.tokens("Biceps Curl") == ["bicep", "curl"])
    }

    @Test func tokenSynonymTricepsToTricep() {
        #expect(NameNormalizer.tokens("Triceps Extension") == ["tricep", "extension"])
    }

    @Test func tokenSynonymForwardToFront() {
        #expect(NameNormalizer.tokens("Forward Lunge") == ["front", "lunge"])
    }

    @Test func synonymsCollapseArmCurlVariantsToOneTokenSet() {
        let a = NameNormalizer.tokens("Arm Curl")
        let b = NameNormalizer.tokens("Biceps Curl")
        let c = NameNormalizer.tokens("Bicep Curl")
        #expect(a == c)
        #expect(b == c)
    }
}
