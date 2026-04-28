//
//  NameNormalizer.swift
//  WorkoutImporter
//
//  Lowers vendor exercise names into a comparable canonical form and
//  extracts equipment hints from parens / prefix words. Used by parsers
//  to populate `ParsedExercise.normalizedName` / `equipmentHint`, and
//  exposed publicly so downstream matchers can reuse the same logic.
//
//  Created by gossamr on 04/27/26.
//

import Foundation

public enum NameNormalizer {

    // MARK: Equipment Vocabulary

    /// The canonical equipment hint strings this normalizer emits.
    /// `extractEquipmentHint(_:)` returns one of these or `nil`.
    public static let equipmentHints: Set<String> = [
        "barbell", "dumbbell", "kettlebell", "cable", "machine",
        "smith", "bodyweight", "band", "plate"
    ]

    // MARK: Stopwords

    /// Small list, biased toward exercise-name vocabulary. We deliberately do
    /// NOT include words like "press", "pull", "row", etc. because they are
    /// load-bearing in matching.
    private static let stopwords: Set<String> = ["the", "a", "an", "with", "and"]

    // MARK: Synonym Vocabulary

    /// Token-window rewrites that canonicalize variant exercise-name
    /// spellings. Mirrors `equipmentVocabulary`'s shape: an ordered list of
    /// `(tokens, replacement)` entries where both sides are token arrays.
    /// Multi-word entries must come before any single-word entry that could
    /// match a subset of their tokens (same rule as equipment).
    ///
    /// Multi-word phrase rewrites are sourced from Nuzzo's published-
    /// research nomenclature audits (JSCR 2017, JSCR 2021). The single-word
    /// folds canonicalize singular/plural anatomy variants ("biceps" →
    /// "bicep") and the `forward ≡ front` direction synonym so vendor names
    /// with either spelling collapse to one comparable form.
    private static let synonymVocabulary: [(tokens: [String], replacement: [String])] = [
        // Multi-word phrase rewrites
        (["arm", "curl"],       ["bicep", "curl"]),
        (["heel", "raise"],     ["calf", "raise"]),
        (["knee", "curl"],      ["leg", "curl"]),
        (["military", "press"], ["overhead", "press"]),
        (["shoulder", "press"], ["overhead", "press"]),
        // Compound-word collapses: source apps inconsistently spell as one
        // word (Pushup, Pullup, Chinup, Situp) or two (Push Up, Pull Up,
        // Chin Up, Sit Up). Collapse to the one-word form so `Push-Up`
        // (template, tokenizes to ["push","up"]) and `Pushup` (source,
        // ["pushup"]) end up in the same token shape.
        (["push", "up"],        ["pushup"]),
        (["pull", "up"],        ["pullup"]),
        (["chin", "up"],        ["chinup"]),
        (["sit", "up"],         ["situp"]),
        // Single-word folds
        (["biceps"],            ["bicep"]),
        (["triceps"],           ["tricep"]),
        (["forward"],           ["front"]),
    ]

    // MARK: Equipment Vocabulary (internal mapping)

    /// Canonical equipment tokens and their aliases. Order is significant only
    /// for multi-word entries (e.g. "smith machine" must be checked before
    /// "machine" so the more specific hint wins).
    private static let equipmentVocabulary: [(tokens: [String], hint: String)] = [
        // Multi-word forms first
        (["smith", "machine"], "smith"),
        (["ez", "bar"], "barbell"),
        // Single-word forms (with plurals/aliases)
        (["barbell"], "barbell"),
        (["barbells"], "barbell"),
        (["dumbbell"], "dumbbell"),
        (["dumbbells"], "dumbbell"),
        (["db"], "dumbbell"),
        (["kettlebell"], "kettlebell"),
        (["kettlebells"], "kettlebell"),
        (["cable"], "cable"),
        (["cables"], "cable"),
        (["smith"], "smith"),
        (["machine"], "machine"),
        (["machines"], "machine"),
        (["bodyweight"], "bodyweight"),
        (["band"], "band"),
        (["bands"], "band"),
        (["plate"], "plate"),
        (["plates"], "plate")
    ]

