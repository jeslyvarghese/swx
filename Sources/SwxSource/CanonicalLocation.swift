// Adapted from SwiftPM's CanonicalPackageLocation (PackageModel; Apache License v2.0 with
// Runtime Library Exception, Copyright (c) Apple Inc. and the Swift project authors).

import Foundation

/// SwiftPM's `CanonicalPackageLocation`: one spelling for every way of writing a repository URL
/// (`https://github.com/a/b.git`, `git@github.com:a/b`, … → `github.com/a/b`).
///
/// SwiftPM hashes it to name fingerprint files, so this must match character for character.
public enum CanonicalLocation {
    private static let schemeDelimiter = "://"
    private static let separator: Character = "/"
    private static let userinfoDelimiter: Character = "@"
    private static let portDelimiter: Character = ":"
    private static let fragmentDelimiter: Character = "#"
    private static let queryDelimiter: Character = "?"
    private static let gitSuffix = ".git"
    private static let sshScheme = "ssh"
    private static let fileScheme = "file"
    private static let homeMarker = "/~/"
    private static let schemeSymbols: Set<Character> = ["+", "-", "."]

    public static func compute(_ string: String) -> String {
        var description = string.precomposedStringWithCanonicalMapping.lowercased()

        // Scheme, then user info (with `~` expansion), port, fragment and query.
        let detectedScheme = Self.dropScheme(&description)
        if let user = Self.dropUserinfo(&description) {
            Self.replaceFirst(Self.homeMarker, with: "/~\(user)/", in: &description)
        }
        Self.removePort(&description)
        Self.removeSuffix(after: Self.fragmentDelimiter, in: &description)
        Self.removeSuffix(after: Self.queryDelimiter, in: &description)

        // `scp`-style SSH (`host:path`) becomes `host/path`.
        if detectedScheme == nil || detectedScheme == Self.sshScheme {
            Self.replaceFirst(String(Self.portDelimiter), with: String(Self.separator), before: description.firstIndex(of: Self.separator), in: &description)
        }

        // Path components without empty ones or percent encoding, and no `.git` at the end.
        var components = description.split(separator: Self.separator, omittingEmptySubsequences: true)
            .map { $0.removingPercentEncoding ?? String($0) }
        var last = components.popLast() ?? ""
        if last.hasSuffix(Self.gitSuffix) {
            last.removeLast(Self.gitSuffix.count)
        }
        components.append(last)
        description = components.joined(separator: String(Self.separator))

        // File URLs and paths keep a leading slash.
        if detectedScheme == Self.fileScheme || string.first == Self.separator {
            description.insert(Self.separator, at: description.startIndex)
        }
        return description
    }

    // MARK: Steps (each mirrors a SwiftPM helper)

    private static func dropScheme(_ text: inout String) -> String? {
        guard let delimiter = text.range(of: Self.schemeDelimiter),
              let first = text.first, first.isLetter,
              text[..<delimiter.lowerBound].allSatisfy({ $0.isLetter || $0.isNumber || Self.schemeSymbols.contains($0) }) else {
            return nil
        }
        let scheme = String(text[..<delimiter.lowerBound])
        text.removeSubrange(..<delimiter.upperBound)
        return scheme
    }

    /// Returns the user when user info preceded the first path separator.
    private static func dropUserinfo(_ text: inout String) -> String? {
        guard let at = text.firstIndex(of: Self.userinfoDelimiter),
              let firstSeparator = text.firstIndex(of: Self.separator),
              at < firstSeparator else {
            return nil
        }
        let userinfo = text[..<at]
        let user = userinfo.split(separator: Self.portDelimiter, maxSplits: 2, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        text.removeSubrange(...at)
        return user
    }

    private static func removePort(_ text: inout String) {
        guard let firstSeparator = text.firstIndex(of: Self.separator),
              let portStart = text.firstIndex(of: Self.portDelimiter),
              let portEnd = text[text.index(after: portStart)...].lastIndex(where: \.isASCIIDigit),
              portEnd <= firstSeparator else {
            return
        }
        text.removeSubrange(portStart...portEnd)
    }

    private static func removeSuffix(after delimiter: Character, in text: inout String) {
        guard let index = text.firstIndex(of: delimiter) else { return }
        text.removeSubrange(index...)
    }

    private static func replaceFirst(_ target: String, with replacement: String, before limit: String.Index? = nil, in text: inout String) {
        guard let range = text.range(of: target) else { return }
        if let limit, range.lowerBound >= limit {
            return
        }
        text.replaceSubrange(range, with: replacement)
    }
}

private extension Character {
    var isASCIIDigit: Bool {
        self.isASCII && self.isNumber
    }
}
