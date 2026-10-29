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
        version: "0.7.0",
        subcommands: [
            PackageCommand.self, Add.self, Remove.self, Upgrade.self, Publish.self, Build.self, Test.self, Run.self, Resolve.self, Update.self,
            Graph.self, Why.self, Outdated.self, Audit.self, Licenses.self, Inspect.self, CacheCommand.self, SelfCommand.self, ToolCommand.self, ToolchainCommand.self, XcodeCommand.self, Devices.self, HotCommand.self, Screenshot.self,
            AgentGuide.self, MCPCommand.self, DebugCommand.self,
        ]
    )

    public init() {}
}

/// `swx package …`, mirroring `swift package …`.
struct PackageCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "package",
        abstract: "Perform operations on Swift packages (other subcommands go to `swift package`).",
        subcommands: [Resolve.self, Update.self, ShowDependencies.self, PackagePassthrough.self],
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

    @Option(name: .customLong("config-path"), help: "SwiftPM's shared configuration directory (registries, mirrors).")
    var configPath: String?

    @Option(name: .customLong("security-path"), help: "SwiftPM's shared security directory (fingerprints).")
    var securityPath: String?

    @Option(name: .customLong("netrc-file"), help: "The netrc file with registry credentials (default: ~/.netrc).")
    var netrcFile: String?

    @Flag(name: .customLong("netrc"), help: "Use the netrc file even where the keychain would be preferred.")
    var forceNetrc = false

    @Flag(name: .customLong("disable-keychain"), help: "Don't read registry credentials from the macOS keychain.")
    var disableKeychain = false

    @Flag(name: .customLong("use-registry-identity-for-scm"), help: "Look git dependencies up in the registry and use their registry identity.")
    var useRegistryIdentityForSCM = false

    @Flag(name: .customLong("replace-scm-with-registry"), help: "Replace versioned git dependencies with their registry packages where the registry knows them.")
    var replaceSCMWithRegistry = false

    @Flag(name: .customLong("disable-scm-to-registry-transformation"), help: "Use git dependencies as declared (the default).")
    var disableSCMToRegistryTransformation = false

    @Flag(inversion: .prefixedEnableDisable, help: "Use prebuilt swift-syntax libraries for macros (as SwiftPM 6.4 does).")
    var experimentalPrebuilts = true

    @Option(name: .customLong("experimental-prebuilts-download-url"), help: .hidden)
    var prebuiltsDownloadURL: String?

    @Option(name: .customLong("experimental-prebuilts-root-cert"), help: .hidden)
    var prebuiltsRootCertificate: String?

    var prebuilts: PrebuiltsOptions {
        PrebuiltsOptions(
            use: self.experimentalPrebuilts ? .enabled : .disabled,
            downloadURL: self.prebuiltsDownloadURL.flatMap(URL.init(string:)),
            rootCertificate: self.prebuiltsRootCertificate.map(FileSystemPaths.absolute)
        )
    }

    var registryTransformation: RegistryTransformation {
        if self.disableSCMToRegistryTransformation {
            return .disabled
        }
        if self.replaceSCMWithRegistry {
            return .replaceWithRegistry
        }
        return self.useRegistryIdentityForSCM ? .useRegistryIdentity : .disabled
    }

    /// The same shared locations and credential sources SwiftPM would use.
    var swiftPMSettings: SwiftPMSettings {
        SwiftPMSettings(
            configurationDirectory: self.configPath.map(FileSystemPaths.absolute),
            securityDirectory: self.securityPath.map(FileSystemPaths.absolute),
            netrcFile: self.netrcFile.map(FileSystemPaths.absolute),
            credentialStore: self.credentialStore
        )
    }

    private var credentialStore: SwiftPMSettings.CredentialStore {
        if self.forceNetrc {
            return .netrc
        }
        return self.disableKeychain ? .keychainDisabled : .platformDefault
    }

    var verbosity: Verbosity {
        if self.quiet {
            return .quiet
        }
        return self.verbose ? .verbose : .normal
    }

    var packageURL: URL {
        FileSystemPaths.absolute(self.packagePath)
    }

    func workspaceOptions() -> WorkspaceOptions {
        WorkspaceOptions(
            root: .package(self.packageURL),
            cacheDirectory: self.cachePath.map { URL(fileURLWithPath: $0) },
            maximumConcurrency: self.jobs ?? ResolverDefaults.concurrency,
            verbosity: self.verbosity,
            swiftPM: self.swiftPMSettings,
            registryTransformation: self.registryTransformation,
            prebuilts: self.prebuilts
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

    @Flag(help: "Only check that Package.resolved is up to date (as `uv lock --check`); exit 1 if resolving would change it.")
    var check = false

    @Flag(help: AllPackages.help)
    var all = false

    @Option(help: "text or json (default: $SWX_FORMAT, else text).")
    var format: ReportFormat = .preferred

    func run() async throws {
        switch (self.check, self.all) {
        case (false, false):
            try await ResolveRunner.run(mode: .respectPins, global: self.global, format: self.format)
            return
        case (false, true):
            try await ResolveRunner.runAll(mode: .respectPins, global: self.global)
            return
        case (true, true):
            try await Self.checkAll(self.global)
            return
        case (true, false):
            break
        }

        // Nothing is written or checked out; the exit status is the answer.
        let status = try await CommandSupport.reportingErrors { try await self.global.makeWorkspace().checkLockfile() }
        if self.format == .json {
            try Self.printJSON(status)
        }
        switch status {
        case .upToDate:
            print("Package.resolved is up to date")
        case .missing:
            FileHandle.standardError.write(Data("error: Package.resolved is missing; run `swx package resolve`\n".utf8))
            throw ExitCode.failure
        case .stale(let reason):
            FileHandle.standardError.write(Data("error: Package.resolved is out of date (\(reason)); run `swx package resolve`\n".utf8))
            throw ExitCode.failure
        }
    }
}

extension Resolve {
    /// `--check --format json`: `{"status":"up-to-date"}`, or the problem as an error code.
    private static func printJSON(_ status: LockfileStatus) throws -> Never {
        switch status {
        case .upToDate:
            JSONOutput.print(["status": "up-to-date"])
            throw ExitCode.success
        case .missing:
            JSONOutput.printError(WorkspaceError(description: "Package.resolved is missing", code: .lockfileMissing, fix: "swx resolve"))
        case .stale(let reason):
            JSONOutput.printError(WorkspaceError(description: "Package.resolved is out of date (\(reason))", code: .lockfileStale, fix: "swx resolve"))
        }
        throw ExitCode.failure
    }

    /// `--check --all`: every package's lockfile, each failing on its own line.
    static func checkAll(_ global: GlobalOptions) async throws {
        try await AllPackages.forEach(global) { options in
            switch try await options.makeWorkspace().checkLockfile() {
            case .upToDate:
                return ["Package.resolved is up to date"]
            case .missing:
                throw ValidationError("Package.resolved is missing; run `swx package resolve`")
            case .stale(let reason):
                throw ValidationError("Package.resolved is out of date (\(reason)); run `swx package resolve`")
            }
        }
    }
}

/// `swx package update`: re-resolve to the newest allowed versions.
struct Update: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Update package dependencies.")

    @OptionGroup var global: GlobalOptions

    @Flag(help: AllPackages.help)
    var all = false

    @Option(help: "text or json (default: $SWX_FORMAT, else text).")
    var format: ReportFormat = .preferred

    func run() async throws {
        guard self.all else {
            try await ResolveRunner.run(mode: .update, global: self.global, format: self.format)
            return
        }
        try await ResolveRunner.runAll(mode: .update, global: self.global)
    }
}
