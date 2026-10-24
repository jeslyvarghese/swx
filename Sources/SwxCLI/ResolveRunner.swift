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
    static func run(mode: ResolveMode, global: GlobalOptions) async throws {
        let clock = ContinuousClock()
        let started = clock.now

        // Resolve, mapping errors to a clean exit.
        let report: ResolveReport
        do {
            report = try await global.makeWorkspace().resolve(mode: mode)
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            throw ExitCode.failure
        }
        guard global.verbosity > .quiet else { return }

        // Pin changes, then a one-line summary.
        for change in report.changes {
            print(Self.describe(change))
        }
        let elapsed = clock.now - started
        print("\(Self.describe(report.outcome)) \(report.pins.count) package\(report.pins.count == 1 ? "" : "s") in \(Self.format(elapsed))")
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

    private static let millisecondsPerSecond = 1000.0
    private static let attosecondsPerSecond = 1e18

    private static func format(_ duration: Duration) -> String {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / Self.attosecondsPerSecond
        guard seconds < 1 else {
            return String(format: "%.2fs", seconds)
        }
        return String(format: "%.0fms", seconds * Self.millisecondsPerSecond)
    }
}
