import Foundation

/// Reports edited files by comparing their size, modification time and identity a few times a
/// second: editors that save by replacing the file are seen too, and nothing is platform-specific.
/// Watched directories report files with the watched extension being added or removed (not their
/// modification time, which every atomic save bumps).
public struct SourceWatcher: Sendable {
    private let files: [String]
    private let directories: [String]
    private let fileExtension: String

    private static let interval = Duration.milliseconds(200)
    /// Changes are reported once nothing moved for this long, so a save in several writes counts once.
    private static let settling = Duration.milliseconds(150)

    public init(files: [URL], directories: [URL], fileExtension: String) {
        self.files = files.map(\.path)
        self.directories = directories.map(\.path)
        self.fileExtension = fileExtension
    }

    private enum Stamp: Equatable {
        case file(size: Int64, modified: TimeInterval, inode: UInt64)
        case listing([String])
    }

    /// Each element lists the files (or directories) that changed since the previous one.
    public func changes() -> AsyncStream<[URL]> {
        let watcher = self
        return AsyncStream { continuation in
            let task = Task {
                var known = watcher.stamps()
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.interval)
                    var current = watcher.stamps()
                    guard current != known else { continue }

                    // Wait for the save to finish before reporting it.
                    while !Task.isCancelled {
                        try? await Task.sleep(for: Self.settling)
                        let settled = watcher.stamps()
                        if settled == current { break }
                        current = settled
                    }
                    let changed = Set(known.keys).union(current.keys).filter { known[$0] != current[$0] }
                    known = current
                    continuation.yield(changed.sorted().map { URL(fileURLWithPath: $0) })
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Missing files have no stamp, so deleting or creating one is a change.
    private func stamps() -> [String: Stamp] {
        var stamps: [String: Stamp] = [:]
        for path in self.files {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { continue }
            stamps[path] = .file(
                size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
                modified: (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
                inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            )
        }
        for path in self.directories {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
            stamps[path] = .listing(names.filter { ($0 as NSString).pathExtension == self.fileExtension }.sorted())
        }
        return stamps
    }
}
