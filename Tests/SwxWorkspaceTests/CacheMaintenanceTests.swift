import Foundation
@testable import SwxWorkspace
import Testing

struct CacheMaintenanceTests {
    @Test func groupsRemoteKeysByKind() {
        #expect(RemoteCacheSection(key: "v1/trees/abc.tar.gz") == .trees)
        #expect(RemoteCacheSection(key: "v1/builds/k.tar.gz") == .builds)
        #expect(RemoteCacheSection(key: "v1/tests/k") == .tests)
        #expect(RemoteCacheSection(key: "notes.txt") == .other)
        #expect(RemoteCacheSection(key: "v1/unknown/x") == .other)
    }

    /// Only old files swx wrote are deleted; a dry run deletes nothing.
    @Test func prunesOldRemoteFiles() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let old = Date().addingTimeInterval(-40 * 24 * 60 * 60)
        for key in ["v1/trees/old.tar.gz", "v1/trees/new.tar.gz", "v1/tests/old", "notes.txt"] {
            let file = base.appendingPathComponent(key)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 1, count: 5).write(to: file)
            if key.contains("old") || key == "notes.txt" {
                try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file.path)
            }
        }
        let maintenance = CacheMaintenance(cacheDirectory: base.appendingPathComponent("store"))
        let month: TimeInterval = 30 * 24 * 60 * 60

        let preview = try await maintenance.pruneRemote(base.path, unusedFor: month, effect: .dryRun)
        #expect(preview.entries == 2)
        #expect(preview.bytes == 10)
        #expect(preview.kept == 2)
        #expect(FileManager.default.fileExists(atPath: base.appendingPathComponent("v1/trees/old.tar.gz").path))

        _ = try await maintenance.pruneRemote(base.path, unusedFor: month, effect: .apply)
        let remaining = try await maintenance.remoteSizes(base.path)
        #expect(remaining.map(\.section) == [.trees, .other])
        #expect(FileManager.default.fileExists(atPath: base.appendingPathComponent("notes.txt").path))
    }
}
