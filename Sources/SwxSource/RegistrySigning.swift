// Package signature validation (SE-0391), adapted from SwiftPM's PackageSigning and
// PackageRegistry modules (Apache License v2.0 with Runtime Library Exception, Copyright (c)
// Apple Inc. and the Swift project authors), so swx accepts and refuses exactly what SwiftPM does.

import Foundation
import SwiftASN1
@_spi(CMS) @_spi(DisableValidityCheck) import X509
import SwxCore
import SwxSystem

// MARK: - Policy

/// `security.…signing` in `registries.json`, after SwiftPM's default → registry → scope →
/// package overrides.
public struct SigningPolicy: Sendable, Hashable {
    /// What to do about an unsigned release, or a signer whose certificate isn't trusted.
    public enum Action: String, Sendable, Hashable, Decodable {
        case prompt
        case error
        case warn
        case silentAllow
    }

    public enum Expiration: String, Sendable, Hashable, Decodable {
        case enabled
        case disabled
    }

    public enum Revocation: String, Sendable, Hashable, Decodable {
        case strict
        case allowSoftFail
        case disabled
    }

    public var onUnsigned: Action = .warn
    public var onUntrustedCertificate: Action = .warn
    public var trustedRootCertificatesPath: String?
    public var includeDefaultTrustedRootCertificates = true
    public var certificateExpiration: Expiration = .disabled
    public var certificateRevocation: Revocation = .disabled

    /// SwiftPM's defaults (`Signing.default`).
    public static let `default` = SigningPolicy()

    /// The stored form, every field optional so overrides merge field by field.
    struct Stored: Decodable, Sendable, Hashable {
        struct ValidationChecks: Decodable, Sendable, Hashable {
            let certificateExpiration: Expiration?
            let certificateRevocation: Revocation?
        }

        let onUnsigned: Action?
        let onUntrustedCertificate: Action?
        let trustedRootCertificatesPath: String?
        let includeDefaultTrustedRootCertificates: Bool?
        let validationChecks: ValidationChecks?
    }

    mutating func merge(_ stored: Stored?) {
        guard let stored else { return }
        self.onUnsigned = stored.onUnsigned ?? self.onUnsigned
        self.onUntrustedCertificate = stored.onUntrustedCertificate ?? self.onUntrustedCertificate
        self.trustedRootCertificatesPath = stored.trustedRootCertificatesPath ?? self.trustedRootCertificatesPath
        self.includeDefaultTrustedRootCertificates = stored.includeDefaultTrustedRootCertificates ?? self.includeDefaultTrustedRootCertificates
        self.certificateExpiration = stored.validationChecks?.certificateExpiration ?? self.certificateExpiration
        self.certificateRevocation = stored.validationChecks?.certificateRevocation ?? self.certificateRevocation
    }
}

// MARK: - Signing entities

/// Who signed a release. Only Apple Developer Program certificates are "recognized".
public enum SigningEntity: Sendable, Hashable, CustomStringConvertible {
    case recognized(type: String, name: String, organizationalUnit: String, organization: String)
    case unrecognized(name: String?, organizationalUnit: String?, organization: String?)

    static let developerProgramType = "adp"

    /// For Apple Developer Program signers only the team (organizational unit) must match.
    public static func == (lhs: SigningEntity, rhs: SigningEntity) -> Bool {
        switch (lhs, rhs) {
        case (.recognized(let lType, let lName, let lUnit, let lOrganization), .recognized(let rType, let rName, let rUnit, let rOrganization)):
            if lType == Self.developerProgramType, rType == Self.developerProgramType {
                return lUnit == rUnit
            }
            return lType == rType && lName == rName && lUnit == rUnit && lOrganization == rOrganization
        case (.unrecognized(let lName, let lUnit, let lOrganization), .unrecognized(let rName, let rUnit, let rOrganization)):
            return lName == rName && lUnit == rUnit && lOrganization == rOrganization
        default:
            return false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case .recognized(let type, _, let unit, _):
            hasher.combine(type)
            hasher.combine(unit)
        case .unrecognized(let name, let unit, let organization):
            hasher.combine(name)
            hasher.combine(unit)
            hasher.combine(organization)
        }
    }

