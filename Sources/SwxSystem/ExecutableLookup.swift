import Foundation

/// Cheap facts about which `swift` will run, used to avoid spawning `swift --version` repeatedly.
public enum ExecutableLookup {
    private enum Environment {
        static let path = "PATH"
        static let developerDirectory = "DEVELOPER_DIR"
        static let toolchains = "TOOLCHAINS"
    }

    private static let pathSeparator: Character = ":"
    /// Where `xcode-select -s` records the active Xcode.
    private static let xcodeSelectLink = "/var/db/xcode_select_link"

    /// The first executable named `name` on PATH.
    public static func find(_ name: String) -> URL? {
        let path = ProcessInfo.processInfo.environment[Environment.path] ?? ""
        for directory in path.split(separator: Self.pathSeparator) {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// Changes whenever a different `swift` would run: binary, its mtime, and Xcode selection.
    public static func fingerprint(of name: String) -> String {
        let environment = ProcessInfo.processInfo.environment
        let binary = Self.find(name)?.resolvingSymlinksInPath()
        let modified = binary
            .flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date }
            .map { String($0.timeIntervalSince1970) } ?? ""
        let xcode = (try? FileManager.default.destinationOfSymbolicLink(atPath: Self.xcodeSelectLink)) ?? ""

        return [
            binary?.path ?? "",
            modified,
            environment[Environment.developerDirectory] ?? "",
            environment[Environment.toolchains] ?? "",
            xcode,
        ].joined(separator: "\u{0}")
    }
}
