import Foundation

/// How `swx licenses` prints its report.
public enum LicenseFormat: Sendable {
    case text
    case json
    case csv
}

/// Recognizes common licenses by distinctive phrases of their text, as SPDX identifiers.
public enum LicenseDetector {
    /// File names that hold a package's license, matched case-insensitively by prefix.
    static let filePrefixes = ["license", "licence", "copying"]

    /// The license file in a package root: `LICENSE` first, then the rest alphabetically.
    public static func licenseFile(among fileNames: [String]) -> String? {
        let candidates = fileNames.filter { name in
            let lowered = name.lowercased()
            return Self.filePrefixes.contains { lowered.hasPrefix($0) }
        }
        return candidates.sorted { ($0.count, $0) < ($1.count, $1) }.first
    }

    /// A rule: every phrase must appear, and none of the excluded ones.
    private struct Rule {
        let spdx: String
        let phrases: [String]
        var excluded: [String] = []
    }

    // Most specific first: exceptions and variants before the licenses they extend.
    private static let rules: [Rule] = [
        Rule(spdx: "Apache-2.0 WITH Swift-exception", phrases: ["apache license", "version 2.0", "runtime library exception"]),
        Rule(spdx: "Apache-2.0", phrases: ["apache license", "version 2.0"]),
        Rule(spdx: "MIT", phrases: ["permission is hereby granted, free of charge", "the above copyright notice and this permission notice shall be included"]),
        Rule(spdx: "BSD-3-Clause", phrases: ["redistribution and use in source and binary forms", "neither the name"]),
        Rule(spdx: "BSD-3-Clause", phrases: ["redistribution and use in source and binary forms", "names of its contributors may not be used"]),
        Rule(spdx: "BSD-2-Clause", phrases: ["redistribution and use in source and binary forms"]),
        Rule(spdx: "ISC", phrases: ["permission to use, copy, modify, and/or distribute this software for any purpose", "provided that the above copyright notice and this permission notice appear in all copies"]),
        Rule(spdx: "0BSD", phrases: ["permission to use, copy, modify, and/or distribute this software for any purpose with or without fee is hereby granted"]),
        Rule(spdx: "MPL-2.0", phrases: ["mozilla public license", "version 2.0"]),
        Rule(spdx: "AGPL-3.0", phrases: ["gnu affero general public license", "version 3"]),
        Rule(spdx: "LGPL-3.0", phrases: ["gnu lesser general public license", "version 3"]),
        Rule(spdx: "LGPL-2.1", phrases: ["gnu lesser general public license", "version 2.1"]),
        Rule(spdx: "GPL-3.0", phrases: ["gnu general public license", "version 3"], excluded: ["lesser general public license"]),
        Rule(spdx: "GPL-2.0", phrases: ["gnu general public license", "version 2"], excluded: ["lesser general public license"]),
        Rule(spdx: "Unlicense", phrases: ["this is free and unencumbered software released into the public domain"]),
        Rule(spdx: "Zlib", phrases: ["altered source versions must be plainly marked as such"]),
        Rule(spdx: "BSL-1.0", phrases: ["boost software license"]),
        Rule(spdx: "CC0-1.0", phrases: ["cc0 1.0 universal"]),
    ]

    /// The SPDX identifier of `text`'s license, or `nil` when no rule matches.
    public static func identify(_ text: String) -> String? {
        let normalized = Self.normalize(text)
        return Self.rules.first { rule in
            rule.phrases.allSatisfy(normalized.contains) && !rule.excluded.contains(where: normalized.contains)
        }?.spdx
    }

    /// Comment markers some license files carry at line starts (`/` stays: "and/or" matters).
    private static let decoration: Set<Character> = ["*", "#"]

    /// Lower-case, with all runs of whitespace (and comment decoration) as single spaces.
    static func normalize(_ text: String) -> String {
        let decoration = Self.decoration
        var result = ""
        var pendingSpace = false
        for character in text.lowercased() {
            if character.isWhitespace || decoration.contains(character) {
                pendingSpace = !result.isEmpty
                continue
            }
            if pendingSpace {
                result.append(" ")
                pendingSpace = false
            }
            result.append(character)
        }
        return result
    }
}

/// One package's license, as found on disk.
public struct PackageLicense: Sendable, Equatable, Encodable {
    public let identity: String
    public let version: String?
    /// SPDX identifier; `nil` when there's a file swx doesn't recognize, or no file.
    public let license: String?
    /// The license file, relative to the package.
    public let file: String?

    public init(identity: String, version: String?, license: String?, file: String?) {
        self.identity = identity
        self.version = version
        self.license = license
        self.file = file
    }
}

extension [PackageLicense] {
    private static let unknown = "unknown"
    private static let missing = "no license file"
    private static let columnGap = 2

    public func render(_ format: LicenseFormat) -> String {
        switch format {
        case .text:
            return self.table()
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return String(decoding: (try? encoder.encode(self)) ?? Data(), as: UTF8.self) + "\n"
        case .csv:
            let rows = self.map { [$0.identity, $0.version ?? "", $0.license ?? "", $0.file ?? ""].map(Self.csvField).joined(separator: ",") }
            return (["package,version,license,file"] + rows).joined(separator: "\n") + "\n"
        }
    }

    /// `swift-nio  2.104.0  Apache-2.0`, aligned, then a count per license.
    private func table() -> String {
        let rows = self.map { [$0.identity, $0.version ?? "", Self.licenseText($0)] }
        var widths = [0, 0]
        for row in rows {
            widths[0] = Swift.max(widths[0], row[0].count)
            widths[1] = Swift.max(widths[1], row[1].count)
        }
        var output = ""
        for row in rows {
            let package = row[0].padding(toLength: widths[0] + Self.columnGap, withPad: " ", startingAt: 0)
            let version = row[1].padding(toLength: widths[1] + Self.columnGap, withPad: " ", startingAt: 0)
            output += package + version + row[2] + "\n"
        }

        // Totals, most common first.
        let counts = Dictionary(grouping: self, by: Self.licenseText).mapValues(\.count)
        let summary = counts.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.map { "\($0.value) \($0.key)" }
        return output + "\n" + summary.joined(separator: ", ") + "\n"
    }

    private static func licenseText(_ license: PackageLicense) -> String {
        guard license.file != nil else { return Self.missing }
        return license.license ?? Self.unknown
    }

    private static func csvField(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
