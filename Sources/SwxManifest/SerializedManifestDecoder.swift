import Foundation
import SwxCore
import SwxSystem

/// Decodes the package a compiled manifest serializes (`{"errors": […], "package": {…}}`).
///
/// This is PackageDescription's own format, not `dump-package`'s: enums are single-key objects
/// with named payloads (`{"exact": {"_0": {"major": 1, …}}}`), locations are raw, and nothing is
/// resolved yet. Normalization here mirrors what SwiftPM's manifest parser does before
/// `dump-package` prints it, so both paths produce the same `Manifest`.
enum SerializedManifestDecoder {
    private enum Key {
        static let errors = "errors"
        static let package = "package"
        static let name = "name"
        static let dependencies = "dependencies"
        static let targets = "targets"
        static let products = "products"
        static let traits = "traits"
        static let platforms = "platforms"
        static let kind = "kind"
        static let location = "location"
        static let requirement = "requirement"
        static let path = "path"
        static let id = "id"
        static let lowerBound = "lowerBound"
        static let upperBound = "upperBound"
        static let payload = "_0"
        static let major = "major"
        static let minor = "minor"
        static let patch = "patch"
        static let prerelease = "prereleaseIdentifiers"
        static let build = "buildMetadataIdentifiers"
        static let type = "type"
        static let condition = "condition"
        static let pluginUsages = "pluginUsages"
        static let plugin = "plugin"
        static let url = "url"
        static let checksum = "checksum"
        static let productType = "productType"
        static let settings = "settings"
        static let enabledTraits = "enabledTraits"
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

    /// The setting AppleProductTypes adds to the executable products it declares.
    private static let applicationSetting = "iOSAppInfo"

    static func decode(_ data: Data, packageDirectory: URL, toolsVersion: ToolsVersion) throws -> Manifest {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ManifestError(description: "the manifest did not produce a JSON object")
        }
        if let errors = root[Key.errors] as? [String], !errors.isEmpty {
            throw ManifestError(description: errors.joined(separator: "\n"))
        }
        guard let package = root[Key.package] as? [String: Any] else {
            throw ManifestError(description: "the manifest did not produce a package")
        }

        let dependencies = try (package[Key.dependencies] as? [[String: Any]] ?? []).map {
            try Self.dependency($0, packageDirectory: packageDirectory)
        }
        let targets = (package[Key.targets] as? [[String: Any]] ?? []).map(Self.target)
        let products = (package[Key.products] as? [[String: Any]] ?? []).map(Self.product)

        // Sets in PackageDescription serialize in arbitrary order: normalize by sorting.
        let traits = (package[Key.traits] as? [[String: Any]] ?? []).map {
            Manifest.Trait(name: $0[Key.name] as? String ?? "", enabledTraits: ($0[Key.enabledTraits] as? [String] ?? []).sorted())
        }.sorted { $0.name < $1.name }

        return Manifest(
            name: package[Key.name] as? String ?? "",
            toolsVersion: toolsVersion.description,
            dependencies: dependencies,
            targets: targets,
            products: products,
            traits: traits
        )
    }

    // MARK: Dependencies

    private static func dependency(_ json: [String: Any], packageDirectory: URL) throws -> Manifest.Dependency {
        guard let (kind, settings) = Self.enumCase(json[Key.kind]) else {
            throw ManifestError(description: "unrecognized dependency encoding")
        }
        let explicitName = settings[Key.name] as? String
        let traits = ((json[Key.traits] as? [[String: Any]])?.compactMap { $0[Key.name] as? String } ?? [Manifest.defaultTrait]).sorted()
        let traitConditions = Self.traitConditions(json[Key.traits])

        switch kind {
        case DependencyKind.sourceControl:
            let rawLocation = settings[Key.location] as? String ?? ""
            let location = Self.sourceControlLocation(rawLocation, packageDirectory: packageDirectory)
            return Manifest.Dependency(
                identity: PackageIdentity(location: Self.identityLocation(of: location)).description,
                explicitName: explicitName,
                location: location,
                requirement: Self.requirement(settings[Key.requirement]),
                traits: traits,
                traitConditions: traitConditions
            )

        case DependencyKind.fileSystem:
            // Paths are made absolute against the package, as `dump-package` prints them.
            let path = FileSystem.normalize(settings[Key.path] as? String ?? "", relativeTo: packageDirectory.path)
            return Manifest.Dependency(
                identity: PackageIdentity(location: path).description,
                explicitName: explicitName,
                location: .local(path: path),
                requirement: .none,
                traits: traits,
                traitConditions: traitConditions
            )

        case DependencyKind.registry:
            let identity = settings[Key.id] as? String ?? ""
            return Manifest.Dependency(
                identity: identity,
                explicitName: nil,
                location: .registry(identity: identity),
                requirement: Self.requirement(settings[Key.requirement]),
                traits: traits,
                traitConditions: traitConditions
            )

        default:
            throw ManifestError(description: "unknown dependency kind '\(kind)'")
        }
    }

