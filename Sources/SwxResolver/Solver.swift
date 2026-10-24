import SwxCore

/// What the solver needs from the outside world before it can continue.
public enum SolverRequest: Sendable, Hashable {
    /// The list of versions (tags) of a package.
    case versions(PackageReference)
    /// The pruned dependency declarations of `package@version`.
    case dependencies(PackageReference, Version)
}

/// The dependencies of one package version, as loaded by the shell.
public enum DependencyFacts: Sendable, Hashable {
    case available([DependencyDeclaration])
    /// The version can't be used: its manifest failed to load, or requires a newer toolchain.
    case unavailable(reason: String)
}

/// A package chosen by resolution.
public struct ResolvedBinding: Sendable, Hashable {
    public let package: PackageReference
    public let version: Version
}

/// One step of the sans-I/O solver loop.
public enum SolverStep: Sendable {
    /// Fulfil `required` (and ideally `prefetch`, in parallel), feed the results back, then `resume()`.
    case needs(required: [SolverRequest], prefetch: [SolverRequest])
    case solved([ResolvedBinding])
    case failed(ResolutionFailure)
}

public struct ResolutionFailure: Error, Sendable, CustomStringConvertible {
    public let description: String
}

/// PubGrub version solving as a pure state machine.
///
/// The solver never performs I/O. When it needs facts it doesn't have, `resume()` returns
/// `.needs`; the shell fetches them (concurrently), calls `provide`, and resumes. Because a
/// decision is only committed once all of its facts are known, resuming is idempotent.
public struct Solver: Sendable {
    private static let prefetchLimit = 8
    private static let rootVersion = Version.zero

    private let root: PackageReference
    private let rootDependencies: [DependencyDeclaration]
    private let preferred: [PackageIdentity: Version]
    private let overridden: Set<PackageIdentity>

    // Facts provided by the shell.
    private var domains: [PackageIdentity: [Version]] = [:]
    private var facts: [PackageIdentity: [Version: DependencyFacts]] = [:]
    private var references: [PackageIdentity: PackageReference] = [:]

    // PubGrub state.
    private var incompatibilities: [Incompatibility] = []
    private var incompatibilitiesByPackage: [PackageIdentity: [IncompatibilityID]] = [:]
    private var solution = PartialSolution()
    private var pendingPropagation: PackageIdentity?
    private var isStarted = false

    /// - Parameters:
    ///   - root: The root package (resolved at a single synthetic version).
    ///   - rootDependencies: Dependencies of the root, including those contributed by overrides.
    ///   - preferred: Pinned versions to prefer when they still satisfy the constraints.
    ///   - overridden: Packages fixed outside version solving (branch, revision, or path at the root).
    public init(
        root: PackageReference,
        rootDependencies: [DependencyDeclaration],
        preferred: [PackageIdentity: Version] = [:],
        overridden: Set<PackageIdentity> = []
    ) {
        self.root = root
        self.rootDependencies = rootDependencies
        self.preferred = preferred
        self.overridden = overridden
        self.references[root.identity] = root
        self.domains[root.identity] = [Self.rootVersion]
        self.facts[root.identity] = [Self.rootVersion: .available(rootDependencies)]
    }

    // MARK: Feeding facts

    public mutating func provideVersions(_ versions: [Version], for package: PackageIdentity) {
        // Domains are fixed once known: sets built over them must stay comparable.
        guard self.domains[package] == nil else { return }
        self.domains[package] = Array(Set(versions)).sorted()
    }

    public mutating func provideDependencies(_ facts: DependencyFacts, for package: PackageIdentity, at version: Version) {
        self.facts[package, default: [:]][version] = facts
    }

    public func hasVersions(for package: PackageIdentity) -> Bool {
        self.domains[package] != nil
    }

    public func hasDependencies(for package: PackageIdentity, at version: Version) -> Bool {
        self.facts[package]?[version] != nil
    }

    // MARK: Main loop

    public mutating func resume() -> SolverStep {
        // Seed: the root must be selected.
        if !self.isStarted {
            self.isStarted = true
            let rootTerm = Term(self.root.identity, .negative, VersionSet(full: 1))
            self.add(Incompatibility(terms: [rootTerm], cause: .root))
            self.pendingPropagation = self.root.identity
        }

        while true {
            // Propagate whatever changed since the last decision.
            if let package = self.pendingPropagation {
                self.pendingPropagation = nil
                if let failure = self.propagate(from: package) {
                    return .failed(self.report(failure))
                }
            }

            // Choose the next decision; this is the only place the solver can block on facts.
            switch self.decide() {
            case .done:
                return .solved(self.bindings())
            case .needs(let required, let prefetch):
                return .needs(required: required, prefetch: prefetch)
            case .propagate(let package):
                self.pendingPropagation = package
            }
        }
    }

