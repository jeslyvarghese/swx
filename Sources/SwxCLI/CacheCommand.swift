import ArgumentParser
import Foundation
import SwxWorkspace

/// `swx cache pull|push`: share the store with other machines (CI) through a remote cache.
struct CacheCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cache",
        abstract: "Share the store through a remote cache, and keep both from growing forever.",
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
        subcommands: [Pull.self, Push.self, Size.self, Prune.self]
    )

    /// Options both subcommands take.
    struct Options: ParsableArguments {
        @OptionGroup var global: GlobalOptions

        @Option(help: "The remote cache (default: $SWX_REMOTE_CACHE).")
        var remote: String?

        @Flag(help: "Also copy the package's build outputs (.build).")
        var build = false

        @Flag(help: AllPackages.help)
        var all = false

        func location() throws -> String {
            guard let remote = self.remote ?? ProcessInfo.processInfo.environment[Workspace.remoteCacheVariable], !remote.isEmpty else {
                throw ValidationError("name a remote cache with --remote or $\(Workspace.remoteCacheVariable)")
            }
            return remote
        }

        func transfer(_ direction: CacheDirection) async throws {
            let location = try self.location()
            let outputs: BuildOutputs = self.build ? .include : .exclude
            guard !self.all else {
                try await AllPackages.forEach(self.global) { options in
                    Self.lines(try await options.makeWorkspace().transferCache(direction, remote: location, build: outputs), direction)
                }
                return
            }

            let report = try await CommandSupport.reportingErrors {
                try await self.global.makeWorkspace().transferCache(direction, remote: location, build: outputs)
            }
            for line in Self.lines(report, direction) {
                print(line)
            }
        }

        private static func lines(_ report: CacheTransferReport, _ direction: CacheDirection) -> [String] {
            let verb = direction == .pull ? "pulled" : "pushed"
            let side = direction == .pull ? "not in the remote cache" : "not in the local store"
            let summary = "\(verb) \(report.transferred) entries (\(ByteCount.megabytes(report.bytes))); \(report.present) already there, \(report.unavailable) \(side)"
            return [summary] + (report.build.map { [Self.describe($0)] } ?? [])
        }

        private static func describe(_ match: BuildCacheMatch) -> String {
            match == .exact ? "built from these sources" : "built with the same dependencies"
        }

        private static func describe(_ outcome: BuildCacheOutcome) -> String {
            switch outcome {
            case .restored(let match, let bytes):
                return "build: restored .build (\(ByteCount.megabytes(bytes))), \(Self.describe(match))"
            case .notCached:
                return "build: nothing cached for these sources or dependencies"
            case .keptLocal:
                return "build: kept the existing .build"
            case .uploaded(let matches, let bytes):
                return "build: uploaded .build (\(ByteCount.megabytes(bytes))) as \(matches.map(Self.describe).joined(separator: " and "))"
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

/// Sizes as people read them.
enum ByteCount {
    private static let bytesPerMegabyte = 1_048_576.0

    static func megabytes(_ bytes: Int64) -> String {
        String(format: "%.1f MB", Double(bytes) / Self.bytesPerMegabyte)
    }
}

/// `--older-than 30d`: a number and a unit (h, d or w).
struct Age: ExpressibleByArgument, Sendable {
    let seconds: TimeInterval

    private enum Unit: Character, CaseIterable {
        case hours = "h"
        case days = "d"
        case weeks = "w"

        var seconds: TimeInterval {
            switch self {
            case .hours: return 60 * 60
            case .days: return 24 * 60 * 60
            case .weeks: return 7 * 24 * 60 * 60
            }
        }
    }

    static let defaultDays = 30
    static let `default` = Age(seconds: TimeInterval(Self.defaultDays) * Unit.days.seconds)

    private init(seconds: TimeInterval) {
        self.seconds = seconds
    }

    init?(argument: String) {
        guard let last = argument.last, let unit = Unit(rawValue: last), let count = Int(argument.dropLast()), count >= 0 else {
            return nil
        }
        self.seconds = TimeInterval(count) * unit.seconds
    }

    static var defaultValueDescription: String {
        "\(Self.defaultDays)d"
    }
}

extension CacheCommand {
    /// Options of `size` and `prune`: they work on the store, or on a remote named explicitly.
    struct MaintenanceOptions: ParsableArguments {
        @Option(name: .customLong("cache-path"), help: "Specify the shared cache directory.")
        var cachePath: String?

        @Option(help: "Work on this remote cache instead of the local store ($SWX_REMOTE_CACHE is not used, so a prune never deletes remotely by accident).")
        var remote: String?

        var maintenance: CacheMaintenance {
            CacheMaintenance(cacheDirectory: self.cachePath.map { URL(fileURLWithPath: $0) })
        }
    }

    struct Size: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show how much space the store (or a remote cache) takes, by kind of entry."
        )

        @OptionGroup var options: MaintenanceOptions

        func run() async throws {
            let maintenance = self.options.maintenance
            guard let remote = self.options.remote else {
                let sizes = maintenance.sizes().filter { $0.entries > 0 }
                print("store: \(maintenance.storeLocation.path)")
                Self.printTable(sizes.map { ($0.section.description, $0.entries, $0.bytes) })
                return
            }
            let sizes = try await CommandSupport.reportingErrors { try await maintenance.remoteSizes(remote) }
            print("remote: \(remote)")
            Self.printTable(sizes.map { ($0.section.description, $0.entries, $0.bytes) })
        }

        private static let nameWidth = 24
        private static let countWidth = 8

        static func printTable(_ rows: [(name: String, entries: Int, bytes: Int64)]) {
            for row in rows {
                let name = row.name.padding(toLength: Self.nameWidth, withPad: " ", startingAt: 0)
                let entries = String(row.entries).leftPadded(to: Self.countWidth)
                print("  \(name)\(entries) entries  \(ByteCount.megabytes(row.bytes))")
            }
            let total = rows.reduce(Int64(0)) { $0 + $1.bytes }
            print("  \("total".padding(toLength: Self.nameWidth, withPad: " ", startingAt: 0))\(String(rows.reduce(0) { $0 + $1.entries }).leftPadded(to: Self.countWidth)) entries  \(ByteCount.megabytes(total))")
        }
    }

    struct Prune: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Remove store entries no project pins and nothing has used lately (or old remote files).",
            discussion: """
            Locally, an entry stays while any project resolved with swx still pins it (its Package.resolved
            exists), or while it was used within --older-than; scratch from interrupted runs goes after a
            day. Projects keep working either way: checkouts are copies, so only a fresh checkout of a
            removed entry fetches it again. Small metadata (manifests, release lists) is always kept.

            With --remote, files swx wrote that were last uploaded (in a directory remote, last
            downloaded) before --older-than are deleted; the next `swx cache push` uploads what a
            project still needs. HTTP remotes can't be listed: expire files on the server.
            """
        )

        @OptionGroup var options: MaintenanceOptions

        @Option(name: .customLong("older-than"), help: "Keep what was used within this long: a number and h, d or w.")
        var age: Age = .default

        @Flag(name: .customLong("dry-run"), help: "Only report what would be removed.")
        var dryRun = false

        func run() async throws {
            let maintenance = self.options.maintenance
            let effect: PruneEffect = self.dryRun ? .dryRun : .apply
            let verb = self.dryRun ? "would remove" : "removed"

            guard let remote = self.options.remote else {
                let report = try CommandSupport.reportingErrors { try maintenance.prune(unusedFor: self.age.seconds, effect: effect) }
                Size.printTable(report.removed.values.sorted { $0.bytes > $1.bytes }.map { ($0.section.description, $0.entries, $0.bytes) })
                print("\(verb) \(report.entries) entries (\(ByteCount.megabytes(report.bytes))); forgot \(report.forgottenProjects) projects whose Package.resolved is gone")
                return
            }
            let report = try await CommandSupport.reportingErrors { try await maintenance.pruneRemote(remote, unusedFor: self.age.seconds, effect: effect) }
            Size.printTable(report.removed.map { ($0.section.description, $0.entries, $0.bytes) })
            print("\(verb) \(report.entries) remote files (\(ByteCount.megabytes(report.bytes))); kept \(report.kept)")
        }
    }
}

private extension String {
    func leftPadded(to width: Int) -> String {
        String(repeating: " ", count: max(0, width - self.count)) + self
    }
}
