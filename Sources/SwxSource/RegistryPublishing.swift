import Crypto
import Foundation
@_spi(CMS) import X509
import SwxSystem

/// Signs release content as `swift package-registry publish` does: detached CMS signatures
/// (`cms-1.0.0`) with a P-256 key and the certificate chain that vouches for it.
public struct RegistrySigner: Sendable {
    /// The only signature format SwiftPM writes and reads.
    public static let format = "cms-1.0.0"

    private let certificate: Certificate
    private let intermediates: [Certificate]
    private let privateKey: Certificate.PrivateKey

    /// `chain` is DER certificates, leaf first; the rest travel with every signature.
    public init(privateKey: Data, chain: [Data]) throws {
        guard let leaf = chain.first else {
            throw SourceError(description: "signing needs at least the signing certificate (--cert-chain-paths)")
        }
        do {
            self.certificate = try Certificate(derEncoded: Array(leaf))
            self.intermediates = try chain.dropFirst().map { try Certificate(derEncoded: Array($0)) }
        } catch {
            throw SourceError(description: "invalid certificate: \(error)")
        }
        do {
            self.privateKey = Certificate.PrivateKey(try P256.Signing.PrivateKey(derRepresentation: privateKey))
        } catch {
            throw SourceError(description: "invalid key (expected a DER-encoded PKCS#8 P-256 key): \(error)")
        }
    }

    public func sign(_ content: Data) throws -> Data {
        do {
            return Data(try CMS.sign(
                Array(content),
                signatureAlgorithm: .ecdsaWithSHA256,
                additionalIntermediateCertificates: self.intermediates,
                certificate: self.certificate,
                privateKey: self.privateKey
            ))
        } catch {
            throw SourceError(description: "signing failed: \(error)")
        }
    }

    /// A manifest with its signature appended as SwiftPM's trailing comment, which the registry
    /// serves and resolvers check (`// signature: cms-1.0.0;<base64>`).
    public func signedManifest(_ manifest: Data) throws -> Data {
        let signature = try self.sign(manifest)
        return manifest + Data("\n// signature: \(Self.format);\(signature.base64EncodedString())".utf8)
    }
}

/// What a registry answered to a publish (SE-0391).
public enum PublishResponse: Sendable, Equatable {
    /// 201: the release exists, perhaps at `location`.
    case published(location: URL?)
    /// 202: the registry is still processing; poll `status`.
    case processing(status: URL, retryAfter: Int?)
}

/// The parts of one release upload.
public struct ReleaseUpload: Sendable {
    public let archive: Data
    public let archiveSignature: Data?
    public let metadata: Data?
    public let metadataSignature: Data?

    public init(archive: Data, archiveSignature: Data?, metadata: Data?, metadataSignature: Data?) {
        self.archive = archive
        self.archiveSignature = archiveSignature
        self.metadata = metadata
        self.metadataSignature = metadataSignature
    }
}

/// Uploads a release to a registry: `PUT /{scope}/{name}/{version}` with a multipart body laid out
/// byte for byte as SwiftPM's (registries are tested against SwiftPM's requests).
public struct RegistryPublisher: Sendable {
    private enum Header {
        static let contentType = "Content-Type"
        static let accept = "Accept"
        static let expect = "Expect"
        static let prefer = "Prefer"
        static let signatureFormat = "X-Swift-Package-Signature-Format"
        static let authorization = "Authorization"
        static let location = "Location"
        static let retryAfter = "Retry-After"
        static let contentVersion = "Content-Version"
    }

    private enum Value {
        static let accept = "application/vnd.swift.registry.v1+json"
        static let expectContinue = "100-continue"
        static let respondAsync = "respond-async"
        static let apiVersion = "1"
    }

    private enum Field {
        static let archive = "source-archive"
        static let archiveSignature = "source-archive-signature"
        static let metadata = "metadata"
        static let metadataSignature = "metadata-signature"
    }

    private enum Status {
        static let created = 201
        static let accepted = 202
    }

    let configuration: RegistryConfiguration
    let credentials: RegistryCredentials

