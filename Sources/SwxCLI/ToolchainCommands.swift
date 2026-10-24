import ArgumentParser
import Foundation
import SwxWorkspace

/// `swx toolchain …`: install and select Swift toolchains (like swiftly / `uv python`).
struct ToolchainCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "toolchain",
        abstract: "Install and select Swift toolchains; projects pin one with .swift-version.",
        subcommands: [ToolchainList.self, ToolchainInstall.self, ToolchainUninstall.self, ToolchainUse.self, ToolchainWhich.self]
    )
}

struct ToolchainList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List installed and recent available toolchains.")

    private static let availableCount = 10

    @Flag(help: "Also list recent releases from swift.org.")
    var available = false

    func run() async throws {
        let toolchains = Toolchains()
        for (name, path) in toolchains.installed() {
            print("\(name)\t\(path.path)")
        }
        guard self.available else { return }
        print("available: \(try await toolchains.available(limit: Self.availableCount).joined(separator: ", "))")
    }
}

struct ToolchainInstall: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "install", abstract: "Install a release: 6.3, 6.4.1, or latest.")

    @Argument var version: String

    func run() async throws {
        let installed = try await CommandSupport.reportingErrors {
            try await Toolchains().install(self.version) { CommandSupport.status($0) }
        }
        print("Installed Swift \(installed.name) at \(installed.path.path)")
    }
}

struct ToolchainUninstall: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "uninstall", abstract: "Remove an installed toolchain.")

    @Argument var version: String

    func run() async throws {
        try CommandSupport.reportingErrors { try Toolchains().uninstall(self.version) }
        print("Removed Swift \(self.version)")
    }
}

struct ToolchainUse: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "use", abstract: "Pin the current directory to a toolchain (writes .swift-version).")

    @Argument var version: String

    func run() async throws {
        let file = try Toolchains().use(self.version, in: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        print("Wrote \(file.path)")
    }
}

struct ToolchainWhich: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "which", abstract: "Show the toolchain swx would use here.")

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        let selection = try await CommandSupport.reportingErrors {
            try await Toolchains().prepare(for: self.global.packageURL, missing: .fail) { _ in }
        }
        print(selection)
    }
}
