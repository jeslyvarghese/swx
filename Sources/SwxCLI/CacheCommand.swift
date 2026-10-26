import ArgumentParser
import Foundation
import SwxWorkspace

/// `swx cache pull|push`: share the store with other machines (CI) through a remote cache.
struct CacheCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cache",
        abstract: "Share source trees, binary artifacts and test results through a remote cache.",
        discussion: """
        The remote is --remote or $SWX_REMOTE_CACHE: a directory or file:// URL, an http(s):// server
        that accepts GET, HEAD and PUT (bearer token in $SWX_REMOTE_CACHE_TOKEN), or s3://bucket/prefix
        (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_REGION; $SWX_S3_ENDPOINT for R2 or MinIO).

        In CI: swx cache pull, swx package resolve (no git needed for cached pins),
        swx test --selective, then swx cache push.
        """,
        subcommands: [Pull.self, Push.self]
    )

    /// Options both subcommands take.
    struct Options: ParsableArguments {
        @OptionGroup var global: GlobalOptions

        @Option(help: "The remote cache (default: $SWX_REMOTE_CACHE).")
        var remote: String?

        func location() throws -> String {
            guard let remote = self.remote ?? ProcessInfo.processInfo.environment[Workspace.remoteCacheVariable], !remote.isEmpty else {
                throw ValidationError("name a remote cache with --remote or $\(Workspace.remoteCacheVariable)")
            }
            return remote
        }

        func transfer(_ direction: CacheDirection) async throws {
            let location = try self.location()
            let report = try await CommandSupport.reportingErrors {
                try await self.global.makeWorkspace().transferCache(direction, remote: location)
            }
            let verb = direction == .pull ? "pulled" : "pushed"
            let side = direction == .pull ? "not in the remote cache" : "not in the local store"
            let megabytes = Double(report.bytes) / Self.bytesPerMegabyte
            print("\(verb) \(report.transferred) entries (\(String(format: "%.1f", megabytes)) MB); \(report.present) already there, \(report.unavailable) \(side)")
        }

        private static let bytesPerMegabyte = 1_048_576.0
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