    // MARK: Unit propagation

    /// Returns the failing incompatibility if resolution is impossible.
    private mutating func propagate(from start: PackageIdentity) -> IncompatibilityID? {
        var changed: [PackageIdentity] = [start]

        while let package = changed.popLast() {
            // Newest incompatibilities first: they tend to be the most specific.
            let candidates = self.incompatibilitiesByPackage[package, default: []].reversed()

            for id in candidates {
                switch self.propagationResult(for: id) {
                case .none:
                    continue

                case .almostSatisfied(let term):
                    // The only undecided term must be false.
                    self.solution.derive(term.inverse, cause: id)
                    changed.append(term.package)
                    continue

                case .satisfied:
                    // A conflict: learn a root cause and backjump.
                    guard let rootCause = self.resolveConflict(id) else {
                        return self.lastFailure
                    }

                    // After backjumping the learned incompatibility is almost satisfied: derive from it.
                    changed = []
                    if case .almostSatisfied(let term) = self.propagationResult(for: rootCause) {
                        self.solution.derive(term.inverse, cause: rootCause)
                        changed = [term.package]
                    }
                }

                // The partial solution was rewound; restart from the derived package.
                break
            }
        }
        return nil
    }

    private enum PropagationResult {
        case none
        case satisfied
        case almostSatisfied(Term)
    }

    private func propagationResult(for id: IncompatibilityID) -> PropagationResult {
        var unsatisfied: Term?

        for term in self.incompatibilities[id].terms {
            switch self.solution.relation(to: term) {
            case .contradicted:
                return .none
            case .satisfied:
                continue
            case .inconclusive:
                // Two unknowns: nothing can be derived yet.
                guard unsatisfied == nil else { return .none }
                unsatisfied = term
            }
        }

        guard let unsatisfied else {
            return .satisfied
        }
        return .almostSatisfied(unsatisfied)
    }

    // MARK: Conflict resolution

    private var lastFailure: IncompatibilityID?

    /// PubGrub's conflict resolution. Returns the learned incompatibility, or `nil` on total failure.
    private mutating func resolveConflict(_ conflict: IncompatibilityID) -> IncompatibilityID? {
        var current = self.incompatibilities[conflict]
        var currentID = conflict

        while !self.isFailure(current) {
            // Find the term whose satisfier came last, and the level we can backjump to.
            var mostRecentTerm: Term?
            var mostRecentIndex = -1
            var difference: Term?
            var previousLevel = 1

            for term in current.terms {
                guard let index = self.solution.satisfierIndex(for: term) else { continue }

                if index > mostRecentIndex {
                    if mostRecentIndex >= 0 {
                        previousLevel = max(previousLevel, self.solution.assignments[mostRecentIndex].decisionLevel)
                    }
                    mostRecentTerm = term
                    mostRecentIndex = index
                    difference = nil
                } else {
                    previousLevel = max(previousLevel, self.solution.assignments[index].decisionLevel)
                }

                // If the satisfier is broader than the term, earlier assignments must cover the rest.
                if mostRecentTerm == term {
                    difference = self.solution.assignments[mostRecentIndex].term.difference(term)
                    if let difference, let differenceIndex = self.solution.satisfierIndex(for: difference.inverse) {
                        previousLevel = max(previousLevel, self.solution.assignments[differenceIndex].decisionLevel)
                    }
                }
            }

            guard let mostRecentTerm, mostRecentIndex >= 0 else {
                break
            }
            let satisfier = self.solution.assignments[mostRecentIndex]

            // Backjump when the satisfier is a decision or sits above every other term's level.
            let causeID: IncompatibilityID
            switch satisfier.kind {
            case .decision:
                return self.backjump(to: previousLevel, learning: currentID)
            case .derivation(let cause):
                if previousLevel < satisfier.decisionLevel {
                    return self.backjump(to: previousLevel, learning: currentID)
                }
                causeID = cause
            }

            // Otherwise resolve with the satisfier's cause and keep going.
            let cause = self.incompatibilities[causeID]
            var terms = current.terms.filter { $0 != mostRecentTerm }
            terms += cause.terms.filter { $0.package != satisfier.term.package }
            if let difference {
                terms.append(difference.inverse)
            }
            current = Incompatibility(terms: terms, cause: .conflict(currentID, causeID))

            // Intermediate derivations are kept for error reports but not used for propagation.
            currentID = self.add(current, indexing: .recordOnly)
        }

        self.lastFailure = currentID
        return nil
    }

    private func isFailure(_ incompatibility: Incompatibility) -> Bool {
        if incompatibility.terms.isEmpty {
            return true
        }
        guard incompatibility.terms.count == 1, let only = incompatibility.terms.first else {
            return false
        }
        return only.package == self.root.identity && only.polarity == .positive
    }

    // MARK: Decision making

