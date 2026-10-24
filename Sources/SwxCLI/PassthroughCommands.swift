import ArgumentParser
import Foundation
import SwxSystem
import SwxWorkspace

/// Runs a SwiftPM command after `swx` has resolved dependencies, so SwiftPM never touches the network.
enum Passthrough {
    private static let swift = "swift"
    private static let disableResolution = "--disable-automatic-resolution"
    private static let packagePathOption = "--package-path"
    private static let assignment = "="

    /// Whether to resolve before handing over.
    enum Resolution {
        case resolveFirst
        case none
    }

    /// Resolves (unless told not to), then replaces this process with `swift <command> …`.
    static func run(_ command: [String], arguments: [String], resolution: Resolution) async throws -> Never {
        if resolution == .resolveFirst {
            try await Self.resolve(packagePath: Self.packagePath(in: arguments))
        }

        // SwiftPM accepts `--disable-automatic-resolution` on every command that may resolve.
        var invocation = [Self.swift] + command
        if resolution == .resolveFirst && !arguments.contains(Self.disableResolution) {
            invocation.append(Self.disableResolution)
        }
        ProcessRunner.exec(invocation + arguments)
    }

    /// Honours `--package-path` among the passed-through arguments.
    static func packagePath(in arguments: [String]) -> String {
        for (index, argument) in arguments.enumerated() {
            if argument == Self.packagePathOption, index + 1 < arguments.count {
                return arguments[index + 1]
            }
            if argument.hasPrefix(Self.packagePathOption + Self.assignment) {
                return String(argument.dropFirst(Self.packagePathOption.count + Self.assignment.count))
            }
        }
        return "."
    }

    private static func resolve(packagePath: String) async throws {
        let workspace = Workspace(options: WorkspaceOptions(
            root: .package(URL(fileURLWithPath: packagePath).standardizedFileURL),
            cacheDirectory: nil,
            maximumConcurrency: ResolverDefaults.concurrency,
            verbosity: .normal
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

/// `swx build`: resolve with swx, build with SwiftPM.
struct Build: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Resolve with swx, then run `swift build`.")

    @Argument(parsing: .captureForPassthrough, help: "Arguments for `swift build`.")
    var arguments: [String] = []

    func run() async throws {
        try await Passthrough.run(["build"], arguments: self.arguments, resolution: .resolveFirst)
    }
}

/// `swx test`: resolve with swx, test with SwiftPM.
struct Test: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Resolve with swx, then run `swift test`.")

    @Argument(parsing: .captureForPassthrough, help: "Arguments for `swift test`.")
    var arguments: [String] = []

    func run() async throws {
        try await Passthrough.run(["test"], arguments: self.arguments, resolution: .resolveFirst)
    }
}

/// `swx run`: resolve with swx, run with SwiftPM.
struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Resolve with swx, then run `swift run`.")

    @Argument(parsing: .captureForPassthrough, help: "Arguments for `swift run`.")
    var arguments: [String] = []

    func run() async throws {
        try await Passthrough.run(["run"], arguments: self.arguments, resolution: .resolveFirst)
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