    public init(configuration: RegistryConfiguration, credentials: RegistryCredentials) {
        self.configuration = configuration
        self.credentials = credentials
    }

    public func publish(_ upload: ReleaseUpload, scope: String, name: String, version: String, to registry: URL) async throws -> PublishResponse {
        let url = registry.appendingPathComponent(scope).appendingPathComponent(name).appendingPathComponent(version)
        let boundary = UUID().uuidString

        var headers = [
            Header.contentType: "multipart/form-data;boundary=\"\(boundary)\"",
            Header.accept: Value.accept,
            Header.expect: Value.expectContinue,
            Header.prefer: Value.respondAsync,
        ]
        if upload.archiveSignature != nil {
            headers[Header.signatureFormat] = RegistrySigner.format
        }
        if let credential = await self.credentials.credential(for: registry) {
            headers[Header.authorization] = RegistryAuthorization.header(for: credential, authentication: self.configuration.authentication(for: registry))
        }

        // In memory, as SwiftPM sends it (a file upload would add resumable-upload headers).
        let response = try await HTTP.put(url, body: Self.body(upload, boundary: boundary), headers: headers)

        if let version = response.header(Header.contentVersion), version != Value.apiVersion {
            throw SourceError(description: "\(url.absoluteString) speaks registry API version \(version), expected \(Value.apiVersion)")
        }
        switch response.status {
        case Status.created:
            return .published(location: response.header(Header.location).flatMap(URL.init(string:)))
        case Status.accepted:
            guard let status = response.header(Header.location).flatMap(URL.init(string:)) else {
                throw SourceError(description: "\(url.absoluteString) accepted the release but gave no status location")
            }
            return .processing(status: status, retryAfter: response.header(Header.retryAfter).flatMap { Int($0) })
        default:
            throw SourceError(description: "publishing to \(url.absoluteString) failed: HTTP \(response.status) \(Self.problem(in: response.body))")
        }
    }

    /// SwiftPM's multipart layout, quirks included: binary parts carry
    /// `Content-Transfer-Encoding`, and the metadata part ends with its JSON, no CRLF.
    static func body(_ upload: ReleaseUpload, boundary: String) -> Data {
        var body = Data()
        func binaryPart(_ name: String, type: String, _ bytes: Data, first: Bool) {
            let lead = first ? "" : "\r\n"
            body.append(Data("\(lead)--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\nContent-Type: \(type)\r\nContent-Transfer-Encoding: binary\r\n\r\n".utf8))
            body.append(bytes)
        }

        binaryPart(Field.archive, type: "application/zip", upload.archive, first: true)
        if let signature = upload.archiveSignature {
            binaryPart(Field.archiveSignature, type: "application/octet-stream", signature, first: false)
        }
        if let metadata = upload.metadata {
            body.append(Data("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"\(Field.metadata)\"\r\nContent-Type: application/json\r\n\r\n".utf8))
            body.append(metadata)
            if let signature = upload.metadataSignature {
                binaryPart(Field.metadataSignature, type: "application/octet-stream", signature, first: false)
            }
        }
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    /// The `detail` of an RFC 7807 problem, else the start of the body.
    private static func problem(in body: Data) -> String {
        struct Problem: Decodable {
            let detail: String?
        }
        if let detail = (try? JSONDecoder().decode(Problem.self, from: body))?.detail {
            return detail
        }
        return String(decoding: body.prefix(300), as: UTF8.self)
    }
}

/// The `Authorization` header SwiftPM sends a registry for a credential.
enum RegistryAuthorization {
    /// The configured type, or by default basic auth (bearer when the login is `token`).
    static func header(for credential: Credential, authentication: RegistryAuthentication?) -> String {
        let basic = "Basic " + Data("\(credential.login):\(credential.password)".utf8).base64EncodedString()
        let bearer = "Bearer " + credential.password

        switch authentication {
        case .basic:
            return basic
        case .token:
            return bearer
        case nil:
            return credential.login == RegistryCredentials.tokenLogin ? bearer : basic
        }
    }
}
