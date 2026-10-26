@testable import SwxGraph
import SwxManifest
import Testing

// MARK: - Fixtures

private func dependency(_ url: String, traits: [String] = [Manifest.defaultTrait]) -> Manifest.Dependency {
    let name = url.split(separator: "/").last.map(String.init) ?? url
    return Manifest.Dependency(identity: name.lowercased(), explicitName: nil, location: .remote(url: url), requirement: .range(lowerBound: "1.0.0", upperBound: "2.0.0"), traits: traits)
}

private func manifest(
    _ name: String,
    dependencies: [Manifest.Dependency] = [],
    targets: [Manifest.Target] = [],
    products: [Manifest.Product] = [],
    traits: [Manifest.Trait] = []
) -> Manifest {
    Manifest(name: name, toolsVersion: "6.0.0", dependencies: dependencies, targets: targets, products: products, traits: traits)
}

private func package(_ identity: String, _ manifest: Manifest, version: String? = "1.0.0", role: GraphPackage.Role = .dependency) -> GraphPackage {
    let location = role == .root ? "/work/\(identity)" : "https://example.com/\(identity)"
    let path = role == .root ? "/work/\(identity)" : "/work/app/.build/checkouts/\(identity)"
    return GraphPackage(identity: identity, manifest: manifest, location: location, version: role == .root ? nil : version, path: path, role: role)
}

/// A library product `name` built from one target that uses `uses` products of `packages`.
private func library(_ name: String, uses products: [(String, String)] = [], traitGated: [(String, String, String)] = []) -> (Manifest.Target, Manifest.Product) {
    var dependencies = products.map { Manifest.TargetDependency.product(name: $0.0, package: $0.1, condition: nil) }
    dependencies += traitGated.map { .product(name: $0.0, package: $0.1, condition: Manifest.Condition(traits: [$0.2])) }
    return (Manifest.Target(name: name, dependencies: dependencies, pluginUsages: []), Manifest.Product(name: name, targets: [name]))
}

/// app → a → (b, c); app → b. `c` declares traits whose default enables none.
private func sampleGraph() -> PackageGraph {
    let (aTarget, aProduct) = library("A", uses: [("B", "b"), ("C", "c")])
    let (bTarget, bProduct) = library("B")
    let (cTarget, cProduct) = library("C")
    let app = manifest(
        "App",
        dependencies: [dependency("https://example.com/a"), dependency("https://example.com/b")],
        targets: [
            Manifest.Target(name: "App", kind: .executable, dependencies: [.product(name: "A", package: "a", condition: nil), .byName(name: "B", condition: nil)], pluginUsages: []),
            Manifest.Target(name: "AppTests", kind: .test, dependencies: [.target(name: "App", condition: nil)], pluginUsages: []),
        ]
    )
    return PackageGraphBuilder.build(
        root: package("app", app, role: .root),
        dependencies: [
            package("a", manifest("A", dependencies: [dependency("https://example.com/b"), dependency("https://example.com/c")], targets: [aTarget], products: [aProduct])),
            package("b", manifest("B", targets: [bTarget], products: [bProduct]), version: "2.1.0"),
            package("c", manifest("C", targets: [cTarget], products: [cProduct], traits: [Manifest.Trait(name: "default", enabledTraits: []), Manifest.Trait(name: "Fast", enabledTraits: [])])),
        ],
        identify: { $0.identity }
    )
}

// MARK: - Package graph

struct PackageGraphTests {
    @Test func walksRequiredDependenciesInManifestOrder() {
        let graph = sampleGraph()
        #expect(graph.dependencies["app"] == ["a", "b"])
        #expect(graph.dependencies["a"] == ["b", "c"])
        #expect(graph.reachablePackages.map(\.identity) == ["app", "a", "b", "c"])
    }

    /// No traits declared: `default`. Traits declared but none enabled: nothing.
    @Test func reportsTraitsLikeSwiftPM() {
        let graph = sampleGraph()
        #expect(graph.enabledTraits["b"] == ["default"])
        #expect(graph.enabledTraits["c"] == [])
    }

