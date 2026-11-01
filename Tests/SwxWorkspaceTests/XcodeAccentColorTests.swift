import Foundation
import SwxManifest
@testable import SwxWorkspace
import Testing

/// `.iOSApplication(accentColor:)` reaches the generated project: a preset becomes a generated
/// `AccentColor` color set referencing the system color; an asset name is used as is.
struct XcodeAccentColorTests {
    private func manifest(accent: Manifest.Product.ApplicationSettings.AccentColor?) -> Manifest {
        Manifest(
            name: "Lift",
            toolsVersion: "6.2.0",
            dependencies: [],
            targets: [Manifest.Target(name: "App", kind: .executable, dependencies: [], pluginUsages: [])],
            products: [Manifest.Product(name: "Lift", targets: ["App"], kind: .application, application: .init(
                bundleIdentifier: "app.lift", teamIdentifier: nil, displayVersion: "1.0", bundleVersion: "1",
                deviceFamilies: ["phone"], interfaceOrientations: ["portrait"], accentColor: accent
            ))],
            traits: []
        )
    }

    private func appTarget(accent: Manifest.Product.ApplicationSettings.AccentColor?) throws -> [String: Any] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("swx-accent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Sources/App"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let spec = try XcodeProjectGenerator.spec(for: self.manifest(accent: accent), packageDirectory: directory, deploymentTarget: "17.0")
        return try #require((spec["targets"] as? [String: Any])?["Lift"] as? [String: Any])
    }

    private func settings(_ target: [String: Any]) -> [String: String] {
        (target["settings"] as? [String: Any])?["base"] as? [String: String] ?? [:]
    }

    @Test func presetBecomesAGeneratedCatalog() throws {
        let target = try self.appTarget(accent: .preset("orange"))
        #expect(self.settings(target)["ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME"] == "AccentColor")
        // No catalog of the app's own: no AppIcon for Xcode's default icon name to find.
        #expect(self.settings(target)["ASSETCATALOG_COMPILER_APPICON_NAME"] == "")

        let sources = target["sources"] as? [[String: String]] ?? []
        #expect(sources.contains(["path": "XcodeSupport/Lift.xcassets"]))

        let files = try XcodeProjectGenerator.supportFiles(for: self.manifest(accent: .preset("orange")))
        let colorSet = try #require(files["XcodeSupport/Lift.xcassets/AccentColor.colorset/Contents.json"])
        #expect(String(decoding: colorSet, as: UTF8.self).contains("systemOrangeColor"))
        #expect(files["XcodeSupport/Lift.xcassets/Contents.json"] != nil)
    }

    @Test func assetNameIsUsedAsIs() throws {
        let target = try self.appTarget(accent: .asset("Brand"))
        #expect(self.settings(target)["ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME"] == "Brand")
        #expect(try XcodeProjectGenerator.supportFiles(for: self.manifest(accent: .asset("Brand"))).isEmpty)
    }

    @Test func noAccentNoCatalog() throws {
        let target = try self.appTarget(accent: nil)
        #expect(self.settings(target)["ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME"] == nil)
        #expect(try XcodeProjectGenerator.supportFiles(for: self.manifest(accent: nil)).isEmpty)
    }
}
