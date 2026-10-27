import ArgumentParser
import Foundation
import SwxWorkspace

/// `swx cache pull|push`: share the store with other machines (CI) through a remote cache.
struct CacheCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cache",
        abstract: "Share source trees, binary artifacts, test results and build outputs through a remote cache.",
        discussion: """
        The remote is --remote or $SWX_REMOTE_CACHE: a directory or file:// URL, an http(s):// server
        that accepts GET, HEAD and PUT (bearer token in $SWX_REMOTE_CACHE_TOKEN), or s3://bucket/prefix
        (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_REGION; $SWX_S3_ENDPOINT for R2 or MinIO).

        In CI: swx cache pull --build, swx package resolve (no git needed for cached pins),
        swx test --selective, then swx cache push --build.

        --build also copies .build. SwiftPM reuses it only at the same absolute path with the same
        toolchain, which CI runners keep stable; a pull restores the archive built from exactly these
        files, else one built with the same Package.resolved, and leaves an existing build alone.
        """,
        subcommands: [Pull.self, Push.self]
    )

    /// Options both subcommands take.
    struct Options: ParsableArguments {
        @OptionGroup var global: GlobalOptions

        @Option(help: "The remote cache (default: $SWX_REMOTE_CACHE).")
        var remote: String?

        @Flag(help: "Also copy the package's build outputs (.build).")
        var build = false

        func location() throws -> String {
            guard let remote = self.remote ?? ProcessInfo.processInfo.environment[Workspace.remoteCacheVariable], !remote.isEmpty else {
                throw ValidationError("name a remote cache with --remote or $\(Workspace.remoteCacheVariable)")
            }
            return remote
        }

        func transfer(_ direction: CacheDirection) async throws {
            let location = try self.location()
            let outputs: BuildOutputs = self.build ? .include : .exclude
            let report = try await CommandSupport.reportingErrors {
                try await self.global.makeWorkspace().transferCache(direction, remote: location, build: outputs)
            }
            let verb = direction == .pull ? "pulled" : "pushed"
            let side = direction == .pull ? "not in the remote cache" : "not in the local store"
            print("\(verb) \(report.transferred) entries (\(Self.megabytes(report.bytes))); \(report.present) already there, \(report.unavailable) \(side)")
            if let build = report.build {
                print(Self.describe(build))
            }
        }

        private static let bytesPerMegabyte = 1_048_576.0

        private static func megabytes(_ bytes: Int64) -> String {
            String(format: "%.1f MB", Double(bytes) / Self.bytesPerMegabyte)
        }

        private static func describe(_ match: BuildCacheMatch) -> String {
            match == .exact ? "built from these sources" : "built with the same dependencies"
        }

        private static func describe(_ outcome: BuildCacheOutcome) -> String {
            switch outcome {
            case .restored(let match, let bytes):
                return "build: restored .build (\(Self.megabytes(bytes))), \(Self.describe(match))"
            case .notCached:
                return "build: nothing cached for these sources or dependencies"
            case .keptLocal:
                return "build: kept the existing .build"
            case .uploaded(let matches, let bytes):
                return "build: uploaded .build (\(Self.megabytes(bytes))) as \(matches.map(Self.describe).joined(separator: " and "))"
            case .alreadyCached:
                return "build: already cached"
            case .nothingBuilt:
                return "build: nothing built yet"
            }
        }
    }

    struct Pull: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Download what this project's pins and tests need from the remote cache into the store."
        )

        @OptionGroup var options: Options

        func run() async throws {
            try await self.options.transfer(.pull)
        }
    }

    struct Push: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Upload this project's store entries the remote cache doesn't have yet."
        )

        @OptionGroup var options: Options

        func run() async throws {
            try await self.options.transfer(.push)
        }
    }
}
