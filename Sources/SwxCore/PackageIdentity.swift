/// A package's identity: the lowercased last path component of its location, minus `.git`,
/// or a registry identity (`scope.name`).
///
/// Matches SwiftPM's `PackageIdentity(urlString:)` / `computeDefaultName(fromLocation:)`.
/// Like SwiftPM, identities compare case-insensitively but keep their spelling, so a registry
/// identity is written as declared (`mona.LinkedList`).
public struct PackageIdentity: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let description: String
    /// The case-folded form equality and hashing use.
    private let key: String

    private static let pathSeparator: Character = "/"
    private static let gitSuffix = ".git"

    /// Wraps an already-computed identity string, unmodified.
    public init(plain value: String) {
        self.description = value
        self.key = value.lowercased()
    }

    /// Computes the identity for a URL or file path.
    public init(location: String) {
        self.init(plain: Self.defaultName(fromLocation: location).lowercased())
    }

    public static func == (lhs: PackageIdentity, rhs: PackageIdentity) -> Bool {
        lhs.key == rhs.key
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(self.key)
    }

    private static let registrySeparator: Character = "."

    /// `scope` and `name` of a registry identity (`mona.LinkedList`).
    public var registryComponents: (scope: String, name: String)? {
        guard let separator = self.description.firstIndex(of: Self.registrySeparator) else { return nil }
        let scope = String(self.description[..<separator])
        let name = String(self.description[self.description.index(after: separator)...])
        guard !scope.isEmpty, !name.isEmpty else { return nil }
        return (scope, name)
    }

    /// The case-preserving default name SwiftPM uses for checkouts and `packageRef.name`.
    public static func defaultName(fromLocation location: String) -> String {
        // Ignore a single trailing separator.
        var end = location.endIndex
        if location.last == Self.pathSeparator {
            end = location.index(before: end)
        }

        // Take the last path component.
        let head = location[..<end]
        let start = head.lastIndex(of: Self.pathSeparator).map { location.index(after: $0) } ?? location.startIndex
        var component = location[start..<end]

        // Strip `.git`.
        if component.hasSuffix(Self.gitSuffix) {
            component = component.dropLast(Self.gitSuffix.count)
        }
        return String(component)
    }

    public static func < (lhs: PackageIdentity, rhs: PackageIdentity) -> Bool {
        lhs.description < rhs.description
    }
}

/// Where a package comes from.
public enum PackageKind: Sendable, Hashable {
    case root(path: String)
    case fileSystem(path: String)
    /// A git repository on disk (`.package(url: "file:///…")` or an absolute path).
    case localSourceControl(path: String)
    case remoteSourceControl(url: String)
    /// A package from a registry (SE-0292), named by its `scope.name` identity.
    case registry(identity: String)

    private static let fileScheme = "file://"
    private static let absolutePathPrefix = "/"
    private static let relativePathPrefix = "."

    /// SwiftPM's split for `.package(url:)`: file URLs and absolute paths name local repositories.
    /// Returns `nil` for relative paths, whose base only the manifest's directory knows.
    public static func sourceControl(location: String) -> PackageKind? {
        if location.hasPrefix(Self.fileScheme) {
            return .localSourceControl(path: String(location.dropFirst(Self.fileScheme.count)))
        }
        if location.hasPrefix(Self.absolutePathPrefix) {
            return .localSourceControl(path: location)
        }
        guard !location.hasPrefix(Self.relativePathPrefix) else { return nil }
        return .remoteSourceControl(url: location)
    }

    /// What `git` clones from, for source-control packages.
    public var sourceControlLocation: String? {
        switch self {
        case .remoteSourceControl(let url):
            return url
        case .localSourceControl(let path):
            return path
        case .root, .fileSystem, .registry:
            return nil
        }
    }

    /// The value SwiftPM writes as `"kind"` in `Package.resolved` and workspace state.
    public var serializedName: String {
        switch self {
        case .root:
            return "root"
        case .fileSystem:
            return "fileSystem"
        case .localSourceControl:
            return "localSourceControl"
        case .remoteSourceControl:
            return "remoteSourceControl"
        case .registry:
            return "registry"
        }
    }

    public var location: String {
        switch self {
        case .root(let path), .fileSystem(let path), .localSourceControl(let path):
            return path
        case .remoteSourceControl(let url):
            return url
        case .registry(let identity):
            return identity
        }
    }
}

/// A reference to a package: identity plus where to get it.
public struct PackageReference: Sendable, Hashable, CustomStringConvertible {
    public let identity: PackageIdentity
    public let kind: PackageKind

    /// SwiftPM's `deprecatedName`: the case-preserving default name of the location.
    public var name: String {
        PackageIdentity.defaultName(fromLocation: self.kind.location)
    }

    public init(identity: PackageIdentity, kind: PackageKind) {
        self.identity = identity
        self.kind = kind
    }

    public static func remote(_ url: String) -> PackageReference {
        PackageReference(identity: PackageIdentity(location: url), kind: .remoteSourceControl(url: url))
    }

    public var description: String {
        "\(self.identity) (\(self.kind.location))"
    }
}

/// A dependency as declared by a manifest, after SwiftPM's pruning of unused dependencies.
public struct DependencyDeclaration: Sendable, Hashable {
    public let package: PackageReference
    public let requirement: Requirement

    public init(package: PackageReference, requirement: Requirement) {
        self.package = package
        self.requirement = requirement
    }
}

/// SwiftPM's rules for a registry identity's parts (`swift package-registry publish` checks them).
public enum RegistryIdentityRules {
    private static let maximumScopeLength = 39
    private static let maximumNameLength = 100
    private static let hyphen: Character = "-"
    private static let underscore: Character = "_"

    /// Why `scope` isn't valid, or `nil` when it is: ASCII letters, digits and single inner hyphens.
    public static func problem(scope: String) -> String? {
        Self.problem(scope, kind: "scope", maximumLength: Self.maximumScopeLength, separators: [Self.hyphen])
    }

    /// Why `name` isn't valid, or `nil`: ASCII letters, digits, single inner hyphens and underscores.
    public static func problem(name: String) -> String? {
        Self.problem(name, kind: "name", maximumLength: Self.maximumNameLength, separators: [Self.hyphen, Self.underscore])
    }

    private static func problem(_ text: String, kind: String, maximumLength: Int, separators: Set<Character>) -> String? {
        guard !text.isEmpty else { return "a package \(kind) has at least 1 character" }
        guard text.count <= maximumLength else { return "a package \(kind) has at most \(maximumLength) characters" }

        var previous: Character?
        for character in text {
            let isSeparator = separators.contains(character)
            guard character.isASCII, character.isLetter || character.isNumber || isSeparator else {
                return "a package \(kind) consists of letters, digits and \(separators.count > 1 ? "hyphens or underscores" : "hyphens")"
            }
            if isSeparator, previous == nil || previous.map(separators.contains) == true {
                return "separators may not begin a package \(kind) or occur consecutively"
            }
            previous = character
        }
        guard let last = previous, !separators.contains(last) else {
            return "separators may not end a package \(kind)"
        }
        return nil
    }
}
