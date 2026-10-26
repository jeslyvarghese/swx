import Foundation
import SwxManifest

/// Prints a `DisplayGraph`. Output is deterministic (manifest order), so it diffs well in CI.
extension DisplayGraph {
    public func render(_ format: GraphFormat) -> String {
        switch format {
        case .text:
            return self.text()
        case .dot:
            return self.dot()
        case .mermaid:
            return self.mermaid()
        case .json:
            return self.json()
        }
    }

    // MARK: Labels

    /// "executable", "library product", …
    static func kindName(_ kind: NodeKind) -> String {
        switch kind {
        case .target(let kind):
            switch kind {
            case .regular:
                return "target"
            case .executable:
                return "executable"
            case .test:
                return "test"
            case .plugin:
                return "plugin"
            case .macro:
                return "macro"
            case .system:
                return "system library"
            case .binary:
                return "binary"
            }
        case .product(let kind):
            switch kind {
            case .application:
                return "app"
            case .library, .executable, .plugin, .macro, .snippet, .test:
                return "\(kind.rawValue) product"
            }
        case .package:
            return "package"
        }
    }

    private static let traitPrefix = "trait: "

    /// `linux, macos, trait: TLS`; empty when unconditional.
    static func conditionText(_ edge: Edge) -> String {
        (edge.platforms + edge.traits.map { Self.traitPrefix + $0 }).joined(separator: ", ")
    }

