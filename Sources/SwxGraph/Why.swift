import Foundation
import SwxManifest

/// How `swx why` prints its answer.
public enum WhyFormat: Sendable {
    case text
    case json
}

/// `swx why <package>`: who depends on a package, up to the root (an inverted tree, like `cargo tree -i`).
extension PackageGraph {
    /// The package a name refers to: an identity, a package's own name, or one of its products.
    public func package(named name: String) throws -> GraphPackage {
        let lowered = name.lowercased()
        let reachable = self.reachablePackages
        if let package = reachable.first(where: { $0.identity == lowered || $0.manifest.name.lowercased() == lowered }) {
            return package
        }
        if let package = reachable.first(where: { $0.manifest.products.contains { $0.name == name } }) {
            return package
        }

        // Close matches help with typos and partial names.
        let suggestions = reachable.map(\.identity).filter { $0.contains(lowered) || lowered.contains($0) }
        let hint = suggestions.isEmpty ? "" : "; did you mean \(suggestions.joined(separator: ", "))?"
        throw GraphError(description: "no package or product named \(name) in the graph\(hint)")
    }

    public func why(_ name: String, format: WhyFormat) throws -> String {
        let package = try self.package(named: name)
        switch format {
        case .text:
            return self.whyText(package)
        case .json:
            return self.whyJSON(package)
        }
    }

    // MARK: Dependents

    /// Who depends on each package, in the order packages are reached from the root.
    func dependents() -> [String: [GraphPackage]] {
        var dependents: [String: [GraphPackage]] = [:]
        for package in self.reachablePackages {
            for dependency in self.directDependencies(of: package) {
                dependents[dependency.identity, default: []].append(package)
            }
        }
        return dependents
    }

    /// Root targets that use one of `package`'s products directly, with the product.
    func directUses(of package: GraphPackage) -> [(target: String, product: String)] {
        let root = self.root.manifest
        var uses: [(String, String)] = []
        for target in root.targets {
            for dependency in target.dependencies {
                guard let product = self.product(dependency, in: package) else { continue }
                uses.append((target.name, product))
            }
        }
        return uses
    }

    /// The product of `package` a root target dependency names, if it names one.
    private func product(_ dependency: Manifest.TargetDependency, in package: GraphPackage) -> String? {
        let root = self.root.manifest
        switch dependency {
        case .product(let name, let packageName?, _):
            guard let declared = root.packageDependency(named: packageName),
                  self.package(satisfying: declared, declaredBy: self.root)?.identity == package.identity else { return nil }
            return name
        case .product(let name, nil, _), .byName(let name, _):
            let isLocal = root.targets.contains { $0.name == name }
            guard !isLocal, package.manifest.products.contains(where: { $0.name == name }) else { return nil }
            return name
        case .target:
            return nil
        }
    }

    // MARK: text

    private enum Tree {
        static let branch = "├── "
        static let lastBranch = "└── "
        static let continuation = "│   "
        static let lastContinuation = "    "
        static let repeated = " (*)"
        static let root = " (root)"
        static let arrow = " → "
        static let directUses = "\nused directly by:\n"
        static let indent = "  "
    }

    private func title(_ package: GraphPackage) -> String {
        guard package.role == .dependency else { return package.manifest.name + Tree.root }
        return [package.identity, package.pinned].compactMap { $0 }.joined(separator: " ")
    }

    private func whyText(_ package: GraphPackage) -> String {
        guard package.role == .dependency else { return "\(package.manifest.name) is the root package\n" }
        let dependents = self.dependents()
        var expanded: Set<String> = []
        var output = self.title(package) + "\n"

        // Parents of parents, up to the root; a package shown before isn't expanded again.
        func walk(_ identity: String, prefix: String) {
            let parents = dependents[identity] ?? []
            for (index, parent) in parents.enumerated() {
                let isLast = index == parents.count - 1
                let isRepeat = !(dependents[parent.identity] ?? []).isEmpty && !expanded.insert(parent.identity).inserted
                output += prefix + (isLast ? Tree.lastBranch : Tree.branch) + self.title(parent) + (isRepeat ? Tree.repeated : "") + "\n"
                guard !isRepeat else { continue }
                walk(parent.identity, prefix: prefix + (isLast ? Tree.lastContinuation : Tree.continuation))
            }
        }
        walk(package.identity, prefix: "")

        // Root targets that use its products themselves.
        let uses = self.directUses(of: package)
        if !uses.isEmpty {
            output += Tree.directUses
            for use in uses {
                output += Tree.indent + use.target + Tree.arrow + use.product + "\n"
            }
        }
        return output
    }

    // MARK: json

    private struct JSONDependent: Encodable {
        let identity: String
        let version: String?
        let root: Bool
        /// `nil` where the package's dependents were already listed earlier in the tree.
        let dependents: [JSONDependent]?
    }

    private struct JSONUse: Encodable {
        let target: String
        let product: String
    }

    private struct JSONWhy: Encodable {
        let identity: String
        let version: String?
        let dependents: [JSONDependent]
        let usedBy: [JSONUse]
    }

    private func whyJSON(_ package: GraphPackage) -> String {
        let dependents = self.dependents()
        var expanded: Set<String> = []

        func tree(_ identity: String) -> [JSONDependent] {
            (dependents[identity] ?? []).map { parent in
                let hasParents = !(dependents[parent.identity] ?? []).isEmpty
                let expand = hasParents && expanded.insert(parent.identity).inserted
                return JSONDependent(
                    identity: parent.identity,
                    version: parent.pinned,
                    root: parent.role == .root,
                    dependents: expand ? tree(parent.identity) : (hasParents ? nil : [])
                )
            }
        }

        let why = JSONWhy(
            identity: package.identity,
            version: package.pinned,
            dependents: tree(package.identity),
            usedBy: self.directUses(of: package).map { JSONUse(target: $0.target, product: $0.product) }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(why)) ?? Data(), as: UTF8.self) + "\n"
    }
}