    private enum DecisionOutcome {
        case done
        case needs([SolverRequest], [SolverRequest])
        case propagate(PackageIdentity)
    }

    private mutating func decide() -> DecisionOutcome {
        let undecided = self.solution.undecided
        guard !undecided.isEmpty else {
            return .done
        }

        // SwiftPM's heuristic: release-only terms first, then the fewest matching versions.
        let term = undecided.min { lhs, rhs in
            let lhsPrerelease = self.allowsPrerelease(lhs)
            let rhsPrerelease = self.allowsPrerelease(rhs)
            if lhsPrerelease != rhsPrerelease {
                return !lhsPrerelease
            }
            return lhs.versions.cardinality < rhs.versions.cardinality
        }!
        let package = term.package

        // Pick the preferred (pinned) version if allowed, else the highest.
        guard let index = self.bestIndex(for: term) else {
            self.add(Incompatibility(terms: [term], cause: .noVersions))
            return .propagate(package)
        }
        let version = self.domains[package]![index]

        // We need this version's dependencies before deciding it.
        guard let facts = self.facts[package]?[version] else {
            let request = SolverRequest.dependencies(self.references[package]!, version)
            return .needs([request], self.prefetchRequests(excluding: package, undecided: undecided))
        }

        // An unusable version is ruled out and solving continues.
        let declarations: [DependencyDeclaration]
        switch facts {
        case .unavailable(let reason):
            self.forbid(package, index: index, reason: reason)
            return .propagate(package)
        case .available(let available):
            declarations = available.filter { !self.overridden.contains($0.package.identity) && $0.package.identity != package }
        }

        // Unversioned dependencies of a versioned package make that version unusable.
        if package != self.root.identity, let unversioned = declarations.first(where: { $0.requirement.isUnversioned }) {
            self.forbid(package, index: index, reason: "depends on '\(unversioned.package.identity)' with an unversioned requirement (\(unversioned.requirement))")
            return .propagate(package)
        }

        // Every dependency's version list must be known to express its constraint.
        for declaration in declarations where self.references[declaration.package.identity] == nil {
            self.references[declaration.package.identity] = declaration.package
        }
        let missing = declarations
            .filter { self.domains[$0.package.identity] == nil }
            .map { SolverRequest.versions(self.references[$0.package.identity]!) }
        guard missing.isEmpty else {
            return .needs(Array(Set(missing)), [])
        }

        // Add one incompatibility per dependency; decide unless one is already violated.
        let decisionTerm = Term(package, .positive, VersionSet(count: self.domains[package]!.count, indices: [index]))
        var hasConflict = false
        for declaration in declarations {
            guard case .version(let requirement) = declaration.requirement else { continue }
            let dependencyTerm = Term(declaration.package.identity, .negative, self.versionSet(for: declaration.package.identity, matching: requirement))
            let cause = IncompatibilityCause.dependency(requirement: requirement.description)
            let id = self.add(Incompatibility(terms: [decisionTerm, dependencyTerm], cause: cause))
            hasConflict = hasConflict || self.incompatibilities[id].terms.allSatisfy { $0.package == package || self.solution.satisfies($0) }
        }
        if !hasConflict {
            self.solution.decide(package, index: index, domainSize: self.domains[package]!.count)
        }
        return .propagate(package)
    }

    private func bestIndex(for term: Term) -> Int? {
        let versions = self.domains[term.package]!
        if let preferred = self.preferred[term.package],
           let preferredIndex = versions.firstIndex(of: preferred),
           term.versions.contains(preferredIndex) {
            return preferredIndex
        }
        return term.versions.highestIndex
    }

    private func allowsPrerelease(_ term: Term) -> Bool {
        let versions = self.domains[term.package]!
        return term.versions.ascendingIndices.contains { versions[$0].hasPrerelease }
    }

    private mutating func forbid(_ package: PackageIdentity, index: Int, reason: String) {
        let term = Term(package, .positive, VersionSet(count: self.domains[package]!.count, indices: [index]))
        self.add(Incompatibility(terms: [term], cause: .unavailable(reason: reason)))
    }

    /// Speculative fetches: the best candidate of every other undecided package.
    private func prefetchRequests(excluding package: PackageIdentity, undecided: [Term]) -> [SolverRequest] {
        var requests: [SolverRequest] = []
        for term in undecided where term.package != package {
            guard requests.count < Self.prefetchLimit else { break }
            guard let index = self.bestIndex(for: term) else { continue }
            let version = self.domains[term.package]![index]
            guard self.facts[term.package]?[version] == nil else { continue }
            requests.append(.dependencies(self.references[term.package]!, version))
        }
        return requests
    }

    // MARK: Helpers

    func versionSet(for package: PackageIdentity, matching requirement: VersionRequirement) -> VersionSet {
        let versions = self.domains[package]!
        return VersionSet(count: versions.count, indices: versions.indices.filter { requirement.contains(versions[$0]) })
    }

