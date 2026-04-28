//
//  CSVReader.swift
//  WorkoutImporter
//
//  Tiny RFC4180 CSV reader. Hand-rolled (no deps) because all third-party
//  Swift CSV libs are heavier than what the importers need. Handles:
//   - Quoted fields containing commas, newlines, and "" escapes.
//   - Optional UTF-8 BOM at the start of the file.
//   - CRLF or LF line endings (LF only inside quotes is preserved verbatim).
//
//  Created by gossamr on 04/27/26.
//

import Foundation

/// Errors thrown by `CSVReader`.
public enum CSVReaderError: Error {
    /// The file at the given URL could not be read with the requested
    /// encoding (or did not exist).
    case unreadableFile(URL)
}

/// Tiny RFC4180 CSV reader. Handles quoted fields with embedded commas /
/// newlines / `""` escapes, optional UTF-8 BOM, and CRLF/LF/CR line
/// endings (including grapheme-collapsed `\r\n` clusters). Public so
/// downstream consumers can reuse it for related parsing tasks.
public struct CSVReader {

    /// Returns every row as an array of fields. The first row is treated
    /// like any other — callers wanting a header should use `dictRows`.
    public static func rows(from url: URL, encoding: String.Encoding = .utf8) throws -> [[String]] {
        guard let text = try? String(contentsOf: url, encoding: encoding) else {
            throw CSVReaderError.unreadableFile(url)
        }
        return parse(text)
    }

    /// Returns every row keyed by the header row's column names. Trims
    /// whitespace around header keys (Strong's exports occasionally vary
    /// trailing spaces). Fields are returned verbatim — no trim — to
    /// preserve note formatting.
    public static func dictRows(from url: URL, encoding: String.Encoding = .utf8) throws -> [[String: String]] {
        let allRows = try rows(from: url, encoding: encoding)
        guard let header = allRows.first else { return [] }
        let keys = header.map { $0.trimmingCharacters(in: .whitespaces) }
        return allRows.dropFirst().map { row in
            var dict: [String: String] = [:]
            dict.reserveCapacity(keys.count)
            for (i, key) in keys.enumerated() {
                dict[key] = i < row.count ? row[i] : ""
            }
            return dict
        }
    }

    /// Index-driven state-machine parser. `inQuotes` toggles on every
    /// unescaped `"`; inside quotes a doubled `""` is a literal `"`.
    /// Field/row separators only apply outside quotes.
    public static func parse(_ input: String) -> [[String]] {
        // Strip optional UTF-8 BOM.
        let chars = Array(input.first == "\u{FEFF}" ? input.dropFirst() : Substring(input))
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    // Escaped doubled-quote inside a quoted field.
                    if i + 1 < chars.count, chars[i + 1] == "\"" {
                        field.append("\""); i += 2; continue
                    }
                    inQuotes = false
                } else {
                    field.append(c)
                }
            } else {
                switch c {
                case "\"":
                    inQuotes = true
                case ",":
                    row.append(field); field = ""
                case "\r\n", "\r", "\n":
                    // Swift collapses CRLF into a single extended grapheme
                    // cluster, so we match all three line-ending variants
                    // (Windows \r\n, classic Mac \r, Unix \n) here.
                    row.append(field); rows.append(row); field = ""; row = []
                default:
                    field.append(c)
                }
            }
            i += 1
        }
        // Close the trailing row if there's residual content.
        if !field.isEmpty || !row.isEmpty {
            row.append(field); rows.append(row)
        }
        return rows
    }
}
