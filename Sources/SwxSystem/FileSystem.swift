import Foundation

/// Small file-system helpers used by the shell layers.
public enum FileSystem {
    public static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    public static func createDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    public static func read(_ url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    public static func readIfPresent(_ url: URL) -> Data? {
        try? Data(contentsOf: url)
    }

    /// Writes via a temporary file and rename, so readers never see a partial file.
    public static func writeAtomically(_ data: Data, to url: URL) throws {
        try Self.createDirectory(url.deletingLastPathComponent())
        try data.write(to: url, options: .atomic)
    }

    /// Removes a tree, first restoring write permission (store trees are read-only).
    public static func removeTree(_ url: URL) throws {
        guard Self.exists(url) else { return }
        Self.makeWritable(url)
        try FileManager.default.removeItem(at: url)
    }

    public static func makeWritable(_ url: URL) {
        Self.setWritable(url, permission: .writable)
    }

    public static func makeReadOnly(_ url: URL) {
        Self.setWritable(url, permission: .readOnly)
    }

    public static func makeTemporaryDirectory(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try Self.createDirectory(url)
        return url
    }

    /// Moves `source` to `destination`, tolerating a concurrent writer that got there first.
    public static func moveIntoPlace(_ source: URL, _ destination: URL) throws {
        try Self.createDirectory(destination.deletingLastPathComponent())
        do {
            try FileManager.default.moveItem(at: source, to: destination)
        } catch where Self.exists(destination) {
            // Another process published the same content-addressed entry; ours is redundant.
            try? Self.removeTree(source)
        }
    }

    // MARK: Permissions

    private enum WritePermission {
        case writable
        case readOnly
    }

    private static let ownerWriteBit: Int = 0o200

    /// Toggles the owner-write bit on every regular file under `url`.
    private static func setWritable(_ url: URL, permission: WritePermission) {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return
        }
        for case let file as URL in enumerator {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
                  let mode = attributes[.posixPermissions] as? Int else {
                continue
            }
            let updated: Int
            switch permission {
            case .writable:
                updated = mode | Self.ownerWriteBit
            case .readOnly:
                updated = mode & ~Self.ownerWriteBit
            }
            guard updated != mode else { continue }
            try? FileManager.default.setAttributes([.posixPermissions: updated], ofItemAtPath: file.path)
        }
    }
}
