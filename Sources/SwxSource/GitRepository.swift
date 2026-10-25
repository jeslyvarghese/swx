import Foundation
import SwxStore
import SwxSystem

/// A remote ref as reported by `git ls-remote`.
struct RemoteTag: Sendable, Hashable {
    let name: String
    /// The commit the tag points to (annotated tags are peeled).
    let revision: String
}

/// A submodule recorded at a revision: where it goes, where it comes from, and its pinned commit.
struct Submodule: Sendable, Hashable {
    let path: String
    /// As written in `.gitmodules`; may be relative to the parent's URL.
    let url: String
    let commit: String
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
        static let indexFileVariable = "GIT_INDEX_FILE"
        static let terminalPromptVariable = "GIT_TERMINAL_PROMPT"
        static let blobType = "blob"
        static let indexFileName = "swx-export.index"
        static let gitlinkMode = "160000"
        static let modulesFile = ".gitmodules"
        static let submoduleKeyPrefix = "submodule."
        static let pathKey = ".path"
        static let urlKey = ".url"
        static let updateKey = ".update"
        /// `update = none` opts a submodule out of `git submodule update`.
        static let updateNone = "none"
        static let pathOrURLPattern = #"^submodule\..*\.(path|url|update)$"#
    }

    /// Git LFS, which SwiftPM runs on checkouts whose `.gitattributes` use `filter=lfs`.
    private enum LFS {
        static let subcommand = "lfs"
        static let attributesFile = ".gitattributes"
        static let filterAttribute = "filter=lfs"
        static let commentPrefix = "#"
        /// Keeps a globally installed smudge filter from downloading during `read-tree`.
        static let skipSmudgeVariable = "GIT_LFS_SKIP_SMUDGE"
        static let enabled = "1"
        /// Objects live at `lfs/objects/<2 hex>/<2 hex>/<oid>` inside the repository.
        static let mediaDirectory = "lfs/objects"
        static let fanoutWidth = 2
        static let missingHint = """
            this package stores files with Git LFS, but git-lfs is not installed:
              macOS:   brew install git-lfs && git lfs install
              Ubuntu:  apt-get install git-lfs && git lfs install
            """
    }

    /// Never block on credential prompts; fail fast instead.
    private static let nonInteractive = [Git.terminalPromptVariable: "0"]

    /// Network operations get one more attempt: transient server or connection hiccups are common.
    private static let networkAttempts = 2

    @discardableResult
    private static func withNetworkRetry<T: Sendable>(_ operation: () async throws -> T) async throws -> T {
        var lastError: Error?
        for _ in 0..<Self.networkAttempts {
            do {
                return try await operation()
            } catch {
                lastError = error
            }
        }
        throw lastError!
    }

    let url: String
    let path: URL

    // MARK: Remote queries

    /// Lists tags without cloning: one request to the server, over HTTP directly when the
    /// remote speaks git's protocol v2, else through `git ls-remote` (SSH, credentials, …).
    static func listRemoteTags(url: String) async throws -> [RemoteTag] {
        if let tags = await GitHTTP.listTags(url: url) {
            Trace.event("ls-refs \(url)")
            return tags
        }
        let result = try await Self.withNetworkRetry {
            try await ProcessRunner.run([Git.executable, "ls-remote", "--tags", url], environment: Self.nonInteractive)
        }
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
        try await Self.withNetworkRetry {
            try? FileSystem.removeTree(staging)
            try await ProcessRunner.run(
                [Git.executable, "clone", "--bare", "--quiet", Git.blobFilter, self.url, staging.path],
                environment: Self.nonInteractive
            )
        }
        try FileSystem.moveIntoPlace(staging, self.path)
    }

    /// Fetches new commits and tags (still without blobs).
    func fetch() async throws {
        try await Self.withNetworkRetry {
            try await self.git(["fetch", "--quiet", "--tags", "--force", Git.blobFilter, "origin"])
        }
    }

    /// Fetches one commit that no tag or branch tip carries (e.g. a submodule's pinned commit).
    func fetchCommit(_ revision: String) async throws {
        try await Self.withNetworkRetry {
            try await self.git(["fetch", "--quiet", "--no-tags", Git.blobFilter, "origin", revision])
        }
    }

    /// The subset of `revisions` whose commits are not in the local repository.
    func missingCommits(_ revisions: [String]) async throws -> [String] {
        try await self.missingObjects(revisions)
    }

    /// The subset of `ids` not present locally.
    ///
    /// Lists what *is* present rather than probing what isn't: probing a missing object in a
    /// partial clone is fatal on older git (2.43) when lazy fetching is disabled, and would
    /// trigger one network round trip per object when it isn't.
    func missingObjects(_ ids: [String]) async throws -> [String] {
        let wanted = Set(ids)
        guard !wanted.isEmpty else { return [] }

        let result = try await self.git(["cat-file", "--batch-all-objects", "--batch-check=%(objectname)", "--unordered"])
        var missing = wanted
        for line in result.output.split(separator: "\n") where missing.contains(String(line)) {
            missing.remove(String(line))
            if missing.isEmpty { break }
        }
        return Array(missing)
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

        // Find which blobs are not local yet.
        let missing = try await self.missingObjects(unique)

        // One round trip for everything missing.
        if !missing.isEmpty {
            try await Self.withNetworkRetry { try await self.git(
                ["-c", "fetch.negotiationAlgorithm=noop", "fetch", "--quiet", "--no-tags", "--no-write-fetch-head",
                 "--recurse-submodules=no", Git.blobFilter, "--stdin", "origin"],
                input: missing
            ) }
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
        let workTree = [Git.executable, "--git-dir=\(self.path.path)", "--work-tree=\(destination.path)"]
        let environment = Self.nonInteractive.merging([Git.indexFileVariable: index.path, LFS.skipSmudgeVariable: LFS.enabled]) { $1 }
        try await ProcessRunner.run(workTree + ["read-tree", "-u", "--reset", revision], environment: environment)

        // LFS files arrive as pointers; fetch their objects into the store repository, then swap them in.
        guard Self.tracksLFS(destination) else { return }
        try await Self.requireLFS()
        try await Self.withNetworkRetry {
            try await self.git([LFS.subcommand, "fetch", "origin", revision])
        }
        try await self.replaceLFSPointers(at: revision, in: destination)
    }

    /// Copies each LFS object over its pointer. `git lfs checkout` would need a `HEAD`, which a
    /// shared store repository can't move per export, so list the revision's files explicitly.
    private func replaceLFSPointers(at revision: String, in tree: URL) async throws {
        let listing = try await self.git([LFS.subcommand, "ls-files", "--long", revision])
        let mediaDirectory = self.path.appendingPathComponent(LFS.mediaDirectory, isDirectory: true)

        for file in Self.parseLFSFiles(listing.output) {
            let object = mediaDirectory
                .appendingPathComponent(String(file.oid.prefix(LFS.fanoutWidth)))
                .appendingPathComponent(String(file.oid.dropFirst(LFS.fanoutWidth).prefix(LFS.fanoutWidth)))
                .appendingPathComponent(file.oid)
            guard FileSystem.exists(object) else {
                throw SourceError(description: "LFS object \(file.oid) for \(file.path) was not downloaded")
            }

            // Keep the pointer's permissions (an executable stays executable).
            let destination = tree.appendingPathComponent(file.path)
            let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
            try FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: object, to: destination)
            if let permissions = attributes[.posixPermissions] {
                try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: destination.path)
            }
        }
    }

    /// `git lfs ls-files --long` lines: `<oid> <*|-> <path>`.
    static func parseLFSFiles(_ output: String) -> [(oid: String, path: String)] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 2)
            guard parts.count == 3 else { return nil }
            return (String(parts[0]), String(parts[2]))
        }
    }

    /// SwiftPM's test: any non-comment `.gitattributes` line with `filter=lfs`.
    static func tracksLFS(_ tree: URL) -> Bool {
        guard let data = FileSystem.readIfPresent(tree.appendingPathComponent(LFS.attributesFile)) else { return false }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix(LFS.commentPrefix) else { return false }
            return trimmed.split(whereSeparator: \.isWhitespace).contains { $0 == LFS.filterAttribute }
        }
    }

    private static func requireLFS() async throws {
        let probe = try await ProcessRunner.run([Git.executable, LFS.subcommand, "version"], exitPolicy: .allowFailure)
        guard probe.succeeded else {
            throw SourceError(description: LFS.missingHint)
        }
    }

    // MARK: Submodules

    /// The submodules `git submodule update --init` would check out for the tree exported at `tree`.
    func submodules(at revision: String, exportedTo tree: URL) async throws -> [Submodule] {
        let modulesFile = tree.appendingPathComponent(Git.modulesFile)
        guard FileSystem.exists(modulesFile) else { return [] }

        // `.gitmodules`: name → path, url (git's own parser handles its quoting rules).
        let config = try await ProcessRunner.run(
            [Git.executable, "config", "--file", modulesFile.path, "--get-regexp", Git.pathOrURLPattern],
            exitPolicy: .allowFailure
        )
        let declared = Self.parseModules(config.output)
        guard !declared.isEmpty else { return [] }

        // Each submodule's commit is the gitlink at its path.
        let paths = declared.map(\.path)
        let listing = try await self.git(["ls-tree", "-z", revision, "--"] + paths)
        let gitlinks = Self.parseGitlinks(listing.output)

        return declared.compactMap { module in
            guard let commit = gitlinks[module.path] else { return nil }
            return Submodule(path: module.path, url: module.url, commit: commit)
        }
    }

    /// `submodule.<name>.path <value>` lines → declared modules, skipping `update = none`.
    static func parseModules(_ output: String) -> [(path: String, url: String)] {
        var paths: [String: String] = [:]
        var urls: [String: String] = [:]
        var skipped: Set<String> = []
        var order: [String] = []

        for line in output.split(separator: "\n") {
            guard let space = line.firstIndex(of: " ") else { continue }
            let key = String(line[..<space])
            let value = String(line[line.index(after: space)...])
            guard key.hasPrefix(Git.submoduleKeyPrefix) else { continue }

            if key.hasSuffix(Git.pathKey) {
                let name = String(key.dropFirst(Git.submoduleKeyPrefix.count).dropLast(Git.pathKey.count))
                if paths[name] == nil, urls[name] == nil { order.append(name) }
                paths[name] = value
            } else if key.hasSuffix(Git.urlKey) {
                let name = String(key.dropFirst(Git.submoduleKeyPrefix.count).dropLast(Git.urlKey.count))
                if paths[name] == nil, urls[name] == nil { order.append(name) }
                urls[name] = value
            } else if key.hasSuffix(Git.updateKey), value == Git.updateNone {
                skipped.insert(String(key.dropFirst(Git.submoduleKeyPrefix.count).dropLast(Git.updateKey.count)))
            }
        }

        return order.compactMap { name in
            guard !skipped.contains(name), let path = paths[name], let url = urls[name] else { return nil }
            return (path, url)
        }
    }

    /// `ls-tree -z` records → `path → commit` for gitlinks.
    static func parseGitlinks(_ output: String) -> [String: String] {
        var result: [String: String] = [:]
        for record in output.split(separator: "\0") {
            // `<mode> <type> <object>\t<path>`
            let parts = record.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let meta = parts[0].split(separator: " ")
            guard meta.count == 3, meta[0] == Git.gitlinkMode else { continue }
            result[String(parts[1])] = String(meta[2])
        }
        return result
    }

    private static let relativeCurrent = "./"
    private static let relativeParent = "../"
    private static let pathSeparator: Character = "/"
    private static let scpSeparator: Character = ":"

    /// Resolves a relative submodule URL (`../other.git`) against the parent's URL, as git does.
    static func resolveSubmoduleURL(_ url: String, relativeTo base: String) -> String {
        guard url.hasPrefix(Self.relativeCurrent) || url.hasPrefix(Self.relativeParent) else { return url }

        var resolved = base
        while resolved.hasSuffix(String(Self.pathSeparator)) {
            resolved.removeLast()
        }
        var remainder = Substring(url)

        // Each `../` drops one component of the base; `./` drops none.
        while true {
            if remainder.hasPrefix(Self.relativeCurrent) {
                remainder = remainder.dropFirst(Self.relativeCurrent.count)
                continue
            }
            guard remainder.hasPrefix(Self.relativeParent) else { break }
            remainder = remainder.dropFirst(Self.relativeParent.count)

            // Stop at the scheme's `//` or an scp-style `host:`.
            guard let cut = resolved.lastIndex(where: { $0 == Self.pathSeparator || $0 == Self.scpSeparator }) else { break }
            let separator = resolved[cut]
            resolved = String(resolved[..<cut])
            if separator == Self.scpSeparator {
                resolved.append(Self.scpSeparator)
                return resolved + remainder
            }
        }
        return resolved + String(Self.pathSeparator) + remainder
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