    public var isRecognized: Bool {
        if case .recognized = self { return true }
        return false
    }

    /// SwiftPM's wording, which users see in its messages.
    public var description: String {
        switch self {
        case .recognized(let type, let name, let unit, let organization):
            return "SigningEntity[type=\(type), name=\(name), organizationalUnit=\(unit), organization=\(organization)]"
        case .unrecognized(let name, let unit, let organization):
            return "SigningEntity[name=\(String(describing: name)), organizationalUnit=\(String(describing: unit)), organization=\(String(describing: organization))]"
        }
    }

    /// Marker extension of Apple's Swift Package signing certificates.
    static let developerProgramMarker: ASN1ObjectIdentifier = [1, 2, 840, 113_635, 100, 6, 1, 35]

    static func from(certificate: Certificate) -> SigningEntity {
        let name = certificate.subject.commonName
        let unit = certificate.subject.organizationalUnitName
        let organization = certificate.subject.organizationName
        if Self.isDeveloperProgramCertificate(certificate), let name, let unit, let organization {
            return .recognized(type: Self.developerProgramType, name: name, organizationalUnit: unit, organization: organization)
        }
        return .unrecognized(name: name, organizationalUnit: unit, organization: organization)
    }

    /// Has the marker and is issued by one of Apple's WWDR intermediates.
    private static func isDeveloperProgramCertificate(_ certificate: Certificate) -> Bool {
        guard certificate.extensions.contains(where: { $0.oid == Self.developerProgramMarker }) else { return false }
        return SigningCertificates.wwdrIntermediates.contains {
            $0.subject == certificate.issuer && $0.publicKey.isValidSignature(certificate.signature, for: certificate)
        }
    }
}

private extension DistinguishedName {
    func value(_ oid: ASN1ObjectIdentifier) -> String? {
        for name in self {
            for attribute in name where attribute.type == oid {
                return String(describing: attribute.value)
            }
        }
        return nil
    }

    var commonName: String? { self.value(.RDNAttributeType.commonName) }
    var organizationalUnitName: String? { self.value(.RDNAttributeType.organizationalUnitName) }
    var organizationName: String? { self.value(.RDNAttributeType.organizationName) }
}

// MARK: - Verification

/// The outcome of checking one signature.
public enum SignatureStatus: Sendable, Hashable {
    case valid(SigningEntity)
    case invalid(String)
    case certificateInvalid(String)
    case certificateNotTrusted(SigningEntity)
}

/// Apple's roots (trusted by default) and WWDR intermediates (always offered for chain building).
enum SigningCertificates {
    static let appleRoots: [Certificate] = [
        AppleCertificateData.AppleComputerRootCertificate_cer,
        AppleCertificateData.AppleIncRootCertificate_cer,
        AppleCertificateData.AppleRootCA_G2_cer,
        AppleCertificateData.AppleRootCA_G3_cer,
    ].compactMap { try? Certificate(derEncoded: $0) }

    static let wwdrIntermediates: [Certificate] = [
        AppleCertificateData.AppleWWDRCAG2_cer,
        AppleCertificateData.AppleWWDRCAG3_cer,
        AppleCertificateData.AppleWWDRCAG4_cer,
        AppleCertificateData.AppleWWDRCAG5_cer,
        AppleCertificateData.AppleWWDRCAG6_cer,
        AppleCertificateData.AppleWWDRCAG7_cer,
        AppleCertificateData.AppleWWDRCAG8_cer,
    ].compactMap { try? Certificate(derEncoded: $0) }
}

/// The only signature format SE-0391 defines.
public enum SignatureFormat: String, Sendable {
    case cms = "cms-1.0.0"
}

