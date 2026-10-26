import SwxManifest

/// What `swx graph` shows.
public enum GraphLevel: Sendable {
    /// Root targets, plus the products (and optionally targets) they reach in dependencies.
    case target
    /// One node per package, as `show-dependencies` shows them.
    case package
}

/// How `swx graph` prints the graph.
public enum GraphFormat: Sendable {
    case text
    case dot
    case mermaid
    case json
}

/// How much of the dependencies a target graph shows.
public enum ExternalNodes: Sendable {
    /// Products used from dependencies, as leaves.
    case products
    /// Products and the targets behind them, all the way down.
    case targets
    /// Only the root package's own targets.
    case skip
}

/// Whether the root package's test targets appear.
public enum TestTargets: Sendable {
    case include
    case skip
}

public struct GraphRequest: Sendable {
    public var level: GraphLevel
    public var format: GraphFormat
    /// Only what these targets, products or packages reach (all of the graph when empty).
    public var focus: [String]
    public var external: ExternalNodes
    public var tests: TestTargets

    public init(level: GraphLevel, format: GraphFormat, focus: [String], external: ExternalNodes, tests: TestTargets) {
        self.level = level
        self.format = format
        self.focus = focus
        self.external = external
        self.tests = tests
    }
}

public struct GraphError: Error, CustomStringConvertible, Sendable {
    public let description: String
}

/// A graph ready to print: nodes grouped by package, edges labelled with their conditions.
public struct DisplayGraph: Sendable, Equatable {
    public enum NodeKind: Sendable, Hashable {
        case target(Manifest.Target.Kind)
        case product(Manifest.Product.Kind)
        case package
    }

    public struct Node: Sendable, Hashable {
        public let id: String
        public let name: String
        public let kind: NodeKind
        /// The identity of the package the node belongs to.
        public let package: String
    }

    public enum EdgeKind: Sendable, Hashable {
        case dependency
        case plugin
    }

    public struct Edge: Sendable, Hashable {
        public let from: String
        public let to: String
        public let kind: EdgeKind
        /// `.when(platforms:)`, empty when unconditional.
        public let platforms: [String]
        /// `.when(traits:)`, empty when unconditional.
        public let traits: [String]
    }

    public struct Package: Sendable, Hashable {
        public let identity: String
        public let name: String
        /// A version, a branch or a short commit; `nil` for roots and path dependencies.
        public let version: String?
        public let isRoot: Bool
    }

    /// Root first, then in the order they were reached.
    public var packages: [Package] = []
    /// In the order they were reached.
    public var nodes: [Node] = []
    public var edges: [Edge] = []
    /// Where a tree starts: the root's targets, the root package, or the focus.
    public var entries: [String] = []

    /// Outgoing edges per node, in insertion order.
    func outgoing() -> [String: [Edge]] {
        Dictionary(grouping: self.edges, by: \.from)
    }
}

// MARK: - Building

extension DisplayGraph {
    private enum IDSeparator {
        static let target = "/target/"
        static let product = "/product/"
    }

    static func targetID(_ package: String, _ name: String) -> String {
        package + IDSeparator.target + name
    }

    static func productID(_ package: String, _ name: String) -> String {
        package + IDSeparator.product + name
    }

    /// The graph for `request`, focused if it names anything.
    public static func build(_ graph: PackageGraph, request: GraphRequest) throws -> DisplayGraph {
        var display: DisplayGraph
        switch request.level {
        case .target:
            display = TargetGraphBuilder(graph: graph, external: request.external).build(tests: request.tests)
        case .package:
            display = Self.packageLevel(graph)
        }
        guard !request.focus.isEmpty else { return display }
        return try display.focused(on: request.focus)
    }

