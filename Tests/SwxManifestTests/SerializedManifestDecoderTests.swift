import Foundation
import SwxCore
@testable import SwxManifest
import Testing

/// Excerpts of what a compiled manifest serializes (PackageDescription 6.4), as captured from a probe.
private let serialized = #"""
{"errors": [], "package": {
  "name": "Probe",
  "dependencies": [
    {"kind": {"sourceControl": {"location": "https://github.com/apple/swift-nio", "requirement": {"exact": {"_0": {"buildMetadataIdentifiers": [], "major": 2, "minor": 60, "patch": 0, "prereleaseIdentifiers": []}}}}}, "traits": [{"name": "default"}]},
    {"kind": {"sourceControl": {"location": "https://github.com/apple/swift-atomics", "name": "Named", "requirement": {"range": {"lowerBound": {"buildMetadataIdentifiers": [], "major": 1, "minor": 0, "patch": 0, "prereleaseIdentifiers": []}, "upperBound": {"buildMetadataIdentifiers": [], "major": 2, "minor": 0, "patch": 0, "prereleaseIdentifiers": []}}}}}, "traits": [{"name": "default"}]},
    {"kind": {"fileSystem": {"path": "../Local"}}, "traits": [{"name": "default"}]},
    {"kind": {"registry": {"id": "mona.LinkedList", "requirement": {"branch": {"_0": "main"}}}}, "traits": [{"name": "X"}, {"condition": {"traits": ["A"]}, "name": "Y"}, {"name": "default"}]},
    {"kind": {"sourceControl": {"location": "file:///repos/kit.git", "requirement": {"range": {"lowerBound": {"buildMetadataIdentifiers": [], "major": 1, "minor": 0, "patch": 0, "prereleaseIdentifiers": ["beta", "1"]}, "upperBound": {"buildMetadataIdentifiers": [], "major": 2, "minor": 0, "patch": 0, "prereleaseIdentifiers": []}}}}}}
  ],
  "targets": [
    {"name": "Lib", "type": {"regular": {}}, "dependencies": [
      {"byName": {"name": "ByName"}},
      {"target": {"condition": {"platforms": [{"name": "linux"}]}, "name": "T2"}},
      {"product": {"condition": {"traits": ["B"]}, "name": "ArgumentParser", "package": "swift-argument-parser"}}
    ], "pluginUsages": [{"plugin": {"name": "P2", "package": "pkg"}}]},
    {"name": "Bin", "type": {"binary": {}}, "dependencies": [], "url": "https://example.com/a.zip", "checksum": "abc"}
  ],
  "products": [
    {"name": "Lib", "productType": {"library": {"type": {"automatic": {}}}}, "targets": ["Lib"]},
    {"name": "HelloApp", "productType": {"executable": {}}, "targets": ["HelloApp"], "settings": [{"iOSAppInfo": {"_0": {}}}]}
  ],
  "traits": [{"enabledTraits": ["A"], "name": "default"}, {"enabledTraits": [], "name": "A"}]
}}
"""#

struct SerializedManifestDecoderTests {
    private func decode() throws -> Manifest {
        try SerializedManifestDecoder.decode(Data(serialized.utf8), packageDirectory: URL(fileURLWithPath: "/work/Probe"), toolsVersion: ToolsVersion(6, 1))
    }

    /// Locations, identities and requirements come out as `dump-package` prints them.
    @Test func normalizesDependenciesLikeDumpPackage() throws {
        let dependencies = try self.decode().dependencies
        #expect(dependencies[0].identity == "swift-nio")
        #expect(dependencies[0].requirement == .exact("2.60.0"))
        #expect(dependencies[1].explicitName == "Named")
        #expect(dependencies[1].requirement == .range(lowerBound: "1.0.0", upperBound: "2.0.0"))
        #expect(dependencies[2].location == .local(path: "/work/Local"))
        #expect(dependencies[2].identity == "local")
        #expect(dependencies[3].location == .registry(identity: "mona.LinkedList"))
        #expect(dependencies[3].traits == ["X", "Y", "default"])
        #expect(dependencies[4].location == .localSourceControl(path: "/repos/kit.git"))
        #expect(dependencies[4].requirement == .range(lowerBound: "1.0.0-beta.1", upperBound: "2.0.0"))
        #expect(dependencies[4].traits == [Manifest.defaultTrait])
    }

    @Test func readsTargetsAndProducts() throws {
        let manifest = try self.decode()
        #expect(manifest.toolsVersion == "6.1.0")
        #expect(manifest.targets[0].dependencies == [
            .byName(name: "ByName", condition: nil),
            .target(name: "T2", condition: Manifest.Condition(traits: nil)),
            .product(name: "ArgumentParser", package: "swift-argument-parser", condition: Manifest.Condition(traits: ["B"])),
        ])
        #expect(manifest.targets[0].pluginUsages == [Manifest.PluginUsage(name: "P2", package: "pkg")])
        #expect(manifest.targets[1].binaryLocation == .remote(url: "https://example.com/a.zip", checksum: "abc"))

        // AppleProductTypes apps serialize as executables with an `iOSAppInfo` setting.
        #expect(manifest.products.map(\.kind) == [.library, .application])
        #expect(manifest.traits.map(\.name) == ["A", "default"])
    }

    @Test func detectsManifestsNeedingXcode() {
        #expect(XcodeManifestEvaluator.isNeeded(for: "import PackageDescription\nimport AppleProductTypes\n"))
        #expect(XcodeManifestEvaluator.isNeeded(for: "@preconcurrency import AppleProductTypes"))
        #expect(!XcodeManifestEvaluator.isNeeded(for: "import PackageDescription\n// import AppleProductTypes is not needed\n"))
    }
}
