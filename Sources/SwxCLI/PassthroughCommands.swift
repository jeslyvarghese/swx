import ArgumentParser
import Foundation
import SwxSystem
import SwxWorkspace

/// Runs a SwiftPM command after `swx` has resolved dependencies, so SwiftPM never touches the network.
enum Passthrough {
    private static let swift = "swift"
    private static let disableResolution = "--disable-automatic-resolution"
    private static let packagePathOption = "--package-path"
    private static let configPathOption = "--config-path"
    private static let securityPathOption = "--security-path"
    private static let netrcFileOption = "--netrc-file"
    private static let netrcFlag = "--netrc"
    private static let disableKeychainFlag = "--disable-keychain"
    private static let assignment = "="
    private static let compilingCommands: Set<[String]> = [["build"], ["test"], ["run"]]

    /// Whether to resolve before handing over.
    enum Resolution {
        case resolveFirst
        case none
    }

    /// Resolves (unless told not to), then replaces this process with `swift <command> …`.
    static func run(_ command: [String], arguments: [String], resolution: Resolution) async throws -> Never {
        // `.swift-version` picks the toolchain for both swx and the SwiftPM it hands over to.
        let packageURL = FileSystemPaths.absolute(Self.packagePath(in: arguments))
        try await CommandSupport.reportingErrors {
            try await Toolchains().prepare(for: packageURL, missing: .install) { CommandSupport.status($0) }
        }

        if resolution == .resolveFirst {
            try await Self.resolve(packagePath: Self.packagePath(in: arguments), settings: Self.swiftPMSettings(in: arguments))
        }

        // SwiftPM accepts `--disable-automatic-resolution` on every command that may resolve.
        var invocation = [Self.swift] + command
        if resolution == .resolveFirst && !arguments.contains(Self.disableResolution) {
            invocation.append(Self.disableResolution)
        }

        // Builds share one compilation cache across projects when the toolchain can.
        if Self.compilingCommands.contains(command) {
            invocation += await HostBuilds.cacheArguments(
                existing: arguments,
                cacheDirectory: nil,
                packageDirectory: FileSystemPaths.absolute(Self.packagePath(in: arguments))
            )
        }
        ProcessRunner.exec(invocation + arguments)
    }

    /// Honours `--package-path` among the passed-through arguments.
    static func packagePath(in arguments: [String]) -> String {
        Self.value(of: Self.packagePathOption, in: arguments) ?? "."
    }

    /// SwiftPM's shared locations and credential flags, read from the passed-through arguments.
    static func swiftPMSettings(in arguments: [String]) -> SwiftPMSettings {
        SwiftPMSettings(
            configurationDirectory: Self.value(of: Self.configPathOption, in: arguments).map(FileSystemPaths.absolute),
            securityDirectory: Self.value(of: Self.securityPathOption, in: arguments).map(FileSystemPaths.absolute),
            netrcFile: Self.value(of: Self.netrcFileOption, in: arguments).map(FileSystemPaths.absolute),
            credentialStore: Self.credentialStore(in: arguments)
        )
    }

    private static func credentialStore(in arguments: [String]) -> SwiftPMSettings.CredentialStore {
        if arguments.contains(Self.netrcFlag) {
            return .netrc
        }
        return arguments.contains(Self.disableKeychainFlag) ? .keychainDisabled : .platformDefault
    }

    /// `--name value` or `--name=value`.
    private static func value(of option: String, in arguments: [String]) -> String? {
        for (index, argument) in arguments.enumerated() {
            if argument == option, index + 1 < arguments.count {
                return arguments[index + 1]
            }
            if argument.hasPrefix(option + Self.assignment) {
                return String(argument.dropFirst(option.count + Self.assignment.count))
            }
        }
        return nil
    }

    private static func resolve(packagePath: String, settings: SwiftPMSettings) async throws {
        let workspace = Workspace(options: WorkspaceOptions(
            root: .package(FileSystemPaths.absolute(packagePath)),
            cacheDirectory: nil,
            maximumConcurrency: ResolverDefaults.concurrency,
            verbosity: .normal,
            swiftPM: settings
        ))
        do {
            let report = try await workspace.resolve(mode: .respectPins)
            ResolveRunner.printChanges(report)
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            throw ExitCode.failure
        }
    }
}