/// CMS signature verification with SwiftPM's policy set.
enum SignatureVerifier {
    static func status(signature: [UInt8], content: [UInt8], policy: SigningPolicy) async throws -> SignatureStatus {
        var roots: [Certificate] = []
        if policy.includeDefaultTrustedRootCertificates {
            roots += SigningCertificates.appleRoots
        }
        roots += try Self.configuredRoots(policy)

        let result = await CMS.isValidSignature(
            dataBytes: content,
            signatureBytes: signature,
            additionalIntermediateCertificates: SigningCertificates.wwdrIntermediates,
            trustRoots: CertificateStore(roots)
        ) {
            Self.policies(policy)
        }

        switch result {
        case .success(let valid):
            return .valid(SigningEntity.from(certificate: valid.signer))
        case .failure(CMS.VerificationError.unableToValidateSigner(let failure)):
            // No failed policy means the chain just doesn't end in a trusted root.
            guard !failure.policyFailures.isEmpty else {
                return .certificateNotTrusted(SigningEntity.from(certificate: failure.signer))
            }
            return .certificateInvalid("failures: \(failure.policyFailures.map(\.policyFailureReason))")
        case .failure(CMS.VerificationError.invalidCMSBlock(let error)):
            return .invalid(error.reason)
        case .failure(let error):
            return .invalid(String(describing: error))
        }
    }

    /// DER certificates in `trustedRootCertificatesPath`.
    private static func configuredRoots(_ policy: SigningPolicy) throws -> [Certificate] {
        guard let path = policy.trustedRootCertificatesPath else { return [] }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        guard FileSystem.isDirectory(directory) else {
            throw SourceError(description: "trusted root certificates path \(path) is not a directory")
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        return try names.map { try Certificate(derEncoded: Array(FileSystem.read(directory.appendingPathComponent($0)))) }
    }

    @PolicyBuilder
    private static func policies(_ policy: SigningPolicy) -> some VerifierPolicy {
        CodeSigningPolicy()
        DeveloperProgramMarkerPolicy()
        switch (policy.certificateExpiration, policy.certificateRevocation) {
        case (.enabled, .strict), (.disabled, .strict):
            RFC5280Policy()
            OCSPVerifierPolicy(failureMode: .hard, requester: OCSPRequesterOverHTTP())
        case (.enabled, .allowSoftFail), (.disabled, .allowSoftFail):
            RFC5280Policy()
            OCSPVerifierPolicy(failureMode: .soft, requester: OCSPRequesterOverHTTP())
        case (.enabled, .disabled):
            RFC5280Policy()
        case (.disabled, .disabled):
            // Basic validation still applies when expiry isn't checked.
            RFC5280Policy.withValidityCheckDisabled()
        }
    }
}

/// The leaf must be a code-signing certificate.
private struct CodeSigningPolicy: VerifierPolicy {
    let verifyingCriticalExtensions: [ASN1ObjectIdentifier] = [
        .X509ExtensionID.keyUsage,
        .X509ExtensionID.extendedKeyUsage,
    ]

    func chainMeetsPolicyRequirements(chain: UnverifiedCertificateChain) async -> PolicyEvaluationResult {
        let isCodeSigning = (try? chain.leaf.extensions.extendedKeyUsage?.contains(.codeSigning)) ?? false
        guard isCodeSigning else {
            return .failsToMeetPolicy(reason: "Certificate \(chain.leaf) does not have code signing extended key usage")
        }
        return .meetsPolicy
    }
}

/// Lists Apple's marker extensions so they don't count as unhandled critical extensions.
private struct DeveloperProgramMarkerPolicy: VerifierPolicy {
    let verifyingCriticalExtensions: [ASN1ObjectIdentifier] = [
        SigningEntity.developerProgramMarker,
        [1, 2, 840, 113_635, 100, 6, 1, 2],
        [1, 2, 840, 113_635, 100, 6, 1, 12],
    ]

    func chainMeetsPolicyRequirements(chain: UnverifiedCertificateChain) async -> PolicyEvaluationResult {
        .meetsPolicy
    }
}

/// OCSP queries over the shared HTTP client.
private struct OCSPRequesterOverHTTP: OCSPRequester {
    private static let contentType = "application/ocsp-request"
    private static let ok = 200

