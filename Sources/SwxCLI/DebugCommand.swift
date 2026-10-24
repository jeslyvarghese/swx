import ArgumentParser
import Foundation
import SwxWorkspace

/// `swx debug …`: verification tools for swx itself.
struct DebugCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "debug",
        abstract: "Verification tools for swx itself.",
        subcommands: [ManifestParityCommand.self]
    )
}

/// Compares the static manifest parser with `swift package dump-package` on every cached manifest.
struct ManifestParityCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "manifest-parity",
        abstract: "Differential-test the static manifest parser against real evaluation."
    )

    @OptionGroup var global: GlobalOptions

    @Option(help: "Check at most this many manifests.")
    var limit: Int?

    func run() async throws {
        let diagnostics = Diagnostics(
            cacheDirectory: self.global.cachePath.map { URL(fileURLWithPath: $0) },
            maximumConcurrency: self.global.jobs ?? ResolverDefaults.concurrency
        )
        let report = try await diagnostics.manifestParity(limit: self.limit)

        for (reason, count) in report.declineReasons {
            print("declined ×\(count): \(reason)")
        }
        for (revision, explanation) in report.mismatches {
            print("MISMATCH \(revision)\n\(explanation)\n")
        }
        print("checked \(report.checked): \(report.matched) matched, \(report.declined) declined (fallback), \(report.evaluationFailed) unevaluable, \(report.mismatches.count) mismatched")
        if !report.mismatches.isEmpty {
            throw ExitCode.failure
        }
    }
}
