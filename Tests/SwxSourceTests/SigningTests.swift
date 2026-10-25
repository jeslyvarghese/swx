import Foundation
import SwxCore
@testable import SwxSource
import Testing

struct ManifestSignatureTests {
    @Test func splitsTheSignatureLine() throws {
        let body = "// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: \"P\")\n"
        let manifest = body + "//  signature:  cms-1.0.0;" + Data([1, 2, 3]).base64EncodedString() + "\n"
        let parsed = try #require(try ManifestSignature.parse(manifest))
        #expect(parsed.format == "cms-1.0.0")
        #expect(parsed.signature == [1, 2, 3])
        #expect(parsed.contents == Array(body.dropLast().utf8))
    }

    @Test func treatsOtherTrailingCommentsAsUnsigned() throws {
        #expect(try ManifestSignature.parse("let package = Package(name: \"P\")\n// just a comment\n") == nil)
        #expect(try ManifestSignature.parse("let package = Package(name: \"P\")\n") == nil)
    }

    @Test func rejectsMalformedSignatures() {
        #expect(throws: ManifestSignature.Malformed.self) {
            _ = try ManifestSignature.parse("let package = Package(name: \"P\")\n// signature: cms-1.0.0;!!!not base64\n")
        }
    }
}

struct SigningPolicyTests {
    /// Package overrides beat scope overrides, which beat registry and default settings.
    @Test func appliesOverridesInSwiftPMsOrder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("swx-signing-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("registries.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("""
        {"registries": {"[default]": {"url": "https://r.example.com"}},
         "security": {
           "default": {"signing": {"onUnsigned": "error", "onUntrustedCertificate": "prompt"}},
           "registryOverrides": {"r.example.com": {"signing": {"includeDefaultTrustedRootCertificates": false}}},
           "scopeOverrides": {"mona": {"signing": {"onUntrustedCertificate": "warn"}}},
           "packageOverrides": {"mona.LinkedList": {"signing": {"onUnsigned": "silentAllow", "validationChecks": {"certificateExpiration": "enabled"}}}}
         },
         "version": 1}
        """.utf8).write(to: file)

        let configuration = try RegistryConfiguration.load(packageDirectory: root.appendingPathComponent("none"), configurationDirectory: root)
        let registry = try #require(configuration.defaultRegistry)

        let linkedList = configuration.signingPolicy(scope: "mona", name: "LinkedList", registry: registry)
        #expect(linkedList.onUnsigned == .silentAllow)
        #expect(linkedList.onUntrustedCertificate == .warn)
        #expect(linkedList.includeDefaultTrustedRootCertificates == false)
        #expect(linkedList.certificateExpiration == .enabled)

        let other = configuration.signingPolicy(scope: "acme", name: "Tool", registry: registry)
        #expect(other.onUnsigned == .error)
        #expect(other.onUntrustedCertificate == .prompt)
        #expect(other.certificateRevocation == .disabled)
    }
}

struct SigningEntityTests {
    private let team = SigningEntity.recognized(type: "adp", name: "Mona", organizationalUnit: "TEAM1", organization: "Mona Inc")

    /// Apple Developer Program signers are the same signer when the team matches.
    @Test func comparesDeveloperProgramSignersByTeam() {
        #expect(self.team == .recognized(type: "adp", name: "Other name", organizationalUnit: "TEAM1", organization: "Renamed Inc"))
        #expect(self.team != .recognized(type: "adp", name: "Mona", organizationalUnit: "TEAM2", organization: "Mona Inc"))
        #expect(SigningEntity.unrecognized(name: "A", organizationalUnit: nil, organization: "O") != .unrecognized(name: "B", organizationalUnit: nil, organization: "O"))
    }

    /// The first recognized signer is recorded; another signer for a new version is refused.
    @Test func refusesASignerChange() async throws {
        let security = FileManager.default.temporaryDirectory.appendingPathComponent("swx-signers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: security) }
        let store = SigningEntityStore(securityDirectory: security)
        let identity = PackageIdentity(plain: "mona.LinkedList")
        let impostor = SigningEntity.recognized(type: "adp", name: "Eve", organizationalUnit: "TEAM9", organization: "Eve Inc")

        try await store.validate(identity, version: Version(1, 0, 0), signingEntity: self.team, registry: "https://r.example.com")
        try await store.validate(identity, version: Version(1, 1, 0), signingEntity: self.team, registry: "https://r.example.com")
        await #expect(throws: SourceError.self) {
            try await store.validate(identity, version: Version(1, 2, 0), signingEntity: impostor, registry: "https://r.example.com")
        }
        await #expect(throws: SourceError.self) {
            try await store.validate(identity, version: Version(1, 0, 0), signingEntity: nil, registry: "https://r.example.com")
        }

        // Unrecognized signers are never recorded, as in SwiftPM.
        let other = PackageIdentity(plain: "mona.Other")
        try await store.validate(other, version: Version(1, 0, 0), signingEntity: .unrecognized(name: "X", organizationalUnit: nil, organization: nil), registry: "https://r.example.com")
        #expect(!FileManager.default.fileExists(atPath: security.appendingPathComponent("signing-entities/mona.Other.json").path))
    }
}