    /// One node per reachable package, one edge per required dependency.
    static func packageLevel(_ graph: PackageGraph) -> DisplayGraph {
        var display = DisplayGraph()
        for package in graph.reachablePackages {
            let isRoot = package.role == .root
            display.packages.append(Package(identity: package.identity, name: package.manifest.name, version: package.pinned, isRoot: isRoot))
            display.nodes.append(Node(id: package.identity, name: isRoot ? package.manifest.name : package.identity, kind: .package, package: package.identity))
            for dependency in graph.directDependencies(of: package) {
                display.edges.append(Edge(from: package.identity, to: dependency.identity, kind: .dependency, platforms: [], traits: []))
            }
        }
        display.entries = [graph.root.identity]
        return display
    }

    /// Keeps only what the named nodes reach; names match targets, products or packages.
    func focused(on names: [String]) throws -> DisplayGraph {
        let wanted = Set(names)
        let starts = self.nodes.filter { wanted.contains($0.name) || ($0.kind == .package && wanted.contains($0.package)) }.map(\.id)
        guard !starts.isEmpty else {
            throw GraphError(description: "nothing named \(names.joined(separator: ", ")) in the graph")
        }

        // Everything reachable from the focus.
        let outgoing = self.outgoing()
        let reach = Dictionary(uniqueKeysWithValues: starts.map { ($0, Self.reachable(from: $0, outgoing: outgoing)) })
        let kept = reach.values.reduce(into: Set<String>()) { $0.formUnion($1) }

        // A start another start already reaches (product A and its target A) is shown under it.
        let entries = starts.enumerated().filter { index, start in
            !starts.enumerated().contains { otherIndex, other in
                guard other != start, reach[other]?.contains(start) == true else { return false }
                // Reaching each other (a cycle): the earlier one stays.
                let mutual = reach[start]?.contains(other) == true
                return !mutual || otherIndex < index
            }
        }.map(\.element)

        var focused = DisplayGraph()
        focused.nodes = self.nodes.filter { kept.contains($0.id) }
        focused.edges = self.edges.filter { kept.contains($0.from) && kept.contains($0.to) }
        let packages = Set(focused.nodes.map(\.package))
        focused.packages = self.packages.filter { packages.contains($0.identity) }
        focused.entries = entries
        return focused
    }

    /// `start` and every node it reaches.
    private static func reachable(from start: String, outgoing: [String: [Edge]]) -> Set<String> {
        var seen: Set<String> = [start]
        var pending = [start]
        while let id = pending.popLast() {
            for edge in outgoing[id] ?? [] where seen.insert(edge.to).inserted {
                pending.append(edge.to)
            }
        }
        return seen
    }
}

/// Walks from the root's targets through target, product and plugin references.
private struct TargetGraphBuilder {
    let graph: PackageGraph
    let external: ExternalNodes

    private var display = DisplayGraph()
    private var nodeIDs: Set<String> = []
    private var edgeKeys: Set<Edge> = []
    private var pending: [(package: GraphPackage, target: Manifest.Target)] = []

    private typealias Edge = DisplayGraph.Edge

    init(graph: PackageGraph, external: ExternalNodes) {
        self.graph = graph
        self.external = external
    }

    func build(tests: TestTargets) -> DisplayGraph {
        var builder = self
        let root = self.graph.root

        // The root's targets are the entry points, in manifest order.
        for target in root.manifest.targets where tests == .include || target.kind != .test {
            let id = builder.addTarget(target, of: root)
            builder.display.entries.append(id)
        }
        while !builder.pending.isEmpty {
            let (package, target) = builder.pending.removeFirst()
            builder.visit(target, of: package)
        }

        // Packages in the order their first node appeared, root first.
        let used = builder.display.nodes.map(\.package)
        var seen: Set<String> = []
        for identity in [root.identity] + used where seen.insert(identity).inserted {
            guard let package = self.graph.packages[identity] else { continue }
            builder.display.packages.append(DisplayGraph.Package(identity: identity, name: package.manifest.name, version: package.pinned, isRoot: package.role == .root))
        }
        return builder.display
    }

    // MARK: Nodes

    @discardableResult
    private mutating func addTarget(_ target: Manifest.Target, of package: GraphPackage) -> String {
        let id = DisplayGraph.targetID(package.identity, target.name)
        guard self.nodeIDs.insert(id).inserted else { return id }
        self.display.nodes.append(DisplayGraph.Node(id: id, name: target.name, kind: .target(target.kind), package: package.identity))
        self.pending.append((package, target))
        return id
    }

