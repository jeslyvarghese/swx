import SwxCore

/// The subset of a SwiftPM manifest that dependency resolution needs.
///
/// Decoded from `swift package dump-package` output, and cached as JSON in the store.
public struct Manifest: Sendable, Codable, Hashable {
    public var name: String
    public var toolsVersion: String
    public var dependencies: [Dependency]
    public var targets: [Target]
    public var products: [Product]
    public var traits: [Trait]

    public init(
        name: String,
        toolsVersion: String,
        dependencies: [Dependency],
        targets: [Target],
        products: [Product],
        traits: [Trait]
    ) {
        self.name = name
        self.toolsVersion = toolsVersion
        self.dependencies = dependencies
        self.targets = targets
        self.products = products
        self.traits = traits
    }

    public var parsedToolsVersion: ToolsVersion {
        ToolsVersion.parse(versionText: self.toolsVersion) ?? .v3
    }

    // MARK: Nested types

    public struct Dependency: Sendable, Codable, Hashable {
        public enum Location: Sendable, Codable, Hashable {
            case remote(url: String)
            case local(path: String)
            case registry(identity: String)
        }

        public enum Requirement: Sendable, Codable, Hashable {
            case range(lowerBound: String, upperBound: String)
            case exact(String)
            case branch(String)
            case revision(String)
            case none
        }

        public var identity: String
        /// The deprecated `name:` argument, when given.
        public var explicitName: String?
        public var location: Location
        public var requirement: Requirement
        /// Traits this manifest enables on the dependency.
        public var traits: [String]

        public init(identity: String, explicitName: String?, location: Location, requirement: Requirement, traits: [String]) {
            self.identity = identity
            self.explicitName = explicitName
            self.location = location
            self.requirement = requirement
            self.traits = traits
        }

        /// The name target dependencies use to refer to this package (`nameForModuleDependencyResolutionOnly`).
        public var referenceName: String {
            if let explicitName {
                return explicitName
            }
            switch self.location {
            case .remote(let url):
                return PackageIdentity.defaultName(fromLocation: url)
            case .local(let path):
                return PackageIdentity.defaultName(fromLocation: path)
            case .registry(let identity):
                return identity
            }
        }
    }

    public struct Condition: Sendable, Codable, Hashable {
        public var traits: [String]?

        public init(traits: [String]?) {
            self.traits = traits
        }
    }

    public enum TargetDependency: Sendable, Codable, Hashable {
        case target(name: String, condition: Condition?)
        case product(name: String, package: String?, condition: Condition?)
        case byName(name: String, condition: Condition?)

        public var condition: Condition? {
            switch self {
            case .target(_, let condition), .product(_, _, let condition), .byName(_, let condition):
                return condition
            }
        }
    }

    public struct PluginUsage: Sendable, Codable, Hashable {
        public var name: String
        public var package: String?

        public init(name: String, package: String?) {
            self.name = name
            self.package = package
        }
    }

    public struct Target: Sendable, Codable, Hashable {
        public var name: String
        public var dependencies: [TargetDependency]
        public var pluginUsages: [PluginUsage]

        public init(name: String, dependencies: [TargetDependency], pluginUsages: [PluginUsage]) {
            self.name = name
            self.dependencies = dependencies
            self.pluginUsages = pluginUsages
        }
    }

    public struct Product: Sendable, Codable, Hashable {
        public enum Kind: String, Sendable, Codable, Hashable {
            case library
            case executable
            case plugin
            case macro
            case snippet
            case test
            /// AppleProductTypes applications (`.iOSApplication`, …).
            case application
        }

        public var name: String
        public var targets: [String]
        public var kind: Kind

        public init(name: String, targets: [String], kind: Kind = .library) {
            self.name = name
            self.targets = targets
            self.kind = kind
        }
    }

    public struct Trait: Sendable, Codable, Hashable {
        public var name: String
        public var enabledTraits: [String]

        public init(name: String, enabledTraits: [String]) {
            self.name = name
            self.enabledTraits = enabledTraits
        }
    }
}
