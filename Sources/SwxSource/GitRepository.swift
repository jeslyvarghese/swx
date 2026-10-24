import Foundation
import SwxStore
import SwxSystem

/// A remote ref as reported by `git ls-remote`.
struct RemoteTag: Sendable, Hashable {
    let name: String
    /// The commit the tag points to (annotated tags are peeled).
    let revision: String
}

/// Thin wrappers over the `git` CLI for one bare, blobless repository in the store.
///
/// Blobless clones (`--filter=blob:none`) download every commit and tree but no file
/// contents, so listing files at any tag is local, and blobs are fetched in batches only
/// when needed (manifests during resolution, whole trees on checkout).
struct GitRepository: Sendable {
    private enum Git {
        static let executable = "git"
        static let tagsPrefix = "refs/tags/"
        static let headsPrefix = "refs/heads/"
        static let peeledSuffix = "^{}"
        static let blobFilter = "--filter=blob:none"
        static let noLazyFetchVariable = "GIT_NO_LAZY_FETCH"
        static let indexFileVariable = "GIT_INDEX_FILE"
        static let terminalPromptVariable = "GIT_TERMINAL_PROMPT"
        static let missingMarker = "missing"
        static let blobType = "blob"
        static let indexFileName = "swx-export.index"
    }

    /// Never block on credential prompts; fail fast instead.
    private static let nonInteractive = [Git.terminalPromptVariable: "0"]

    let url: String
    let path: URL

    // MARK: Remote queries

    /// Lists tags without cloning: one request to the server.
    static func listRemoteTags(url: String) async throws -> [RemoteTag] {
        let result = try await ProcessRunner.run([Git.executable, "ls-remote", "--tags", url], environment: Self.nonInteractive)
        return Self.parseTags(result.output)
    }

    static func resolveRemoteBranch(url: String, branch: String) async throws -> String? {
        let result = try await ProcessRunner.run(
            [Git.executable, "ls-remote", url, Git.headsPrefix + branch],
            environment: Self.nonInteractive
        )
        return result.output.split(separator: "\t").first.map(String.init)
    }

    /// Parses `ls-remote --tags` output, preferring peeled (`^{}`) commits for annotated tags.
    static func parseTags(_ output: String) -> [RemoteTag] {
        var direct: [String: String] = [:]
        var peeled: [String: String] = [:]
        var order: [String] = []

        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 1)
            guard fields.count == 2, fields[1].hasPrefix(Git.tagsPrefix) else { continue }
            let revision = String(fields[0])
            var name = String(fields[1].dropFirst(Git.tagsPrefix.count))

