// Prebuilt swift-syntax libraries for macros, as SwiftPM 6.4 downloads them while resolving
// (adapted from SwiftPM's Workspace+Prebuilts and ManifestSigning, Apache-2.0).

import _CryptoExtras
import Crypto
import Foundation
import SwiftASN1
import SwxCore
import SwxStore
import SwxSystem
import X509

/// One library a prebuilts manifest offers (SwiftPM's `PrebuiltsManifest.Library`).
public struct PrebuiltLibrary: Codable, Sendable, Equatable {
    public let name: String
    public let checksum: String
    public let products: [String]
    public let includePath: [String]?
}

/// The files of one downloaded library, in the store.
public struct PrebuiltArtifact: Sendable {
    public let library: PrebuiltLibrary
    /// The checked archive, and where it is extracted.
    public let archive: URL
    public let directory: URL
}

/// A package's prebuilt libraries for one toolchain and version, all in the store.
public struct PrebuiltRelease: Sendable {
    /// The signed manifest, as downloaded (SwiftPM keeps a copy next to the libraries).
    public let manifest: URL
    public let artifacts: [PrebuiltArtifact]
}

/// Downloads prebuilt libraries from download.swift.org into the store, once per toolchain and
/// version. Like SwiftPM, any failure (no prebuilts for this toolchain, a bad signature, a
/// checksum mismatch) means "build from source": the answer is `nil`, never an error.
public struct PrebuiltSource: Sendable {
    /// The packages SwiftPM has prebuilts for, and the URLs it recognizes them by.
    public static let packages: [String: [String]] = [
        "swift-syntax": [
            "https://github.com/swiftlang/swift-syntax.git",
            // The old location, redirected but still in use.
            "https://github.com/apple/swift-syntax.git",
            "git@github.com:swiftlang/swift-syntax.git",
        ],
    ]

    private static let defaultBase = "https://download.swift.org/prebuilts"
    private static let gitSuffix = ".git"
    private static let jsonExtension = "json"
    private static let unavailableMarker = ".unavailable"

    private let store: Store
    private let base: URL
    /// A root certificate to trust instead of Apple's (`--experimental-prebuilts-root-cert`).
    private let trustedRoot: URL?

    public init(store: Store, downloadURL: URL? = nil, trustedRoot: URL? = nil) {
        self.store = store
        self.base = downloadURL ?? URL(string: Self.defaultBase) ?? URL(fileURLWithPath: "/")
        self.trustedRoot = trustedRoot
    }

    /// Whether SwiftPM offers prebuilts for this package: its identity and URL (with or
    /// without `.git`) must match one it knows.
    public static func hasPrebuilts(identity: String, url: String) -> Bool {
        guard let urls = Self.packages[identity] else { return false }
        return urls.contains(url) || (!url.hasSuffix(Self.gitSuffix) && urls.contains(url + Self.gitSuffix))
    }

    /// The release's libraries for `prebuiltName` (`swiftlang-6.4.0.34.1-macosx27.0`), or `nil`.
    public func release(package: String, version: String, prebuiltName: String, archiveExtension: String) async -> PrebuiltRelease? {
        let directory = self.store.prebuiltPath(package: package, version: version)
        let manifestFile = directory.appendingPathComponent(prebuiltName).appendingPathExtension(Self.jsonExtension)
        let unavailable = directory.appendingPathComponent(prebuiltName + Self.unavailableMarker)
        guard !FileSystem.exists(unavailable) else { return nil }

        // The manifest: checked once when downloaded, then trusted from the store. A toolchain
        // the server has none for is remembered, so later resolves don't ask again.
        let libraries: [PrebuiltLibrary]
        switch await self.libraries(at: manifestFile, package: package, version: version, prebuiltName: prebuiltName) {
        case .found(let found):
            libraries = found
        case .unavailable:
            try? FileSystem.writeAtomically(Data(), to: unavailable)
            return nil
        case .failed:
            return nil
        }

        var artifacts: [PrebuiltArtifact] = []
        for library in libraries {
            guard let artifact = await self.artifact(library, package: package, version: version, prebuiltName: prebuiltName, archiveExtension: archiveExtension) else {
                return nil
            }
            artifacts.append(artifact)
        }
        self.store.markUsed(directory)
        return PrebuiltRelease(manifest: manifestFile, artifacts: artifacts)
    }

