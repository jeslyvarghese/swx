import ArgumentParser
import Foundation
import SwxSystem
import SwxWorkspace

/// Shared steps of the graph commands: resolve quietly, print or write the result.
enum GraphSupport {
    /// Resolves like `swift build` would first; stdout stays clean for the graph.
    static func resolve(_ workspace: Workspace) async throws {
        let report = try await CommandSupport.reportingErrors { try await workspace.resolve(mode: .respectPins) }
        ResolveRunner.reportChanges(report)
    }

    /// Prints `text`, or writes it to `path`.
    static func emit(_ text: String, to path: String?) throws {
        guard let path else {
            FileHandle.standardOutput.write(Data(text.utf8))
            return
        }
        try CommandSupport.reportingErrors { try FileSystem.writeAtomically(Data(text.utf8), to: FileSystemPaths.absolute(path)) }
    }
}

/// `swx package show-dependencies`: SwiftPM's output, byte for byte, without SwiftPM's start-up.
struct ShowDependencies: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show-dependencies",
        abstract: "Print the resolved dependency graph (as `swift package show-dependencies`)."
    )

    @OptionGroup var global: GlobalOptions

    // A string, not an enum: SwiftPM accepts any case, and reports bad values itself.
    @Option(help: "Set the output format: text, dot, json or flatlist.")
    var format: String = ShowDependenciesFormat.text.rawValue

    @Option(name: [.customShort("o"), .customLong("output-path")], help: "The path to write the resolved dependency graph to.")
    var outputPath: String?

    /// Flags swx doesn't know send the whole command to SwiftPM.
    @Argument(parsing: .allUnrecognized)
    var unrecognized: [String] = []

    func run() async throws {
        guard self.unrecognized.isEmpty, let format = ShowDependenciesFormat(rawValue: self.format.lowercased()) else {
            try await self.handOver()
        }
        try await CommandSupport.prepareToolchain(for: self.global)
        let workspace = self.global.makeWorkspace()
        try await GraphSupport.resolve(workspace)

        // Graphs swx can't reproduce exactly (edited packages, …) are SwiftPM's to print.
        let output: String
        do {
            output = try await workspace.showDependencies(format)
        } catch is GraphUnsupported {
            try await self.handOver()
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            throw ExitCode.failure
        }
        try GraphSupport.emit(output, to: self.outputPath)
    }

    private static let packageCommand = "package"

    /// `swift package show-dependencies` with this command's arguments, after swx has resolved.
    private func handOver() async throws -> Never {
        let commandName = Self.configuration.commandName ?? ""
        let arguments = Array(CommandLine.arguments.drop { $0 != commandName }.dropFirst())
        try await Passthrough.run([Self.packageCommand, commandName], arguments: arguments, resolution: .resolveFirst)
    }
}

/// `swx graph`: the target or package graph, as a tree, Graphviz, Mermaid or JSON.
struct Graph: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print the dependency graph of targets and products (or packages) as text, dot, mermaid or json."
    )

    enum Level: String, ExpressibleByArgument, CaseIterable {
        case target
        case package

        var graphLevel: GraphLevel {
            switch self {
            case .target:
                return .target
            case .package:
                return .package
            }
        }
    }

    enum Format: String, ExpressibleByArgument, CaseIterable {
        case text
        case dot
        case mermaid
        case json

        var graphFormat: GraphFormat {
            switch self {
            case .text:
                return .text
            case .dot:
                return .dot
            case .mermaid:
                return .mermaid
            case .json:
                return .json
            }
        }
    }

    enum External: String, ExpressibleByArgument, CaseIterable {
        case products
        case targets
        case none

        var externalNodes: ExternalNodes {
            switch self {
            case .products:
                return .products
            case .targets:
                return .targets
            case .none:
                return .skip
            }
        }
    }

    enum Tests: EnumerableFlag {
        case includeTests
        case skipTests

        var testTargets: TestTargets {
            self == .includeTests ? .include : .skip
        }
    }

    @OptionGroup var global: GlobalOptions

    @Option(help: "target: targets and the products they use; package: one node per package.")
    var level: Level = .target

    @Option(help: "text (a tree), dot (Graphviz), mermaid or json. Default: text, or dot for image output.")
    var format: Format?

    @Option(help: "Show only what this target, product or package reaches (repeatable).")
    var focus: [String] = []

    @Option(help: "products: dependencies' products as leaves; targets: the targets behind them too; none: this package only.")
    var external: External = .products

    @Flag(help: "Include or skip the package's test targets.")
    var tests: Tests = .includeTests

    @Option(name: [.short, .long], help: "Write to a file; .svg, .png and .pdf are drawn with Graphviz.")
    var output: String?

    /// Set when `--output` names an image Graphviz draws.
    private var image: GraphImageFormat? {
        self.output.flatMap { GraphImageFormat(rawValue: URL(fileURLWithPath: $0).pathExtension.lowercased()) }
    }

    func validate() throws {
        guard let image = self.image, let format = self.format, format != .dot else { return }
        throw ValidationError("a .\(image.rawValue) image is drawn from dot, not \(format.rawValue): leave --format out, or write to a text file")
    }

    func run() async throws {
        let request = GraphRequest(
            level: self.level.graphLevel,
            format: self.image == nil ? (self.format ?? .text).graphFormat : .dot,
            focus: self.focus,
            external: self.external.externalNodes,
            tests: self.tests.testTargets
        )

        try await CommandSupport.prepareToolchain(for: self.global)
        let workspace = self.global.makeWorkspace()
        try await GraphSupport.resolve(workspace)
        let text = try await CommandSupport.reportingErrors { try await workspace.graph(request) }

        // Images go through Graphviz; everything else is text.
        guard let image = self.image, let output = self.output else {
            try GraphSupport.emit(text, to: self.output)
            return
        }
        try await CommandSupport.reportingErrors {
            try await Workspace.renderImage(dot: text, format: image, to: FileSystemPaths.absolute(output))
        }
    }
}
