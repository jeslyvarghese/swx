import SwxCore

/// Whether an assignment was chosen by the solver or forced by an incompatibility.
enum AssignmentKind: Sendable, Hashable {
    case decision
    case derivation(cause: IncompatibilityID)
}

struct Assignment: Sendable, Hashable {
    let term: Term
    let decisionLevel: Int
    let kind: AssignmentKind
}

/// The solver's current set of decisions and derivations, in order.
struct PartialSolution: Sendable {
    private(set) var assignments: [Assignment] = []

    /// Intersection of every assignment so far, per package.
    private(set) var accumulated: [PackageIdentity: Term] = [:]

    /// Chosen version index per package.
    private(set) var decisions: [PackageIdentity: Int] = [:]

    /// Packages in the order they first received a positive derivation (stable decision tie-break).
    private(set) var positiveOrder: [PackageIdentity] = []

    var decisionLevel: Int {
        self.decisions.count
    }

    // MARK: Recording

    mutating func decide(_ package: PackageIdentity, index: Int, domainSize: Int) {
        self.decisions[package] = index
        let term = Term(package, .positive, VersionSet(count: domainSize, indices: [index]))
        self.record(Assignment(term: term, decisionLevel: self.decisionLevel, kind: .decision))
    }

    mutating func derive(_ term: Term, cause: IncompatibilityID) {
        self.record(Assignment(term: term, decisionLevel: self.decisionLevel, kind: .derivation(cause: cause)))
    }

    private mutating func record(_ assignment: Assignment) {
        self.assignments.append(assignment)
        let package = assignment.term.package

        // Fold into the per-package intersection.
        let combined = self.accumulated[package].map { $0.intersection(assignment.term) } ?? assignment.term
        self.accumulated[package] = combined

        // Track first positive appearance for deterministic decision order.
        if combined.polarity == .positive && !self.positiveOrder.contains(package) {
            self.positiveOrder.append(package)
        }
    }

    /// Drops every assignment above `level` and rebuilds the derived indexes.
    mutating func backtrack(to level: Int) {
        let kept = self.assignments.filter { $0.decisionLevel <= level }
        self.assignments = []
        self.accumulated = [:]
        self.decisions = [:]
        self.positiveOrder = []

        // Replay the kept prefix; decisions are restored from their singleton terms.
        for assignment in kept {
            if case .decision = assignment.kind, let index = assignment.term.versions.lowestIndex {
                self.decisions[assignment.term.package] = index
            }
            self.record(assignment)
        }
    }

    // MARK: Queries

    func relation(to term: Term) -> TermRelation {
        guard let current = self.accumulated[term.package] else {
            return .inconclusive
        }
        return current.relation(to: term)
    }

    func satisfies(_ term: Term) -> Bool {
        self.relation(to: term) == .satisfied
    }

    /// Index of the earliest assignment after which `term` is satisfied.
    func satisfierIndex(for term: Term) -> Int? {
        var running: Term?
        for (index, assignment) in self.assignments.enumerated() where assignment.term.package == term.package {
            let combined = running.map { $0.intersection(assignment.term) } ?? assignment.term
            running = combined
            if combined.satisfies(term) {
                return index
            }
        }
        return nil
    }

    /// Packages with a positive derivation but no decision yet.
    var undecided: [Term] {
        self.positiveOrder.compactMap { package in
            guard self.decisions[package] == nil, let term = self.accumulated[package], term.polarity == .positive else {
                return nil
            }
            return term
        }
    }
}
