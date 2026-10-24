/// A half-open version range `lowerBound..<upperBound`, with SwiftPM's pre-release rules.
public struct VersionRange: Sendable, Hashable, CustomStringConvertible {
    public let lowerBound: Version
    public let upperBound: Version

    public init(_ lowerBound: Version, _ upperBound: Version) {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }

    /// Mirrors `Range<Version>.contains(version:)` in TSCUtility.
    ///
    /// A pre-release only matches when one of the bounds is itself a pre-release,
    /// and never when it is a pre-release of a release upper bound (`2.0.0-beta` ∉ `1.0.0..<2.0.0`).
    public func contains(_ version: Version) -> Bool {
        if version.hasPrerelease {
            // Ranges without pre-release bounds never admit pre-releases.
            guard self.lowerBound.hasPrerelease || self.upperBound.hasPrerelease else {
                return false
            }

            // Reject pre-releases of a release upper bound.
            if !self.upperBound.hasPrerelease && self.upperBound.isEqualIgnoringPrerelease(version) {
                return false
            }
        }
        return self.lowerBound <= version && version < self.upperBound
    }

    public var supportsPrereleases: Bool {
        self.lowerBound.hasPrerelease || self.upperBound.hasPrerelease
    }

    public var description: String {
        "\(self.lowerBound)..<\(self.upperBound)"
    }
}

/// A version-based requirement, as declared in a manifest.
public enum VersionRequirement: Sendable, Hashable, CustomStringConvertible {
    case exact(Version)
    case range(VersionRange)

    public func contains(_ version: Version) -> Bool {
        switch self {
        case .exact(let exact):
            return exact == version
        case .range(let range):
            return range.contains(version)
        }
    }

    public var supportsPrereleases: Bool {
        switch self {
        case .exact(let exact):
            return exact.hasPrerelease
        case .range(let range):
            return range.supportsPrereleases
        }
    }

    public var description: String {
        switch self {
        case .exact(let exact):
            return exact.description
        case .range(let range):
            return range.description
        }
    }
}

/// Any requirement a dependency declaration can carry.
public enum Requirement: Sendable, Hashable, CustomStringConvertible {
    case version(VersionRequirement)
    case branch(String)
    case revision(String)
    /// Local path dependencies carry no requirement.
    case unversioned

    /// Whether this requirement pins the package outside of version resolution.
    public var isUnversioned: Bool {
        switch self {
        case .version:
            return false
        case .branch, .revision, .unversioned:
            return true
        }
    }

    public var description: String {
        switch self {
        case .version(let requirement):
            return requirement.description
        case .branch(let name):
            return "branch \(name)"
        case .revision(let revision):
            return "revision \(revision)"
        case .unversioned:
            return "unversioned"
        }
    }
}
