import Foundation

#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif

/// Small file-system helpers used by the shell layers.
public enum FileSystem {
    private static let separator = "/"
    private static let currentDirectoryComponent: Substring = "."
    private static let parentDirectoryComponent: Substring = ".."

    /// Collapses `.` and `..` lexically, like SwiftPM's `AbsolutePath`.
    ///
    /// Unlike Foundation's `standardizedFileURL`, symlinks are left alone and `/private` is kept,
    /// so paths written to SwiftPM's files match what SwiftPM itself writes.
    public static func normalize(_ path: String, relativeTo base: String) -> String {
        let joined = path.hasPrefix(Self.separator) ? path : base + Self.separator + path
        var components: [Substring] = []
        for component in joined.split(separator: "/") {
            switch component {
            case Self.currentDirectoryComponent:
                continue
            case Self.parentDirectoryComponent:
                _ = components.popLast()
            default:
                components.append(component)
            }
        }
        return Self.separator + components.joined(separator: Self.separator)
    }

    /// The path with every symlink resolved (`realpath`), as `getcwd` reports it.
    ///
    /// Foundation's `resolvingSymlinksInPath` strips `/private` again; this keeps it.
    public static func realPath(_ url: URL) -> URL {
        guard let resolved = realpath(url.path, nil) else { return url }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    /// A user-supplied path made absolute against the working directory, lexically.
    public static func absoluteURL(_ path: String) -> URL {
        URL(fileURLWithPath: Self.normalize(path, relativeTo: FileManager.default.currentDirectoryPath))
    }

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

    /// Renames `source` over `destination` in one step (`rename(2)`), replacing a file already
    /// there. Foundation's `replaceItemAt` needs an existing destination on Linux.
    public static func replace(_ destination: URL, with source: URL) throws {
        guard rename(source.path, destination.path) == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path, NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)])
        }
    }

    /// The bytes of every regular file under `url` (or of `url` itself), symlinks not followed.
    /// Clones share blocks on disk, so this is what the files hold, not what the disk lost.
    public static func size(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard Self.isDirectory(url) else {
            return Int64((try? url.resourceValues(forKeys: Set(keys)).fileSize) ?? 0)
        }
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else {
            return 0
        }

        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    /// When `url` was last modified; `nil` when it doesn't exist.
    public static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Creates `url` empty, or moves its modification date to now.
    public static func touch(_ url: URL, at date: Date = Date()) throws {
        guard Self.exists(url) else {
            try Self.writeAtomically(Data(), to: url)
            return
        }
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
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
