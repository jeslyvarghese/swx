import ArgumentParser
import Foundation
import SwxWorkspace

/// `swx xcode …`: resolve packages for Xcode projects so `xcodebuild` never resolves itself.
struct XcodeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "xcode",
        abstract: "Resolve Swift packages of Xcode projects and workspaces.",
        subcommands: [XcodeResolve.self, XcodeUpdate.self]
    )
}

/// Options shared by the Xcode commands.
struct XcodeOptions: ParsableArguments {
    private static let defaultSourcePackages = "SourcePackages"

    @Option(name: [.customLong("project"), .customLong("workspace")], help: "The .xcodeproj or .xcworkspace (default: the one in the current directory).")
    var project: String?

    @Option(name: .customLong("source-packages"), help: "Where to place checkouts; pass the same path to xcodebuild -clonedSourcePackagesDirPath.")
    var sourcePackages: String = Self.defaultSourcePackages

    @OptionGroup var global: GlobalOptions

    func makeWorkspace() throws -> (Workspace, URL) {
        let projectURL = try self.project.map { FileSystemPaths.absolute($0) }
            ?? Workspace.locateXcodeProject(in: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        let sourcePackages = FileSystemPaths.absolute(self.sourcePackages)
        let workspace = Workspace(options: WorkspaceOptions(
            root: .xcodeProject(projectURL, sourcePackages: sourcePackages),
            cacheDirectory: self.global.cachePath.map { URL(fileURLWithPath: $0) },
            maximumConcurrency: self.global.jobs ?? ResolverDefaults.concurrency,
            verbosity: self.global.verbosity
        ))
        return (workspace, sourcePackages)
    }

    /// The flags that make xcodebuild use what swx prepared.
    static func xcodebuildFlags(sourcePackages: URL) -> String {
        "-clonedSourcePackagesDirPath \(sourcePackages.path) -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile"
    }
}

struct XcodeResolve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "resolve", abstract: "Resolve and check out an Xcode project's packages.")

    @OptionGroup var options: XcodeOptions

    func run() async throws {
        try await Self.resolve(self.options, mode: .respectPins)
    }

    static func resolve(_ options: XcodeOptions, mode: ResolveMode) async throws {
        let (workspace, sourcePackages) = try options.makeWorkspace()
        try await ResolveRunner.run(mode: mode, global: options.global, workspace: workspace)
        guard options.global.verbosity > .quiet else { return }
        print("xcodebuild flags: \(XcodeOptions.xcodebuildFlags(sourcePackages: sourcePackages))")
    }
}

struct XcodeUpdate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "Update an Xcode project's packages to the newest allowed versions.")

    @OptionGroup var options: XcodeOptions

    func run() async throws {
        try await XcodeResolve.resolve(self.options, mode: .update)
    }
}