    @Test func unionsTraitRequestsAcrossParents() {
        let traits = [
            Manifest.Trait(name: "default", enabledTraits: ["Base"]),
            Manifest.Trait(name: "Base", enabledTraits: []),
            Manifest.Trait(name: "TLS", enabledTraits: ["Crypto"]),
            Manifest.Trait(name: "Crypto", enabledTraits: []),
        ]
        let (cTarget, cProduct) = library("C")
        let c = package("c", manifest("C", targets: [cTarget], products: [cProduct], traits: traits))
        let (aTarget, aProduct) = library("A", uses: [("C", "c")])
        let (bTarget, bProduct) = library("B", uses: [("C", "c")])

        // One parent asks for TLS, another for the defaults: both apply, transitively.
        let graph = PackageGraphBuilder.build(
            root: package("app", manifest("App", dependencies: [dependency("https://example.com/a"), dependency("https://example.com/b")]), role: .root),
            dependencies: [
                package("a", manifest("A", dependencies: [dependency("https://example.com/c", traits: ["TLS"])], targets: [aTarget], products: [aProduct])),
                package("b", manifest("B", dependencies: [dependency("https://example.com/c")], targets: [bTarget], products: [bProduct])),
                c,
            ],
            identify: { $0.identity }
        )
        #expect(graph.enabledTraits["c"] == ["Base", "Crypto", "TLS"])

        // `traits: []` alone switches the defaults off.
        #expect(PackageGraphBuilder.enabledTraits(of: c, request: .init(explicit: [], defaults: false, disabled: true)) == [])
        #expect(PackageGraphBuilder.enabledTraits(of: c, request: .init()) == ["Base"])
    }

    /// A dependency used only behind a disabled trait is not an edge.
    @Test func dropsDependenciesBehindDisabledTraits() {
        let (aTarget, aProduct) = library("A", traitGated: [("B", "b", "Extra")])
        let (bTarget, bProduct) = library("B")
        let a = manifest("A", dependencies: [dependency("https://example.com/b")], targets: [aTarget], products: [aProduct], traits: [Manifest.Trait(name: "Extra", enabledTraits: [])])
        let graph = PackageGraphBuilder.build(
            root: package("app", manifest("App", dependencies: [dependency("https://example.com/a")]), role: .root),
            dependencies: [package("a", a), package("b", manifest("B", targets: [bTarget], products: [bProduct]))],
            identify: { $0.identity }
        )
        #expect(graph.dependencies["a"] == [])
    }
}

// MARK: - show-dependencies

