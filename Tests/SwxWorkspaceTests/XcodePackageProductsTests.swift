import Foundation
import SwxManifest
@testable import SwxWorkspace
import Testing

/// Internal targets vended by the package's own library products link as those products
/// (full SwiftPM semantics in Xcode); the others are still translated into static libraries.
struct XcodePackageProductsTests {
    /// `App` imports `Store` (vended by a library product) and `Util` (not vended); `Store`
    /// depends on GRDB.
    private let manifest = Manifest(
        name: "Lift",
        toolsVersion: "6.2.0",
        dependencies: [
            Manifest.Dependency(identity: "grdb.swift", explicitName: nil, location: .remote(url: "https://github.com/groue/GRDB.swift"),
                                requirement: .range(lowerBound: "7.11.1", upperBound: "8.0.0"), traits: ["default"]),
        ],
        targets: [
            Manifest.Target(name: "Store", dependencies: [.product(name: "GRDB", package: "grdb.swift", condition: nil)], pluginUsages: []),
            Manifest.Target(name: "Util", dependencies: [.target(name: "Store", condition: nil)], pluginUsages: []),
            Manifest.Target(name: "App", kind: .executable, dependencies: [
                .target(name: "Store", condition: nil),
                .byName(name: "Util", condition: nil),
            ], pluginUsages: []),
        ],
        products: [
            Manifest.Product(name: "Lift", targets: ["App"], kind: .application, application: .init(
                bundleIdentifier: "app.lift", teamIdentifier: nil, displayVersion: "1.0", bundleVersion: "1",
                deviceFamilies: ["phone"], interfaceOrientations: ["portrait"]
            )),
            // The narrowest product wins: `Store` links through `Store`, not `Everything`.
            Manifest.Product(name: "Everything", targets: ["Store", "Util"]),
            Manifest.Product(name: "Store", targets: ["Store"]),
        ],
        traits: []
    )

    private func packageDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("swx-products-\(UUID().uuidString)")
        for target in ["App", "Store", "Util"] {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("Sources/\(target)"), withIntermediateDirectories: true)
        }
        return directory
    }

    @Test func productCoveredTargetsLinkAsLocalPackageProducts() throws {
        let directory = try self.packageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Without `Everything`, `Util` has no product and is translated as before.
        var manifest = self.manifest
        manifest.products.removeAll { $0.name == "Everything" }

        let spec = try XcodeProjectGenerator.spec(for: manifest, packageDirectory: directory, deploymentTarget: "17.0")
        let targets = try #require(spec["targets"] as? [String: [String: Any]])

        let app = try #require(targets["App"] ?? targets["Lift"])
        let dependencies = try #require(app["dependencies"] as? [[String: String]])
        #expect(dependencies.contains(["package": "Lift", "product": "Store"]))
        #expect(dependencies.contains(["target": "Util"]))
        #expect(targets["Store"] == nil)

        // The translated library links the product too, instead of a translated `Store`.
        let util = try #require(targets["Util"])
        #expect(util["type"] as? String == "library.static")
        #expect((util["dependencies"] as? [[String: String]]) == [["package": "Lift", "product": "Store"]])

        // The package references itself: relative to the project generated next to it.
        let packages = try #require(spec["packages"] as? [String: [String: String]])
        #expect(packages["Lift"] == ["path": "."])
        // GRDB is the product's business now: no translated target references it.
        #expect(packages.keys.sorted() == ["Lift"])
    }

    @Test func narrowestProductWinsAndAbsolutePathsForPrivateProjects() throws {
        let directory = try self.packageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let spec = try XcodeProjectGenerator.spec(for: self.manifest, packageDirectory: directory, deploymentTarget: "17.0", paths: .absolute)
        let targets = try #require(spec["targets"] as? [String: [String: Any]])
        let app = try #require(targets["Lift"])
        #expect((app["dependencies"] as? [[String: String]]) == [["package": "Lift", "product": "Store"], ["package": "Lift", "product": "Everything"]])
        #expect(targets.keys.sorted() == ["Lift"])

        let packages = try #require(spec["packages"] as? [String: [String: String]])
        #expect(packages["Lift"] == ["path": directory.standardizedFileURL.path])
    }

    @Test func withoutLibraryProductsEverythingIsTranslated() throws {
        let directory = try self.packageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        var manifest = self.manifest
        manifest.products.removeAll { $0.kind == .library }

        let spec = try XcodeProjectGenerator.spec(for: manifest, packageDirectory: directory, deploymentTarget: "17.0")
        let targets = try #require(spec["targets"] as? [String: [String: Any]])
        #expect(targets.keys.sorted() == ["Lift", "Store", "Util"])
        #expect((targets["Store"]?["dependencies"] as? [[String: String]])?.map { $0["product"] } == ["GRDB"])
        #expect((spec["packages"] as? [String: [String: String]])?["Lift"] == nil)
    }
}

