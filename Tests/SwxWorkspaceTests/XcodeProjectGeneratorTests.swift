import Foundation
import SwxManifest
@testable import SwxWorkspace
import Testing

struct XcodeProjectGeneratorTests {
    private let manifest = Manifest(
        name: "Hello",
        toolsVersion: "5.9.0",
        dependencies: [
            Manifest.Dependency(identity: "swift-argument-parser", explicitName: nil, location: .remote(url: "https://github.com/apple/swift-argument-parser"),
                                requirement: .range(lowerBound: "1.3.0", upperBound: "2.0.0"), traits: ["default"]),
            Manifest.Dependency(identity: "swift-log", explicitName: nil, location: .remote(url: "https://github.com/apple/swift-log"),
                                requirement: .range(lowerBound: "1.0.0", upperBound: "1.5.0"), traits: ["default"]),
        ],
        targets: [
            Manifest.Target(name: "Core", dependencies: [.product(name: "Logging", package: "swift-log", condition: nil)], pluginUsages: []),
            Manifest.Target(name: "Hello", kind: .executable, dependencies: [
                .target(name: "Core", condition: nil),
                .product(name: "ArgumentParser", package: "swift-argument-parser", condition: nil),
            ], pluginUsages: []),
        ],
        products: [Manifest.Product(name: "Hello", targets: ["Hello"], kind: .application, application: .init(
            bundleIdentifier: "com.example.hello", teamIdentifier: "TEAM42", displayVersion: "1.2", bundleVersion: "7",
            deviceFamilies: ["pad", "phone"], interfaceOrientations: ["portrait", "landscapeLeft"]
        ))],
        traits: []
    )

    /// An app target with its internal targets' sources and the external products they use.
    @Test func mapsApplicationProductsToXcodeGen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("swx-generate-\(UUID().uuidString)")
        for target in ["Core", "Hello"] {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("Sources/\(target)"), withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: directory) }

        let spec = try XcodeProjectGenerator.spec(for: self.manifest, packageDirectory: directory, deploymentTarget: "17.0")
        let targets = try #require(spec["targets"] as? [String: [String: Any]])
        let app = try #require(targets["Hello"])
        #expect(app["type"] as? String == "application")
        #expect((app["sources"] as? [[String: String]])?.map { $0["path"] } == ["Sources/Hello"])
        #expect((app["dependencies"] as? [[String: String]]) == [["package": "swift-argument-parser", "product": "ArgumentParser"], ["target": "Core"]])

        // Internal targets become static libraries with their own package products.
        let core = try #require(targets["Core"])
        #expect(core["type"] as? String == "library.static")
        #expect((core["dependencies"] as? [[String: String]]) == [["package": "swift-log", "product": "Logging"]])

        let settings = try #require((app["settings"] as? [String: Any])?["base"] as? [String: String])
        #expect(settings["PRODUCT_BUNDLE_IDENTIFIER"] == "com.example.hello")
        #expect(settings["DEVELOPMENT_TEAM"] == "TEAM42")
        #expect(settings["TARGETED_DEVICE_FAMILY"] == "2,1")
        #expect(settings["INFOPLIST_KEY_UISupportedInterfaceOrientations"] == "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft")

        // `from:` ranges stay `from`; other ranges become min/max.
        let packages = try #require(spec["packages"] as? [String: [String: String]])
        #expect(packages["swift-argument-parser"] == ["url": "https://github.com/apple/swift-argument-parser", "from": "1.3.0"])
        #expect(packages["swift-log"] == ["url": "https://github.com/apple/swift-log", "minVersion": "1.0.0", "maxVersion": "1.5.0"])
    }

    @Test func refusesPackagesWithoutApps() {
        var library = self.manifest
        library.products = [Manifest.Product(name: "Core", targets: ["Core"])]
        #expect(throws: WorkspaceError.self) {
            _ = try XcodeProjectGenerator.spec(for: library, packageDirectory: URL(fileURLWithPath: "/tmp"), deploymentTarget: "17.0")
        }
    }
}
