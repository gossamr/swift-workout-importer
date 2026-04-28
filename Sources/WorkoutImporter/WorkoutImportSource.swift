//
//  WorkoutImportSource.swift
//  WorkoutImporter
//
//  Vendor-agnostic protocol for third-party workout-history importers
//  (Strong, Hevy, ...). Each parser converts its source format into the
//  vendor-neutral `ParsedImportPayload` IR — downstream consumers never
//  see vendor-specific shapes.
//
//  Created by gossamr on 04/27/26.
//

import Foundation
import UniformTypeIdentifiers

/// Parser contract. Each conformer reads a single export file and produces
/// a `ParsedImportPayload`. Implementations must not touch storage — they
/// should be pure functions of the input file.
public protocol WorkoutImportSource {
    /// The app this parser handles.
    static var sourceApp: ImportSourceApp { get }

    /// Content types this parser will accept in `.fileImporter`. Strong and
    /// Hevy both export `.commaSeparatedText`.
    static var supportedContentTypes: [UTType] { get }

    /// Quick smell-test: does this file look like one we can parse?
    /// Implementations should be cheap (header sniff only) and never throw
    /// on a malformed-but-readable file — return `false` instead.
    static func detect(url: URL) throws -> Bool

    /// Full parse. Throws on unrecoverable errors (file unreadable, no rows,
    /// required columns missing). Per-row issues should be appended to
    /// `ParsedImportPayload.warnings` rather than thrown.
    static func parse(url: URL) throws -> ParsedImportPayload
}
