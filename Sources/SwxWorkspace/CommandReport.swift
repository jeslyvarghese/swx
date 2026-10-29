import Foundation
import SwxBuild
import SwxCore
import SwxSystem

/// What a build, test or run did, for `--format json`: the diagnostics and failing tests an
/// agent acts on, with the full log kept on disk for anything more.
public struct CommandReport: Sendable, Encodable {
    public enum Status: String, Sendable, Encodable {
        case succeeded
        case failed
    }

    public let command: String
    public let status: Status
    public let exitCode: Int32
    public let seconds: Double
    public let diagnostics: [BuildDiagnostic]
    public let tests: TestReport?
    /// The products directory (Apple platforms), or the launched app.
    public let products: String?
    /// The program's own output (`swx run`).
    public let output: String?
    /// The full log.
    public let log: String
    /// The log's last lines, when it failed and no diagnostic says why.
    public let logTail: [String]?
    /// Set when the command was stopped at its deadline.
    public let timedOut: Bool?

    /// How many log lines a failure nothing explains carries.
    static let tailLines = 40
}

/// The kind of report: the log's name and how its output is read.
public enum ReportedCommand: String, Sendable {
    case build
    case test
    case run
}

extension CommandReport {
    /// A report of a finished command from its log.
    init(command: ReportedCommand, exitCode: Int32, seconds: Double, log: URL, logText: String, tests: TestReport? = nil, products: String? = nil, output: String? = nil, timedOut: Bool = false) {
        let diagnostics = BuildLog.diagnostics(in: logText)
        let failedTests = tests.map { $0.failed > 0 } ?? false
        let explained = !diagnostics.filter { $0.severity == .error }.isEmpty || failedTests
        self.init(
            command: command.rawValue,
            status: exitCode == 0 && !timedOut ? .succeeded : .failed,
            exitCode: exitCode,
            seconds: seconds,
            diagnostics: diagnostics,
            tests: tests,
            products: products,
            output: output,
            log: log.path,
            logTail: exitCode != 0 && !explained ? BuildLog.tail(of: logText, lines: Self.tailLines) : nil,
            timedOut: timedOut ? true : nil
        )
    }

    static func seconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }
}

extension HostBuilds {
    private enum Layout {
        static let logs = "swx-logs"
        static let logExtension = "log"
    }

    /// SwiftPM's line after the build, before the program's own output.
    private static let buildCompleteMarkers = ["Build complete!", "Build of product"]

    /// Runs a prepared `swift build|test|run` invocation with its output in a log instead of the
    /// terminal, and reports it.
    public static func runReporting(_ invocation: [String], command: ReportedCommand, packageDirectory: URL, timeout: Duration? = nil) async throws -> CommandReport {
        let logs = packageDirectory.appendingPathComponent(WellKnownFile.buildDirectory).appendingPathComponent(Layout.logs)
        try FileSystem.createDirectory(logs)
        let log = logs.appendingPathComponent(command.rawValue).appendingPathExtension(Layout.logExtension)
        let start = ContinuousClock.now

        // Everything in one log, in order; a deadline only when asked (a server never exits).
        let status: Int32
        var timedOut = false
        var programOutput: String?
        if let timeout {
            // Separate streams: SwiftPM's progress on stderr, the program's output on stdout.
            let (result, stopped) = try await ProcessRunner.run(invocation, in: packageDirectory, timeout: timeout)
            try FileSystem.writeAtomically(result.standardError + result.standardOutput, to: log)
            status = result.exitCode
            timedOut = stopped
            programOutput = Self.programOutput(in: result.output)
        } else {
            status = try await ProcessRunner.runLogged(invocation, in: packageDirectory, log: log) { _ in false }
        }
        let text = String(decoding: FileSystem.readIfPresent(log) ?? Data(), as: UTF8.self)

        // Tests are counted from the log; a run's output is what follows the build.
        let tests = command == .test ? TestLog.report(in: text) : nil
        let output = command == .run ? programOutput ?? Self.programOutput(in: text) : nil
        return CommandReport(command: command, exitCode: status, seconds: CommandReport.seconds(since: start), log: log, logText: text, tests: tests, output: output, timedOut: timedOut)
    }

    private static func programOutput(in log: String) -> String {
        let lines = log.split(separator: "\n", omittingEmptySubsequences: false)
        guard let marker = lines.lastIndex(where: { line in Self.buildCompleteMarkers.contains { line.hasPrefix($0) } }) else {
            return log
        }
        return lines[(marker + 1)...].joined(separator: "\n")
    }
}
