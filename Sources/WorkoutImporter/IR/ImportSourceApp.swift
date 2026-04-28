//
//  ImportSourceApp.swift
//  WorkoutImporter
//
//  Created by gossamr on 04/27/26.
//

import Foundation

/// Identifies the upstream app a workout history was exported from.
/// Persist as `rawValue` if the host app needs to record provenance —
/// adding a new case is then a non-breaking schema change.
public enum ImportSourceApp: String, Codable, CaseIterable, Sendable {
    case strong
    case hevy
    case fitnotes

    /// Human-readable name for use in UI. Stable across versions; treat as
    /// safe to display verbatim.
    public var displayName: String {
        switch self {
        case .strong:   return "Strong"
        case .hevy:     return "Hevy"
        case .fitnotes: return "FitNotes"
        }
    }
}