    private enum Lookup {
        case found([PrebuiltLibrary])
        /// The server has no prebuilts for this toolchain.
        case unavailable
        /// Offline, a server error, or a manifest that fails its checks.
        case failed
    }

    private func libraries(at manifestFile: URL, package: String, version: String, prebuiltName: String) async -> Lookup {
        if let data = FileSystem.readIfPresent(manifestFile), let manifest = try? JSONDecoder().decode(SignedManifest.self, from: data) {
            return .found(manifest.manifest.libraries)
        }

        let url = self.base.appendingPathComponent(package).appendingPathComponent(version).appendingPathComponent(manifestFile.lastPathComponent)
        guard let response = try? await HTTP.get(url, headers: [HTTPHeader.accept: HTTPHeader.json]) else { return .failed }
        if response.status == HTTPStatus.notFound || response.status == HTTPStatus.forbidden {
            return .unavailable
        }
        guard response.status == HTTPStatus.ok,
              let signed = try? JSONDecoder().decode(SignedManifest.self, from: response.body),
              (try? await PrebuiltManifestSignature.verify(signed, trustedRoot: self.trustedRoot)) != nil else {
            return .failed
        }
        try? FileSystem.writeAtomically(response.body, to: manifestFile)
        return .found(signed.manifest.libraries)
    }

    private enum HTTPHeader {
        static let accept = "Accept"
        static let json = "application/json"
    }

    private func artifact(_ library: PrebuiltLibrary, package: String, version: String, prebuiltName: String, archiveExtension: String) async -> PrebuiltArtifact? {
        let directory = self.store.prebuiltPath(package: package, version: version)
        let name = "\(prebuiltName)-\(library.name)"
        let archive = directory.appendingPathComponent(name + archiveExtension)
        let extracted = directory.appendingPathComponent(name, isDirectory: true)
        if FileSystem.isDirectory(extracted), FileSystem.exists(archive) {
            return PrebuiltArtifact(library: library, archive: archive, directory: extracted)
        }

        // Download, check against the manifest's checksum, extract, then publish both atomically.
        let url = self.base.appendingPathComponent(package).appendingPathComponent(version).appendingPathComponent(archive.lastPathComponent)
        guard let scratch = try? self.store.makeTemporaryDirectory() else { return nil }
        defer { try? FileSystem.removeTree(scratch) }
        let downloaded = scratch.appendingPathComponent(archive.lastPathComponent)
        let staging = scratch.appendingPathComponent(name, isDirectory: true)
        do {
            try await HTTP.download(url, to: downloaded)
            guard try ContentHash.sha256(fileAt: downloaded) == library.checksum else { return nil }
            try FileSystem.createDirectory(staging)
            try await Self.extract(downloaded, into: staging)
            FileSystem.makeReadOnly(staging)
            try FileSystem.moveIntoPlace(staging, extracted)
            try FileSystem.moveIntoPlace(downloaded, archive)
        } catch {
            return nil
        }
        return PrebuiltArtifact(library: library, archive: archive, directory: extracted)
    }

    private static let tarExtension = ".tar.gz"

    /// Zip on macOS and Windows, gzipped tar on Linux, as SwiftPM's archiver picks by extension.
    private static func extract(_ archive: URL, into directory: URL) async throws {
        if archive.lastPathComponent.hasSuffix(Self.tarExtension) {
            try await ProcessRunner.run(["tar", "-xzf", archive.path, "-C", directory.path])
            return
        }
        try await ArchiveExtraction.unzip(archive, into: directory)
    }

    private enum HTTPStatus {
        static let ok = 200
        /// download.swift.org answers 403 (an S3 bucket) for files it doesn't have.
        static let forbidden = 403
        static let notFound = 404
    }

    // MARK: Signed manifests

    /// `{"manifest": {...}, "signature": {"signature": "<JWS>", "certificate": {...}}}`.
    struct SignedManifest: Codable {
        let manifest: Manifest
        let signature: Signature