    /// Whether a stored incompatibility takes part in unit propagation.
    private enum Indexing {
        case propagate
        case recordOnly
    }

    @discardableResult
    private mutating func add(_ incompatibility: Incompatibility, indexing: Indexing = .propagate) -> IncompatibilityID {
        let id = self.incompatibilities.count
        self.incompatibilities.append(incompatibility)
        if indexing == .propagate {
            self.index(id)
        }
        return id
    }

    private mutating func index(_ id: IncompatibilityID) {
        for term in self.incompatibilities[id].terms where !self.incompatibilitiesByPackage[term.package, default: []].contains(id) {
            self.incompatibilitiesByPackage[term.package, default: []].append(id)
        }
    }

    /// Rewinds to `level` and makes the learned incompatibility available to propagation.
    private mutating func backjump(to level: Int, learning id: IncompatibilityID) -> IncompatibilityID {
        self.solution.backtrack(to: level)
        self.index(id)
        return id
    }

    private func bindings() -> [ResolvedBinding] {
        self.solution.decisions
            .filter { $0.key != self.root.identity }
            .map { ResolvedBinding(package: self.references[$0.key]!, version: self.domains[$0.key]![$0.value]) }
            .sorted { $0.package.identity < $1.package.identity }
    }

    // MARK: Failure reporting

    private func report(_ failure: IncompatibilityID) -> ResolutionFailure {
        var lines: [String] = []
        var explained: Set<IncompatibilityID> = []
        self.explain(failure, into: &lines, explained: &explained)
        return ResolutionFailure(description: lines.joined(separator: "\n"))
    }

    /// Walks the derivation graph, emitting external facts before the conclusions drawn from them.
    private func explain(_ id: IncompatibilityID, into lines: inout [String], explained: inout Set<IncompatibilityID>) {
        guard explained.insert(id).inserted else { return }
        let incompatibility = self.incompatibilities[id]

        guard case .conflict(let left, let right) = incompatibility.cause else {
            lines.append(self.describeExternal(incompatibility))
            return
        }
        self.explain(left, into: &lines, explained: &explained)
        self.explain(right, into: &lines, explained: &explained)
        lines.append("Therefore, \(self.describeConclusion(incompatibility)).")
    }

    private func describeExternal(_ incompatibility: Incompatibility) -> String {
        switch incompatibility.cause {
        case .root:
            return "\(self.root.identity) is the root package."
        case .noVersions:
            let term = incompatibility.terms[0]
            return "No versions of '\(term.package)' match \(self.describe(term.versions, of: term.package))."
        case .unavailable(let reason):
            let term = incompatibility.terms[0]
            return "'\(term.package)' \(self.describe(term.versions, of: term.package)) can't be used: \(reason)."
        case .dependency(let requirement):
            let depender = incompatibility.terms[0]
            let dependee = incompatibility.terms[1]
            let unmatched = dependee.versions.isEmpty ? " (no matching versions)" : ""
            return "'\(depender.package)' \(self.describe(depender.versions, of: depender.package)) depends on '\(dependee.package)' \(requirement)\(unmatched)."
        case .conflict:
            return self.describeConclusion(incompatibility)
        }
    }

    private func describeConclusion(_ incompatibility: Incompatibility) -> String {
        if self.isFailure(incompatibility) {
            return "dependencies could not be resolved"
        }
        let parts = incompatibility.terms.map { term -> String in
            let versions = self.describe(term.versions, of: term.package)
            switch term.polarity {
            case .positive:
                return "'\(term.package)' \(versions)"
            case .negative:
                return "not '\(term.package)' \(versions)"
            }
        }
        if parts.count == 1 {
            return "\(parts[0]) is forbidden"
        }
        return parts.joined(separator: " and ") + " are incompatible"
    }

    /// Renders a version set as contiguous runs: `1.0.0...1.4.2, 2.0.0`.
    private func describe(_ set: VersionSet, of package: PackageIdentity) -> String {
        guard package != self.root.identity else { return "(root)" }
        let versions = self.domains[package] ?? []
        guard !set.isEmpty else { return "(no versions)" }
        if set.cardinality == versions.count { return "(any version)" }

        var runs: [String] = []
        var runStart: Int?
        var previous: Int?
        for index in set.ascendingIndices {
            if let last = previous, index == last + 1 {
                previous = index
                continue
            }
            if let start = runStart, let last = previous {
                runs.append(start == last ? "\(versions[start])" : "\(versions[start])...\(versions[last])")
            }
            runStart = index
            previous = index
        }
        if let start = runStart, let last = previous {
            runs.append(start == last ? "\(versions[start])" : "\(versions[start])...\(versions[last])")
        }
        return runs.joined(separator: ", ")
    }
}
