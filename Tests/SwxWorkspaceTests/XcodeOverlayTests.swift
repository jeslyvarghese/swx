import Foundation
import SwxManifest
@testable import SwxWorkspace
import Testing

struct XcodeOverlayTests {
    /// An app with a shared model library, a widget target and a watch target.
    private let manifest = Manifest(
        name: "Lift",
        toolsVersion: "6.0.0",
        dependencies: [],
        targets: [
            Manifest.Target(name: "Model", dependencies: [], pluginUsages: []),
            Manifest.Target(name: "AppKitOnly", dependencies: [], pluginUsages: []),
            Manifest.Target(name: "LiftApp", kind: .executable, dependencies: [.target(name: "Model", condition: nil), .target(name: "AppKitOnly", condition: nil)], pluginUsages: []),
            Manifest.Target(name: "LiftWidget", dependencies: [.target(name: "Model", condition: nil)], pluginUsages: []),
            Manifest.Target(name: "LiftWatch", dependencies: [.target(name: "Model", condition: nil)], pluginUsages: []),
        ],
        products: [Manifest.Product(name: "Lift", targets: ["LiftApp"], kind: .application, application: .init(
            bundleIdentifier: "app.lift.ios", teamIdentifier: "TEAM42", displayVersion: "1.0", bundleVersion: "3",
            deviceFamilies: ["phone"], interfaceOrientations: ["portrait"]
        ))],
        traits: []
    )

    private let overlayJSON = """
    {
      "applications": {
        "Lift": {
          "entitlements": { "com.apple.developer.healthkit": true, "com.apple.security.application-groups": ["group.app.lift"] },
          "infoPlist": { "NSSupportsLiveActivities": true, "NSHealthShareUsageDescription": "Reads HRV." }
        }
      },
      "targets": {
        "Widget": { "kind": "widgetExtension", "sources": ["LiftWidget"], "bundleIdentifier": "app.lift.ios.Widget", "embedIn": "Lift",
                    "entitlements": { "com.apple.security.application-groups": ["group.app.lift"] } },
        "Watch": { "kind": "watchApp", "sources": ["LiftWatch"], "bundleIdentifier": "app.lift.ios.watchkitapp", "embedIn": "Lift", "deploymentTarget": "11.0" }
      }
    }
    """

