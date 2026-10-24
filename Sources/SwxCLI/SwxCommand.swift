import ArgumentParser
import Foundation
import SwxCore
import SwxWorkspace

/// `swx`: a fast, SwiftPM-compatible package manager.
///
/// Installed as `swift-x` it also works as `swift x …` through SwiftPM's subcommand discovery.
public struct SwxCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "swx",
        abstract: "A fast, drop-in companion to SwiftPM.",
        version: "0.1.0",
        subcommands: [
            PackageCommand.self, Build.self, Test.self, Run.self, Resolve.self, Update.self,
            ToolCommand.self, ToolchainCommand.self, XcodeCommand.self, DebugCommand.self,
        ]
    )

    public init() {}
}

/// `swx package …`, mirroring `swift package …`.
struct PackageCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "package",
        abstract: "Perform operations on Swift packages (other subcommands go to `swift package`).",
        subcommands: [Resolve.self, Update.self, PackagePassthrough.self],
        defaultSubcommand: PackagePassthrough.self
    )
}

/// Options shared by every command, spelled like SwiftPM's.
struct GlobalOptions: ParsableArguments {
    @Option(name: .customLong("package-path"), help: "Specify the package path to operate on.")
    var packagePath: String = "."

    @Option(name: .customLong("cache-path"), help: "Specify the shared cache directory.")
    var cachePath: String?

    @Option(name: .customShort("j"), help: "The number of jobs to spawn in parallel.")
    var jobs: Int?

    @Flag(name: [.customShort("v"), .customLong("verbose")], help: "Increase verbosity.")
    var verbose = false

    @Flag(name: [.customShort("q"), .customLong("quiet")], help: "Decrease verbosity.")
    var quiet = false

    var verbosity: Verbosity {
        if self.quiet {
            return .quiet
        }
        return self.verbose ? .verbose : .normal
    }

    var packageURL: URL {
        URL(fileURLWithPath: self.packagePath).standardizedFileURL
    }

    func workspaceOptions() -> WorkspaceOptions {
        WorkspaceOptions(
            root: .package(self.packageURL),
            cacheDirectory: self.cachePath.map { URL(fileURLWithPath: $0) },
            maximumConcurrency: self.jobs ?? ResolverDefaults.concurrency,
            verbosity: self.verbosity
        )
    }

    func makeWorkspace() -> Workspace {
        Workspace(options: self.workspaceOptions())
    }
}

/// `swx package resolve`: resolve dependencies, honouring `Package.resolved`.
struct Resolve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Resolve package dependencies.")

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await ResolveRunner.run(mode: .respectPins, global: self.global)
    }
}

/// `swx package update`: re-resolve to the newest allowed versions.
struct Update: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Update package dependencies.")

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await ResolveRunner.run(mode: .update, global: self.global)
    }
}
