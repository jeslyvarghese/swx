import Foundation
import SwxCore
import SwxWorkspace
import Testing

/// A `Package.resolved` written by SwiftPM 6.4, used to check byte-for-byte compatibility.
private let swiftPMResolvedFile = """
{
  "originHash" : "5e3be737f494d0fe019b49cfa29c7fda5ae0ed70a0d268429b881846a8457637",
  "pins" : [
    {
      "identity" : "swift-argument-parser",
      "kind" : "remoteSourceControl",
      "location" : "https://github.com/apple/swift-argument-parser",
      "state" : {
        "revision" : "6a52f3251125d74daf04fcbd5e6f08a75d074382",
        "version" : "1.8.2"
      }
    },
    {
      "identity" : "swift-nio",
      "kind" : "remoteSourceControl",
      "location" : "https://github.com/apple/swift-nio.git",
      "state" : {
        "revision" : "6db9d9abd92ad7399b8a564cafbb87d3507245fa",
        "version" : "2.104.0"
      }
    }
  ],
  "version" : 3
}

"""

/// The matching `workspace-state.json` (SwiftPM writes no trailing newline here).
private let swiftPMWorkspaceState = """
{
  "object" : {
    "artifacts" : [

    ],
    "dependencies" : [
      {
        "basedOn" : null,
        "packageRef" : {
          "identity" : "swift-argument-parser",
          "kind" : "remoteSourceControl",
          "location" : "https://github.com/apple/swift-argument-parser",
          "name" : "swift-argument-parser"
        },
        "state" : {
          "checkoutState" : {
            "revision" : "6a52f3251125d74daf04fcbd5e6f08a75d074382",
            "version" : "1.8.2"
          },
          "name" : "sourceControlCheckout"
        },
        "subpath" : "swift-argument-parser"
      }
    ],
    "prebuilts" : [

    ]
  },
  "version" : 7
}
"""

/// SwiftPM 6.4's lockfile for an app on a registry (`mona.Graph` → `mona.LinkedList`) plus git.
private let swiftPMRegistryResolvedFile = """
{
  "pins" : [
    {
      "identity" : "mona.Graph",
      "kind" : "registry",
      "location" : "",
      "state" : {
        "version" : "1.0.0"
      }
    },
    {
      "identity" : "mona.LinkedList",
      "kind" : "registry",
      "location" : "",
      "state" : {
        "version" : "1.1.0"
      }
    },
    {
      "identity" : "swift-argument-parser",
      "kind" : "remoteSourceControl",
      "location" : "https://github.com/apple/swift-argument-parser",
      "state" : {
        "revision" : "6a52f3251125d74daf04fcbd5e6f08a75d074382",
        "version" : "1.8.2"
      }
    }
  ],
  "version" : 2
}

"""

/// The matching workspace state entry for a registry download.
private let swiftPMRegistryWorkspaceState = """
{
  "object" : {
    "artifacts" : [

    ],
    "dependencies" : [
      {
        "basedOn" : null,
        "packageRef" : {
          "identity" : "mona.Graph",
          "kind" : "registry",
          "location" : "mona.Graph",
          "name" : "mona.Graph"
        },
        "state" : {
          "name" : "registryDownload",
          "version" : "1.0.0"
        },
        "subpath" : "mona/Graph/1.0.0"
      }
    ],
    "prebuilts" : [

    ]
  },
  "version" : 7
}
"""

struct RegistryPinTests {
    @Test func roundTripsRegistryPinsByteForByte() throws {
        let original = Data(swiftPMRegistryResolvedFile.utf8)
        let decoded = try ResolvedFile.decode(original)

        let graph = try #require(decoded.pins[PackageIdentity(plain: "mona.graph")])
        #expect(graph.state == .registryVersion(Version(1, 0, 0)))
        #expect(graph.package.kind == .registry(identity: "mona.Graph"))
        #expect(try decoded.encode(format: .v2) == original)
    }

    @Test func roundTripsRegistryDownloadsByteForByte() throws {
        let original = Data(swiftPMRegistryWorkspaceState.utf8)
        let decoded = try #require(WorkspaceState.decodeIfCompatible(original))

        let graph = try #require(decoded.dependencies[PackageIdentity(plain: "mona.Graph")])
        #expect(graph.state == .registryDownload(Version(1, 0, 0)))
        #expect(graph.subpath == "mona/Graph/1.0.0")
        #expect(try decoded.encode() == original)
    }
}

struct ResolvedFileTests {
    @Test func roundTripsSwiftPMOutputByteForByte() throws {
        let original = Data(swiftPMResolvedFile.utf8)
        let decoded = try ResolvedFile.decode(original)

        #expect(decoded.pins.count == 2)
        #expect(decoded.originHash == "5e3be737f494d0fe019b49cfa29c7fda5ae0ed70a0d268429b881846a8457637")
        #expect(try decoded.encode(format: .v3) == original)
    }

    @Test func picksFormatFromToolsVersion() {
        #expect(ResolvedFile.FormatVersion.forTools(ToolsVersion(6, 0)) == .v3)
        #expect(ResolvedFile.FormatVersion.forTools(ToolsVersion(5, 9)) == .v2)
        #expect(ResolvedFile.FormatVersion.forTools(ToolsVersion(5, 6)) == .v2)
        #expect(ResolvedFile.FormatVersion.forTools(ToolsVersion(5, 5)) == .v1)
    }

    @Test func writesV2WithoutOriginHash() throws {
        let decoded = try ResolvedFile.decode(Data(swiftPMResolvedFile.utf8))
        let text = String(decoding: try decoded.encode(format: .v2), as: UTF8.self)
        #expect(!text.contains("originHash"))
        #expect(text.contains("\"version\" : 2"))
    }

    @Test func readsLegacyV1() throws {
        let legacy = """
        {"object": {"pins": [{"package": "Nimble", "repositoryURL": "https://github.com/Quick/Nimble.git",
          "state": {"branch": null, "revision": "abc", "version": "9.0.0"}}]}, "version": 1}
        """
        let decoded = try ResolvedFile.decode(Data(legacy.utf8))
        #expect(decoded.pins[PackageIdentity(plain: "nimble")]?.state == .version(Version(9, 0, 0), revision: "abc"))
    }
}

struct WorkspaceStateTests {
    /// SwiftPM 6.4's state after `swift package edit swift-argument-parser`.
    @Test func preservesEditedDependenciesByteForByte() throws {
        let url = try #require(Bundle.module.url(forResource: "workspace-state-edited", withExtension: "json", subdirectory: "Fixtures"))
        let original = try Data(contentsOf: url)
        let decoded = try #require(WorkspaceState.decodeIfCompatible(original))

        #expect(decoded.editedDependencies[PackageIdentity(plain: "swift-argument-parser")] == EditedDependency(subpath: "swift-argument-parser", path: nil))
        #expect(decoded.dependencies[PackageIdentity(plain: "swift-argument-parser")] == nil)
        #expect(decoded.dependencies.count == 4)
        #expect(try decoded.encode() == original)
    }

    @Test func roundTripsSwiftPMOutputByteForByte() throws {
        let original = Data(swiftPMWorkspaceState.utf8)
        let decoded = try #require(WorkspaceState.decodeIfCompatible(original))
        #expect(decoded.dependencies.count == 1)
        #expect(try decoded.encode() == original)
    }
}
