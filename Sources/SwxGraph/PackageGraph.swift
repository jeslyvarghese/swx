import SwxCore
import SwxManifest

/// One package of a resolved graph, as SwiftPM's `ResolvedPackage` describes it.
public struct GraphPackage: Sendable, Hashable {
    public enum Role: Sendable, Hashable {
        case root
        case dependency
    }

    public let identity: String
    public let manifest: Manifest
    /// SwiftPM's `manifest.packageLocation`: the root's path, a dependency's URL, path or registry identity.
    public let location: String
    /// The resolved version; `nil` for roots, branches, revisions and path dependencies.
    public let version: String?
    /// What the package is pinned to, for people: a version, a branch, or a short commit.
    public let pinned: String?
    /// The package directory: the root, a checkout, a registry download or a local path.
    public let path: String
    public let role: Role

    public init(identity: String, manifest: Manifest, location: String, version: String?, pinned: String? = nil, path: String, role: Role) {
        self.identity = identity
        self.manifest = manifest
        self.location = location
        self.version = version
        self.pinned = pinned ?? version
        self.path = path
        self.role = role
    }
}

/// The package-level graph SwiftPM builds after resolution: which packages each package depends on,
/// and which traits are enabled where.
public struct PackageGraph: Sendable {
    public let root: GraphPackage
    /// Every managed package, keyed by identity (some may be unreachable from the root).
    public let packages: [String: GraphPackage]
    /// Each reachable package's required dependencies, in manifest order (`ResolvedPackage.dependencies`).
    public let dependencies: [String: [String]]
    /// Each reachable package's enabled traits, sorted (`ResolvedPackage.enabledTraits`).
    public let enabledTraits: [String: [String]]
    /// Per package: a declared dependency's identity → the managed package satisfying it (after mirrors).
    public let resolvedIdentities: [String: [String: String]]

    /// The managed package behind one of `package`'s declared dependencies.
    public func package(satisfying dependency: Manifest.Dependency, declaredBy package: GraphPackage) -> GraphPackage? {
        self.resolvedIdentities[package.identity]?[dependency.identity].flatMap { self.packages[$0] }
    }

    /// The packages `package` depends on, in manifest order.
    public func directDependencies(of package: GraphPackage) -> [GraphPackage] {
        (self.dependencies[package.identity] ?? []).compactMap { self.packages[$0] }
    }

    /// Every package reachable from the root, root first, in breadth-first manifest order.
    public var reachablePackages: [GraphPackage] {
        var seen: Set<String> = [self.root.identity]
        var ordered = [self.root]
        var index = 0
        while index < ordered.count {
            for dependency in self.directDependencies(of: ordered[index]) where seen.insert(dependency.identity).inserted {
                ordered.append(dependency)
            }
            index += 1
        }
        return ordered
    }
}

/// Builds a `PackageGraph` from the manifests of the root and every managed dependency.
///
/// Pure port of SwiftPM's graph loading as far as `show-dependencies` can see it: required
/// dependencies come from `Manifest.requiredDependencies` (SwiftPM's pruning), and traits are
/// unified across the graph like `Workspace.updateEnabledTraits`.
public enum PackageGraphBuilder {
    /// SwiftPM settles traits in one pass over the manifests; a few extra passes let later
    /// requests reach packages computed earlier, without ever looping forever.
    private static let extraPasses = 2

