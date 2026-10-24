import Foundation

public struct ManifestError: Error, CustomStringConvertible {
    public let description: String
}

/// Decodes `swift package dump-package` JSON into a `Manifest`.
///
/// SwiftPM encodes enums as single-key objects whose value is an array of associated
/// values (`{"product": ["NIOCore", "swift-nio", null, null]}`), so this walks the JSON
/// by hand rather than through `Codable`.
enum DumpPackageDecoder {
    private enum Key {
        static let name = "name"
        static let toolsVersion = "toolsVersion"
        static let versionValue = "_version"
        static let dependencies = "dependencies"
        static let targets = "targets"
        static let products = "products"
        static let traits = "traits"
        static let identity = "identity"
        static let explicitName = "nameForTargetDependencyResolutionOnly"
        static let location = "location"
        static let requirement = "requirement"
        static let path = "path"
        static let remote = "remote"
        static let local = "local"
        static let urlString = "urlString"
        static let lowerBound = "lowerBound"
        static let upperBound = "upperBound"
        static let enabledTraits = "enabledTraits"
        static let pluginUsages = "pluginUsages"
        static let plugin = "plugin"
    }

    private enum DependencyKind {
        static let sourceControl = "sourceControl"
        static let fileSystem = "fileSystem"
        static let registry = "registry"
    }

    private enum RequirementKind {
        static let range = "range"
        static let exact = "exact"
        static let branch = "branch"
        static let revision = "revision"
    }

    private enum TargetDependencyKind {
        static let target = "target"
        static let product = "product"
        static let byName = "byName"
    }

    /// Positions inside the encoded associated-value arrays.
    private enum Position {
        static let name = 0
        static let productPackage = 1
        static let byNameCondition = 1
        static let targetCondition = 1
        static let productCondition = 3
    }

    static func decode(_ data: Data) throws -> Manifest {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ManifestError(description: "dump-package output is not a JSON object")
        }

        let toolsVersion = (json[Key.toolsVersion] as? [String: Any])?[Key.versionValue] as? String ?? ""
        let dependencies = try (json[Key.dependencies] as? [[String: Any]] ?? []).map(Self.dependency)
        let targets = (json[Key.targets] as? [[String: Any]] ?? []).map(Self.target)
        let products = (json[Key.products] as? [[String: Any]] ?? []).map {
            Manifest.Product(name: $0[Key.name] as? String ?? "", targets: $0[Key.targets] as? [String] ?? [])
        }
        let traits = (json[Key.traits] as? [[String: Any]] ?? []).map {
            Manifest.Trait(name: $0[Key.name] as? String ?? "", enabledTraits: $0[Key.enabledTraits] as? [String] ?? [])
        }

        return Manifest(
            name: json[Key.name] as? String ?? "",
            toolsVersion: toolsVersion,
            dependencies: dependencies,
            targets: targets,
            products: products,
            traits: traits
        )
    }

    // MARK: Dependencies

    private static func dependency(_ json: [String: Any]) throws -> Manifest.Dependency {
        // `{"sourceControl": [settings]}` / `{"fileSystem": [settings]}` / `{"registry": [settings]}`
        guard let (kind, payload) = Self.enumCase(json), let settings = payload.first as? [String: Any] else {
            throw ManifestError(description: "unrecognized dependency encoding")
        }

        let identity = settings[Key.identity] as? String ?? ""
        let explicitName = settings[Key.explicitName] as? String
        let traits = (settings[Key.traits] as? [[String: Any]])?.compactMap { $0[Key.name] as? String } ?? [Manifest.defaultTrait]

        switch kind {
        case DependencyKind.sourceControl:
            return Manifest.Dependency(
                identity: identity,
                explicitName: explicitName,
                location: Self.sourceControlLocation(settings[Key.location]),
                requirement: Self.requirement(settings[Key.requirement]),
                traits: traits
            )
        case DependencyKind.fileSystem:
            return Manifest.Dependency(
                identity: identity,
                explicitName: explicitName,
                location: .local(path: settings[Key.path] as? String ?? ""),
                requirement: .none,
                traits: traits
            )
        case DependencyKind.registry:
            return Manifest.Dependency(
                identity: identity,
                explicitName: nil,
                location: .registry(identity: identity),
                requirement: Self.requirement(settings[Key.requirement]),
                traits: traits
            )
        default:
            throw ManifestError(description: "unknown dependency kind '\(kind)'")
        }
    }

    private static func sourceControlLocation(_ json: Any?) -> Manifest.Dependency.Location {
        guard let (kind, payload) = Self.enumCase(json as? [String: Any] ?? [:]) else {
            return .local(path: "")
        }
        switch kind {
        case Key.remote:
            let url = (payload.first as? [String: Any])?[Key.urlString] as? String ?? payload.first as? String ?? ""
            return .remote(url: url)
        default:
            return .local(path: payload.first as? String ?? "")
        }
    }

    private static func requirement(_ json: Any?) -> Manifest.Dependency.Requirement {
        guard let (kind, payload) = Self.enumCase(json as? [String: Any] ?? [:]) else {
            return .none
        }
        switch kind {
        case RequirementKind.range:
            let bounds = payload.first as? [String: Any] ?? [:]
            return .range(lowerBound: bounds[Key.lowerBound] as? String ?? "", upperBound: bounds[Key.upperBound] as? String ?? "")
        case RequirementKind.exact:
            return .exact(payload.first as? String ?? "")
        case RequirementKind.branch:
            return .branch(payload.first as? String ?? "")
        case RequirementKind.revision:
            return .revision(payload.first as? String ?? "")
        default:
            return .none
        }
    }

    // MARK: Targets

    private static func target(_ json: [String: Any]) -> Manifest.Target {
        let dependencies = (json[Key.dependencies] as? [[String: Any]] ?? []).compactMap(Self.targetDependency)
        let plugins = (json[Key.pluginUsages] as? [[String: Any]] ?? []).compactMap { usage -> Manifest.PluginUsage? in
            guard let values = usage[Key.plugin] as? [Any], let name = values.first as? String else { return nil }
            return Manifest.PluginUsage(name: name, package: values.count > 1 ? values[1] as? String : nil)
        }
        return Manifest.Target(name: json[Key.name] as? String ?? "", dependencies: dependencies, pluginUsages: plugins)
    }

    private static func targetDependency(_ json: [String: Any]) -> Manifest.TargetDependency? {
        guard let (kind, values) = Self.enumCase(json), let name = values.first as? String else {
            return nil
        }
        switch kind {
        case TargetDependencyKind.target:
            return .target(name: name, condition: Self.condition(values, at: Position.targetCondition))
        case TargetDependencyKind.product:
            let package = values.count > Position.productPackage ? values[Position.productPackage] as? String : nil
            return .product(name: name, package: package, condition: Self.condition(values, at: Position.productCondition))
        case TargetDependencyKind.byName:
            return .byName(name: name, condition: Self.condition(values, at: Position.byNameCondition))
        default:
            return nil
        }
    }

    private static func condition(_ values: [Any], at position: Int) -> Manifest.Condition? {
        guard values.count > position, let json = values[position] as? [String: Any] else {
            return nil
        }
        return Manifest.Condition(traits: json[Key.traits] as? [String])
    }

    // MARK: Helpers

    /// Unwraps `{"case": [associated values]}`.
    private static func enumCase(_ json: [String: Any]) -> (String, [Any])? {
        guard json.count == 1, let (key, value) = json.first else {
            return nil
        }
        return (key, value as? [Any] ?? [value])
    }
}
