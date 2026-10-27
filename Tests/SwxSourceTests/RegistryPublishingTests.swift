import Foundation
@testable import SwxSource
import Testing

struct RegistryPublishingTests {
    /// SwiftPM's layout exactly: binary parts with a transfer encoding, the metadata part
    /// running straight into the next boundary's CRLF.
    @Test func laysOutTheBodyAsSwiftPMDoes() {
        let upload = ReleaseUpload(archive: Data("ZIP".utf8), archiveSignature: Data("SIG".utf8), metadata: Data("{}".utf8), metadataSignature: Data("MSIG".utf8))
        let body = String(decoding: RegistryPublisher.body(upload, boundary: "B", metadataEncoding: .unlabeled), as: UTF8.self)
        let expected = "--B\r\nContent-Disposition: form-data; name=\"source-archive\"\r\nContent-Type: application/zip\r\nContent-Transfer-Encoding: binary\r\n\r\nZIP"
            + "\r\n--B\r\nContent-Disposition: form-data; name=\"source-archive-signature\"\r\nContent-Type: application/octet-stream\r\nContent-Transfer-Encoding: binary\r\n\r\nSIG"
            + "\r\n--B\r\nContent-Disposition: form-data; name=\"metadata\"\r\nContent-Type: application/json\r\n\r\n{}"
            + "\r\n--B\r\nContent-Disposition: form-data; name=\"metadata-signature\"\r\nContent-Type: application/octet-stream\r\nContent-Transfer-Encoding: binary\r\n\r\nMSIG"
            + "\r\n--B--\r\n"
        #expect(body == expected)
    }

    @Test func leavesOutWhatIsMissing() {
        let upload = ReleaseUpload(archive: Data("ZIP".utf8), archiveSignature: nil, metadata: nil, metadataSignature: nil)
        let body = String(decoding: RegistryPublisher.body(upload, boundary: "B", metadataEncoding: .unlabeled), as: UTF8.self)
        #expect(body == "--B\r\nContent-Disposition: form-data; name=\"source-archive\"\r\nContent-Type: application/zip\r\nContent-Transfer-Encoding: binary\r\n\r\nZIP\r\n--B--\r\n")
    }

    /// SwiftPM before 6.4 labels the metadata part.
    @Test func labelsMetadataAsOlderSwiftPMDoes() {
        let upload = ReleaseUpload(archive: Data("ZIP".utf8), archiveSignature: nil, metadata: Data("{}".utf8), metadataSignature: nil)
        let body = String(decoding: RegistryPublisher.body(upload, boundary: "B", metadataEncoding: .quotedPrintableLabel), as: UTF8.self)
        #expect(body.contains("name=\"metadata\"\r\nContent-Type: application/json\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n{}\r\n--B--"))
    }

    @Test func refusesAKeyWithoutCertificates() {
        #expect(throws: SourceError.self) { try RegistrySigner(privateKey: Data(), chain: []) }
        #expect(throws: SourceError.self) { try RegistrySigner(privateKey: Data([1, 2, 3]), chain: [Data([4])]) }
    }
}
