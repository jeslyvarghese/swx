import SwxCore
import SwxManifest
import SwxSource

/// SwiftPM's source-control-to-registry transformation, applied to every manifest it loads.
public enum RegistryTransformation: Sendable {
    /// `--disable-scm-to-registry-transformation` (the default).
    case disabled
    /// `--use-registry-identity-for-scm`: keep fetching from git, under the registry identity.
    case useRegistryIdentity
    /// `--replace-scm-with-registry`: versioned git dependencies become registry ones.
    case replaceWithRegistry
}

/// Rewrites a manifest's remote git dependencies that the registry knows (`/identifiers`).
struct RegistryTransformer: Sendable {
    let mode: RegistryTransformation
    let registry: RegistrySource

    func transform(_ manifest: Manifest) async -> Manifest {
        guard self.mode != .disabled else { return manifest }

        // Look every remote URL up at once; a failed lookup only leaves that dependency alone.
        let identities = await withTaskGroup(of: (Int, PackageIdentity?).self) { group in
            for (index, dependency) in manifest.dependencies.enumerated() {
                guard case .remote(let url) = dependency.location else { continue }
                group.addTask { (index, try? await self.registry.registryIdentity(forURL: url)) }
            }
            return await group.reduce(into: [Int: PackageIdentity]()) { result, element in
                if let identity = element.1 {
                    result[element.0] = identity
                }
            }
        }
        guard !identities.isEmpty else { return manifest }

        var transformed = manifest
        var renamedPackages: [String: String] = [:]
        for (index, identity) in identities {
            let dependency = manifest.dependencies[index]
            switch (self.mode, dependency.requirement) {
            case (.replaceWithRegistry, .range), (.replaceWithRegistry, .exact):
                // The whole dependency moves to the registry; target references follow it.
                renamedPackages[dependency.referenceName.lowercased()] = identity.description
                transformed.dependencies[index] = Manifest.Dependency(
                    identity: identity.description,
                    explicitName: nil,
                    location: .registry(identity: identity.description),
                    requirement: dependency.requirement,
                    traits: dependency.traits
                )
            default:
                // Branch and revision requirements (and identity mode) keep git, under the registry identity.
                transformed.dependencies[index].identity = identity.description
            }
        }

        // `.product(package:)` and by-name references to swapped packages name the registry identity.
        guard !renamedPackages.isEmpty else { return transformed }
        for targetIndex in transformed.targets.indices {
            transformed.targets[targetIndex].dependencies = transformed.targets[targetIndex].dependencies.map { dependency in
                switch dependency {
                case .product(let name, let package?, let condition):
                    guard let renamed = renamedPackages[package.lowercased()] else { return dependency }
                    return .product(name: name, package: renamed, condition: condition)
                case .byName(let name, let condition):
                    guard let renamed = renamedPackages[name.lowercased()] else { return dependency }
                    return .product(name: name, package: renamed, condition: condition)
                case .product, .target:
                    return dependency
                }
            }
        }
        return transformed
    }
}