    /// `file://` URLs and paths are local repositories (relative ones against the package).
    private static func sourceControlLocation(_ location: String, packageDirectory: URL) -> Manifest.Dependency.Location {
        switch PackageKind.sourceControl(location: location) {
        case .localSourceControl(let path)?:
            return .localSourceControl(path: FileSystem.normalize(path, relativeTo: packageDirectory.path))
        case nil:
            return .localSourceControl(path: FileSystem.normalize(location, relativeTo: packageDirectory.path))
        default:
            return .remote(url: location)
        }
    }

    private static func identityLocation(of location: Manifest.Dependency.Location) -> String {
        switch location {
        case .remote(let url):
            return url
        case .localSourceControl(let path), .local(let path):
            return path
        case .registry(let identity):
            return identity
        }
    }

    private static func requirement(_ json: Any?) -> Manifest.Dependency.Requirement {
        guard let (kind, payload) = Self.enumCase(json) else {
            return .none
        }
        switch kind {
        case RequirementKind.range:
            return .range(lowerBound: Self.version(payload[Key.lowerBound]), upperBound: Self.version(payload[Key.upperBound]))
        case RequirementKind.exact:
            return .exact(Self.version(payload[Key.payload]))
        case RequirementKind.branch:
            return .branch(payload[Key.payload] as? String ?? "")
        case RequirementKind.revision:
            return .revision(payload[Key.payload] as? String ?? "")
        default:
            return .none
        }
    }

    /// `{"major": 1, "minor": 2, "patch": 0, "prereleaseIdentifiers": [], …}` → `1.2.0`.
    private static func version(_ json: Any?) -> String {
        guard let object = json as? [String: Any] else { return "" }
        let version = Version(
            object[Key.major] as? Int ?? 0,
            object[Key.minor] as? Int ?? 0,
            object[Key.patch] as? Int ?? 0,
            prereleaseIdentifiers: object[Key.prerelease] as? [String] ?? [],
            buildMetadataIdentifiers: object[Key.build] as? [String] ?? []
        )
        return version.description
    }

    // MARK: Targets and products

    private static func target(_ json: [String: Any]) -> Manifest.Target {
        let kind = Self.enumCase(json[Key.type]).flatMap { Manifest.Target.Kind(rawValue: $0.0) } ?? .regular
        let dependencies = (json[Key.dependencies] as? [Any] ?? []).compactMap(Self.targetDependency)
        let plugins = (json[Key.pluginUsages] as? [Any] ?? []).compactMap { usage -> Manifest.PluginUsage? in
            guard let (_, payload) = Self.enumCase(usage), let name = payload[Key.name] as? String else { return nil }
            return Manifest.PluginUsage(name: name, package: payload[Key.package] as? String)
        }

        var binaryLocation: Manifest.Target.BinaryLocation?
        if kind == .binary {
            if let url = json[Key.url] as? String, let checksum = json[Key.checksum] as? String {
                binaryLocation = .remote(url: url, checksum: checksum)
            } else if let path = json[Key.path] as? String {
                binaryLocation = .local(path: path)
            }
        }
        return Manifest.Target(
            name: json[Key.name] as? String ?? "",
            kind: kind,
            dependencies: dependencies,
            pluginUsages: plugins,
            binaryLocation: binaryLocation,
            path: json[Key.path] as? String
        )
    }