/// `swx build`: resolve with swx, build with SwiftPM, or with xcodebuild for `--platform`.
struct Build: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Resolve with swx, then build (`swift build`, or xcodebuild with --platform ios|watchos|tvos|visionos|macos)."
    )

    @Argument(parsing: .captureForPassthrough, help: "Arguments for `swift build`, plus --platform/--destination/--device/--team.")
    var arguments: [String] = []

    func run() async throws {
        var arguments = self.arguments
        if let apple = AppleArguments.extract(from: &arguments) {
            try await apple.build(action: .build, extraArguments: arguments)
        }
        try await Passthrough.run(["build"], arguments: arguments, resolution: .resolveFirst)
    }
}

/// `swx test`: resolve with swx, test with SwiftPM, or on a simulator/device for `--platform`.
struct Test: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Resolve with swx, then test (`swift test`, or xcodebuild test with --platform).")

    @Argument(parsing: .captureForPassthrough, help: "Arguments for `swift test`, plus --platform/--destination/--device.")
    var arguments: [String] = []

    func run() async throws {
        var arguments = self.arguments
        if let apple = AppleArguments.extract(from: &arguments) {
            try await apple.build(action: .test, extraArguments: arguments)
        }
        try await Passthrough.run(["test"], arguments: arguments, resolution: .resolveFirst)
    }
}

/// `--platform ios [--destination simulator|device] [--device NAME] [--team ID] [--product P] [-c release]`
struct AppleArguments {
    private enum Option {
        static let platform = "--platform"
        static let destination = "--destination"
        static let device = "--device"
        static let team = "--team"
        static let product = "--product"
        static let configuration = "--configuration"
        static let configurationShort = "-c"
        static let packagePath = "--package-path"
    }

    private static let defaultEnvironment = "simulator"
    private static let defaultConfiguration = "debug"

    let target: AppleTarget
    let product: String?
    let configuration: String
    let packageDirectory: URL

    /// Removes the Apple options from `arguments`; `nil` when `--platform` is absent.
    static func extract(from arguments: inout [String]) -> AppleArguments? {
        var values: [String: String] = [:]
        var remaining: [String] = []
        let recognized: Set<String> = [
            Option.platform, Option.destination, Option.device, Option.team, Option.product,
            Option.configuration, Option.configurationShort, Option.packagePath,
        ]

        // Accept both `--opt value` and `--opt=value`.
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if let equals = argument.firstIndex(of: "="), recognized.contains(String(argument[..<equals])) {
                values[String(argument[..<equals])] = String(argument[argument.index(after: equals)...])
            } else if recognized.contains(argument), index + 1 < arguments.count {
                values[argument] = arguments[index + 1]
                index += 1
            } else {
                remaining.append(argument)
            }
            index += 1
        }
        guard let platform = values[Option.platform] else { return nil }

        arguments = remaining
        return AppleArguments(
            target: AppleTarget(
                platform: platform,
                environment: values[Option.destination] ?? Self.defaultEnvironment,
                device: values[Option.device],
                team: values[Option.team]
            ),
            product: values[Option.product],
            configuration: values[Option.configuration] ?? values[Option.configurationShort] ?? Self.defaultConfiguration,
            packageDirectory: FileSystemPaths.absolute(values[Option.packagePath] ?? ".")
        )
    }

    private var builds: AppleBuilds {
        AppleBuilds(
            options: WorkspaceOptions(root: .package(self.packageDirectory), cacheDirectory: nil, maximumConcurrency: ResolverDefaults.concurrency, verbosity: .normal),
            packageDirectory: self.packageDirectory
        )
    }

    func build(action: BuildAction, extraArguments: [String]) async throws -> Never {
        let products = try await CommandSupport.reportingErrors {
            try await self.builds.build(product: self.product, target: self.target, configuration: self.configuration, action: action.request, extraArguments: extraArguments)
        }
        CommandSupport.status("products: \(products.path)")
        throw ExitCode.success
    }

    func run(product: String?, arguments: [String]) async throws -> Never {
        guard let product = product ?? self.product else {
            CommandSupport.status("error: pass the app product to run: swx run --platform \(self.target.platform) <Product>")
            throw ExitCode.failure
        }
        try await CommandSupport.reportingErrors {
            try await self.builds.run(product: product, target: self.target, configuration: self.configuration, arguments: arguments)
        }
    }

    enum BuildAction {
        case build
        case test

        var request: AppleBuildAction {
            switch self {
            case .build:
                return .build
            case .test:
                return .test
            }
        }
    }
}

