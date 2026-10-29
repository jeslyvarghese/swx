import ArgumentParser
import Foundation
import SwxCore
import SwxWorkspace

/// Shared defaults for the CLI.
enum ResolverDefaults {
    /// Subprocess fan-out: git and swiftc are I/O- and CPU-bound, so twice the cores.
    private static let concurrencyPerCore = 2

    static var concurrency: Int {
        ProcessInfo.processInfo.activeProcessorCount * Self.concurrencyPerCore
    }
}

/// Runs a resolve and prints a SwiftPM-style summary.
enum ResolveRunner {
    static func run(mode: ResolveMode, global: GlobalOptions, workspace: Workspace? = nil, format: ReportFormat = .preferred) async throws {
        try await CommandSupport.prepareToolchain(for: global)
        let clock = ContinuousClock()
        let started = clock.now

        // Resolve, mapping errors to a clean exit.
        let report: ResolveReport
        do {
            report = try await (workspace ?? global.makeWorkspace()).resolve(mode: mode)
        } catch {
            CommandSupport.report(error)
            throw ExitCode.failure
        }
        let elapsed = clock.now - started
        if format == .json {
            JSONOutput.print(ResolveSummary(report, elapsed: elapsed))
            return
        }
        guard global.verbosity > .quiet else { return }

        // Pin changes, then a one-line summary.
        Self.printChanges(report)
        print("\(Self.describe(report.outcome)) \(report.pins.count) package\(report.pins.count == 1 ? "" : "s") in \(Self.format(elapsed))")
    }

    /// Pin changes and the summary line, for `--all` (printed under each package's path).
    static func lines(_ report: ResolveReport, elapsed: Duration) -> [String] {
        report.changes.map(Self.describe) + ["\(Self.describe(report.outcome)) \(report.pins.count) package\(report.pins.count == 1 ? "" : "s") in \(Self.format(elapsed))"]
    }

    /// Resolves every package under the package path (`--all`).
    static func runAll(mode: ResolveMode, global: GlobalOptions) async throws {
        try await AllPackages.forEach(global) { options in
            try await Toolchains().prepare(for: options.packageURL, missing: .install) { CommandSupport.status($0) }
            let clock = ContinuousClock()
            let started = clock.now
            let report = try await options.makeWorkspace().resolve(mode: mode)
            return Self.lines(report, elapsed: clock.now - started)
        }
    }

    static func printChanges(_ report: ResolveReport) {
        // With `--format json`, stdout is the report's alone.
        guard OutputFormat.active == .text else {
            Self.reportChanges(report)
            return
        }
        for change in report.changes {
            print(Self.describe(change))
        }
    }

    /// For commands whose stdout is data (graphs, JSON): pin changes go to stderr.
    static func reportChanges(_ report: ResolveReport) {
        for change in report.changes {
            FileHandle.standardError.write(Data((Self.describe(change) + "\n").utf8))
        }
    }

    private static func describe(_ change: PinChange) -> String {
        switch (change.old, change.new) {
        case (nil, let new?):
            return "+ \(change.identity) \(new)"
        case (let old?, nil):
            return "- \(change.identity) \(old)"
        case (let old?, let new?):
            return "~ \(change.identity) \(old) -> \(new)"
        case (nil, nil):
            return "  \(change.identity)"
        }
    }

    private static func describe(_ outcome: ResolveOutcome) -> String {
        switch outcome {
        case .upToDate:
            return "Up to date:"
        case .restoredFromPins:
            return "Restored"
        case .resolved:
            return "Resolved"
        }
    }

    /// `swx resolve --format json`.
    struct ResolveSummary: Encodable {
        struct Package: Encodable {
            let identity: String
            let state: String
        }

        struct Change: Encodable {
            let identity: String
            let old: String?
            let new: String?
        }

        let status = "succeeded"
        let outcome: String
        let packages: [Package]
        let changes: [Change]
        let seconds: Double

        init(_ report: ResolveReport, elapsed: Duration) {
            switch report.outcome {
            case .upToDate:
                self.outcome = "up-to-date"
            case .restoredFromPins:
                self.outcome = "restored"
            case .resolved:
                self.outcome = "resolved"
            }
            self.packages = report.pins.map { Package(identity: "\($0.package.identity)", state: "\($0.state)") }.sorted { $0.identity < $1.identity }
            self.changes = report.changes.map { Change(identity: "\($0.identity)", old: $0.old.map { "\($0)" }, new: $0.new.map { "\($0)" }) }
            self.seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / ResolveRunner.attosecondsPerSecond
        }
    }

    private static let millisecondsPerSecond = 1000.0
    fileprivate static let attosecondsPerSecond = 1e18

    private static func format(_ duration: Duration) -> String {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / Self.attosecondsPerSecond
        guard seconds < 1 else {
            return String(format: "%.2fs", seconds)
        }
        return String(format: "%.0fms", seconds * Self.millisecondsPerSecond)
    }
}