struct ShowDependenciesTests {
    @Test func printsSwiftPMText() {
        #expect(sampleGraph().showDependencies(.text) == """
        .
        ├── a<https://example.com/a@1.0.0>(traits: default)
        │   ├── b<https://example.com/b@2.1.0>(traits: default)
        │   └── c<https://example.com/c@1.0.0>
        └── b<https://example.com/b@2.1.0>(traits: default)

        """)
    }

    @Test func printsSwiftPMFlatList() {
        #expect(sampleGraph().showDependencies(.flatlist) == "a\nb\nc\nb\n")
    }

    /// Nodes and edges once each, in walk order.
    @Test func printsSwiftPMDot() {
        #expect(sampleGraph().showDependencies(.dot) == #"""
        digraph DependenciesGraph {
        node [shape = box]
        "/work/app" [label="app\n/work/app\nunspecified"]
        "https://example.com/a" [label="a\nhttps://example.com/a\n1.0.0"]
        "/work/app" -> "https://example.com/a"
        "https://example.com/b" [label="b\nhttps://example.com/b\n2.1.0"]
        "https://example.com/a" -> "https://example.com/b"
        "https://example.com/c" [label="c\nhttps://example.com/c\n1.0.0"]
        "https://example.com/a" -> "https://example.com/c"
        "/work/app" -> "https://example.com/b"
        }

        """#)
    }

    /// TSCBasic's layout: empty arrays keep a blank line, and the output ends with two newlines.
    @Test func printsSwiftPMJSON() {
        let leaf = PackageGraphBuilder.build(root: package("leaf", manifest("Leaf"), role: .root), dependencies: [], identify: { $0.identity })
        #expect(leaf.showDependencies(.json) == """
        {
          "identity": "leaf",
          "name": "Leaf",
          "url": "/work/leaf",
          "version": "unspecified",
          "path": "/work/leaf",
          "traits": [
            "default"
          ],
          "dependencies": [

          ]
        }


        """)
    }

    @Test func reportsNoDependencies() {
        let leaf = PackageGraphBuilder.build(root: package("leaf", manifest("Leaf"), role: .root), dependencies: [], identify: { $0.identity })
        #expect(leaf.showDependencies(.text) == "No external dependencies found\n")
        #expect(leaf.showDependencies(.dot) == "No external dependencies found\n")
        #expect(leaf.showDependencies(.flatlist) == "")
    }

    @Test func escapesJSONStringsLikeTSCBasic() {
        #expect(TSCJSON.string("a\"b\\c/d\u{1}é").prettyPrinted() == #""a\"b\\c/d\u0001é""#)
        #expect(TSCJSON.string("\u{1B}").prettyPrinted() == #""\u001B""#)
    }
}

// MARK: - Target graph

struct TargetGraphTests {
    private func display(_ external: ExternalNodes = .products, tests: TestTargets = .include, focus: [String] = []) throws -> DisplayGraph {
        try DisplayGraph.build(sampleGraph(), request: GraphRequest(level: .target, format: .text, focus: focus, external: external, tests: tests))
    }

    /// `.byName` finds products of dependencies; `.product(package:)` goes through the declaration.
    @Test func resolvesTargetAndProductReferences() throws {
        let graph = try self.display()
        #expect(graph.entries == ["app/target/App", "app/target/AppTests"])
        #expect(graph.edges.map { "\($0.from) -> \($0.to)" } == [
            "app/target/App -> a/product/A",
            "app/target/App -> b/product/B",
            "app/target/AppTests -> app/target/App",
        ])
        #expect(graph.packages.map(\.identity) == ["app", "a", "b"])
    }

    @Test func expandsProductsIntoTargets() throws {
        let graph = try self.display(.targets)
        #expect(graph.edges.map { "\($0.from) -> \($0.to)" }.contains("a/target/A -> c/product/C"))
        #expect(graph.nodes.map(\.id).contains("c/target/C"))
    }

    @Test func skipsTestsAndExternalNodes() throws {
        let graph = try self.display(.skip, tests: .skip)
        #expect(graph.nodes.map(\.id) == ["app/target/App"])
        #expect(graph.edges.isEmpty)
    }

    @Test func focusesOnWhatANodeReaches() throws {
        let graph = try self.display(.targets, focus: ["A"])
        #expect(graph.entries == ["a/product/A"])
        #expect(!graph.nodes.contains { $0.package == "app" })
        #expect(throws: GraphError.self) { try self.display(focus: ["Missing"]) }
    }

    @Test func rendersATextTree() throws {
        #expect(try self.display().render(.text) == """
        App (executable)
        ├── A · a 1.0.0 (library product)
        └── B · b 2.1.0 (library product)
        AppTests (test)
        └── App (executable) (*)

        """)
    }

    @Test func rendersMermaidWithPackagesAsSubgraphs() throws {
        #expect(try self.display(tests: .skip).render(.mermaid) == """
        flowchart LR
            subgraph p0["App"]
                n0["App"]
            end
            subgraph p1["a 1.0.0"]
                n1(["A"])
            end
            subgraph p2["b 2.1.0"]
                n2(["B"])
            end
            n0 --> n1
            n0 --> n2

        """)
    }

    @Test func labelsConditionsAndPlugins() {
        let edge = DisplayGraph.Edge(from: "x", to: "y", kind: .dependency, platforms: ["linux", "macos"], traits: ["TLS"])
        #expect(DisplayGraph.conditionText(edge) == "linux, macos, trait: TLS")
    }

    @Test func packageLevelMatchesShowDependencies() {
        let graph = DisplayGraph.packageLevel(sampleGraph())
        #expect(graph.nodes.map(\.id) == ["app", "a", "b", "c"])
        #expect(graph.edges.count == 4)
    }
}
