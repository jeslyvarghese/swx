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

    private static let zipExtension = "zip"

    /// Installs every remote binary target `manifest` declares, and records local ones in place.
    /// `directory` holds the package (its checkout, or the root).
    func install(package: PackageReference, manifest: Manifest, directory: URL, change: PackageChange) async throws -> PackageArtifacts {
        var declared: Set<ManagedArtifact.Key> = []
        var outcomes: [ManagedArtifact.Key: ArtifactOutcome] = [:]

        for target in manifest.targets where target.kind == .binary {
            let key = ManagedArtifact.Key(package: package.identity, targetName: target.name)
            declared.insert(key)

            switch target.binaryLocation {
            case .remote(let declaredURL, let checksum)?:
                let url = self.mirrors.location(declaredURL)
                outcomes[key] = try await self.install(key: key, package: package, packageName: manifest.name, url: url, checksum: checksum, change: change)
            case .local(let path)?:
                outcomes[key] = try await self.recordLocal(key: key, package: package, packageName: manifest.name, path: path, in: directory)
            case nil:
                continue
            }
        }
        return PackageArtifacts(declared: declared, outcomes: outcomes)
    }

    /// SwiftPM uses a local XCFramework or artifact bundle where it is, and records it as a
    /// `local` artifact at the artifact it finds there; a missing one fails the resolve, as in
    /// SwiftPM. A local zip is extracted into `artifacts/<package>/<target>` and recorded with its
    /// checksum.
    private func recordLocal(key: ManagedArtifact.Key, package: PackageReference, packageName: String, path: String, in directory: URL) async throws -> ArtifactOutcome {
        let location = URL(fileURLWithPath: FileSystem.normalize(path, relativeTo: directory.path))
        if location.pathExtension.lowercased() == Self.zipExtension {
            return try await self.installLocalArchive(location, key: key, package: package, packageName: packageName)
        }
        guard let derived = BinaryArtifactSource.deriveLocal(at: location) else {
            throw WorkspaceError(description: "local binary target '\(key.targetName)' at '\(location.path)' does not contain a binary artifact.")
        }
        let artifact = derived.relativePath.isEmpty ? location : location.appendingPathComponent(derived.relativePath)
        return .installed(ManagedArtifact(
            package: package,
            packageName: packageName,
            targetName: key.targetName,
            source: .local(checksum: nil),
            path: self.pathStyle.spelling(of: artifact),
            kind: Self.kind(derived.kind)
        ))
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

    /// SwiftPM skips an archive whose checksum is already recorded, else extracts it in place.
    private func installLocalArchive(_ archive: URL, key: ManagedArtifact.Key, package: PackageReference, packageName: String) async throws -> ArtifactOutcome {
        guard FileSystem.exists(archive) else {
            throw WorkspaceError(description: "local binary target '\(key.targetName)' at '\(archive.path)' does not contain a binary artifact.")
        }
        let (tree, checksum) = try await self.source.tree(localArchive: archive)
        if let recorded = self.previous.artifact(key), case .local(let recordedChecksum?)? = recorded.source,
           recordedChecksum == checksum, FileSystem.exists(URL(fileURLWithPath: recorded.path)) {
            return .upToDate
        }

        // The last artifact found, as SwiftPM derives it in the extracted directory.
        guard let derived = BinaryArtifactSource.deriveLocal(at: tree) else {
            throw WorkspaceError(description: "local archived binary target '\(key.targetName)' at '\(archive.path)' does not contain a binary artifact.")
        }
        let destination = self.directory(for: key)
        try Materializer.materialize(tree, at: destination)
        FileSystem.makeWritable(destination)

        let path = derived.relativePath.isEmpty ? destination : destination.appendingPathComponent(derived.relativePath)
        return .installed(ManagedArtifact(
            package: package,
            packageName: packageName,
            targetName: key.targetName,
            source: .local(checksum: checksum),
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
