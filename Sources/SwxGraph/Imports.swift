import Foundation
import SwxManifest

/// How `swx inspect imports` prints its report.
public enum ImportsFormat: Sendable {
    case text
    case json
}

/// What `swx inspect imports` found in one target.
public struct TargetImportFindings: Sendable, Equatable, Encodable {
    /// A module imported from the graph without being declared.
    public struct ImplicitImport: Sendable, Equatable, Encodable {
        public let module: String
        /// The package that provides it.
        public let package: String
        /// A product of that package that contains the module, to declare instead.
        public let product: String?
    }

    public let target: String
    public let implicit: [ImplicitImport]
    /// Declared dependencies none of whose modules are imported, as `product X (package)` or `target X`.
    public let unused: [String]
}

public struct ImportsReport: Sendable, Equatable, Encodable {
    public let targets: [TargetImportFindings]

    /// Implicit imports break builds that start clean; unused dependencies only cost build time.
    public var hasImplicitImports: Bool {
        self.targets.contains { !$0.implicit.isEmpty }
    }
}

extension PackageGraph {
    /// SwiftPM's module name for a target: its name with characters Swift identifiers can't hold
    /// replaced by `_` (`c99name`).
    public static func moduleName(of target: String) -> String {
        String(target.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" })
    }

    /// One declared dependency of a root target and the modules it makes importable.
    private struct Declared {
        let label: String
        let modules: Set<String>
        /// Executables, plugins, macros and binaries are used without being imported.
        let checksUse: Bool
    }

    private static let unimportedKinds: Set<Manifest.Target.Kind> = [.executable, .plugin, .macro, .binary, .system]
    private static let unimportedProductKinds: Set<Manifest.Product.Kind> = [.executable, .plugin, .macro, .snippet, .test, .application]

    /// Checks each root target's imports (`imports[target]`, from its sources) against what it declares.
    public func inspectImports(_ imports: [String: Set<String>]) -> ImportsReport {
        let root = self.root.manifest

        // Every module the graph provides, and which package (and product) provides it.
        var providers: [String: (package: GraphPackage, product: String?)] = [:]
        for package in self.reachablePackages {
            for target in package.manifest.targets where target.kind != .test {
                let product = package.manifest.products.first { $0.targets.contains(target.name) }?.name
                providers[Self.moduleName(of: target.name)] = providers[Self.moduleName(of: target.name)] ?? (package, product)
            }
        }

        var findings: [TargetImportFindings] = []
        for target in root.targets {
            guard let imported = imports[target.name] else { continue }
            let own = Self.moduleName(of: target.name)
            let declared = target.dependencies.compactMap { self.declared($0) }
            let declaredModules = declared.reduce(into: Set<String>()) { $0.formUnion($1.modules) }

            // Imports of graph modules nobody declared.
            let implicit = imported.sorted().compactMap { module -> TargetImportFindings.ImplicitImport? in
                guard module != own, !declaredModules.contains(module), let provider = providers[module] else { return nil }
                return .init(module: module, package: provider.package.identity, product: provider.package.role == .root ? nil : provider.product)
            }

            // Declarations none of whose modules are imported.
            let unused = declared.filter { $0.checksUse && $0.modules.isDisjoint(with: imported) }.map(\.label)
            findings.append(TargetImportFindings(target: target.name, implicit: implicit, unused: unused))
        }
        return ImportsReport(targets: findings)
    }

    /// The modules a root target dependency makes importable.
    private func declared(_ dependency: Manifest.TargetDependency) -> Declared? {
        let root = self.root.manifest
        let local = { (name: String) -> Declared? in
            guard let target = root.targets.first(where: { $0.name == name }) else { return nil }
            return Declared(label: "target \(name)", modules: [Self.moduleName(of: name)], checksUse: !Self.unimportedKinds.contains(target.kind))
        }
        let product = { (name: String, packages: [GraphPackage]) -> Declared? in
            for package in packages {
                guard let product = package.manifest.products.first(where: { $0.name == name }) else { continue }
                return Declared(
                    label: "product \(name) (\(package.identity))",
                    modules: Set(product.targets.map(Self.moduleName(of:))),
                    checksUse: !Self.unimportedProductKinds.contains(product.kind)
                )
            }
            return nil
        }

        switch dependency {
        case .target(let name, _):
            return local(name)
        case .byName(let name, _):
            return local(name) ?? product(name, self.directDependencies(of: self.root))
        case .product(let name, let packageName?, _):
            guard let declared = root.packageDependency(named: packageName),
                  let owner = self.package(satisfying: declared, declaredBy: self.root) else { return nil }
            return product(name, [owner])
        case .product(let name, nil, _):
            return product(name, self.directDependencies(of: self.root))
        }
    }
}

extension ImportsReport {
    private enum Text {
        static let implicit = "  implicit import: "
        static let unused = "  unused dependency: "
        static let declare = "declare "
    }

    public func render(_ format: ImportsFormat) -> String {
        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return String(decoding: (try? encoder.encode(self)) ?? Data(), as: UTF8.self) + "\n"
        case .text:
            return self.text()
        }
    }

    private func text() -> String {
        var output = ""
        for target in self.targets where !(target.implicit.isEmpty && target.unused.isEmpty) {
            output += target.target + "\n"
            for finding in target.implicit {
                let fix = finding.product.map { " — \(Text.declare).product(name: \"\($0)\", package: \"\(finding.package)\")" } ?? ""
                output += Text.implicit + "\(finding.module) (\(finding.package))\(fix)\n"
            }
            for dependency in target.unused {
                output += Text.unused + dependency + "\n"
            }
        }

        // A one-line verdict, so CI logs say what failed.
        let implicit = self.targets.reduce(0) { $0 + $1.implicit.count }
        let unused = self.targets.reduce(0) { $0 + $1.unused.count }
        let targets = Self.count(self.targets.count, "target")
        guard implicit + unused > 0 else {
            return "\(targets): every import is declared, every dependency used\n"
        }
        if !output.isEmpty {
            output += "\n"
        }
        return output + "\(Self.count(implicit, "implicit import")), \(Self.count(unused, "unused dependency", plural: "unused dependencies")) in \(targets)\n"
    }

    private static func count(_ value: Int, _ singular: String, plural: String? = nil) -> String {
        "\(value) " + (value == 1 ? singular : plural ?? singular + "s")
    }
}
