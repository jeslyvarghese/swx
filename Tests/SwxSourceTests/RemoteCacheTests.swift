import Foundation
@testable import SwxSource
import SwxStore
import Testing

struct OSVNameTests {
    /// Every spelling of a GitHub URL becomes OSV's `github.com/owner/repo`.
    @Test func normalizesURLSpellings() {
        #expect(OSV.packageName(forURL: "https://github.com/apple/swift-nio.git") == "github.com/apple/swift-nio")
        #expect(OSV.packageName(forURL: "https://github.com/apple/swift-nio/") == "github.com/apple/swift-nio")
        #expect(OSV.packageName(forURL: "git@github.com:apple/swift-nio.git") == "github.com/apple/swift-nio")
        #expect(OSV.packageName(forURL: "https://user@github.com/apple/swift-nio") == "github.com/apple/swift-nio")
        #expect(OSV.packageName(forURL: "ssh://git@github.com/apple/swift-nio.git") == "github.com/apple/swift-nio")
        #expect(OSV.packageName(forURL: "swift-nio") == nil)
    }
}

struct RemoteStorageTests {
    @Test func picksBackendsByScheme() throws {
        #expect(try RemoteStorages.make("file:///tmp/cache") is DirectoryStorage)
        #expect(try RemoteStorages.make("/tmp/cache") is DirectoryStorage)
        #expect(try RemoteStorages.make("https://cache.example.com/swx") is HTTPStorage)
        #expect(throws: RemoteStorageError.self) { try RemoteStorages.make("s3://bucket/prefix", environment: [:]) }
        #expect(throws: RemoteStorageError.self) { try RemoteStorages.make("ftp://example.com") }
    }

    /// SigV4 headers have the documented shape; path-style on custom endpoints, virtual-hosted on AWS.
    @Test func signsS3Requests() throws {
        let environment = ["AWS_ACCESS_KEY_ID": "AKID", "AWS_SECRET_ACCESS_KEY": "secret", "AWS_REGION": "eu-west-1"]
        let aws = try #require(try RemoteStorages.make("s3://bucket/ci", environment: environment) as? S3Storage)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let (url, headers) = aws.signed("GET", key: "v1/trees/abc.tar.gz", date: date)
        #expect(url.absoluteString == "https://bucket.s3.eu-west-1.amazonaws.com/ci/v1/trees/abc.tar.gz")
        #expect(headers["x-amz-date"] == "20231114T221320Z")
        #expect(headers["x-amz-content-sha256"] == "UNSIGNED-PAYLOAD")
        let authorization = try #require(headers["Authorization"])
        #expect(authorization.hasPrefix("AWS4-HMAC-SHA256 Credential=AKID/20231114/eu-west-1/s3/aws4_request, SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature="))

        // The same request signs identically; another key signs differently.
        #expect(aws.signed("GET", key: "v1/trees/abc.tar.gz", date: date).1["Authorization"] == authorization)
        #expect(aws.signed("GET", key: "v1/trees/abd.tar.gz", date: date).1["Authorization"] != authorization)

        var custom = environment
        custom["SWX_S3_ENDPOINT"] = "http://127.0.0.1:9000"
        let minio = try #require(try RemoteStorages.make("s3://bucket", environment: custom) as? S3Storage)
        #expect(minio.signed("PUT", key: "v1/tests/k", date: date).0.absoluteString == "http://127.0.0.1:9000/bucket/v1/tests/k")
    }
}

struct StoreEntryTests {
    @Test func keysEntriesStably() {
        #expect(StoreEntry.sourceTree(revision: "abc").remoteKey == "v1/trees/abc.tar.gz")
        #expect(StoreEntry.revisionManifests(revision: "abc").remoteKey == "v1/revisions/abc.json")
        #expect(StoreEntry.artifact(checksum: "f00").remoteKey == "v1/artifacts/f00.tar.gz")
        #expect(StoreEntry.testResult(key: "k").remoteKey == "v1/tests/k")
    }

    /// Packing a tree and unpacking it into another store gives the same files, read-only.
    @Test func roundTripsDirectories() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let source = Store(root: base.appendingPathComponent("a"))
        let destination = Store(root: base.appendingPathComponent("b"))

        let tree = source.localPath(of: .sourceTree(revision: "r1"))
        try FileManager.default.createDirectory(at: tree.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try Data("let x = 1\n".utf8).write(to: tree.appendingPathComponent("Sources/x.swift"))

        let archive = try await source.pack(.sourceTree(revision: "r1"))
        try await destination.unpack(.sourceTree(revision: "r1"), from: archive)
        let copied = destination.localPath(of: .sourceTree(revision: "r1")).appendingPathComponent("Sources/x.swift")
        #expect(try String(contentsOf: copied, encoding: .utf8) == "let x = 1\n")
        // Check the mode bits: CI's Linux container runs as root, for whom every file is writable.
        let mode = try #require(try FileManager.default.attributesOfItem(atPath: copied.path)[.posixPermissions] as? Int)
        let writeBits = 0o222
        #expect(mode & writeBits == 0)

        // Unpacked trees are read-only; make them writable again so the test can clean up.
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: copied.deletingLastPathComponent().path)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: copied.deletingLastPathComponent().deletingLastPathComponent().path)
    }
}