/// `swx devices`: simulators and paired devices.
struct Devices: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List simulators and paired devices for --platform/--device.")

    func run() async throws {
        for line in try await CommandSupport.reportingErrors({ try await AppleBuilds.listTargets() }) {
            print(line)
        }
    }
}

/// `swx run`: resolve with swx and run with SwiftPM, or run a single-file script.
struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run an executable product (via `swift run`) or a script: swx run tool.swift [args]."
    )

    private static let releaseFlag = "--release"

    @Argument(parsing: .captureForPassthrough, help: "Arguments for `swift run`, or a .swift script followed by its arguments.")
    var arguments: [String] = []

    func run() async throws {
        // `swx run --platform ios App [args…]` installs and launches on a simulator or device.
        var appleArguments = self.arguments
        if let apple = AppleArguments.extract(from: &appleArguments) {
            let product = appleArguments.first { !$0.hasPrefix("-") }
            try await apple.run(product: product, arguments: Array(appleArguments.drop { $0 != product }.dropFirst()))
        }

        // `swx run [--release] file.swift args…` compiles and runs a script.
        let isRelease = self.arguments.first == Self.releaseFlag
        let rest = isRelease ? Array(self.arguments.dropFirst()) : self.arguments
        if let script = rest.first, ScriptRunner.isScript(script) {
            try await Self.runScript(URL(fileURLWithPath: script), arguments: Array(rest.dropFirst()), configuration: isRelease ? .release : .debug)
        }
        try await Passthrough.run(["run"], arguments: self.arguments, resolution: .resolveFirst)
    }

    private static func runScript(_ script: URL, arguments: [String], configuration: BuildConfiguration) async throws -> Never {
        let directory = script.deletingLastPathComponent()
        try await CommandSupport.reportingErrors {
            try await Toolchains().prepare(for: directory, missing: .install) { CommandSupport.status($0) }
        }
        let options = WorkspaceOptions(root: .package(directory), cacheDirectory: nil, maximumConcurrency: ResolverDefaults.concurrency, verbosity: .quiet)
        let binary = try await CommandSupport.reportingErrors {
            try await ScriptRunner(options: options).prepare(script: script, configuration: configuration)
        }
        ProcessRunner.exec([binary.path] + arguments)
    }
}

/// Any other `swx package <subcommand>`: forwarded to `swift package`.
struct PackagePassthrough: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "passthrough",
        abstract: "Forward any other subcommand to `swift package`.",
        shouldDisplay: false
    )

    /// Subcommands that never need resolved dependencies.
    private static let standalone: Set<String> = [
        "init", "dump-package", "describe", "clean", "reset", "purge-cache", "tools-version",
        "compute-checksum", "config", "completion-tool", "archive-source", "add-dependency",
        "add-target", "add-product", "add-target-dependency", "add-setting", "migrate",
    ]

    @Argument(parsing: .captureForPassthrough)
    var arguments: [String] = []

    func run() async throws {
        let subcommand = self.arguments.first { !$0.hasPrefix("-") } ?? ""
        let resolution: Passthrough.Resolution = Self.standalone.contains(subcommand) ? .none : .resolveFirst
        try await Passthrough.run(["package"], arguments: self.arguments, resolution: resolution)
    }
}
