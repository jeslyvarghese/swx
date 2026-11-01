import Foundation
import SwxManifest
@testable import SwxWorkspace
import Testing

/// Every app gets an explicit, shared scheme that builds the app target. Without it, a package
/// named like its app makes `xcodebuild -scheme <App>` pick the package's own scheme, which
/// builds only the package's libraries and leaves the app stale.
struct XcodeAppSchemeTests {
    @Test func eachAppGetsASchemeBuildingItsTarget() {
        let schemes = XcodeProjectGenerator.schemes(for: ["Lift", "Tools"])
        let lift = schemes[XcodeProjectGenerator.schemeName(for: "Lift")] as? [String: Any]
        let build = lift?["build"] as? [String: Any]

        #expect(build?["targets"] as? [String: String] == ["Lift": "all"])
        #expect(schemes.count == 2)
    }

    @Test func theSpecCarriesTheSchemes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("swx-schemes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Sources/App"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let manifest = Manifest(
            name: "Lift",
            toolsVersion: "6.2.0",
            dependencies: [],
            targets: [Manifest.Target(name: "App", kind: .executable, dependencies: [], pluginUsages: [])],
            products: [Manifest.Product(name: "Lift", targets: ["App"], kind: .application, application: .init(
                bundleIdentifier: "app.lift", teamIdentifier: nil, displayVersion: "1.0", bundleVersion: "1",
                deviceFamilies: ["phone"], interfaceOrientations: ["portrait"]
            ))],
            traits: []
        )

        let spec = try XcodeProjectGenerator.spec(for: manifest, packageDirectory: directory, deploymentTarget: "17.0")
        let schemes = try #require(spec["schemes"] as? [String: Any])
        #expect(schemes.keys.sorted() == ["Lift"])
    }
}
