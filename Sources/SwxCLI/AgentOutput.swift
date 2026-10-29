import ArgumentParser
import Foundation
import SwxWorkspace

/// `--format text|json`, or `SWX_FORMAT=json` for every command: text for people, one JSON
/// object on stdout for agents and scripts (progress stays on stderr).
enum OutputFormat: String, ExpressibleByArgument, CaseIterable {
    case text
    case json

    static let option = "--format"
    private static let environmentVariable = "SWX_FORMAT"
    private static let assignment = "="
    /// Options after this belong to the program being run.
    private static let endOfOptions = "--"

    /// `SWX_FORMAT`, else text.
    static var preferred: OutputFormat {
        ProcessInfo.processInfo.environment[Self.environmentVariable].flatMap(OutputFormat.init(rawValue:)) ?? .text
    }

    /// The format of this invocation: `--format json` anywhere among swx's own arguments, or
    /// `SWX_FORMAT`. Errors are reported in it, whichever command fails.
    static var active: OutputFormat {
        var arguments = Array(CommandLine.arguments.dropFirst())
        return Self.take(from: &arguments)
    }

    /// Takes `--format X` / `--format=X` out of passed-through arguments (up to `--`).
    static func take(from arguments: inout [String]) -> OutputFormat {
        var format = Self.preferred
        var kept: [String] = []
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            if argument == Self.endOfOptions {
                kept += arguments[index...]
                break
            }
            if argument == Self.option, index + 1 < arguments.endIndex, let value = OutputFormat(rawValue: arguments[index + 1]) {
                format = value
                index += 2
                continue
            }
            if argument.hasPrefix(Self.option + Self.assignment), let value = OutputFormat(rawValue: String(argument.dropFirst(Self.option.count + Self.assignment.count))) {
                format = value
                index += 1
                continue
            }
            kept.append(argument)
            index += 1
        }
        arguments = kept
        return format
    }
}

extension ReportFormat {
    /// `SWX_FORMAT=json` makes every report JSON by default.
    static var preferred: ReportFormat {
        OutputFormat.preferred == .json ? .json : .text
    }
}

/// One JSON object per command on stdout.
enum JSONOutput {
    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func print<T: Encodable>(_ value: T) {
        guard var data = try? Self.encoder.encode(value) else { return }
        data.append(UInt8(ascii: "\n"))
        FileHandle.standardOutput.write(data)
    }

    /// `{"status":"error","error":{"code":…,"message":…,"fix":…}}`
    static func printError(_ error: Error) {
        Self.print(ErrorReport(error: ErrorSummary(error)))
    }

    private struct ErrorReport: Encodable {
        let status = "error"
        let error: ErrorSummary
    }

    /// Prints a command's report and exits like the command: 0 when it succeeded, 1 otherwise.
    static func finish(_ report: CommandReport) throws -> Never {
        Self.print(report)
        throw report.status == .succeeded ? ExitCode.success : ExitCode.failure
    }
}