/// The deployment targets of generated projects follow the package's `platforms:`.
struct PlatformMinimumsTests {
    @Test func readsStringAndEnumVersions() {
        let source = """
        // swift-tools-version: 6.2
        import PackageDescription
        let package = Package(
            name: "Lift",
            platforms: [.iOS("26.0"), .watchOS(.v10), .macOS(.v14_4)],
            targets: []
        )
        """
        #expect(PlatformMinimums.read(manifestSource: source) == PlatformMinimums(iOS: "26.0", watchOS: "10.0"))
    }

    @Test func minorVersionsAndMissingPlatforms() {
        #expect(PlatformMinimums.read(manifestSource: #"let package = Package(name: "A", platforms: [.iOS(.v17_4)])"#) == PlatformMinimums(iOS: "17.4", watchOS: nil))
        #expect(PlatformMinimums.read(manifestSource: #"let package = Package(name: "A")"#) == .none)
    }

    /// A computed list isn't guessed at.
    @Test func nonLiteralPlatformsYieldNothing() {
        #expect(PlatformMinimums.read(manifestSource: #"let p: [SupportedPlatform] = [.iOS(.v17)]; let package = Package(name: "A", platforms: p)"#) == .none)
    }

    @Test func explicitTargetWinsThenPackageThenDefault() {
        let minimums = PlatformMinimums(iOS: "26.0", watchOS: nil)
        #expect(XcodeProjectGenerator.iOSDeploymentTarget(explicit: "18.0", minimums: minimums) == "18.0")
        #expect(XcodeProjectGenerator.iOSDeploymentTarget(explicit: nil, minimums: minimums) == "26.0")
        #expect(XcodeProjectGenerator.iOSDeploymentTarget(explicit: nil, minimums: .none) == XcodeProjectGenerator.defaultDeploymentTarget)
    }

    @Test func watchAppsDefaultToThePackagesWatchMinimum() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("swx-watch-\(UUID().uuidString)")
        for target in ["App", "Watch"] {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("Sources/\(target)"), withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: directory) }

        let manifest = Manifest(
            name: "Lift",
            toolsVersion: "6.2.0",
            dependencies: [],
            targets: [
                Manifest.Target(name: "App", kind: .executable, dependencies: [], pluginUsages: []),
                Manifest.Target(name: "Watch", dependencies: [], pluginUsages: []),
            ],
            products: [Manifest.Product(name: "Lift", targets: ["App"], kind: .application, application: .init(
                bundleIdentifier: "app.lift", teamIdentifier: nil, displayVersion: "1.0", bundleVersion: "1",
                deviceFamilies: ["phone"], interfaceOrientations: ["portrait"]
            ))],
            traits: []
        )
        let overlay = try XcodeOverlay.parse(Data(#"{"targets": {"LiftWatch": {"kind": "watchApp", "sources": ["Watch"], "bundleIdentifier": "app.lift.watchkitapp", "embedIn": "Lift"}}}"#.utf8), manifest: manifest)

        let spec = try XcodeProjectGenerator.spec(for: manifest, packageDirectory: directory, deploymentTarget: "26.0", overlay: overlay, platforms: PlatformMinimums(iOS: "26.0", watchOS: "26.0"))
        #expect((spec["options"] as? [String: [String: String]])?["deploymentTarget"] == ["iOS": "26.0", "watchOS": "26.0"])
    }
}
