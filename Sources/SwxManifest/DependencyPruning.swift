import SwxCore

/// Whether a manifest is a root of the workspace or a dependency.
public enum ManifestRole: Sendable {
    case root
    case dependency
}

/// SwiftPM's rules for which declared dependencies actually take part in resolution.
///
/// Pure port of `Manifest.dependenciesRequired(for:_:)` (the shipping, non target-based
/// branch) plus its trait handling.
extension Manifest {
    public static let defaultTrait = "default"

    /// Tools version from which unused dependencies of non-root packages are pruned.
    private static let pruningToolsVersion = ToolsVersion(5, 2, 0)

    /// The dependencies that participate in resolution for the given role and traits.
    public func requiredDependencies(role: ManifestRole, enabledTraits: Set<String> = [Manifest.defaultTrait]) -> [Dependency] {
        let traits = self.expand(traits: enabledTraits)

        // Roots and pre-5.2 manifests keep every dependency not hidden behind a disabled trait.
        if role == .root || self.parsedToolsVersion < Self.pruningToolsVersion {
            return self.dependencies.filter { !self.isTraitGuarded($0, enabledTraits: traits) }
        }

        // Otherwise only dependencies referenced by targets that products need.
        var required: Set<String> = []
        for target in self.targetsRequiredByProducts() {
            for dependency in target.dependencies where self.isEnabled(dependency, enabledTraits: traits) {
                if let package = self.packageDependency(referencedBy: dependency) {
                    required.insert(package.identity)
                }
            }
            for usage in target.pluginUsages {
                if let packageName = usage.package, let package = self.packageDependency(named: packageName) {
                    required.insert(package.identity)
                }
            }
        }
        return self.dependencies.filter { required.contains($0.identity) }
    }

    // MARK: Target closure

    /// Targets reachable from any product, following in-package target dependencies and plugins.
    func targetsRequiredByProducts() -> [Target] {
        let targetsByName = Dictionary(self.targets.map { ($0.name, $0) }, uniquingKeysWith: { $1 })
        let productsByName = Dictionary(self.products.map { ($0.name, $0) }, uniquingKeysWith: { $1 })

        var required: Set<String> = []
        var pending = self.products.flatMap(\.targets)

        // Breadth-first over target-to-target edges.
        while let name = pending.popLast() {
            guard required.insert(name).inserted, let target = targetsByName[name] else { continue }

            for dependency in target.dependencies {
                switch dependency {
                case .target(let name, _), .byName(let name, _):
                    if targetsByName[name] != nil {
                        pending.append(name)
                    }
                case .product:
                    continue
                }
            }

            // Local plugins are required too, by target name or via a local product.
            for usage in target.pluginUsages where usage.package == nil {
                if targetsByName[usage.name] != nil {
                    pending.append(usage.name)
                } else if let first = productsByName[usage.name]?.targets.first {
                    pending.append(first)
                }
            }
        }

        return self.targets.filter { required.contains($0.name) }
    }

    // MARK: Package lookup

    func packageDependency(referencedBy dependency: TargetDependency) -> Dependency? {
        switch dependency {
        case .product(_, let package?, _), .byName(let package, _):
            return self.packageDependency(named: package)
        case .product, .target:
            return nil
        }
    }

    /// Case-insensitive, matching rdar://80594761.
    func packageDependency(named name: String) -> Dependency? {
        let lowered = name.lowercased()
        return self.dependencies.first { $0.referenceName.lowercased() == lowered }
    }

    // MARK: Traits

    private var supportsTraits: Bool {
        !self.traits.isEmpty
    }

    /// Expands `default` (and nested enabled traits) into the full enabled set.
    func expand(traits requested: Set<String>) -> Set<String> {
        let byName = Dictionary(self.traits.map { ($0.name, $0) }, uniquingKeysWith: { $1 })
        var enabled: Set<String> = []
        var pending = Array(requested)

        while let name = pending.popLast() {
            guard enabled.insert(name).inserted else { continue }
            pending.append(contentsOf: byName[name]?.enabledTraits ?? [])
        }
        return enabled
    }

    func isEnabled(_ dependency: TargetDependency, enabledTraits: Set<String>) -> Bool {
        guard self.supportsTraits, let guards = dependency.condition?.traits, !guards.isEmpty else {
            return true
        }
        return guards.contains { enabledTraits.contains($0) }
    }

    /// A dependency is trait-guarded when every target reference to it sits behind a disabled trait.
    func isTraitGuarded(_ dependency: Dependency, enabledTraits: Set<String>) -> Bool {
        let identity = dependency.identity.lowercased()
        let references = self.targets.flatMap(\.dependencies).filter { reference in
            guard case .product(_, let package?, _) = reference else { return false }
            return package.lowercased() == identity
        }
        guard !references.isEmpty else { return false }

        // Used anywhere without a trait condition: not guarded.
        let usedUnconditionally = references.contains { $0.condition?.traits == nil }
        guard !usedUnconditionally else { return false }

        return references.allSatisfy { !self.isEnabled($0, enabledTraits: enabledTraits) }
    }
}

// MARK: - Conversion to resolver input

extension Manifest.Dependency {
    /// The package reference and requirement the resolver works with.
    ///
    /// Returns `nil` for registry dependencies, which are not supported yet.
    public var declaration: DependencyDeclaration? {
        let reference: PackageReference
        switch self.location {
        case .remote(let url):
            reference = PackageReference(identity: PackageIdentity(plain: self.identity), kind: .remoteSourceControl(url: url))
        case .local(let path):
            reference = PackageReference(identity: PackageIdentity(plain: self.identity), kind: .fileSystem(path: path))
        case .registry:
            return nil
        }
        return DependencyDeclaration(package: reference, requirement: self.resolverRequirement)
    }

    var resolverRequirement: SwxCore.Requirement {
        switch self.requirement {
        case .range(let lower, let upper):
            guard let lowerVersion = Version(lower), let upperVersion = Version(upper) else {
                return .unversioned
            }
            return .version(.range(VersionRange(lowerVersion, upperVersion)))
        case .exact(let text):
            guard let version = Version(text) else {
                return .unversioned
            }
            return .version(.exact(version))
        case .branch(let name):
            return .branch(name)
        case .revision(let revision):
            return .revision(revision)
        case .none:
            return .unversioned
        }
    }
}