            // `refs/tags/1.0.0^{}` carries the commit behind an annotated tag.
            if name.hasSuffix(Git.peeledSuffix) {
                name.removeLast(Git.peeledSuffix.count)
                peeled[name] = revision
                continue
            }
            if direct[name] == nil {
                order.append(name)
            }
            direct[name] = revision
        }

        return order.map { RemoteTag(name: $0, revision: peeled[$0] ?? direct[$0]!) }
    }

    // MARK: Local repository

    var exists: Bool {
        FileSystem.isDirectory(self.path)
    }

    /// Creates the blobless bare clone, publishing it atomically.
    func clone(using store: Store) async throws {
        let staging = try store.makeTemporaryDirectory().appendingPathComponent(self.path.lastPathComponent)
        try await ProcessRunner.run(
            [Git.executable, "clone", "--bare", "--quiet", Git.blobFilter, self.url, staging.path],
            environment: Self.nonInteractive
        )
        try FileSystem.moveIntoPlace(staging, self.path)
    }

    /// Fetches new commits and tags (still without blobs).
    func fetch() async throws {
        try await self.git(["fetch", "--quiet", "--tags", "--force", Git.blobFilter, "origin"])
    }

    /// The subset of `revisions` whose commits are not in the local repository.
    func missingCommits(_ revisions: [String]) async throws -> [String] {
        let unique = Array(Set(revisions))
        guard !unique.isEmpty else { return [] }

        // One batch query; output lines come back in input order.
        let result = try await self.git(
            ["cat-file", "--batch-check"],
            input: unique.map { "\($0)^{commit}" },
            environment: [Git.noLazyFetchVariable: "1"]
        )
        let lines = result.output.split(separator: "\n", omittingEmptySubsequences: false)
        return zip(unique, lines).compactMap { revision, line in
            line.hasSuffix(Git.missingMarker) ? revision : nil
        }
    }

    /// `name → blob id` for the files at the root of `revision`.
    func rootFiles(at revision: String) async throws -> [String: String] {
        let result = try await self.git(["ls-tree", revision])
        var files: [String: String] = [:]

        // Lines look like `100644 blob <sha>\t<name>`.
        for line in result.output.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let meta = parts[0].split(separator: " ")
            guard meta.count == 3, meta[1] == Git.blobType else { continue }
            files[String(parts[1])] = String(meta[2])
        }
        return files
    }

    /// Reads blobs, downloading the missing ones in a single batched request.
    func readBlobs(_ ids: [String]) async throws -> [String: Data] {
        let unique = Array(Set(ids))
        guard !unique.isEmpty else { return [:] }

        // Find which blobs are not local yet (without triggering one-by-one lazy fetches).
        let check = try await self.git(
            ["cat-file", "--batch-check"],
            input: unique,
            environment: [Git.noLazyFetchVariable: "1"]
        )
        let missing = check.output.split(separator: "\n").compactMap { line -> String? in
            let fields = line.split(separator: " ")
            return fields.count == 2 && fields[1] == Git.missingMarker ? String(fields[0]) : nil
        }

        // One round trip for everything missing.
        if !missing.isEmpty {
            try await self.git(
                ["-c", "fetch.negotiationAlgorithm=noop", "fetch", "--quiet", "--no-tags", "--no-write-fetch-head",
                 "--recurse-submodules=no", Git.blobFilter, "--stdin", "origin"],
                input: missing
            )
        }

        // Read them all through one `cat-file --batch`.
        let contents = try await self.git(["cat-file", "--batch"], input: unique)
        return Self.parseBatch(contents.standardOutput)
    }

    /// Writes the full tree at `revision` into `destination` (blobs are prefetched in bulk).
    func export(revision: String, to destination: URL) async throws {
        try FileSystem.createDirectory(destination)
        let index = destination.deletingLastPathComponent().appendingPathComponent(Git.indexFileName)
        defer { try? FileManager.default.removeItem(at: index) }

        // A private index file keeps concurrent exports of the same repository independent.
        try await ProcessRunner.run(
            [Git.executable, "--git-dir=\(self.path.path)", "--work-tree=\(destination.path)", "read-tree", "-u", "--reset", revision],
            environment: Self.nonInteractive.merging([Git.indexFileVariable: index.path]) { $1 }
        )
    }

    // MARK: Helpers

    @discardableResult
    private func git(
        _ arguments: [String],
        input: [String]? = nil,
        environment: [String: String] = [:],
        exitPolicy: ExitPolicy = .requireSuccess
    ) async throws -> ProcessResult {
        let command = [Git.executable, "--git-dir=\(self.path.path)"] + arguments
        let stdin = input.map { Data(($0.joined(separator: "\n") + "\n").utf8) }
        return try await ProcessRunner.run(
            command,
            environment: Self.nonInteractive.merging(environment) { $1 },
            input: stdin,
            exitPolicy: exitPolicy
        )
    }

    /// Parses `cat-file --batch` output: `<id> <type> <size>\n<bytes>\n` repeated.
    static func parseBatch(_ data: Data) -> [String: Data] {
        var result: [String: Data] = [:]
        let bytes = [UInt8](data)
        var cursor = 0
        let newline = UInt8(ascii: "\n")

        while cursor < bytes.count {
            // Header line.
            guard let headerEnd = bytes[cursor...].firstIndex(of: newline) else { break }
            let header = String(decoding: bytes[cursor..<headerEnd], as: UTF8.self).split(separator: " ")
            cursor = headerEnd + 1
            guard header.count == 3, let size = Int(header[2]) else { continue }

            // Body, then the trailing newline.
            let end = min(cursor + size, bytes.count)
            result[String(header[0])] = Data(bytes[cursor..<end])
            cursor = end + 1
        }
        return result
    }
}
