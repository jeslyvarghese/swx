import Foundation
import SwxCore
@testable import SwxSource
import Testing

struct NetrcTests {
    @Test func matchesTheLastEntryForAHost() {
        let netrc = Netrc(parsing: """
        machine registry.example.com login old password one
        machine other.example.com login x password y
        machine REGISTRY.example.com
            login new
            password two
        """)
        #expect(netrc.credential(forHost: "registry.example.com") == Credential(login: "new", password: "two"))
        #expect(netrc.credential(forHost: "other.example.com") == Credential(login: "x", password: "y"))
        #expect(netrc.credential(forHost: "unknown.example.com") == nil)
    }

    @Test func fallsBackToTheDefaultEntry() {
        let netrc = Netrc(parsing: "machine a.example.com login a password 1\ndefault login anyone password 2\n")
        #expect(netrc.credential(forHost: "b.example.com") == Credential(login: "anyone", password: "2"))
    }

    /// Macro bodies run to the next blank line and must not leak tokens.
    @Test func skipsMacroDefinitions() {
        let netrc = Netrc(parsing: """
        macdef init
        machine evil.example.com login evil password evil

        machine good.example.com login good password ok
        """)
        #expect(netrc.credential(forHost: "evil.example.com") == nil)
        #expect(netrc.credential(forHost: "good.example.com") == Credential(login: "good", password: "ok"))
    }
}

struct LinkHeaderTests {
    @Test func readsAlternateManifests() {
        let header = #"<http://r.example.com/mona/LinkedList/1.1.0/Package.swift?swift-version=5.8>; rel="alternate"; filename="Package@swift-5.8.swift"; swift-tools-version="5.8", <http://r.example.com/x?a=1,2>; rel="next""#
        let entries = LinkHeader.parse(header)

        #expect(entries.count == 2)
        #expect(entries[0].relation == "alternate")
        #expect(entries[0].fields["filename"] == "Package@swift-5.8.swift")
        #expect(entries[0].fields["swift-tools-version"] == "5.8")
        #expect(entries[1].target == "http://r.example.com/x?a=1,2")
        #expect(entries[1].relation == LinkHeader.next)
    }

    @Test func toleratesMissingHeaders() {
        #expect(LinkHeader.parse(nil).isEmpty)
        #expect(LinkHeader.parse("not a link").isEmpty)
    }
}

struct KeychainOutputTests {
    @Test func readsTheAccountAttribute() {
        let output = """
        keychain: "/Users/me/Library/Keychains/login.keychain-db"
        class: "inet"
        attributes:
            "acct"<blob>="mona"
            "srvr"<blob>="registry.example.com"
        """
        #expect(Keychain.account(in: output) == "mona")
    }
}

struct RegistryConfigurationTests {
    private func write(_ json: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)
    }

    /// The package's file overlays the shared one; scopes win over the default.
    @Test func mergesSharedAndLocalFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("swx-registries-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = root.appendingPathComponent("shared")
        let package = root.appendingPathComponent("package")

        try self.write("""
        {"registries": {"[default]": {"url": "https://shared.example.com"}, "acme": {"url": "https://acme.example.com"}},
         "authentication": {"acme.example.com": {"type": "token"}}, "version": 1}
        """, to: shared.appendingPathComponent("registries.json"))
        try self.write("""
        {"registries": {"[default]": {"url": "https://local.example.com:8443", "supportsAvailability": true}},
         "authentication": {"local.example.com:8443": {"type": "basic"}}, "version": 1}
        """, to: package.appendingPathComponent(".swiftpm/configuration/registries.json"))

        let configuration = try RegistryConfiguration.load(packageDirectory: package, configurationDirectory: shared)
        #expect(configuration.registry(forScope: "mona")?.url.absoluteString == "https://local.example.com:8443")
        #expect(configuration.registry(forScope: "mona")?.supportsAvailability == true)
        #expect(configuration.registry(forScope: "ACME")?.url.absoluteString == "https://acme.example.com")
        #expect(configuration.authentication(for: URL(string: "https://local.example.com:8443/x")!) == .basic)
        #expect(configuration.authentication(for: URL(string: "https://acme.example.com/x")!) == .token)
        #expect(configuration.authentication(for: URL(string: "https://local.example.com/x")!) == nil)
    }
}

struct RegistryIdentityTests {
    /// SwiftPM keeps the declared spelling but compares identities case-insensitively.
    @Test func comparesCaseInsensitivelyAndKeepsSpelling() {
        let declared = PackageIdentity(plain: "mona.LinkedList")
        #expect(declared == PackageIdentity(plain: "Mona.linkedlist"))
        #expect(declared.description == "mona.LinkedList")
        #expect(declared.registryComponents?.scope == "mona")
        #expect(declared.registryComponents?.name == "LinkedList")
        #expect(PackageIdentity(plain: "swift-nio").registryComponents == nil)
    }
}

struct CanonicalLocationTests {
    /// Every spelling of a repository maps to one location (SwiftPM's `CanonicalPackageLocation`).
    @Test func canonicalizesRepositoryLocations() {
        let expected = "github.com/apple/swift-nio"
        #expect(CanonicalLocation.compute("https://github.com/apple/swift-nio") == expected)
        #expect(CanonicalLocation.compute("https://github.com/apple/swift-nio.git") == expected)
        #expect(CanonicalLocation.compute("HTTPS://GitHub.com/Apple/Swift-NIO/") == expected)
        #expect(CanonicalLocation.compute("git@github.com:apple/swift-nio.git") == expected)
        #expect(CanonicalLocation.compute("ssh://git@github.com/apple/swift-nio.git") == expected)
        #expect(CanonicalLocation.compute("https://user:secret@github.com:443/apple/swift-nio.git") == expected)
        #expect(CanonicalLocation.compute("https://github.com/apple/swift-nio.git?x=1#y") == expected)
        // SwiftPM's quirk: the port is stripped before the query, and only when no digit follows it.
        #expect(CanonicalLocation.compute("https://github.com:443/apple/swift-nio.git?x=1") == "github.com:443/apple/swift-nio")
        #expect(CanonicalLocation.compute("file:///repos/Kit.git") == "/repos/kit")
        #expect(CanonicalLocation.compute("/repos/Kit") == "/repos/kit")
    }

    /// The file-name hash of SwiftPM's fingerprint files (`async-http-client-3c9c1259.json`).
    @Test func namesSourceControlFingerprintFilesLikeSwiftPM() {
        let subject = FingerprintSubject.sourceControl(PackageIdentity(plain: "async-http-client"), url: "https://github.com/swift-server/async-http-client.git")
        #expect(subject.fileName == "async-http-client-3c9c1259.json")
        #expect(FingerprintSubject.registry(PackageIdentity(plain: "mona.LinkedList")).fileName == "mona.LinkedList.json")
    }
}
