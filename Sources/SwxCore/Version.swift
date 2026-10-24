/// A semantic version, compatible with SwiftPM's `TSCUtility.Version`.
///
/// Ordering follows SemVer 2.0: build metadata is ignored, and a version with
/// pre-release identifiers sorts before the same version without them.
public struct Version: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prereleaseIdentifiers: [String]
    public let buildMetadataIdentifiers: [String]

    public init(
        _ major: Int,
        _ minor: Int,
        _ patch: Int,
        prereleaseIdentifiers: [String] = [],
        buildMetadataIdentifiers: [String] = []
    ) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prereleaseIdentifiers = prereleaseIdentifiers
        self.buildMetadataIdentifiers = buildMetadataIdentifiers
    }

    public static let zero = Version(0, 0, 0)

    public var hasPrerelease: Bool {
        !self.prereleaseIdentifiers.isEmpty
    }

    public var withoutPrerelease: Version {
        Version(self.major, self.minor, self.patch, buildMetadataIdentifiers: self.buildMetadataIdentifiers)
    }

    public func isEqualIgnoringPrerelease(_ other: Version) -> Bool {
        (self.major, self.minor, self.patch) == (other.major, other.minor, other.patch)
    }

    public var description: String {
        var text = "\(self.major).\(self.minor).\(self.patch)"
        if !self.prereleaseIdentifiers.isEmpty {
            text += "-" + self.prereleaseIdentifiers.joined(separator: ".")
        }
        if !self.buildMetadataIdentifiers.isEmpty {
            text += "+" + self.buildMetadataIdentifiers.joined(separator: ".")
        }
        return text
    }

    // MARK: Equality and ordering ignore build metadata, as SemVer requires.

    public static func == (lhs: Version, rhs: Version) -> Bool {
        lhs.major == rhs.major
            && lhs.minor == rhs.minor
            && lhs.patch == rhs.patch
            && lhs.prereleaseIdentifiers == rhs.prereleaseIdentifiers
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(self.major)
        hasher.combine(self.minor)
        hasher.combine(self.patch)
        hasher.combine(self.prereleaseIdentifiers)
    }

    public static func < (lhs: Version, rhs: Version) -> Bool {
        // Numeric components decide first.
        if (lhs.major, lhs.minor, lhs.patch) != (rhs.major, rhs.minor, rhs.patch) {
            return (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
        }

        // A release outranks any of its pre-releases.
        switch (lhs.hasPrerelease, rhs.hasPrerelease) {
        case (false, false), (false, true):
            return false
        case (true, false):
            return true
        case (true, true):
            return Self.comparePrerelease(lhs.prereleaseIdentifiers, rhs.prereleaseIdentifiers)
        }
    }

    /// SemVer §11: compare identifiers left to right; numeric < alphanumeric; shorter list wins ties.
    private static func comparePrerelease(_ lhs: [String], _ rhs: [String]) -> Bool {
        for (left, right) in zip(lhs, rhs) where left != right {
            switch (Int(left), Int(right)) {
            case let (leftNumber?, rightNumber?):
                return leftNumber < rightNumber
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                return left < right
            }
        }
        return lhs.count < rhs.count
    }
}

// MARK: - Parsing

extension Version {
    private static let componentSeparator: Character = "."
    private static let prereleaseSeparator: Character = "-"
    private static let buildMetadataSeparator: Character = "+"
    private static let requiredNumericComponents = 3
    private static let tagPrefix: Character = "v"

    /// Parses `MAJOR.MINOR.PATCH[-PRERELEASE][+BUILD]`. All three numeric components are required.
    public init?(_ text: String) {
        var remainder = Substring(text)

        // Split off build metadata first: it may itself contain "-".
        var build: [String] = []
        if let plus = remainder.firstIndex(of: Self.buildMetadataSeparator) {
            build = remainder[remainder.index(after: plus)...].split(separator: Self.componentSeparator, omittingEmptySubsequences: false).map(String.init)
            remainder = remainder[..<plus]
        }

        // Then the pre-release identifiers.
        var prerelease: [String] = []
        if let dash = remainder.firstIndex(of: Self.prereleaseSeparator) {
            prerelease = remainder[remainder.index(after: dash)...].split(separator: Self.componentSeparator, omittingEmptySubsequences: false).map(String.init)
            remainder = remainder[..<dash]
        }

        // Identifiers must be non-empty.
        guard !prerelease.contains(where: \.isEmpty), !build.contains(where: \.isEmpty) else {
            return nil
        }

        // Exactly three non-negative integers.
        let numbers = remainder.split(separator: Self.componentSeparator, omittingEmptySubsequences: false)
        guard numbers.count == Self.requiredNumericComponents else {
            return nil
        }
        var values: [Int] = []
        for number in numbers {
            guard !number.isEmpty, number.allSatisfy(\.isASCII), let value = Int(number), value >= 0 else {
                return nil
            }
            values.append(value)
        }

        self.init(values[0], values[1], values[2], prereleaseIdentifiers: prerelease, buildMetadataIdentifiers: build)
    }

    /// Parses a git tag the way SwiftPM does: an optional leading `v`, then a full version.
    public init?(tag: String) {
        guard tag.first == Self.tagPrefix else {
            self.init(tag)
            return
        }
        self.init(String(tag.dropFirst()))
    }
}
