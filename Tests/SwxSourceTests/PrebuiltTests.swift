import Crypto
import Foundation
import SwiftASN1
@testable import SwxSource
import Testing
import X509

struct PrebuiltTests {
    /// SwiftPM recognizes swift-syntax by identity and one of three URLs, `.git` optional.
    @Test func recognizesSwiftSyntax() {
        #expect(PrebuiltSource.hasPrebuilts(identity: "swift-syntax", url: "https://github.com/swiftlang/swift-syntax.git"))
        #expect(PrebuiltSource.hasPrebuilts(identity: "swift-syntax", url: "https://github.com/swiftlang/swift-syntax"))
        #expect(PrebuiltSource.hasPrebuilts(identity: "swift-syntax", url: "https://github.com/apple/swift-syntax.git"))
        #expect(PrebuiltSource.hasPrebuilts(identity: "swift-syntax", url: "git@github.com:swiftlang/swift-syntax.git"))
        #expect(!PrebuiltSource.hasPrebuilts(identity: "swift-syntax", url: "https://example.com/fork/swift-syntax.git"))
        #expect(!PrebuiltSource.hasPrebuilts(identity: "swift-format", url: "https://github.com/swiftlang/swift-format.git"))
    }

    /// A JWS over the manifest, signed by a code-signing leaf of a trusted root, passes; a
    /// manifest that isn't the payload, or a root that isn't trusted, fails.
    @Test func verifiesSignedManifests() async throws {
        let pki = try TestPKI()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("root.der")
        try Data(try pki.rootDER()).write(to: root)

        let library = PrebuiltLibrary(name: "MacroSupport", checksum: "abc", products: ["SwiftSyntax"], includePath: ["Sources/include"])
        let manifest = PrebuiltSource.SignedManifest.Manifest(libraries: [library])
        let signed = try pki.sign(manifest)
        try await PrebuiltManifestSignature.verify(signed, trustedRoot: root)

        // The outer manifest must be what was signed.
        let other = PrebuiltSource.SignedManifest(
            manifest: .init(libraries: [PrebuiltLibrary(name: "MacroSupport", checksum: "evil", products: [], includePath: nil)]),
            signature: signed.signature
        )
        await #expect(throws: PrebuiltManifestSignature.Invalid.self) { try await PrebuiltManifestSignature.verify(other, trustedRoot: root) }

        // Without the test root, Apple's roots don't vouch for it.
        await #expect(throws: PrebuiltManifestSignature.Invalid.self) { try await PrebuiltManifestSignature.verify(signed, trustedRoot: nil) }
    }
}

/// A P-256 root and a code-signing leaf it issued.
private struct TestPKI {
    let rootKey = P256.Signing.PrivateKey()
    let leafKey = P256.Signing.PrivateKey()
    let root: Certificate
    let leaf: Certificate

    init() throws {
        let now = Date()
        let rootName = try DistinguishedName { CommonName("Test Root") }
        self.root = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: .init(self.rootKey.publicKey),
            notValidBefore: now.addingTimeInterval(-60),
            notValidAfter: now.addingTimeInterval(3600),
            issuer: rootName,
            subject: rootName,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: nil))
                Critical(KeyUsage(keyCertSign: true))
            },
            issuerPrivateKey: .init(self.rootKey)
        )
        self.leaf = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: .init(self.leafKey.publicKey),
            notValidBefore: now.addingTimeInterval(-60),
            notValidAfter: now.addingTimeInterval(3600),
            issuer: rootName,
            subject: try DistinguishedName { CommonName("Test Signer") },
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                Critical(KeyUsage(digitalSignature: true))
                try ExtendedKeyUsage([.codeSigning])
            },
            issuerPrivateKey: .init(self.rootKey)
        )
    }

    func rootDER() throws -> [UInt8] {
        var serializer = DER.Serializer()
        try serializer.serialize(self.root)
        return serializer.serializedBytes
    }

    private func der(_ certificate: Certificate) throws -> Data {
        var serializer = DER.Serializer()
        try serializer.serialize(certificate)
        return Data(serializer.serializedBytes)
    }

    /// `header.payload.signature`, base64url without padding, ES256.
    func sign(_ manifest: PrebuiltSource.SignedManifest.Manifest) throws -> PrebuiltSource.SignedManifest {
        let header = try JSONSerialization.data(withJSONObject: ["alg": "ES256", "x5c": [try self.der(self.leaf).base64EncodedString(), try self.der(self.root).base64EncodedString()]])
        let payload = try JSONEncoder().encode(manifest)
        let message = Self.base64URL(header) + "." + Self.base64URL(payload)
        let signature = try self.leafKey.signature(for: SHA256.hash(data: Data(message.utf8)))
        let jws = message + "." + Self.base64URL(signature.rawRepresentation)
        return PrebuiltSource.SignedManifest(manifest: manifest, signature: .init(signature: jws))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