    /// `traits: [{name, condition: {traits: […]}}]` → trait name → condition traits, for conditional ones.
    private static func traitConditions(_ raw: Any?) -> [String: [String]] {
        var conditions: [String: [String]] = [:]
        for trait in raw as? [[String: Any]] ?? [] {
            guard let name = trait[Key.name] as? String,
                  let condition = (trait[Key.condition] as? [String: Any])?[Key.traits] as? [String] else { continue }
            conditions[name] = condition.sorted()
        }
        return conditions
    }

    private static func targetDependency(_ json: Any) -> Manifest.TargetDependency? {
        guard let (kind, payload) = Self.enumCase(json), let name = payload[Key.name] as? String else { return nil }

        // `{platforms: [{name: "linux"}], traits: [...]}`; only traits matter for resolution, platforms label graphs.
        let condition = (payload[Key.condition] as? [String: Any]).map { condition in
            let platforms = (condition[Key.platforms] as? [[String: Any]] ?? []).compactMap { $0[Key.name] as? String }
            return Manifest.Condition(platforms: platforms.isEmpty ? nil : platforms, traits: (condition[Key.traits] as? [String])?.sorted())
        }
        switch kind {
        case TargetDependencyKind.target:
            return .target(name: name, condition: condition)
        case TargetDependencyKind.product:
            return .product(name: name, package: payload[Key.package] as? String, condition: condition)
        case TargetDependencyKind.byName:
            return .byName(name: name, condition: condition)
        default:
            return nil
        }
    }

    private enum ApplicationKey {
        static let bundleIdentifier = "bundleIdentifier"
        static let teamIdentifier = "teamIdentifier"
        static let displayVersion = "displayVersion"
        static let bundleVersion = "bundleVersion"
        static let deviceFamilies = "supportedDeviceFamilies"
        static let orientations = "supportedInterfaceOrientations"
    }

    /// AppleProductTypes products serialize as executables carrying an `iOSAppInfo` setting.
    private static func product(_ json: [String: Any]) -> Manifest.Product {
        let name = json[Key.name] as? String ?? ""
        let targets = json[Key.targets] as? [String] ?? []
        let type = Self.enumCase(json[Key.productType])?.0
        let settings = json[Key.settings] as? [[String: Any]] ?? []
        if let info = settings.lazy.compactMap({ $0[Self.applicationSetting] as? [String: Any] }).first {
            // Each setting is `{"<name>": {"_0": value}}`.
            func value(_ key: String) -> String? {
                settings.lazy.compactMap { ($0[key] as? [String: Any])?[Key.payload] as? String }.first
            }
            let appInfo = info[Key.payload] as? [String: Any] ?? [:]
            let orientations = (appInfo[ApplicationKey.orientations] as? [Any] ?? []).compactMap { Self.enumCase($0)?.0 }
            let application = Manifest.Product.ApplicationSettings(
                bundleIdentifier: value(ApplicationKey.bundleIdentifier),
                teamIdentifier: value(ApplicationKey.teamIdentifier),
                displayVersion: value(ApplicationKey.displayVersion),
                bundleVersion: value(ApplicationKey.bundleVersion),
                deviceFamilies: appInfo[ApplicationKey.deviceFamilies] as? [String] ?? [],
                interfaceOrientations: orientations
            )
            return Manifest.Product(name: name, targets: targets, kind: .application, application: application)
        }
        return Manifest.Product(name: name, targets: targets, kind: type.flatMap(Manifest.Product.Kind.init(rawValue:)) ?? .library)
    }

    // MARK: Helpers

    /// `{"case": {payload}}` → `("case", payload)`.
    private static func enumCase(_ json: Any?) -> (String, [String: Any])? {
        guard let object = json as? [String: Any], object.count == 1, let (key, value) = object.first else {
            return nil
        }
        return (key, value as? [String: Any] ?? [:])
    }
}