    // MARK: Normalize

    /// Lowercase, fold diacritics, replace any non-alphanumeric character
    /// (including parens themselves) with a space, collapse runs, trim.
    ///
    /// Parens content survives as tokens — the third-party importers we
    /// consume put their disambiguator in parens ("Bench Press (Barbell)" vs
    /// "Bench Press (Cable)"). Stripping the block would collapse those onto
    /// a shared key and force `ExerciseMatchingEngine` to disambiguate
    /// downstream. The matcher's `capExactWhenParensDisagree` post-process
    /// is kept as a defensive net but is mostly dead on this contract.
    ///
    /// "Bench Press (Barbell, Incline)" → "bench press barbell incline"
    /// "Crush-Grip Dumbbell Bench Press" → "crush grip dumbbell bench press"
    /// "café"                            → "cafe"
    public static func normalize(_ s: String) -> String {
        // 1. Fold diacritics / case via the locale-insensitive ASCII folding.
        //    `.diacriticInsensitive` removes accents; `.caseInsensitive` lowercases.
        let folded = s.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: nil
        )

        // 2. Replace any non-alphanumeric character with a space, then collapse runs.
        var collapsed = ""
        var lastWasSpace = true
        for scalar in folded.unicodeScalars {
            let isAlphaNumeric = (scalar.value >= 0x30 && scalar.value <= 0x39) // 0-9
                || (scalar.value >= 0x61 && scalar.value <= 0x7A)              // a-z
                || (scalar.value >= 0x41 && scalar.value <= 0x5A)              // A-Z (post-fold should be rare)
            if isAlphaNumeric {
                collapsed.unicodeScalars.append(scalar)
                lastWasSpace = false
            } else if !lastWasSpace {
                collapsed.append(" ")
                lastWasSpace = true
            }
        }

        // 3. Trim trailing space if any.
        if collapsed.hasSuffix(" ") {
            collapsed.removeLast()
        }