    func query(request: [UInt8], uri: String) async -> OCSPRequesterQueryResult {
        guard let url = URL(string: uri) else {
            return .terminalError(SourceError(description: "invalid OCSP responder URL \(uri)"))
        }
        do {
            let response = try await HTTP.post(url, body: Data(request), headers: ["Content-Type": Self.contentType])
            guard response.status == Self.ok else {
                throw SourceError(description: "OCSP responder \(uri) answered HTTP \(response.status)")
            }
            return .response(Array(response.body))
        } catch {
            return .nonTerminalError(error)
        }
    }
}

// MARK: - Manifest signatures

/// A signed manifest ends with `// signature: cms-1.0.0;<base64>` (SwiftPM's `ManifestSignatureParser`).
struct ManifestSignature: Sendable {
    let contents: [UInt8]
    let format: String
    let signature: [UInt8]

    private static let label = "signature"
    private static let commentCharacter: Character = "/"
    private static let labelTerminator: Character = ":"
    private static let formatTerminator: Character = ";"

    struct Malformed: Error {}

    /// `nil` when the manifest carries no signature line.
    static func parse(_ manifest: String) throws -> ManifestSignature? {
        // The signature, if any, is the last line.
        let endOfSignature = manifest.lastIndex { !$0.isWhitespace } ?? manifest.endIndex
        let endOfContents = manifest[..<endOfSignature].lastIndex { $0.isNewline } ?? manifest.endIndex
        let commentStart = manifest[endOfContents...].firstIndex(of: Self.commentCharacter) ?? manifest.endIndex
        guard commentStart < endOfSignature else { return nil }

        let commentEnd = manifest[commentStart...].firstIndex { $0 != Self.commentCharacter } ?? manifest.endIndex
        let labelStart = manifest[commentEnd...].firstIndex { !$0.isWhitespace } ?? manifest.endIndex
        let labelEnd = manifest[labelStart...].firstIndex(of: Self.labelTerminator) ?? manifest.endIndex
        guard labelStart < labelEnd, manifest[labelStart..<labelEnd].lowercased() == Self.label else { return nil }

        let formatStart = manifest[labelEnd...].firstIndex { $0 != Self.labelTerminator && !$0.isWhitespace } ?? manifest.endIndex
        let formatEnd = manifest[formatStart...].firstIndex(of: Self.formatTerminator) ?? manifest.endIndex
        guard formatStart < formatEnd else { return nil }

        let signatureStart = manifest[formatEnd...].firstIndex { $0 != Self.formatTerminator } ?? manifest.endIndex
        guard signatureStart < endOfSignature else { return nil }

        guard let signature = Data(base64Encoded: String(manifest[signatureStart...endOfSignature])) else {
            throw Malformed()
        }
        return ManifestSignature(
            contents: Array(String(manifest[..<endOfContents]).utf8),
            format: String(manifest[formatStart..<formatEnd]),
            signature: Array(signature)
        )
    }
}

// MARK: - Signing entity trust on first use

/// SwiftPM's `<security>/signing-entities/<scope>.<name>.json`: who signed which versions, so a
/// release later signed by someone else is refused. Only recognized signers are recorded.
public actor SigningEntityStore {
    private static let directory = "signing-entities"
    private static let fileExtension = "json"

    private let directory: URL

    public init(securityDirectory: URL) {
        self.directory = securityDirectory.appendingPathComponent(Self.directory, isDirectory: true)
    }

    private struct Stored: Codable {
        struct Entity: Codable, Hashable {
            struct Recognized: Codable, Hashable {
                let type: String
                let name: String
                let organizationalUnit: String
                let organization: String
            }

            struct Unrecognized: Codable, Hashable {
                let name: String?
                let organizationalUnit: String?
                let organization: String?
            }

            let recognized: Recognized?
            let unrecognized: Unrecognized?

            var signingEntity: SigningEntity? {
                if let recognized {
                    return .recognized(type: recognized.type, name: recognized.name, organizationalUnit: recognized.organizationalUnit, organization: recognized.organization)
                }
                if let unrecognized {
                    return .unrecognized(name: unrecognized.name, organizationalUnit: unrecognized.organizationalUnit, organization: unrecognized.organization)
                }
                return nil
            }

            init(_ entity: SigningEntity) {
                switch entity {
                case .recognized(let type, let name, let unit, let organization):
                    self.recognized = Recognized(type: type, name: name, organizationalUnit: unit, organization: organization)
                    self.unrecognized = nil
                case .unrecognized(let name, let unit, let organization):
                    self.recognized = nil
                    self.unrecognized = Unrecognized(name: name, organizationalUnit: unit, organization: organization)
                }
            }
        }

        struct Origin: Codable, Hashable {
            struct Registry: Codable, Hashable {
                let _0: String
            }

            let registry: Registry
        }

        struct Signer: Codable {
            let signingEntity: Entity
            var origins: [Origin]
            var versions: [String]
        }

        struct Expected: Codable {
            let signingEntity: Entity
            let fromVersion: String
        }

        let expectedSigner: Expected?
        var signers: [Signer]
    }

    private func file(for identity: PackageIdentity) -> URL {
        self.directory.appendingPathComponent(identity.description).appendingPathExtension(Self.fileExtension)
    }

    private func load(_ identity: PackageIdentity) -> Stored {
        guard let data = FileSystem.readIfPresent(self.file(for: identity)),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            return Stored(expectedSigner: nil, signers: [])
        }
        return stored
    }