    private var packagesByIdentity: [String: Package] {
        Dictionary(self.packages.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// `swift-nio 2.104.0`, or just the identity for unversioned packages.
    static func packageTitle(_ package: Package) -> String {
        guard let version = package.version else { return package.isRoot ? package.name : package.identity }
        return "\(package.identity) \(version)"
    }

    // MARK: text

    private enum Tree {
        static let branch = "├── "
        static let lastBranch = "└── "
        static let continuation = "│   "
        static let lastContinuation = "    "
        /// Marks a node whose dependencies were already printed above (as `cargo tree` does).
        static let repeated = " (*)"
        static let separator = " · "
        static let pluginUse = "plugin, "
    }

    private func text() -> String {
        let nodes = Dictionary(self.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let packages = self.packagesByIdentity
        let outgoing = self.outgoing()
        var expanded: Set<String> = []
        var output = ""

        // `App (executable)`, `NIOCore · swift-nio 2.104.0 (library product) [linux]`.
        func label(_ node: Node, via edge: Edge?) -> String {
            var label = node.name
            if node.kind != .package, let package = packages[node.package], !package.isRoot {
                label += Tree.separator + Self.packageTitle(package)
            }
            if node.kind == .package, let version = packages[node.package]?.version {
                label += " " + version
            }
            // Package graphs need no kind; plugins say how they are used.
            if node.kind != .package {
                label += " (\(edge?.kind == .plugin ? Tree.pluginUse : "")\(Self.kindName(node.kind)))"
            }
            if let edge, !(edge.platforms.isEmpty && edge.traits.isEmpty) {
                label += " [\(Self.conditionText(edge))]"
            }
            return label
        }

        func walk(_ id: String, via edge: Edge?, prefix: String, hanger: String) {
            guard let node = nodes[id] else { return }
            let children = outgoing[id] ?? []
            let isRepeat = !children.isEmpty && !expanded.insert(id).inserted
            output += hanger + label(node, via: edge) + (isRepeat ? Tree.repeated : "") + "\n"
            guard !isRepeat else { return }

            for (index, child) in children.enumerated() {
                let isLast = index == children.count - 1
                walk(child.to, via: child, prefix: prefix + (isLast ? Tree.lastContinuation : Tree.continuation), hanger: prefix + (isLast ? Tree.lastBranch : Tree.branch))
            }
        }
        for entry in self.entries {
            walk(entry, via: nil, prefix: "", hanger: "")
        }
        return output
    }

    // MARK: dot

    private enum DotStyle {
        static let header = """
            rankdir=LR
            node [shape=box, style=rounded, fontname="Helvetica"]
            edge [fontname="Helvetica", fontsize=10]
        """
        static let rootCluster = "style=filled; color=\"#f2f2f2\""
        static let cluster = "style=dashed; color=\"#999999\""
        static let pluginEdge = "style=dashed"
    }

    /// Shapes per node kind, so apps, tests, macros and products stand apart.
    private static func dotAttributes(_ kind: NodeKind) -> String {
        switch kind {
        case .target(.executable), .product(.application):
            return "style=\"rounded,bold\""
        case .target(.test):
            return "style=\"rounded,dashed\""
        case .target(.macro), .product(.macro):
            return "shape=hexagon, style=solid"
        case .target(.plugin), .product(.plugin):
            return "shape=component, style=solid"
        case .target(.binary):
            return "shape=box3d, style=solid"
        case .target(.system):
            return "shape=cylinder, style=solid"
        case .product:
            return "shape=ellipse, style=solid"
        case .target, .package:
            return ""
        }
    }

    private func dot() -> String {
        let title = self.packages.first.map(Self.packageTitle) ?? ""
        var output = "digraph \(Self.dotQuoted(title)) {\n\(DotStyle.header)\n"
        let byPackage = Dictionary(grouping: self.nodes, by: \.package)

        // One cluster per package (none for a package-level graph, where the node is the package).
        for (index, package) in self.packages.enumerated() {
            let nodes = byPackage[package.identity] ?? []
            let clustered = nodes.contains { $0.kind != .package }
            if clustered {
                output += "\n    subgraph \"cluster_\(index)\" {\n"
                output += "        label=\(Self.dotQuoted(Self.packageTitle(package)))\n"
                output += "        \(package.isRoot ? DotStyle.rootCluster : DotStyle.cluster)\n"
            }
            let indent = clustered ? "        " : "    "
            for node in nodes {
                let name = node.kind == .package ? Self.packageTitle(package) : node.name
                let attributes = Self.dotAttributes(node.kind)
                output += "\(indent)\(Self.dotQuoted(node.id)) [label=\(Self.dotQuoted(name))\(attributes.isEmpty ? "" : ", " + attributes)]\n"
            }
            if clustered {
                output += "    }\n"
            }
        }

        // Edges, labelled with their conditions; plugins dashed.
        output += "\n"
        for edge in self.edges {
            var attributes: [String] = []
            if edge.kind == .plugin {
                attributes.append(DotStyle.pluginEdge)
            }
            let condition = Self.conditionText(edge)
            if !condition.isEmpty {
                attributes.append("label=\(Self.dotQuoted(condition))")
            }
            let suffix = attributes.isEmpty ? "" : " [\(attributes.joined(separator: ", "))]"
            output += "    \(Self.dotQuoted(edge.from)) -> \(Self.dotQuoted(edge.to))\(suffix)\n"
        }
        return output + "}\n"
    }

    private static func dotQuoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // MARK: mermaid

    private enum Mermaid {
        static let header = "flowchart LR\n"
        static let nodePrefix = "n"
        static let packagePrefix = "p"
        static let edge = "-->"
        static let pluginEdge = "-.->"
        /// Mermaid has no escape for `"` inside labels but this entity.
        static let quoteEntity = "#quot;"
    }

    /// Mermaid shapes: `["…"]` box, `(["…"])` stadium, `{{"…"}}` hexagon, `[["…"]]` subroutine, `[("…")]` cylinder.
    private static func mermaidShape(_ kind: NodeKind, label: String) -> String {
        let quoted = "\"" + label.replacingOccurrences(of: "\"", with: Mermaid.quoteEntity) + "\""
        switch kind {
        case .target(.macro), .product(.macro):
            return "{{\(quoted)}}"
        case .target(.plugin), .product(.plugin):
            return "[[\(quoted)]]"
        case .target(.binary), .target(.system):
            return "[(\(quoted))]"
        case .product:
            return "([\(quoted)])"
        case .target, .package:
            return "[\(quoted)]"
        }
    }

    private func mermaid() -> String {
        // Short ids: Mermaid ids can't hold `/` or `.`.
        let ids = Dictionary(uniqueKeysWithValues: self.nodes.enumerated().map { ($1.id, Mermaid.nodePrefix + String($0)) })
        let byPackage = Dictionary(grouping: self.nodes, by: \.package)
        var output = Mermaid.header

        for (index, package) in self.packages.enumerated() {
            let nodes = byPackage[package.identity] ?? []
            let clustered = nodes.contains { $0.kind != .package }
            if clustered {
                output += "    subgraph \(Mermaid.packagePrefix)\(index)[\"\(Self.packageTitle(package).replacingOccurrences(of: "\"", with: Mermaid.quoteEntity))\"]\n"
            }
            let indent = clustered ? "        " : "    "
            for node in nodes {
                let name = node.kind == .package ? Self.packageTitle(package) : node.name
                output += indent + (ids[node.id] ?? "") + Self.mermaidShape(node.kind, label: name) + "\n"
            }
            if clustered {
                output += "    end\n"
            }
        }

        for edge in self.edges {
            guard let from = ids[edge.from], let to = ids[edge.to] else { continue }
            let arrow = edge.kind == .plugin ? Mermaid.pluginEdge : Mermaid.edge
            let condition = Self.conditionText(edge)
            let label = condition.isEmpty ? "" : "|\"\(condition)\"|"
            output += "    \(from) \(arrow)\(label) \(to)\n"
        }
        return output
    }

    // MARK: json

    private struct JSONGraph: Encodable {
        struct Package: Encodable {
            let identity: String
            let name: String
            let version: String?
            let root: Bool
        }

        struct Node: Encodable {
            let id: String
            let name: String
            /// `target`, `product` or `package`.
            let type: String
            /// The target or product kind, as SwiftPM names it.
            let kind: String
            let package: String
        }

        struct Edge: Encodable {
            let from: String
            let to: String
            /// `dependency` or `plugin`.
            let kind: String
            let platforms: [String]
            let traits: [String]
        }

        let packages: [Package]
        let nodes: [Node]
        let edges: [Edge]
    }

    private enum JSONName {
        static let target = "target"
        static let product = "product"
        static let package = "package"
        static let dependency = "dependency"
        static let plugin = "plugin"
    }

    private func json() -> String {
        let graph = JSONGraph(
            packages: self.packages.map { .init(identity: $0.identity, name: $0.name, version: $0.version, root: $0.isRoot) },
            nodes: self.nodes.map { node in
                switch node.kind {
                case .target(let kind):
                    return .init(id: node.id, name: node.name, type: JSONName.target, kind: kind.rawValue, package: node.package)
                case .product(let kind):
                    return .init(id: node.id, name: node.name, type: JSONName.product, kind: kind.rawValue, package: node.package)
                case .package:
                    return .init(id: node.id, name: node.name, type: JSONName.package, kind: JSONName.package, package: node.package)
                }
            },
            edges: self.edges.map {
                .init(from: $0.from, to: $0.to, kind: $0.kind == .plugin ? JSONName.plugin : JSONName.dependency, platforms: $0.platforms, traits: $0.traits)
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(graph)) ?? Data()
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}