        // 4. Synonym rewrites (e.g. "shoulder press" → "overhead press",
        //    "biceps" → "bicep"). Operates in token space so single-word
        //    folds don't accidentally trigger inside larger tokens, then
        //    re-joins.
        if collapsed.isEmpty { return collapsed }
        let toks = collapsed.split(separator: " ").map(String.init)
        return applySynonyms(tokens: toks).joined(separator: " ")
    }

    // MARK: applySynonyms

    /// Walk `synonymVocabulary` in declaration order, rewriting matching
    /// token windows in-place. Single-token entries replace every
    /// occurrence; multi-word entries replace contiguous windows. Order
    /// matters: multi-word entries must run before any single-word entry
    /// that could mask them.
    ///
    /// Public so callers that tokenize without going through `normalize`
    /// (e.g. wide-token extraction in the matching engine) can stay in
    /// parity with tier-1/tier-3 matching.
    public static func applySynonyms(tokens toks: [String]) -> [String] {
        if toks.isEmpty { return toks }
        var result = toks
        for entry in synonymVocabulary {
            let needle = entry.tokens
            let replacement = entry.replacement
            if needle.count == 1 {
                let n0 = needle[0]
                let r0 = replacement[0]
                result = result.map { $0 == n0 ? r0 : $0 }
            } else {
                if result.count < needle.count { continue }
                var next: [String] = []
                var i = 0
                while i < result.count {
                    if i + needle.count <= result.count {
                        var matched = true
                        for offset in 0..<needle.count {
                            if result[i + offset] != needle[offset] {
                                matched = false
                                break
                            }
                        }
                        if matched {
                            next.append(contentsOf: replacement)
                            i += needle.count
                            continue
                        }
                    }
                    next.append(result[i])
                    i += 1
                }
                result = next
            }
        }
        return result
    }

    // MARK: Tokens

    /// Tokenize on whitespace + punctuation, drop empty + stopwords.
    /// Operates on the result of `normalize`, so the caller can pass either
    /// raw or pre-normalized input.
    public static func tokens(_ s: String) -> Set<String> {
        let normalized = normalize(s)
        if normalized.isEmpty { return [] }
        var result: Set<String> = []
        for piece in normalized.split(separator: " ") {
            let token = String(piece)
            if token.isEmpty { continue }
            if stopwords.contains(token) { continue }
            result.insert(token)
        }
        return result
    }

    // MARK: Equipment Hint

    /// Extract an equipment hint from an exercise name. Returns one of the
    /// strings in `equipmentHints` or `nil`. Inspects the first parenthesized
    /// block first (Strong convention — equipment in parens after the
    /// movement), then falls back to scanning prefix words (Hevy convention
    /// — equipment as a prefix word).
    ///
    /// "Squat (Barbell)"                    → "barbell"
    /// "Bench Press (Smith Machine)"        → "smith"
    /// "Bench Press (Smith Machine, Incline)" → "smith"
    /// "Smith Machine Bench Press"          → "smith"
    /// "Incline Dumbbell Bench Press"       → "dumbbell"
    /// "Chin Up"                            → nil
    public static func extractEquipmentHint(_ s: String) -> String? {
        // 1. Parens content: take the first parenthesized block, split on commas,
        //    look at each comma-separated piece for an equipment token.
        if let parensContent = firstParensContent(in: s) {
            for piece in parensContent.split(separator: ",") {
                if let hint = matchEquipment(in: String(piece)) {
                    return hint
                }
            }
        }

        // 2. Prefix words: tokenize the name (parens stripped) and walk from the
        //    front, returning the first equipment hit. We accept matches anywhere
        //    in the token stream because Hevy puts equipment in the middle
        //    ("Incline Dumbbell Bench Press").
        let prefixTokens = normalize(s).split(separator: " ").map(String.init)
        return matchEquipment(tokens: prefixTokens)
    }

    // MARK: - Internals

    /// Return the contents of the first balanced parens block, or nil.
    private static func firstParensContent(in s: String) -> String? {
        var inside = ""
        var depth = 0
        var found = false
        for ch in s {
            if ch == "(" {
                if depth == 0 {
                    found = true
                } else {
                    inside.append(ch)
                }
                depth += 1
                continue
            }
            if ch == ")" {
                depth -= 1
                if depth == 0 {
                    return inside
                }
                if depth > 0 {
                    inside.append(ch)
                }
                continue
            }
            if depth > 0 {
                inside.append(ch)
            }
        }
        return found ? inside : nil
    }

    /// Look for an equipment token in a free-text fragment (typically one
    /// comma-separated piece of a parens block).
    private static func matchEquipment(in fragment: String) -> String? {
        let tokens = normalize(fragment).split(separator: " ").map(String.init)
        return matchEquipment(tokens: tokens)
    }

    /// Walk the vocabulary in declaration order. Multi-word entries match
    /// against contiguous token windows; single-word entries match any token.
    private static func matchEquipment(tokens: [String]) -> String? {
        if tokens.isEmpty { return nil }
        for entry in equipmentVocabulary {
            let needle = entry.tokens
            if needle.count == 1 {
                if tokens.contains(needle[0]) {
                    return entry.hint
                }
            } else {
                // Sliding window over tokens
                if tokens.count < needle.count { continue }
                for start in 0...(tokens.count - needle.count) {
                    var matched = true
                    for offset in 0..<needle.count {
                        if tokens[start + offset] != needle[offset] {
                            matched = false
                            break
                        }
                    }
                    if matched {
                        return entry.hint
                    }
                }
            }
        }
        return nil
    }
}
