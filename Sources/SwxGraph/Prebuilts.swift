// SwiftPM's `handlePrebuilts` (PackageGraph/ModulesGraph+Loading.swift, Apache-2.0): which
// package edges remain once host-only modules use prebuilt libraries instead of products.

import SwxCore
import SwxManifest

extension PackageGraph {
    /// Where a module may be built, as SwiftPM decides it for prebuilts.
    private enum Constraint {
        /// Built for the destination (anything a root product reaches).
        case all
        /// Built only for the host (macros, their tests, and what only they reach).
        case host
    }

    /// A module, by package identity and target name.
    private struct ModuleKey: Hashable {
        let package: String
        let target: String
    }

    /// A module's dependency: one of its package's modules, or a product of another package.
    private enum ModuleDependency {
        case module(ModuleKey)
        case product(owner: String, name: String, kind: Manifest.Product.Kind, modules: [ModuleKey])
    }

    private struct Module {
        let kind: Manifest.Target.Kind
        let dependencies: [ModuleDependency]
    }

    private static let packageTestsSuffix = "PackageTests"

    /// The graph SwiftPM prints when `prebuilts` (identity → products a prebuilt library offers)
    /// are recorded: if every host-only module can use them, those modules stop depending on the
    /// prebuilt products, and packages left using none of a prebuilt package's products no longer
    /// depend on it. Otherwise the graph is unchanged, as in SwiftPM.
    public func applyingPrebuilts(_ prebuilts: [String: Set<String>]) -> PackageGraph {
        let reachable = self.reachablePackages
        let prebuiltPackages = Set(reachable.map(\.identity)).intersection(prebuilts.keys)
        guard !prebuiltPackages.isEmpty else { return self }

        // Every module of the graph, with what it depends on.
        var modules: [ModuleKey: Module] = [:]
        for package in reachable {
            for target in package.manifest.targets {
                let key = ModuleKey(package: package.identity, target: target.name)
                modules[key] = Module(kind: target.kind, dependencies: target.dependencies.compactMap { self.moduleDependency($0, of: package) })
            }
        }
        let isHostOnly = { (key: ModuleKey) -> Bool in
            guard let module = modules[key] else { return false }
            switch module.kind {
            case .macro:
                return true
            case .test:
                return module.dependencies.contains { dependency in
                    switch dependency {
                    case .product(_, _, let kind, _):
                        return kind == .macro
                    case .module(let target):
                        return modules[target]?.kind == .macro
                    }
                }
            default:
                return false
            }
        }
        let moduleDependencies = { (key: ModuleKey) -> [ModuleKey] in
            (modules[key]?.dependencies ?? []).flatMap { dependency -> [ModuleKey] in
                switch dependency {
                case .module(let target):
                    return [target]
                case .product(_, _, _, let targets):
                    return targets
                }
            }
        }

        // What the root's products reach is built for the destination, except host-only modules.
        var constraints: [ModuleKey: Constraint] = [:]
        func markAll(_ key: ModuleKey) {
            guard constraints[key] != .all, !isHostOnly(key) else { return }
            constraints[key] = .all
            moduleDependencies(key).forEach(markAll)
        }
        for target in self.rootProductModules() {
            markAll(ModuleKey(package: self.root.identity, target: target))
        }

        // Host-only modules, and what only they reach, are built for the host.
        func markHost(_ key: ModuleKey) -> Bool {
            switch constraints[key] {
            case .all?:
                return false
            case .host?:
                return true
            case nil:
                break
            }
            for dependency in moduleDependencies(key) where !markHost(dependency) {
                // Reaching a destination module: the host-marked modules below become destination
                // too (SwiftPM leaves this one unmarked, so it is reconsidered later).
                func revert(_ key: ModuleKey) {
                    guard constraints[key] == .host else { return }
                    constraints[key] = .all
                    moduleDependencies(key).forEach(revert)
                }
                revert(key)
                return false
            }
            constraints[key] = .host
            return true
        }
        for key in modules.keys.sorted(by: { ($0.package, $0.target) < ($1.package, $1.target) }) where isHostOnly(key) {
            _ = markHost(key)
        }

        // Prebuilts are used only when every host-only module can use them.
        guard modules.keys.allSatisfy({ !isHostOnly($0) || constraints[$0] == .host }) else { return self }

        // Host modules drop their prebuilt products; what's left decides each package's edges.
        var stillUsed: Set<[String]> = []
        for (key, module) in modules {
            for case .product(let owner, let name, _, _) in module.dependencies where prebuiltPackages.contains(owner) {
                let replaced = constraints[key] == .host && prebuilts[owner]?.contains(name) == true
                if !replaced {
                    stillUsed.insert([key.package, owner])
                }
            }
        }
        var edges = self.dependencies
        for package in reachable where !prebuiltPackages.contains(package.identity) {
            edges[package.identity] = edges[package.identity]?.filter { owner in
                !prebuiltPackages.contains(owner) || stillUsed.contains([package.identity, owner])
            }
        }
        return PackageGraph(root: self.root, packages: self.packages, dependencies: edges, enabledTraits: self.enabledTraits, resolvedIdentities: self.resolvedIdentities)
    }

    /// The modules of the root's products: those declared, an executable product for each
    /// executable target, and the test product of all test targets, as SwiftPM synthesizes them.
    private func rootProductModules() -> [String] {
        let manifest = self.root.manifest
        var targets = manifest.products.flatMap(\.targets)
        targets += manifest.targets.filter { $0.kind == .executable || $0.kind == .test }.map(\.name)
        return targets
    }

    private func moduleDependency(_ dependency: Manifest.TargetDependency, of package: GraphPackage) -> ModuleDependency? {
        let manifest = package.manifest
        func product(_ name: String, among owners: [GraphPackage]) -> ModuleDependency? {
            for owner in owners {
                guard let product = owner.manifest.products.first(where: { $0.name == name }) else { continue }
                return .product(owner: owner.identity, name: name, kind: product.kind, modules: product.targets.map { ModuleKey(package: owner.identity, target: $0) })
            }
            return nil
        }

        switch dependency {
        case .target(let name, _):
            return .module(ModuleKey(package: package.identity, target: name))
        case .byName(let name, _):
            if manifest.targets.contains(where: { $0.name == name }) {
                return .module(ModuleKey(package: package.identity, target: name))
            }
            return product(name, among: self.directDependencies(of: package))
        case .product(let name, let packageName?, _):
            guard let declared = manifest.packageDependency(named: packageName),
                  let owner = self.package(satisfying: declared, declaredBy: package) else { return nil }
            return product(name, among: [owner])
        case .product(let name, nil, _):
            return product(name, among: self.directDependencies(of: package))
        }
    }
}
