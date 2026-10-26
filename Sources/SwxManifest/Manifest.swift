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
            /// A git repository on disk, versioned by its tags.
            case localSourceControl(path: String)
            /// A path dependency (`.package(path:)`), unversioned.
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
        /// `.trait(name:condition: .when(traits:))`: trait name → the declaring package's traits that switch it on.
        public var traitConditions: [String: [String]]

        public init(
            identity: String,
            explicitName: String?,
            location: Location,
            requirement: Requirement,
            traits: [String],
            traitConditions: [String: [String]] = [:]
        ) {
            self.identity = identity
            self.explicitName = explicitName
            self.location = location
            self.requirement = requirement
            self.traits = traits
            self.traitConditions = traitConditions
        }

        /// The traits asked of this dependency, given the declaring package's enabled traits:
        /// a conditional trait counts when any of its condition's traits is enabled (SwiftPM's `isSatisfied`).
        public func requestedTraits(enabledInParent parentTraits: Set<String>) -> [String] {
            self.traits.filter { name in
                guard let condition = self.traitConditions[name] else { return true }
                return !parentTraits.isDisjoint(with: condition)
            }
        }

        /// The name target dependencies use to refer to this package (`nameForModuleDependencyResolutionOnly`).
        public var referenceName: String {
            if let explicitName {
                return explicitName
            }
            switch self.location {
            case .remote(let url):
                return PackageIdentity.defaultName(fromLocation: url)
            case .local(let path), .localSourceControl(let path):
                return PackageIdentity.defaultName(fromLocation: path)
            case .registry(let identity):
                return identity
            }
        }
    }

    /// `.when(platforms:traits:)` on a target dependency.
    public struct Condition: Sendable, Codable, Hashable {
        /// PackageDescription's platform names (`macos`, `linux`, …) in declaration order; `nil` when absent or empty.
        public var platforms: [String]?
        public var traits: [String]?

        public init(platforms: [String]? = nil, traits: [String]?) {
            self.platforms = platforms
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
        /// SwiftPM's target types (`dump-package`'s `"type"`).
        public enum Kind: String, Sendable, Codable, Hashable {
            case regular
            case executable
            case test
            case plugin
            case macro
            case system
            case binary
        }

        /// Where a binary target's artifact comes from.
        public enum BinaryLocation: Sendable, Codable, Hashable {
            /// `.binaryTarget(name:url:checksum:)`: downloaded, verified against the checksum.
            case remote(url: String, checksum: String)
            /// `.binaryTarget(name:path:)`: relative to the package directory.
            case local(path: String)
        }

        public var name: String
        public var kind: Kind
        public var dependencies: [TargetDependency]
        public var pluginUsages: [PluginUsage]
        /// Set for binary targets only.
        public var binaryLocation: BinaryLocation?
        /// `path:`, relative to the package; `nil` for the conventional `Sources/<name>`, `Tests/<name>`, ….
        public var path: String?

        public init(
            name: String,
            kind: Kind = .regular,
            dependencies: [TargetDependency],
            pluginUsages: [PluginUsage],
            binaryLocation: BinaryLocation? = nil,
            path: String? = nil
        ) {
            self.name = name
            self.kind = kind
            self.dependencies = dependencies
            self.pluginUsages = pluginUsages
            self.binaryLocation = binaryLocation
            self.path = path
        }
    }

    /// Executables SwiftPM can build with `--product`: declared ones plus the implicit
    /// products of executable targets.
    public var executableProductNames: [String] {
        var names = self.products.filter { $0.kind == .executable }.map(\.name)
        for target in self.targets where target.kind == .executable && !names.contains(target.name) {
            names.append(target.name)
        }
        return names
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

        /// What `.iOSApplication(…)` declares (AppleProductTypes), for project generation.
        public struct ApplicationSettings: Sendable, Codable, Hashable {
            public var bundleIdentifier: String?
            public var teamIdentifier: String?
            public var displayVersion: String?
            public var bundleVersion: String?
            /// `phone`, `pad`, `mac`, in declaration order.
            public var deviceFamilies: [String]
            /// `portrait`, `landscapeLeft`, …, in declaration order (conditions dropped).
            public var interfaceOrientations: [String]

            public init(
                bundleIdentifier: String?,
                teamIdentifier: String?,
                displayVersion: String?,
                bundleVersion: String?,
                deviceFamilies: [String],
                interfaceOrientations: [String]
            ) {
                self.bundleIdentifier = bundleIdentifier
                self.teamIdentifier = teamIdentifier
                self.displayVersion = displayVersion
                self.bundleVersion = bundleVersion
                self.deviceFamilies = deviceFamilies
                self.interfaceOrientations = interfaceOrientations
            }
        }

        public var name: String
        public var targets: [String]
        public var kind: Kind
        /// Set for application products only.
        public var application: ApplicationSettings?

        public init(name: String, targets: [String], kind: Kind = .library, application: ApplicationSettings? = nil) {
            self.name = name
            self.targets = targets
            self.kind = kind
            self.application = application
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