    private func packageDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("swx-overlay-\(UUID().uuidString)")
        for target in self.manifest.targets.map(\.name) {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("Sources/\(target)"), withIntermediateDirectories: true)
        }
        return directory
    }

    private func parse(_ json: String) throws -> XcodeOverlay {
        try XcodeOverlay.parse(Data(json.utf8), manifest: self.manifest)
    }

    // MARK: Spec

    @Test func noOverlayLeavesTheSpecUnchanged() throws {
        let directory = try self.packageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let plain = try XcodeProjectGenerator.spec(for: self.manifest, packageDirectory: directory, deploymentTarget: "17.0")
        let none = try XcodeProjectGenerator.spec(for: self.manifest, packageDirectory: directory, deploymentTarget: "17.0", overlay: .none)
        let encode = { (spec: [String: Any]) in try JSONSerialization.data(withJSONObject: spec, options: [.sortedKeys]) }
        #expect(try encode(plain) == encode(none))

        let targets = try #require(plain["targets"] as? [String: [String: Any]])
        #expect(Set(targets.keys) == ["Lift", "Model", "AppKitOnly"])
        #expect(targets["Model"]?["platform"] as? String == "iOS")
        #expect(targets["Lift"]?["entitlements"] == nil)
        #expect((plain["options"] as? [String: [String: String]])?["deploymentTarget"] == ["iOS": "17.0"])
    }

    @Test func overlayAddsEntitlementsExtensionAndWatchApp() throws {
        let directory = try self.packageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let overlay = try self.parse(self.overlayJSON)
        let spec = try XcodeProjectGenerator.spec(for: self.manifest, packageDirectory: directory, deploymentTarget: "17.0", overlay: overlay)
        let targets = try #require(spec["targets"] as? [String: [String: Any]])

        // The app: entitlements and Info.plist written next to the project, both overlay targets embedded.
        let app = try #require(targets["Lift"])
        let entitlements = try #require(app["entitlements"] as? [String: Any])
        #expect(entitlements["path"] as? String == "XcodeSupport/Lift.entitlements")
        let entitlementValues = try #require(entitlements["properties"] as? [String: Any])
        #expect(entitlementValues["com.apple.developer.healthkit"] as? Bool == true)
        #expect(entitlementValues["com.apple.security.application-groups"] as? [String] == ["group.app.lift"])
        let info = try #require(app["info"] as? [String: Any])
        #expect(info["path"] as? String == "XcodeSupport/Lift-Info.plist")
        #expect((info["properties"] as? [String: Any])?["NSSupportsLiveActivities"] as? Bool == true)

        let dependencies = try #require(app["dependencies"] as? [[String: Any]])
        let widgetEmbed = try #require(dependencies.first { $0["target"] as? String == "Widget" })
        #expect(widgetEmbed["embed"] as? Bool == true)
        #expect(widgetEmbed["copy"] == nil)
        let watchEmbed = try #require(dependencies.first { $0["target"] as? String == "Watch" })
        #expect(watchEmbed["copy"] as? [String: String] == ["destination": "productsDirectory", "subpath": "$(CONTENTS_FOLDER_PATH)/Watch"])

        // The widget: an app extension with WidgetKit's extension point and the app's versions.
        let widget = try #require(targets["Widget"])
        #expect(widget["type"] as? String == "app-extension")
        #expect(widget["platform"] as? String == "iOS")
        #expect((widget["sources"] as? [[String: String]])?.map { $0["path"] } == ["Sources/LiftWidget"])
        #expect(widget["dependencies"] as? [[String: String]] == [["target": "Model"]])
        let widgetSettings = try #require((widget["settings"] as? [String: Any])?["base"] as? [String: String])
        #expect(widgetSettings["PRODUCT_BUNDLE_IDENTIFIER"] == "app.lift.ios.Widget")
        #expect(widgetSettings["MARKETING_VERSION"] == "1.0")
        #expect(widgetSettings["CURRENT_PROJECT_VERSION"] == "3")
        #expect(widgetSettings["DEVELOPMENT_TEAM"] == "TEAM42")
        let widgetInfo = try #require((widget["info"] as? [String: Any])?["properties"] as? [String: Any])
        #expect(widgetInfo["NSExtension"] as? [String: String] == ["NSExtensionPointIdentifier": "com.apple.widgetkit-extension"])
        #expect((widget["entitlements"] as? [String: Any])?["path"] as? String == "XcodeSupport/Widget.entitlements")

        // The watch app: a watchOS application paired with the iOS app.
        let watch = try #require(targets["Watch"])
        #expect(watch["type"] as? String == "application")
        #expect(watch["platform"] as? String == "watchOS")
        #expect(watch["deploymentTarget"] as? String == "11.0")
        let watchSettings = try #require((watch["settings"] as? [String: Any])?["base"] as? [String: String])
        #expect(watchSettings["INFOPLIST_KEY_WKCompanionAppBundleIdentifier"] == "app.lift.ios")
        #expect(((watch["info"] as? [String: Any])?["properties"] as? [String: Any])?["WKApplication"] as? Bool == true)

        // Libraries shared with the watch build for both platforms; iOS-only ones stay iOS.
        let model = try #require(targets["Model"])
        #expect(model["platform"] as? String == "auto")
        #expect(model["supportedDestinations"] as? [String] == ["iOS", "watchOS"])
        #expect(targets["AppKitOnly"]?["platform"] as? String == "iOS")
        #expect(targets["LiftWidget"] == nil)
        #expect(targets["LiftWatch"] == nil)

        #expect((spec["options"] as? [String: [String: String]])?["deploymentTarget"] == ["iOS": "17.0", "watchOS": "11.0"])
    }

    // MARK: Parsing errors

    private func expectError(_ json: String, mentioning fragment: String) {
        do {
            _ = try self.parse(json)
            Issue.record("expected an error mentioning \(fragment)")
        } catch let error as WorkspaceError {
            #expect(error.code == .invalidXcodeOverlay)
            #expect(error.description.contains("swx-xcode.json"))
            #expect(error.description.contains(fragment), "\(error.description)")
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    private func target(_ body: String) -> String {
        "{ \"targets\": { \"Widget\": { \(body) } } }"
    }

    private let validTarget = #""kind": "widgetExtension", "sources": ["LiftWidget"], "bundleIdentifier": "app.lift.ios.Widget", "embedIn": "Lift""#

    @Test func rejectsInvalidJSON() {
        self.expectError("{ nope", mentioning: "not valid JSON")
    }

    @Test func rejectsUnknownKeys() {
        self.expectError(#"{ "target": {} }"#, mentioning: "unknown key(s) target")
        self.expectError(self.target(self.validTarget + #", "entitlement": {}"#), mentioning: "targets.Widget has unknown key(s) entitlement")
    }

    @Test func rejectsUnknownApplications() {
        self.expectError(#"{ "applications": { "Nope": {} } }"#, mentioning: "applications.Nope names no .iOSApplication")
    }

    @Test func rejectsUnknownKinds() {
        self.expectError(self.target(#""kind": "clip", "sources": ["LiftWidget"], "bundleIdentifier": "app.lift.ios.Widget", "embedIn": "Lift""#), mentioning: "targets.Widget.kind 'clip' is not a known kind")
    }

    @Test func rejectsUnknownOrMissingSources() {
        self.expectError(self.target(#""kind": "widgetExtension", "sources": ["Nope"], "bundleIdentifier": "app.lift.ios.Widget", "embedIn": "Lift""#), mentioning: "'Nope' is not a target")
        self.expectError(self.target(#""kind": "widgetExtension", "sources": [], "bundleIdentifier": "app.lift.ios.Widget", "embedIn": "Lift""#), mentioning: "needs at least one")
        self.expectError(self.target(#""kind": "widgetExtension", "sources": ["LiftApp"], "bundleIdentifier": "app.lift.ios.Widget", "embedIn": "Lift""#), mentioning: "already the app's own target")
    }

    @Test func rejectsUnknownEmbeddingApps() {
        self.expectError(self.target(#""kind": "widgetExtension", "sources": ["LiftWidget"], "bundleIdentifier": "app.lift.ios.Widget", "embedIn": "Nope""#), mentioning: "targets.Widget.embedIn 'Nope'")
    }

    @Test func rejectsTargetNamesTakenByThePackage() {
        self.expectError(#"{ "targets": { "Model": { "kind": "widgetExtension", "sources": ["LiftWidget"], "bundleIdentifier": "app.lift.ios.W", "embedIn": "Lift" } } }"#, mentioning: "targets.Model is already the name")
    }

    @Test func rejectsDuplicateOrForeignBundleIdentifiers() {
        self.expectError(self.target(#""kind": "widgetExtension", "sources": ["LiftWidget"], "bundleIdentifier": "app.lift.ios", "embedIn": "Lift""#), mentioning: "already the bundle identifier of Lift")
        self.expectError(self.target(#""kind": "widgetExtension", "sources": ["LiftWidget"], "bundleIdentifier": "com.other.Widget", "embedIn": "Lift""#), mentioning: "must start with 'app.lift.ios.'")
        self.expectError("""
        { "targets": {
          "A": { "kind": "widgetExtension", "sources": ["LiftWidget"], "bundleIdentifier": "app.lift.ios.Same", "embedIn": "Lift" },
          "B": { "kind": "widgetExtension", "sources": ["LiftWatch"], "bundleIdentifier": "app.lift.ios.Same", "embedIn": "Lift" } } }
        """, mentioning: "already the bundle identifier of A")
    }

    @Test func rejectsASecondWatchApp() {
        self.expectError("""
        { "targets": {
          "A": { "kind": "watchApp", "sources": ["LiftWidget"], "bundleIdentifier": "app.lift.ios.a", "embedIn": "Lift" },
          "B": { "kind": "watchApp", "sources": ["LiftWatch"], "bundleIdentifier": "app.lift.ios.b", "embedIn": "Lift" } } }
        """, mentioning: "already embeds a watch app")
    }

    @Test func rejectsMalformedDeploymentTargets() {
        self.expectError(self.target(self.validTarget + #", "deploymentTarget": "eleven""#), mentioning: "'eleven' is not a version")
    }

    @Test func rejectsNullPlistValues() {
        self.expectError(#"{ "applications": { "Lift": { "entitlements": { "x": null } } } }"#, mentioning: "applications.Lift.entitlements.x null")
    }

    @Test func parsesPlistValueTypes() throws {
        let overlay = try self.parse(#"{ "applications": { "Lift": { "infoPlist": { "b": false, "i": 3, "r": 1.5, "s": "x", "a": [1], "d": { "k": "v" } } } } }"#)
        let info = try #require(overlay.applications["Lift"]?.infoPlist)
        #expect(info["b"] == .bool(false))
        #expect(info["i"] == .integer(3))
        #expect(info["r"] == .real(1.5))
        #expect(info["s"] == .string("x"))
        #expect(info["a"] == .array([.integer(1)]))
        #expect(info["d"] == .dictionary(["k": .string("v")]))
    }
}