    /// A product node; with `.targets`, the product also leads to the targets it is made of.
    private mutating func addProduct(_ product: Manifest.Product, of package: GraphPackage) -> String {
        let id = DisplayGraph.productID(package.identity, product.name)
        guard self.nodeIDs.insert(id).inserted else { return id }
        self.display.nodes.append(DisplayGraph.Node(id: id, name: product.name, kind: .product(product.kind), package: package.identity))

        guard self.external == .targets else { return id }
        for name in product.targets {
            guard let target = package.manifest.targets.first(where: { $0.name == name }) else { continue }
            let targetID = self.addTarget(target, of: package)
            self.addEdge(from: id, to: targetID, kind: .dependency, condition: nil)
        }
        return id
    }

    private mutating func addEdge(from: String, to: String, kind: DisplayGraph.EdgeKind, condition: Manifest.Condition?) {
        let edge = Edge(from: from, to: to, kind: kind, platforms: condition?.platforms ?? [], traits: condition?.traits ?? [])
        guard self.edgeKeys.insert(edge).inserted else { return }
        self.display.edges.append(edge)
    }

    // MARK: References

    private mutating func visit(_ target: Manifest.Target, of package: GraphPackage) {
        let from = DisplayGraph.targetID(package.identity, target.name)
        let traits = Set(self.graph.enabledTraits[package.identity] ?? [])

        // Dependencies switched off by traits are not part of the graph, as in SwiftPM's.
        for dependency in target.dependencies where package.manifest.isEnabled(dependency, enabledTraits: traits) {
            guard let to = self.resolve(dependency, in: package) else { continue }
            self.addEdge(from: from, to: to, kind: .dependency, condition: dependency.condition)
        }

        // Plugins: a local target or product, or a product of a dependency.
        for usage in target.pluginUsages {
            let reference: Manifest.TargetDependency = usage.package.map { .product(name: usage.name, package: $0, condition: nil) }
                ?? .byName(name: usage.name, condition: nil)
            guard let to = self.resolve(reference, in: package) else { continue }
            self.addEdge(from: from, to: to, kind: .plugin, condition: nil)
        }
    }

    /// The node a target dependency refers to, added if new; `nil` when it leaves the graph.
    private mutating func resolve(_ dependency: Manifest.TargetDependency, in package: GraphPackage) -> String? {
        let manifest = package.manifest
        switch dependency {
        case .target(let name, _):
            guard let target = manifest.targets.first(where: { $0.name == name }) else { return nil }
            return self.addTarget(target, of: package)

        // `.byName` is a local target if one has the name, otherwise a product of a dependency.
        case .byName(let name, _):
            if let target = manifest.targets.first(where: { $0.name == name }) {
                return self.addTarget(target, of: package)
            }
            // A local product (a plugin, typically) stands for its first target, as in SwiftPM's pruning.
            if let product = manifest.products.first(where: { $0.name == name }),
               let first = product.targets.first, let target = manifest.targets.first(where: { $0.name == first }) {
                return self.addTarget(target, of: package)
            }
            return self.externalProduct(named: name, among: self.graph.directDependencies(of: package))

        case .product(let name, let packageName?, _):
            guard let declared = manifest.packageDependency(named: packageName),
                  let owner = self.graph.package(satisfying: declared, declaredBy: package) else { return nil }
            return self.externalProduct(named: name, among: [owner])

        case .product(let name, nil, _):
            return self.externalProduct(named: name, among: self.graph.directDependencies(of: package))
        }
    }

    private mutating func externalProduct(named name: String, among packages: [GraphPackage]) -> String? {
        guard self.external != .skip else { return nil }
        for package in packages {
            guard let product = package.manifest.products.first(where: { $0.name == name }) else { continue }
            return self.addProduct(product, of: package)
        }
        return nil
    }
}
