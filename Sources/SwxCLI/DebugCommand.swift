import ArgumentParser
import Foundation
import SwxWorkspace

/// `swx debug …`: verification tools for swx itself.
struct DebugCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "debug",
        abstract: "Verification tools for swx itself.",
        subcommands: [ManifestParityCommand.self, TagParityCommand.self]
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

    /// Which manifest reader to hold against `dump-package`.
    enum Candidate: String, ExpressibleByArgument {
        case `static`
        case toolchain
        case xcode
    }

    @Option(help: "The reader to compare with dump-package: static (the parser), toolchain or xcode (compiled against that ManifestAPI).")
    var candidate: Candidate = .static

    func run() async throws {
        let diagnostics = Diagnostics(
            cacheDirectory: self.global.cachePath.map { URL(fileURLWithPath: $0) },
            maximumConcurrency: self.global.jobs ?? ResolverDefaults.concurrency
        )
        let report = try await diagnostics.manifestParity(limit: self.limit, reader: self.reader)

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

    private var reader: ManifestReader {
        switch self.candidate {
        case .static:
            return .staticParser
        case .toolchain:
            return .toolchainManifestAPI
        case .xcode:
            return .xcodeManifestAPI
        }
    }
}

/// Compares tag listings over HTTP (`ls-refs`) with `git ls-remote`.
struct TagParityCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tag-parity",
        abstract: "Check that listing tags over HTTP matches git ls-remote."
    )

    @Argument(help: "Repository URLs.")
    var urls: [String]

    func run() async throws {
        let diagnostics = Diagnostics(cacheDirectory: nil, maximumConcurrency: ResolverDefaults.concurrency)
        var mismatches = 0
        for url in self.urls {
            let result = try await diagnostics.tagListingMatches(url: url)
            let method = result.viaHTTP ? "ls-refs" : "fallback to git"
            print("\(result.matches ? "same" : "DIFFERENT") \(url): \(result.count) tags (\(method))")
            mismatches += result.matches ? 0 : 1
        }
        if mismatches > 0 {
            throw ExitCode.failure
        }
    }
}
