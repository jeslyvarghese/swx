import SwxCore
import SwxResolver
import Testing

/// An in-memory package index for driving the solver without I/O.
private struct Index {
    /// `package → version → dependencies`
    var packages: [String: [String: [(String, VersionRequirement)]]] = [:]

    mutating func add(_ package: String, _ version: String, _ dependencies: [(String, VersionRequirement)] = []) {
        self.packages[package, default: [:]][version] = dependencies
    }

    static func reference(_ name: String) -> PackageReference {
        .remote("https://example.com/\(name).git")
    }

    /// Runs the sans-I/O loop to completion, counting round trips.
    func solve(
        root dependencies: [(String, VersionRequirement)],
        preferred: [String: String] = [:]
    ) -> (result: Result<[String: String], ResolutionFailure>, roundTrips: Int) {
        var solver = Solver(
            root: PackageReference(identity: PackageIdentity(plain: "root"), kind: .root(path: "/root")),
            rootDependencies: dependencies.map { DependencyDeclaration(package: Self.reference($0.0), requirement: .version($0.1)) },
            preferred: Dictionary(uniqueKeysWithValues: preferred.map { (PackageIdentity(plain: $0.key), Version($0.value)!) })
        )
        var roundTrips = 0

        while true {
            switch solver.resume() {
            case .solved(let bindings):
                let result = Dictionary(uniqueKeysWithValues: bindings.map { ($0.package.identity.description, $0.version.description) })
                return (.success(result), roundTrips)
            case .failed(let failure):
                return (.failure(failure), roundTrips)
            case .needs(let required, let prefetch):
                roundTrips += 1
                for request in required + prefetch {
                    self.fulfil(request, into: &solver)
                }
            }
        }
    }

    private func fulfil(_ request: SolverRequest, into solver: inout Solver) {
        switch request {
        case .versions(let package):
            let versions = self.packages[package.identity.description, default: [:]].keys.compactMap { Version($0) }
            solver.provideVersions(versions, for: package.identity)
        case .dependencies(let package, let version):
            let dependencies = self.packages[package.identity.description]?[version.description] ?? []
            let declarations = dependencies.map { DependencyDeclaration(package: Self.reference($0.0), requirement: .version($0.1)) }
            solver.provideDependencies(.available(declarations), for: package.identity, at: version)
        }
    }
}

private func upToNextMajor(_ text: String) -> VersionRequirement {
    let version = Version(text)!
    return .range(VersionRange(version, Version(version.major + 1, 0, 0)))
}

private func range(_ lower: String, _ upper: String) -> VersionRequirement {
    .range(VersionRange(Version(lower)!, Version(upper)!))
}

struct SolverTests {
    @Test func picksNewestCompatibleVersions() throws {
        var index = Index()
        index.add("a", "1.0.0")
        index.add("a", "1.1.0")
        index.add("a", "2.0.0")
        index.add("b", "1.0.0", [("c", upToNextMajor("1.0.0"))])
        index.add("c", "1.0.0")
        index.add("c", "1.4.2")

        let solution = try index.solve(root: [("a", upToNextMajor("1.0.0")), ("b", upToNextMajor("1.0.0"))]).result.get()
        #expect(solution == ["a": "1.1.0", "b": "1.0.0", "c": "1.4.2"])
    }

    @Test func prefersPinnedVersions() throws {
        var index = Index()
        index.add("a", "1.0.0")
        index.add("a", "1.5.0")

        let solution = try index.solve(root: [("a", upToNextMajor("1.0.0"))], preferred: ["a": "1.0.0"]).result.get()
        #expect(solution == ["a": "1.0.0"])
    }

    @Test func ignoresPinsOutsideTheRequirement() throws {
        var index = Index()
        index.add("a", "1.0.0")
        index.add("a", "2.0.0")

        let solution = try index.solve(root: [("a", upToNextMajor("2.0.0"))], preferred: ["a": "1.0.0"]).result.get()
        #expect(solution == ["a": "2.0.0"])
    }

