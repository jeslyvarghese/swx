import Foundation

/// One compiler or tool message from a build log: what an agent needs to fix it, without the
/// rest of the log.
public struct BuildDiagnostic: Sendable, Codable, Hashable {
    public enum Severity: String, Sendable, Codable {
        case error
        case warning
    }

    public let severity: Severity
    /// Absolute path of the file, when the message points into one.
    public let file: String?
    public let line: Int?
    public let column: Int?
    public let message: String

    public init(severity: Severity, file: String?, line: Int?, column: Int?, message: String) {
        self.severity = severity
        self.file = file
        self.line = line
        self.column = column
        self.message = message
    }
}

/// Reads diagnostics out of `swift build` and xcodebuild logs.
public enum BuildLog {
    private enum Marker {
        static let escape: Character = "\u{1B}"
        static let escapeEnd: ClosedRange<Character> = "@"..."~"
        static let pathStart: Character = "/"
        static let separator: Character = ":"
        static let messageSeparator = ": "
        /// Swift's diagnostics for code it has no file for.
        static let unknownLocation = "<unknown>:0"
        static let undefinedSymbols = "Undefined symbols for architecture"
        static let quote: Character = "\""
        /// SwiftPM's and xcodebuild's own summaries of a failure the compiler already explained.
        static let summaries = ["Build failed", "fatalError", "Compilation failed"]
    }

    /// Errors and warnings, each once (xcodebuild repeats a message per architecture and task).
    /// Messages without a file are kept only when no message names one: those are summaries of
    /// the located ones ("SwiftCompile … failed") or, alone, the only explanation (a linker error).
    public static func diagnostics(in log: String) -> [BuildDiagnostic] {
        var located: [BuildDiagnostic] = []
        var unlocated: [BuildDiagnostic] = []
        var seen: Set<BuildDiagnostic> = []
        let lines = log.split(whereSeparator: \.isNewline).map { Self.removingEscapes(String($0)) }

        var index = lines.startIndex
        while index < lines.endIndex {
            let line = lines[index]
            index += 1

            // `Undefined symbols…` is followed by the symbols, indented: one message for them all.
            if line.hasPrefix(Marker.undefinedSymbols) {
                var symbols: [String] = []
                while index < lines.endIndex, lines[index].first?.isWhitespace == true {
                    let entry = lines[index].trimmingCharacters(in: .whitespaces)
                    if entry.first == Marker.quote {
                        symbols.append(entry)
                    }
                    index += 1
                }
                let diagnostic = BuildDiagnostic(severity: .error, file: nil, line: nil, column: nil, message: ([line] + symbols).joined(separator: " "))
                if seen.insert(diagnostic).inserted {
                    unlocated.append(diagnostic)
                }
                continue
            }

            guard let diagnostic = Self.diagnostic(in: line), seen.insert(diagnostic).inserted else { continue }
            if diagnostic.file == nil {
                unlocated.append(diagnostic)
            } else {
                located.append(diagnostic)
            }
        }
        return located.isEmpty ? unlocated.filter { !Self.isSummary($0) } : located
    }

    /// `/a/b.swift:3:7: error: message`, `error: message`, `ld: error: message` or
    /// `<unknown>:0: error: message`.
    static func diagnostic(in line: String) -> BuildDiagnostic? {
        // Located: an absolute path, a line and a column (XCTest failures have no column).
        if line.first == Marker.pathStart, let located = Self.located(line) {
            return located
        }

        // Unlocated: `error: …`, or a tool or `<unknown>:0` in front of it.
        let body = line.hasPrefix(Marker.unknownLocation + Marker.messageSeparator)
            ? String(line.dropFirst(Marker.unknownLocation.count + Marker.messageSeparator.count))
            : line
        for severity in [BuildDiagnostic.Severity.error, .warning] {
            let prefix = severity.rawValue + Marker.messageSeparator
            if body.hasPrefix(prefix) {
                return BuildDiagnostic(severity: severity, file: nil, line: nil, column: nil, message: String(body.dropFirst(prefix.count)))
            }

            // `ld: error: …`, `clang: error: …`: a single word before the severity.
            guard let range = body.range(of: Marker.messageSeparator + prefix) else { continue }
            let tool = body[..<range.lowerBound]
            guard !tool.isEmpty, !tool.contains(" "), !tool.contains(Marker.pathStart) else { continue }
            return BuildDiagnostic(severity: severity, file: nil, line: nil, column: nil, message: tool + Marker.messageSeparator + body[range.upperBound...])
        }
        return nil
    }

    private static func located(_ line: String) -> BuildDiagnostic? {
        for severity in [BuildDiagnostic.Severity.error, .warning] {
            guard let range = line.range(of: Marker.messageSeparator + severity.rawValue + Marker.messageSeparator) else { continue }

            // `path:line:column` before the severity; paths may contain `:`, the numbers can't.
            let location = line[..<range.lowerBound].split(separator: Marker.separator, omittingEmptySubsequences: false)
            guard location.count >= 3, let column = Int(location[location.count - 1]), let lineNumber = Int(location[location.count - 2]) else {
                return nil
            }
            let file = location.dropLast(2).joined(separator: String(Marker.separator))
            return BuildDiagnostic(severity: severity, file: file, line: lineNumber, column: column, message: String(line[range.upperBound...]))
        }
        return nil
    }

    private static func isSummary(_ diagnostic: BuildDiagnostic) -> Bool {
        Marker.summaries.contains { diagnostic.message.hasPrefix($0) }
    }

    /// Drops terminal colour codes (`ESC [ 1 ; 31 m`): Swift 6.4 colours diagnostics even into a file.
    public static func removingEscapes(_ line: String) -> String {
        guard line.contains(Marker.escape) else { return line }
        var result = ""
        var inEscape = false
        var sawBracket = false
        for character in line {
            if character == Marker.escape {
                inEscape = true
                sawBracket = false
                continue
            }
            guard inEscape else {
                result.append(character)
                continue
            }

            // `ESC [` opens the sequence; a letter (or another final byte) closes it.
            if !sawBracket {
                sawBracket = true
                continue
            }
            if Marker.escapeEnd.contains(character) {
                inEscape = false
            }
        }
        return result
    }

    /// The last lines of a log, for failures nothing above explains.
    public static func tail(of log: String, lines count: Int) -> [String] {
        log.split(whereSeparator: \.isNewline).suffix(count).map { Self.removingEscapes(String($0)) }
    }
}