    /// SwiftPM's `PackageSigningEntityTOFU.validate` in strict mode.
    func validate(_ identity: PackageIdentity, version: Version, signingEntity: SigningEntity?, registry: String) throws {
        var stored = self.load(identity)
        let signers = stored.signers.compactMap { signer in signer.signingEntity.signingEntity.map { ($0, signer) } }

        // A package never signed before may stay unsigned or gain a signer.
        if !signers.isEmpty {
            let versionSigners = signers.filter { $0.1.versions.contains(version.description) }.map(\.0)
            if let recorded = versionSigners.first {
                guard let signingEntity, versionSigners.contains(signingEntity) else {
                    throw SourceError(description: "\(identity) version \(version) was previously signed by \(recorded), but is now signed by \(signingEntity.map(String.init(describing:)) ?? "nobody")")
                }
                return
            }
            try Self.checkOtherVersions(identity, version: version, signingEntity: signingEntity, signers: signers, expected: stored.expectedSigner)
        }

        // Record recognized signers only, as SwiftPM does.
        guard let signingEntity, signingEntity.isRecognized else { return }
        let entity = Stored.Entity(signingEntity)
        let origin = Stored.Origin(registry: .init(_0: registry))
        if let index = stored.signers.firstIndex(where: { $0.signingEntity.signingEntity == signingEntity }) {
            if !stored.signers[index].versions.contains(version.description) {
                stored.signers[index].versions.append(version.description)
            }
            if !stored.signers[index].origins.contains(origin) {
                stored.signers[index].origins.append(origin)
            }
        } else {
            stored.signers.append(Stored.Signer(signingEntity: entity, origins: [origin], versions: [version.description]))
        }
        try FileSystem.writeAtomically(try JSONCoding.encoder.encode(stored), to: self.file(for: identity))
    }

    /// A new version signed by someone other than the package's known signers is refused.
    private static func checkOtherVersions(
        _ identity: PackageIdentity,
        version: Version,
        signingEntity: SigningEntity?,
        signers: [(SigningEntity, Stored.Signer)],
        expected: Stored.Expected?
    ) throws {
        guard let signingEntity else {
            // Unsigned after being signed: only allowed before the first signed version.
            let lowest = signers.flatMap(\.1.versions).compactMap { Version($0) }.min()
            if let lowest, version > lowest {
                throw SourceError(description: "\(identity) version \(version) is unsigned, but versions since \(lowest) were signed")
            }
            return
        }
        if let expected, let expectedEntity = expected.signingEntity.signingEntity, let from = Version(expected.fromVersion), version >= from {
            if signingEntity == expectedEntity { return }
            if let known = signers.first(where: { $0.0 == signingEntity }),
               let highest = known.1.versions.compactMap({ Version($0) }).max(), version < highest {
                return
            }
            throw SourceError(description: "\(identity) version \(version) is signed by \(signingEntity), but \(expectedEntity) signs versions since \(from)")
        }
        if signers.contains(where: { $0.0 == signingEntity }) { return }
        if let other = signers.first(where: { $0.0 != signingEntity }) {
            throw SourceError(description: "\(identity) version \(version) is signed by \(signingEntity), but earlier versions were signed by \(other.0)")
        }
    }
}