    /// The classic PubGrub conflict-resolution example: backtracking over a shared dependency.
    @Test func backtracksAfterConflict() throws {
        var index = Index()
        index.add("foo", "1.0.0", [("shared", range("2.0.0", "3.0.0"))])
        index.add("foo", "1.1.0", [("shared", range("3.0.0", "4.0.0"))])
        index.add("bar", "1.0.0", [("shared", range("2.0.0", "3.0.0"))])
        index.add("shared", "2.0.0")
        index.add("shared", "3.0.0")

        let solution = try index.solve(root: [("foo", upToNextMajor("1.0.0")), ("bar", upToNextMajor("1.0.0"))]).result.get()
        #expect(solution == ["foo": "1.0.0", "bar": "1.0.0", "shared": "2.0.0"])
    }

    /// pub's "conflict resolution with a partial satisfier".
    @Test func resolvesWithPartialSatisfier() throws {
        var index = Index()
        index.add("foo", "1.0.0")
        index.add("foo", "1.1.0", [("left", upToNextMajor("1.0.0")), ("right", upToNextMajor("1.0.0"))])
        index.add("left", "1.0.0", [("shared", range("1.0.0", "99.0.0"))])
        index.add("right", "1.0.0", [("shared", range("0.0.0", "1.0.0"))])
        index.add("shared", "1.0.0", [("target", upToNextMajor("1.0.0"))])
        index.add("shared", "0.9.0")
        index.add("target", "1.0.0")
        index.add("target", "2.0.0")

        let solution = try index.solve(root: [("foo", upToNextMajor("1.0.0")), ("target", upToNextMajor("2.0.0"))]).result.get()
        #expect(solution == ["foo": "1.0.0", "target": "2.0.0"])
    }

    @Test func reportsUnsatisfiableConstraints() {
        var index = Index()
        index.add("a", "1.0.0", [("c", upToNextMajor("1.0.0"))])
        index.add("b", "1.0.0", [("c", upToNextMajor("2.0.0"))])
        index.add("c", "1.0.0")
        index.add("c", "2.0.0")

        let (result, _) = index.solve(root: [("a", upToNextMajor("1.0.0")), ("b", upToNextMajor("1.0.0"))])
        guard case .failure(let failure) = result else {
            Issue.record("expected a resolution failure")
            return
        }
        #expect(failure.description.contains("'c'"))
        #expect(failure.description.contains("could not be resolved"))
    }

    @Test func failsWhenNoVersionMatches() {
        var index = Index()
        index.add("a", "1.0.0")

        let (result, _) = index.solve(root: [("a", upToNextMajor("3.0.0"))])
        guard case .failure(let failure) = result else {
            Issue.record("expected a resolution failure")
            return
        }
        #expect(failure.description.contains("depends on 'a' 3.0.0..<4.0.0 (no matching versions)"), "\(failure.description)")
    }

    @Test func skipsUnavailableVersions() throws {
        var solver = Solver(
            root: PackageReference(identity: PackageIdentity(plain: "root"), kind: .root(path: "/root")),
            rootDependencies: [DependencyDeclaration(package: Index.reference("a"), requirement: .version(upToNextMajor("1.0.0")))]
        )
        let newest = Version(1, 1, 0)

        // 1.1.0's manifest needs a newer toolchain: the solver must fall back to 1.0.0.
        while true {
            switch solver.resume() {
            case .solved(let bindings):
                #expect(bindings.map(\.version) == [Version(1, 0, 0)])
                return
            case .failed(let failure):
                Issue.record("unexpected failure: \(failure)")
                return
            case .needs(let required, _):
                for request in required {
                    switch request {
                    case .versions(let package):
                        solver.provideVersions([Version(1, 0, 0), newest], for: package.identity)
                    case .dependencies(let package, let version):
                        let facts: DependencyFacts = version == newest ? .unavailable(reason: "tools version 9.0") : .available([])
                        solver.provideDependencies(facts, for: package.identity, at: version)
                    }
                }
            }
        }
    }

    @Test func batchesPrefetchRequests() {
        var index = Index()
        for name in ["a", "b", "c", "d"] {
            index.add(name, "1.0.0")
        }
        let roots = ["a", "b", "c", "d"].map { ($0, upToNextMajor("1.0.0")) }

        // One round trip for all version lists, one for the first manifest plus prefetch of the rest.
        let (result, roundTrips) = index.solve(root: roots)
        #expect((try? result.get())?.count == 4)
        #expect(roundTrips <= 3)
    }
}
