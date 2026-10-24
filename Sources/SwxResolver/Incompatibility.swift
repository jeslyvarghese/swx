import SwxCore

typealias IncompatibilityID = Int

/// Why an incompatibility exists.
enum IncompatibilityCause: Sendable, Hashable {
    /// The root package must be selected.
    case root
    /// `package@versions` depends on another package, with the requirement as declared.
    case dependency(requirement: String)
    /// No known version matches the constraint.
    case noVersions
    /// A specific version can't be used (manifest failed to load, tools version too new, …).
    case unavailable(reason: String)
    /// Derived during conflict resolution from two earlier incompatibilities.
    case conflict(IncompatibilityID, IncompatibilityID)
}

/// A set of terms that must not all be true at once.
struct Incompatibility: Sendable, Hashable {
    let terms: [Term]
    let cause: IncompatibilityCause

    /// Builds an incompatibility, merging terms that refer to the same package.
    init(terms: [Term], cause: IncompatibilityCause) {
        var merged: [Term] = []
        var positions: [PackageIdentity: Int] = [:]

        // Same-package terms are conjoined; first-seen order is kept for stable output.
        for term in terms {
            guard let position = positions[term.package] else {
                positions[term.package] = merged.count
                merged.append(term)
                continue
            }
            merged[position] = merged[position].intersection(term)
        }

        self.terms = merged
        self.cause = cause
    }

    func term(for package: PackageIdentity) -> Term? {
        self.terms.first { $0.package == package }
    }
}
