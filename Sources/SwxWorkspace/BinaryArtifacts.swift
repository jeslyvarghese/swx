import Foundation
import SwxCore
import SwxManifest
import SwxSource
import SwxStore
import SwxSystem

/// How a tool spells absolute paths in its state file.
enum RecordedPathStyle: Sendable {
    /// SwiftPM: lexically normalized, symlinks kept (`/private/tmp/…`).
    case lexical
    /// Xcode: symlinks resolved, as `URL.resolvingSymlinksInPath` does (`/tmp/…`).
    case symlinksResolved

    func spelling(of url: URL) -> String {
        switch self {
        case .lexical:
            return url.path
        case .symlinksResolved:
            return url.resolvingSymlinksInPath().path
        }
    }
}

/// Whether a package's pin moved in this resolve; SwiftPM only accepts a changed
/// artifact checksum under an unchanged URL when the package itself was updated.
enum PackageChange: Sendable {
    case unchanged
    case updated
}

/// What to do with one binary target's state entry.
enum ArtifactOutcome: Sendable {
    /// Installed from the store: record this entry.
    case installed(ManagedArtifact)
    /// Already in place with the same checksum.
    case upToDate
    /// Something swx doesn't handle (index files, odd archives, a suspicious checksum
    /// change); SwiftPM fetches or reports it on its next run.
    case leftToSwiftPM(reason: String)
}

/// One package's binary targets: what it declares and what happened to each.
struct PackageArtifacts: Sendable {
    let declared: Set<ManagedArtifact.Key>
    let outcomes: [ManagedArtifact.Key: ArtifactOutcome]
}

/// Places remote binary-target artifacts into `<state>/artifacts/<package>/<target>` from the
/// shared store, so a second project (or a clean `.build`) never downloads or unzips again.
struct ArtifactInstaller: Sendable {
    let source: BinaryArtifactSource
    let artifactsDirectory: URL
    let pathStyle: RecordedPathStyle
    let mirrors: DependencyMirrors
    let previous: WorkspaceState
    /// Only artifact bundle indexes need it, so it is computed on demand.
    let hostTriple: @Sendable () async throws -> String

    /// Installs every remote binary target `manifest` declares.
    func install(package: PackageReference, manifest: Manifest, change: PackageChange) async throws -> PackageArtifacts {
        var declared: Set<ManagedArtifact.Key> = []
        var outcomes: [ManagedArtifact.Key: ArtifactOutcome] = [:]

        for target in manifest.targets where target.kind == .binary {
            let key = ManagedArtifact.Key(package: package.identity, targetName: target.name)
            declared.insert(key)

            // Local artifacts are read in place by SwiftPM; nothing to share.
            guard case .remote(let declaredURL, let checksum)? = target.binaryLocation else { continue }
            let url = self.mirrors.location(declaredURL)
            outcomes[key] = try await self.install(key: key, package: package, packageName: manifest.name, url: url, checksum: checksum, change: change)
        }
        return PackageArtifacts(declared: declared, outcomes: outcomes)
    }

    private func install(
        key: ManagedArtifact.Key,
        package: PackageReference,
        packageName: String,
        url: String,
        checksum: String,
        change: PackageChange
    ) async throws -> ArtifactOutcome {
        // SwiftPM's rules for an existing entry: same checksum means up to date; a new checksum
        // under the same URL without a package update is treated as tampering.
        if let recorded = self.previous.artifact(key), case .remote(let recordedURL, let recordedChecksum)? = recorded.source {
            if recordedChecksum == checksum, FileSystem.exists(URL(fileURLWithPath: recorded.path)) {
                return .upToDate
            }
            if recordedChecksum != checksum, recordedURL == url, change == .unchanged {
                return .leftToSwiftPM(reason: "checksum changed without a package update")
            }
        }
        guard BinaryArtifactSource.isSupported(url: url) else {
            return .leftToSwiftPM(reason: "neither a zip archive nor an artifact bundle index")
        }

        // An index names one archive per host; the state still records the index itself.
        var archiveURL = url
        var archiveChecksum = checksum
        if BinaryArtifactSource.isIndex(url: url) {
            let archive = try await self.source.indexedArchive(url: url, checksum: checksum, hostTriple: try await self.hostTriple())
            archiveURL = archive.url
            archiveChecksum = archive.checksum
        }

        // Fetch once into the store, then copy-on-write into place.
        let tree = try await self.source.tree(url: archiveURL, checksum: archiveChecksum)
        guard let derived = BinaryArtifactSource.derive(in: tree) else {
            return .leftToSwiftPM(reason: "no single artifact in the archive")
        }
        let destination = self.directory(for: key)
        try Materializer.materialize(tree, at: destination)

        let path = derived.relativePath.isEmpty ? destination : destination.appendingPathComponent(derived.relativePath)
        return .installed(ManagedArtifact(
            package: package,
            packageName: packageName,
            targetName: key.targetName,
            source: .remote(url: url, checksum: checksum),
            path: self.pathStyle.spelling(of: path),
            kind: Self.kind(derived.kind)
        ))
    }

    // MARK: Recording

    /// Applies outcomes to `state` and removes artifacts no package declares any more.
    func record(_ packages: [PackageArtifacts], into state: inout WorkspaceState) throws {
        var declared: Set<ManagedArtifact.Key> = []
        for package in packages {
            declared.formUnion(package.declared)
            for case .installed(let artifact) in package.outcomes.values {
                try state.setArtifact(artifact)
            }
        }

        // Edited packages belong to SwiftPM, so their artifacts stay too.
        let preserved = state.preservedIdentities
        for key in state.artifactKeys where !declared.contains(key) && !preserved.contains(key.package) {
            let recorded = state.artifact(key)
            state.removeArtifact(key)
            guard let recorded, self.isInArtifactsDirectory(recorded.path) else { continue }
            try FileSystem.removeTree(self.directory(for: key))
            Self.removeIfEmpty(self.directory(for: key).deletingLastPathComponent())
        }
    }

    // MARK: Helpers

    /// SwiftPM's layout: `artifacts/<identity>/<target>/`.
    private func directory(for key: ManagedArtifact.Key) -> URL {
        self.artifactsDirectory
            .appendingPathComponent(key.package.description, isDirectory: true)
            .appendingPathComponent(key.targetName, isDirectory: true)
    }

    private func isInArtifactsDirectory(_ path: String) -> Bool {
        path.hasPrefix(self.pathStyle.spelling(of: self.artifactsDirectory) + "/")
    }

    private static func removeIfEmpty(_ directory: URL) {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: directory.path), contents.isEmpty else {
            return
        }
        try? FileSystem.removeTree(directory)
    }

    private static func kind(_ kind: BinaryArtifactKind) -> ManagedArtifact.Kind {
        switch kind {
        case .xcframework:
            return .xcframework
        case .artifactsArchive(let types):
            return .artifactsArchive(types: types)
        }
    }
}
