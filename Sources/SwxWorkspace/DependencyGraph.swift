import Foundation
import SwxCore
import SwxGraph
import SwxManifest
import SwxSystem

// The graph types the CLI uses, so it needs nothing below SwxWorkspace.
public typealias ShowDependenciesFormat = SwxGraph.ShowDependenciesFormat
public typealias GraphRequest = SwxGraph.GraphRequest
public typealias GraphLevel = SwxGraph.GraphLevel
public typealias GraphFormat = SwxGraph.GraphFormat
public typealias ExternalNodes = SwxGraph.ExternalNodes
public typealias TestTargets = SwxGraph.TestTargets

/// A graph swx can't reproduce exactly; the caller hands the command to SwiftPM instead.
public struct GraphUnsupported: Error, CustomStringConvertible, Sendable {
    public let description: String
}

/// Image formats Graphviz renders `swx graph` into.
public enum GraphImageFormat: String, Sendable, CaseIterable {
    case svg
    case png
    case pdf
}

extension Workspace {
    /// Packages SwiftPM may swap for prebuilt libraries, dropping them from the graph it prints.
    /// Whether it does depends on its prebuilt downloads, so such graphs are SwiftPM's to print.
    private static let prebuiltPackages: Set<String> = ["swift-syntax"]

    /// `swift package show-dependencies --format …`, byte for byte. Expects a resolved workspace.
    public func showDependencies(_ format: ShowDependenciesFormat) async throws -> String {
        let graph = try await self.packageGraph()
        guard !graph.reachablePackages.contains(where: { Self.prebuiltPackages.contains($0.identity) }) else {
            throw GraphUnsupported(description: "graphs with swift-syntax, which SwiftPM may replace with prebuilts")
        }
        return graph.showDependencies(format)
    }

    /// `swx graph`. Expects a resolved workspace.
    public func graph(_ request: GraphRequest) async throws -> String {
        try DisplayGraph.build(try await self.packageGraph(), request: request).render(request.format)
    }

    /// Renders Graphviz `dot` text into an image with the `dot` executable.
    public static func renderImage(dot: String, format: GraphImageFormat, to output: URL) async throws {
        guard ExecutableLookup.find(Graphviz.executable) != nil else {
            throw WorkspaceError(description: "rendering .\(format.rawValue) needs Graphviz (`brew install graphviz` or `apt install graphviz`); `--format dot` or `--format mermaid` print text instead")
        }
        try await ProcessRunner.run([Graphviz.executable, Graphviz.formatFlag + format.rawValue, Graphviz.outputFlag, output.path], input: Data(dot.utf8))
    }

    private enum Graphviz {
        static let executable = "dot"
        static let formatFlag = "-T"
        static let outputFlag = "-o"
    }

    // MARK: Loading

    /// The resolved package graph, built from `workspace-state.json` and the checked-out manifests,
    /// as SwiftPM builds it.
    func packageGraph() async throws -> PackageGraph {
        let root = try await self.rootContext()
        guard case .package(let directory) = root.source else {
            throw GraphUnsupported(description: "graphs of Xcode projects")
        }
        guard self.options.registryTransformation == .disabled else {
            throw GraphUnsupported(description: "graphs with source control to registry transformation")
        }

        // Edited packages live where SwiftPM put them; leave those graphs to SwiftPM.
        let state = FileSystem.readIfPresent(root.layout.workspaceState).flatMap(WorkspaceState.decodeIfCompatible)
            ?? WorkspaceState(dependencies: [:])
        guard state.editedDependencies.isEmpty else {
            throw GraphUnsupported(description: "graphs with edited dependencies")
        }

        let toolchain = try await Toolchain.detect(store: self.store)
        let loader = ManifestLoader(store: self.store, toolchain: toolchain, maximumConcurrency: self.options.maximumConcurrency)
        let rootPackage = GraphPackage(
            identity: root.reference.identity.description,
            manifest: try await loader.load(packageAt: directory),
            location: directory.path,
            version: nil,
            path: directory.path,
            role: .root
        )

        // Every managed dependency's manifest, read from its checkout (cache hits when warm).
        let layout = root.layout
        let toolsVersion = toolchain.toolsVersion
        let dependencies = try await withThrowingTaskGroup(of: GraphPackage.self) { group in
            for dependency in state.dependencies.values {
                group.addTask { try await Self.graphPackage(dependency, layout: layout, loader: loader, toolsVersion: toolsVersion) }
            }
            return try await group.reduce(into: [GraphPackage]()) { $0.append($1) }
        }

        // Declared dependencies map to managed packages the way checkouts were made: through the mirrors.
        let mirrors = root.mirrors
        return PackageGraphBuilder.build(root: rootPackage, dependencies: dependencies) { dependency in
            mirrors.effective(dependency.declaration).package.identity.description
        }
    }

    /// One managed dependency: where it lives, its version, and the manifest SwiftPM would load there.
    private static func graphPackage(_ dependency: ManagedDependency, layout: Layout, loader: ManifestLoader, toolsVersion: ToolsVersion) async throws -> GraphPackage {
        let directory: URL
        let manifest: Manifest
        let version: String?
        var pinned: String?
        switch dependency.state {
        case .fileSystem(let path):
            directory = URL(fileURLWithPath: path, isDirectory: true)
            manifest = try await loader.load(packageAt: directory)
            version = nil
        case .sourceControlCheckout(let pin):
            directory = layout.directory(of: dependency)
            manifest = try await Self.manifest(in: directory, of: dependency, loader: loader, toolsVersion: toolsVersion)
            switch pin {
            case .version(let resolved, _), .registryVersion(let resolved):
                version = resolved.description
            case .branch(let branch, _):
                version = nil
                pinned = branch
            case .revision(let revision):
                version = nil
                pinned = String(revision.prefix(Self.shortRevisionLength))
            }
        case .registryDownload(let downloaded, _):
            directory = layout.directory(of: dependency)
            manifest = try await Self.manifest(in: directory, of: dependency, loader: loader, toolsVersion: toolsVersion)
            version = downloaded.description
        }
        return GraphPackage(
            identity: dependency.package.identity.description,
            manifest: manifest,
            location: dependency.package.kind.location,
            version: version,
            pinned: pinned,
            reference: dependency.package,
            path: directory.path,
            role: .dependency
        )
    }

    /// Commits are shown as git abbreviates them.
    private static let shortRevisionLength = 7

    /// The manifest SwiftPM picks in a checkout, honouring version-specific manifests.
    private static func manifest(in directory: URL, of dependency: ManagedDependency, loader: ManifestLoader, toolsVersion: ToolsVersion) async throws -> Manifest {
        let fileNames = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let read = { (name: String) in
            FileSystem.readIfPresent(directory.appendingPathComponent(name)).map { String(decoding: $0, as: UTF8.self) }
        }
        guard let name = ToolsVersion.selectManifest(fileNames: fileNames, current: toolsVersion, contentsOf: read),
              let contents = read(name) else {
            throw WorkspaceError(description: "\(dependency.package.identity) is not checked out at \(directory.path); run `swx package resolve`")
        }
        return try await loader.load(contents: contents)
    }
}
