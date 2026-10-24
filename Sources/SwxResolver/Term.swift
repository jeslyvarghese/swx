import SwxCore

/// Whether a term asserts that a package is selected within a set, or that it isn't.
enum Polarity: Sendable, Hashable {
    /// The package is selected at a version in the set.
    case positive
    /// The package is not selected at a version in the set (it may not be selected at all).
    case negative

    var inverted: Polarity {
        switch self {
        case .positive:
            return .negative
        case .negative:
            return .positive
        }
    }
}

/// How the accumulated assignments for a package relate to a term.
enum TermRelation {
    case satisfied
    case contradicted
    case inconclusive
}

/// A PubGrub term: a statement about which versions of one package may be selected.
struct Term: Sendable, Hashable {
    let package: PackageIdentity
    let polarity: Polarity
    let versions: VersionSet

    init(_ package: PackageIdentity, _ polarity: Polarity, _ versions: VersionSet) {
        self.package = package
        self.polarity = polarity
        self.versions = versions
    }

    var inverse: Term {
        Term(self.package, self.polarity.inverted, self.versions)
    }

    /// The versions this term allows, if the package is selected.
    var allowedVersions: VersionSet {
        switch self.polarity {
        case .positive:
            return self.versions
        case .negative:
            return VersionSet(full: self.versions.count).subtracting(self.versions)
        }
    }

    /// The conjunction of two terms on the same package.
    func intersection(_ other: Term) -> Term {
        switch (self.polarity, other.polarity) {
        case (.positive, .positive):
            return Term(self.package, .positive, self.versions.intersection(other.versions))
        case (.positive, .negative):
            return Term(self.package, .positive, self.versions.subtracting(other.versions))
        case (.negative, .positive):
            return Term(self.package, .positive, other.versions.subtracting(self.versions))
        case (.negative, .negative):
            return Term(self.package, .negative, self.versions.union(other.versions))
        }
    }

    /// `self ∧ ¬other`, or `nil` when that is empty.
    func difference(_ other: Term) -> Term? {
        let result = self.intersection(other.inverse)
        return result.isEmpty ? nil : result
    }

    /// A term no assignment can satisfy.
    var isEmpty: Bool {
        self.polarity == .positive && self.versions.isEmpty
    }

    /// Does `self` (an accumulated assignment) imply `other`?
    func satisfies(_ other: Term) -> Bool {
        switch (self.polarity, other.polarity) {
        case (.positive, .positive):
            return self.versions.isSubset(of: other.versions)
        case (.positive, .negative):
            return self.versions.isDisjoint(with: other.versions)
        case (.negative, .positive):
            // "Not selected" is always possible under a negative term.
            return false
        case (.negative, .negative):
            return other.versions.isSubset(of: self.versions)
        }
    }

    /// Can `self` and `other` both hold?
    func isDisjoint(with other: Term) -> Bool {
        switch (self.polarity, other.polarity) {
        case (.positive, .positive):
            return self.versions.isDisjoint(with: other.versions)
        case (.positive, .negative):
            return self.versions.isSubset(of: other.versions)
        case (.negative, .positive):
            return other.versions.isSubset(of: self.versions)
        case (.negative, .negative):
            // Both admit "not selected".
            return false
        }
    }

    func relation(to other: Term) -> TermRelation {
        if self.satisfies(other) {
            return .satisfied
        }
        if self.isDisjoint(with: other) {
            return .contradicted
        }
        return .inconclusive
    }
}
