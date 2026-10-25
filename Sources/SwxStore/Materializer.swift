import Foundation
import SwxSystem

#if canImport(Darwin)
import Darwin
#endif

/// How a store tree is placed into a project's `.build/checkouts`.
public enum MaterializeStrategy: Sendable, CustomStringConvertible {
    /// Copy-on-write clone (APFS `clonefile`): instant and takes no extra space.
    case clone
    /// Copy-on-write per file where the file system supports it (`cp --reflink=auto`: Btrfs, XFS).
    case reflink
    /// A plain recursive copy.
    case copy

    public var description: String {
        switch self {
        case .clone:
            return "clone"
        case .reflink:
            return "cp --reflink=auto"
        case .copy:
            return "copy"
        }
    }
}

/// Places immutable store trees at project-local paths.
public enum Materializer {
    #if canImport(Darwin)
    private static let cloneFlags: UInt32 = 0
    #endif

    /// Replaces `destination` with a copy of `source`, preferring copy-on-write.
    @discardableResult
    public static func materialize(_ source: URL, at destination: URL) throws -> MaterializeStrategy {
        try FileSystem.removeTree(destination)
        try FileSystem.createDirectory(destination.deletingLastPathComponent())

        // Try a copy-on-write clone of the whole directory first.
        if Self.cloneTree(source, to: destination) {
            return .clone
        }

        // Linux: GNU cp shares extents on CoW file systems and copies elsewhere.
        if Self.reflinkTree(source, to: destination) {
            return .reflink
        }

        // Fall back to a regular copy (different volume, or a file system without clones).
        try FileManager.default.copyItem(at: source, to: destination)
        return .copy
    }

    #if os(Linux)
    private static let copyCommand = "/bin/cp"
    private static let reflinkArguments = ["-a", "--reflink=auto"]
    #endif

    private static func reflinkTree(_ source: URL, to destination: URL) -> Bool {
        #if os(Linux)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.copyCommand)
        process.arguments = Self.reflinkArguments + [source.path, destination.path]
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
        #else
        return false
        #endif
    }

    private static func cloneTree(_ source: URL, to destination: URL) -> Bool {
        #if canImport(Darwin)
        return clonefile(source.path, destination.path, Self.cloneFlags) == 0
        #else
        return false
        #endif
    }
}