    /// - Parameter identify: the identity of the managed package that satisfies a declared
    ///   dependency (mirrors applied).
    public static func build(
        root: GraphPackage,
        dependencies: [GraphPackage],
        identify: (Manifest.Dependency) -> String
    ) -> PackageGraph {
        var packages = Dictionary(dependencies.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
        packages[root.identity] = root

        // Iterate until trait requests stop changing: traits decide edges, and edges decide who requests traits.
        var requests: [String: TraitRequest] = [:]
        var pass = Pass()
        for _ in 0..<(packages.count + Self.extraPasses) {
            pass = Self.walk(from: root, packages: packages, requests: requests, identify: identify)
            guard pass.requests != requests else { break }
            requests = pass.requests
        }

        return PackageGraph(
            root: root,
            packages: packages,
            dependencies: pass.edges,
            enabledTraits: pass.enabledTraits.mapValues { $0.sorted() },
            resolvedIdentities: pass.resolvedIdentities
        )
    }

    // MARK: One pass

    private struct Pass {
        var edges: [String: [String]] = [:]
        var enabledTraits: [String: Set<String>] = [:]
        var requests: [String: TraitRequest] = [:]
        var resolvedIdentities: [String: [String: String]] = [:]
    }

    /// Walks the graph breadth-first from the root with the given trait requests.
    private static func walk(
        from root: GraphPackage,
        packages: [String: GraphPackage],
        requests: [String: TraitRequest],
        identify: (Manifest.Dependency) -> String
    ) -> Pass {
        var pass = Pass()
        var queue = [root]
        var seen: Set<String> = [root.identity]
        var index = 0

        while index < queue.count {
            let package = queue[index]
            index += 1
            let manifest = package.manifest

            // Traits first: they decide which dependencies are required.
            let traits = Self.enabledTraits(of: package, request: requests[package.identity] ?? TraitRequest())
            pass.enabledTraits[package.identity] = traits

            // Every declared dependency registers what this package asks of it, as SwiftPM does.
            for dependency in manifest.dependencies {
                let identity = identify(dependency)
                pass.requests[identity, default: TraitRequest()].record(dependency.requestedTraits(enabledInParent: traits))
                pass.resolvedIdentities[package.identity, default: [:]][dependency.identity] = identity
            }

            // Required dependencies become edges; unmanaged ones (SwiftPM would have failed) are skipped.
            let role: ManifestRole = package.role == .root ? .root : .dependency
            var edges: [String] = []
            for dependency in manifest.requiredDependencies(role: role, enabledTraits: traits) {
                let identity = identify(dependency)
                guard let target = packages[identity], !edges.contains(identity) else { continue }
                edges.append(identity)
                if seen.insert(identity).inserted {
                    queue.append(target)
                }
            }
            pass.edges[package.identity] = edges
        }
        return pass
    }

    // MARK: Traits

    /// What a package's parents asked for, unioned across the graph.
    struct TraitRequest: Equatable {
        /// Named traits (may include `default`).
        var explicit: Set<String> = []
        /// A parent left `traits:` out, or asked for exactly the defaults.
        var defaults = false
        /// A parent passed `traits: []`.
        var disabled = false

        mutating func record(_ traits: [String]) {
            if traits == [Manifest.defaultTrait] {
                self.defaults = true
            } else if traits.isEmpty {
                self.disabled = true
            } else {
                self.explicit.formUnion(traits)
            }
        }
    }

    /// SwiftPM's enabled traits for a package: `default` alone when it declares none.
    static func enabledTraits(of package: GraphPackage, request: TraitRequest) -> Set<String> {
        let manifest = package.manifest
        guard !manifest.traits.isEmpty else {
            return [Manifest.defaultTrait]
        }

        // Roots use the default configuration; dependencies what their parents asked for.
        guard package.role == .dependency else {
            return Self.flatten([Manifest.defaultTrait], in: manifest)
        }
        var requested: Set<String>
        if !request.explicit.isEmpty {
            requested = request.explicit
        } else if request.defaults || !request.disabled {
            requested = [Manifest.defaultTrait]
        } else {
            requested = []
        }

        // A parent wanting the defaults adds them even next to another parent's explicit traits.
        var enabled = Self.flatten(requested, in: manifest)
        if request.defaults {
            enabled.formUnion(Self.flatten([Manifest.defaultTrait], in: manifest))
        }

        // `traits: [.defaults, "X"]` keeps `default` itself among the enabled traits (SwiftPM records the
        // request as given); a plain default request does not.
        if request.explicit.contains(Manifest.defaultTrait) {
            enabled.insert(Manifest.defaultTrait)
        }
        return enabled
    }

    /// `calculateAllEnabledTraits`: replaces `default` with the default traits, then follows
    /// each trait's own enabled traits. `default` itself is never part of the result.
    static func flatten(_ requested: Set<String>, in manifest: Manifest) -> Set<String> {
        var enabled = requested
        let defaultsEnabled = enabled.remove(Manifest.defaultTrait) != nil
        if defaultsEnabled, let defaults = manifest.traits.first(where: { $0.name == Manifest.defaultTrait }) {
            enabled.formUnion(defaults.enabledTraits)
        }

        // Follow trait-enables-trait links until nothing new appears.
        let byName = Dictionary(manifest.traits.map { ($0.name, $0.enabledTraits) }, uniquingKeysWith: { first, _ in first })
        var pending = Array(enabled)
        while let name = pending.popLast() {
            for implied in byName[name] ?? [] where implied != Manifest.defaultTrait && enabled.insert(implied).inserted {
                pending.append(implied)
            }
        }
        return enabled
    }
}