        struct Manifest: Codable, Equatable {
            let libraries: [PrebuiltLibrary]
        }

        struct Signature: Codable {
            let signature: String
        }
    }
}

/// The JWS SwiftPM signs prebuilts manifests (and package collections) with: the payload is
/// the manifest's JSON, the header names the algorithm and carries the certificate chain.
enum PrebuiltManifestSignature {
    private struct Header: Decodable {
        let alg: Algorithm
        let x5c: [String]
    }

    private enum Algorithm: String, Decodable {
        /// RSASSA-PKCS1-v1_5 with SHA-256.
        case rs256 = "RS256"
        /// ECDSA with P-256 and SHA-256.
        case es256 = "ES256"
    }

    private static let separator = UInt8(ascii: ".")
    private static let partCount = 3

    struct Invalid: Error, CustomStringConvertible {
        let description: String
    }

    /// Checks the chain against Apple's roots (or `trustedRoot`), the signature against the
    /// leaf, and that the signed payload is the manifest beside it.
    static func verify(_ signed: PrebuiltSource.SignedManifest, trustedRoot: URL?) async throws {
        let parts = Array(signed.signature.signature.utf8).split(separator: Self.separator, omittingEmptySubsequences: false)
        guard parts.count == Self.partCount,
              let headerData = Base64URL.decode(parts[0]),
              let header = try? JSONDecoder().decode(Header.self, from: headerData),
              let payload = Base64URL.decode(parts[1]),
              let signature = Base64URL.decode(parts[2]) else {
            throw Invalid(description: "malformed signature")
        }

        // The certificate chain must end in a trusted root and be fit for code signing.
        let chain = try header.x5c.map { text -> Certificate in
            guard let der = Data(base64Encoded: text) else { throw Invalid(description: "malformed certificate") }
            return try Certificate(derEncoded: Array(der))
        }
        guard let leaf = chain.first else { throw Invalid(description: "empty certificate chain") }
        let roots = try trustedRoot.map { [try Certificate(derEncoded: Array(try FileSystem.read($0)))] } ?? SigningCertificates.appleRoots
        var verifier = Verifier(rootCertificates: CertificateStore(roots)) {
            CodeSigningPolicy()
            DeveloperProgramMarkerPolicy()
            RFC5280Policy()
            OCSPVerifierPolicy(failureMode: .soft, requester: OCSPRequesterOverHTTP())
        }
        guard case .validCertificate = await verifier.validate(leaf: leaf, intermediates: CertificateStore(chain)) else {
            throw Invalid(description: "the certificate chain is not trusted")
        }

        // The signature covers `header.payload` as sent.
        let message = Data(parts[0]) + Data([Self.separator]) + Data(parts[1])
        let digest = SHA256.hash(data: message)
        switch header.alg {
        case .es256:
            guard let key = P256.Signing.PublicKey(leaf.publicKey),
                  let value = try? P256.Signing.ECDSASignature(rawRepresentation: signature),
                  key.isValidSignature(value, for: digest) else {
                throw Invalid(description: "invalid signature")
            }
        case .rs256:
            guard let key = _RSA.Signing.PublicKey(leaf.publicKey),
                  key.isValidSignature(_RSA.Signing.RSASignature(rawRepresentation: signature), for: digest, padding: .insecurePKCS1v1_5) else {
                throw Invalid(description: "invalid signature")
            }
        }

        // SwiftPM compares the re-encoded manifest with the payload; equal values say the same.
        let signedManifest = try JSONDecoder().decode(PrebuiltSource.SignedManifest.Manifest.self, from: payload)
        guard signedManifest == signed.manifest else {
            throw Invalid(description: "the signature is for another manifest")
        }
    }
}

/// Base64 with the URL alphabet and no padding (RFC 4648 §5), as JWS uses.
enum Base64URL {
    private static let paddingQuantum = 4

    static func decode(_ bytes: ArraySlice<UInt8>) -> Data? {
        var text = String(decoding: bytes, as: UTF8.self)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (Self.paddingQuantum - text.count % Self.paddingQuantum) % Self.paddingQuantum)
        return Data(base64Encoded: text)
    }
}
