import ArgumentParser
import Foundation
import SwxSystem
import SwxWorkspace

/// `swx tool …`: run and install command-line tools from Swift packages.
struct ToolCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tool",
        abstract: "Run or install command-line tools from Swift packages (like uvx / Mint).",
        subcommands: [ToolRun.self, ToolInstall.self, ToolList.self]
    )
}

struct ToolRun: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "run", abstract: "Build (once) and run a tool: swx tool run swiftformat@0.54.0 --version")

    @Argument(help: "owner/repo[@version], a git URL[@version], or an alias (\(ToolRunner.aliases.keys.sorted().joined(separator: ", "))).")
    var spec: String

    @Option(help: "The executable product to run, when the package has several.")
    var executable: String?

    @OptionGroup var global: GlobalOptions

    @Argument(parsing: .captureForPassthrough, help: "Arguments for the tool.")
    var arguments: [String] = []

    func run() async throws {
        try await CommandSupport.prepareToolchain(for: self.global)
        let tool = try await CommandSupport.reportingErrors {
            try await ToolRunner(options: self.global.workspaceOptions()).prepare(self.spec, executable: self.executable)
        }
        ProcessRunner.exec([tool.executable.path] + self.arguments)
    }
}

struct ToolInstall: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "install", abstract: "Build a tool and link it into a bin directory.")

    private static let defaultBinDirectory = ".local/bin"

    @Argument(help: "owner/repo[@version], a git URL[@version], or an alias.")
    var spec: String

    @Option(help: "The executable product to install, when the package has several.")
    var executable: String?

    @Option(name: .customLong("bin-dir"), help: "Where to link the executable (default ~/.local/bin).")
    var binDirectory: String?

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await CommandSupport.prepareToolchain(for: self.global)
        let runner = ToolRunner(options: self.global.workspaceOptions())
        let tool = try await CommandSupport.reportingErrors { try await runner.prepare(self.spec, executable: self.executable) }

        let binDirectory = self.binDirectory.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(Self.defaultBinDirectory)
        let link = try runner.install(tool, into: binDirectory)
        print("Installed \(tool.name) \(tool.version) → \(link.path)")
    }
}

struct ToolList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List built tools in the cache.")

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        for (key, executable) in ToolRunner(options: self.global.workspaceOptions()).cached() {
            print("\(executable)\t\(key)")
        }
    }
}
