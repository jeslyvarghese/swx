import Foundation
import SwxSystem

/// Builds the agent for an app's SDK and target, once: it's kept in the store by a key of its
/// source, the target and the SDK.
public enum HotReloadAgent {
    /// The variables that make an app load the agent and find swx.
    public enum Variable {
        public static let insertLibraries = "DYLD_INSERT_LIBRARIES"
        public static let port = "SWX_HOT_PORT"
    }

    private enum Layout {
        static let prefix = "agent-"
        static let sourceExtension = "c"
        static let libraryExtension = "dylib"
    }

    /// The agent uses the Objective-C runtime (to redraw) and binds AttributeGraph lazily
    /// (SwiftUI's, when the app has it).
    private static let linkerFlags = ["-lobjc", "-Wl,-undefined,dynamic_lookup"]

    /// The agent dylib for code compiled with `-target target -sdk sdk`.
    public static func library(target: String, sdk: String, in directory: URL) async throws -> URL {
        let sdkStamp = (try? FileManager.default.attributesOfItem(atPath: sdk)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = StableHash.hex([AgentSource.text, target, sdk, String(sdkStamp)])
        let library = directory.appendingPathComponent(Layout.prefix + key).appendingPathExtension(Layout.libraryExtension)
        guard !FileSystem.exists(library) else { return library }

        // Compile next to the result, then move it in place: a half-written agent is never used.
        try FileSystem.createDirectory(directory)
        let source = directory.appendingPathComponent(Layout.prefix + key + "-" + UUID().uuidString).appendingPathExtension(Layout.sourceExtension)
        let output = source.deletingPathExtension().appendingPathExtension(Layout.libraryExtension)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: output)
        }
        try FileSystem.writeAtomically(Data(AgentSource.text.utf8), to: source)
        let result = try await ProcessRunner.run(
            ["xcrun", "clang", "-dynamiclib", "-target", target, "-isysroot", sdk] + Self.linkerFlags + [source.path, "-o", output.path],
            exitPolicy: .allowFailure
        )
        guard result.succeeded else {
            throw HotReloadError(description: "could not build the hot reload agent for \(target): \(result.errorOutput)")
        }
        try? FileManager.default.moveItem(at: output, to: library)
        return library
    }
}

public struct HotReloadError: Error, CustomStringConvertible {
    public let description: String
}

/// FNV-1a: a hash that, unlike `Hasher`, is the same in every run.
enum StableHash {
    private static let offsetBasis: UInt64 = 0xcbf2_9ce4_8422_2325
    private static let prime: UInt64 = 0x100_0000_01b3
    private static let separator: UInt8 = 0

    static func hex(_ parts: [String]) -> String {
        var hash = Self.offsetBasis
        for part in parts {
            for byte in part.utf8 + [Self.separator] {
                hash = (hash ^ UInt64(byte)) &* Self.prime
            }
        }
        return String(hash, radix: 16)
    }
}
