import SwxCore
@testable import SwxManifest
import Testing

private func dependency(_ name: String) -> Manifest.Dependency {
    Manifest.Dependency(
        identity: name,
        explicitName: nil,
        location: .remote(url: "https://example.com/\(name).git"),
        requirement: .range(lowerBound: "1.0.0", upperBound: "2.0.0"),
        traits: [Manifest.defaultTrait]
    )
}

private func manifest(toolsVersion: String = "5.9.0", traits: [Manifest.Trait] = []) -> Manifest {
    Manifest(
        name: "lib",
        toolsVersion: toolsVersion,
        dependencies: [dependency("used"), dependency("test-only"), dependency("plugin-pkg"), dependency("guarded")],
        targets: [
            Manifest.Target(
                name: "Lib",
                dependencies: [
                    .product(name: "Used", package: "used", condition: nil),
                    .target(name: "Internal", condition: nil),
                    .product(name: "Guarded", package: "guarded", condition: Manifest.Condition(traits: ["Extra"])),
                ],
                pluginUsages: []
            ),
            Manifest.Target(name: "Internal", dependencies: [], pluginUsages: [Manifest.PluginUsage(name: "Gen", package: "plugin-pkg")]),
            Manifest.Target(name: "LibTests", dependencies: [.product(name: "TestKit", package: "test-only", condition: nil)], pluginUsages: []),
        ],
        products: [Manifest.Product(name: "Lib", targets: ["Lib"])],
        traits: traits
    )
}

struct DependencyPruningTests {
    @Test func dependencyRoleKeepsOnlyProductReachableDependencies() {
        let required = manifest().requiredDependencies(role: .dependency).map(\.identity)
        #expect(Set(required) == ["used", "plugin-pkg", "guarded"])
    }

    @Test func rootKeepsEverything() {
        let required = manifest().requiredDependencies(role: .root).map(\.identity)
        #expect(Set(required) == ["used", "test-only", "plugin-pkg", "guarded"])
    }

    @Test func preFiveTwoManifestsAreNotPruned() {
        let required = manifest(toolsVersion: "5.1.0").requiredDependencies(role: .dependency).map(\.identity)
        #expect(required.count == 4)
    }

    @Test func traitGuardedDependenciesAreDroppedWhenTraitIsOff() {
        let traits = [Manifest.Trait(name: "default", enabledTraits: []), Manifest.Trait(name: "Extra", enabledTraits: [])]
        let required = manifest(traits: traits).requiredDependencies(role: .dependency).map(\.identity)
        #expect(!required.contains("guarded"))
    }

    @Test func defaultTraitExpansionEnablesGuardedDependencies() {
        let traits = [Manifest.Trait(name: "default", enabledTraits: ["Extra"]), Manifest.Trait(name: "Extra", enabledTraits: [])]
        let required = manifest(traits: traits).requiredDependencies(role: .dependency).map(\.identity)
        #expect(required.contains("guarded"))
    }
}
