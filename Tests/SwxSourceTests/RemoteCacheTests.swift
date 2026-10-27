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

struct StoreMaintenanceTests {
    private static let day: TimeInterval = 24 * 60 * 60

    /// Pinned trees stay however old; unpinned ones go once unused for the age; a stamp counts as use.
    @Test func prunesWhatNothingPinsOrUsed() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = Store(root: base.appendingPathComponent("store"))
        let now = Date()
        let old = now.addingTimeInterval(-40 * Self.day)

        // Three old trees, a fresh scratch directory and an old one.
        for revision in ["pinned", "unused", "stamped"] {
            let tree = store.sourceTreePath(revision: revision)
            try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
            try Data(repeating: 1, count: 10).write(to: tree.appendingPathComponent("file"))
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: tree.path)
        }
        let freshScratch = try store.makeTemporaryDirectory()
        let oldScratch = try store.makeTemporaryDirectory()
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: oldScratch.path)

        // One live project pins a tree; another's Package.resolved is gone.
        let resolved = base.appendingPathComponent("Package.resolved")
        try Data().write(to: resolved)
        try store.recordProject(StoreProject(resolvedFile: resolved.path, revisions: ["pinned"], repositories: []))
        try store.recordProject(StoreProject(resolvedFile: base.appendingPathComponent("gone/Package.resolved").path, revisions: ["unused"], repositories: []))
        store.markUsed(store.sourceTreePath(revision: "stamped").appendingPathComponent("file"))

        // A dry run reports without removing.
        let preview = try store.prune(unusedFor: 30 * Self.day, effect: .dryRun, now: now)
        #expect(preview.removed[.sourceTrees]?.entries == 1)
        #expect(preview.removed[.sourceTrees]?.bytes == 10)
        #expect(preview.removed[.temporary]?.entries == 1)
        #expect(preview.forgottenProjects == 1)
        #expect(FileManager.default.fileExists(atPath: store.sourceTreePath(revision: "unused").path))

        let report = try store.prune(unusedFor: 30 * Self.day, effect: .apply, now: now)
        #expect(report == preview)
        #expect(FileManager.default.fileExists(atPath: store.sourceTreePath(revision: "pinned").path))
        #expect(FileManager.default.fileExists(atPath: store.sourceTreePath(revision: "stamped").path))
        #expect(!FileManager.default.fileExists(atPath: store.sourceTreePath(revision: "unused").path))
        #expect(FileManager.default.fileExists(atPath: freshScratch.path))
        #expect(!FileManager.default.fileExists(atPath: oldScratch.path))

        // The forgotten project is gone for good.
        #expect(try store.prune(unusedFor: 30 * Self.day, effect: .dryRun, now: now).forgottenProjects == 0)
    }

    /// A repository is kept by its URL, whatever name it was cloned under.
    @Test func keepsRepositoriesOfPinnedURLs() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = Store(root: base.appendingPathComponent("store"))
        let old = Date().addingTimeInterval(-40 * Self.day)

        let kept = store.repositoryPath(for: "https://example.com/a.git", name: "a")
        let dropped = store.repositoryPath(for: "https://example.com/b.git", name: "b")
        for repository in [kept, dropped] {
            try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: repository.path)
        }
        let resolved = base.appendingPathComponent("Package.resolved")
        try Data().write(to: resolved)
        try store.recordProject(StoreProject(resolvedFile: resolved.path, revisions: [], repositories: ["https://example.com/a.git"]))

        _ = try store.prune(unusedFor: 30 * Self.day, effect: .apply)
        #expect(FileManager.default.fileExists(atPath: kept.path))
        #expect(!FileManager.default.fileExists(atPath: dropped.path))
    }

    @Test func sizesSections() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = Store(root: base)
        let tree = store.sourceTreePath(revision: "r")
        try FileManager.default.createDirectory(at: tree.appendingPathComponent("a"), withIntermediateDirectories: true)
        try Data(repeating: 0, count: 100).write(to: tree.appendingPathComponent("a/b"))
        try Data(repeating: 0, count: 50).write(to: tree.appendingPathComponent("c"))

        let trees = try #require(store.sizes().first { $0.section == .sourceTrees })
        #expect(trees.entries == 1)
        #expect(trees.bytes == 150)
    }
}

struct RemoteListingTests {
    /// A directory remote lists what was uploaded (not staging files) and deletes by key.
    @Test func listsAndDeletesInDirectories() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let remote = try RemoteStorages.make(base.path)
        let file = base.appendingPathComponent("upload")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 12).write(to: file)

        try await remote.upload(file, as: "v1/trees/a.tar.gz")
        try await remote.upload(file, as: "v1/tests/k")
        try Data().write(to: base.appendingPathComponent("v1/trees/.staging"))
        let keys = try await remote.list(prefix: "v1/").map(\.key)
        #expect(keys == ["v1/tests/k", "v1/trees/a.tar.gz"])
        #expect(try await remote.list(prefix: "v1/trees").first?.bytes == 12)

        try await remote.delete("v1/tests/k")
        #expect(try await remote.list(prefix: "v1/").map(\.key) == ["v1/trees/a.tar.gz"])
    }

    /// ListObjectsV2 pages: keys (escaped), sizes, dates and the continuation token.
    @Test func parsesS3Listings() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Name>bucket</Name><Prefix>ci/</Prefix><KeyCount>2</KeyCount><IsTruncated>true</IsTruncated>\
        <Contents><Key>ci/v1/trees/a&amp;b.tar.gz</Key><LastModified>2026-10-01T10:00:00.000Z</LastModified><ETag>&quot;x&quot;</ETag><Size>2048</Size><StorageClass>STANDARD</StorageClass></Contents>\
        <Contents><Key>ci/v1/tests/k</Key><LastModified>2026-10-02T10:00:00Z</LastModified><Size>0</Size></Contents>\
        <NextContinuationToken>1ueGcxLPRx1Tr/XYExHnhbYLgveDs2J/wm36Hy4vbOwM=</NextContinuationToken></ListBucketResult>
        """
        let page = S3Storage.parseListing(xml)
        #expect(page.objects.map(\.key) == ["ci/v1/trees/a&b.tar.gz", "ci/v1/tests/k"])
        #expect(page.objects.map(\.bytes) == [2048, 0])
        #expect(page.objects[0].modified == Date(timeIntervalSince1970: 1_790_848_800))
        #expect(page.objects[1].modified == Date(timeIntervalSince1970: 1_790_935_200))
        #expect(page.nextToken == "1ueGcxLPRx1Tr/XYExHnhbYLgveDs2J/wm36Hy4vbOwM=")
        #expect(S3Storage.parseListing("<ListBucketResult></ListBucketResult>").nextToken == nil)
    }

    /// Listing signs the query: sorted, strictly encoded, and the bucket path without a key.
    @Test func signsListingQueries() throws {
        let environment = ["AWS_ACCESS_KEY_ID": "AKID", "AWS_SECRET_ACCESS_KEY": "secret", "AWS_REGION": "eu-west-1"]
        let aws = try #require(try RemoteStorages.make("s3://bucket/ci", environment: environment) as? S3Storage)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let (url, headers) = aws.signed("GET", key: "", query: [("prefix", "ci/v1/"), ("list-type", "2")], date: date)
        #expect(url.absoluteString == "https://bucket.s3.eu-west-1.amazonaws.com/?list-type=2&prefix=ci%2Fv1%2F")
        #expect(headers["Authorization"] != aws.signed("GET", key: "", date: date).1["Authorization"])
    }
}
