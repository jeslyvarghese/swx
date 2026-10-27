import Foundation
import SwxCore
import SwxManifest
import SwxSource
import SwxSystem

/// How `swx publish` signs a release.
public enum PublishSigning: Sendable {
    case unsigned
    /// A DER PKCS#8 P-256 key, and DER certificates leaf first.
    case certificate(privateKey: URL, chain: [URL])
}

/// Whether a plain-HTTP registry URL is acceptable (`--allow-insecure-http`).
public enum RegistryTransport: Sendable {
    case httpsOnly
    case allowInsecureHTTP
}

/// Whether `swx publish` uploads, or only prepares and signs (`--dry-run`).
public enum PublishEffect: Sendable {
    case publish
    case dryRun
}

/// `swx publish`'s inputs, spelled as `swift package-registry publish` takes them.
public struct PublishRequest: Sendable {
    public var identity: String
    public var version: String
    public var registryURL: URL?
    /// Working files; by default `.build/registry/publish`, emptied first.
    public var scratchDirectory: URL?
    /// By default `package-metadata.json` in the package, when there is one.
    public var metadataPath: URL?
    public var signing: PublishSigning
    public var transport: RegistryTransport
    public var effect: PublishEffect

    public init(
        identity: String,
        version: String,
        registryURL: URL? = nil,
        scratchDirectory: URL? = nil,
        metadataPath: URL? = nil,
        signing: PublishSigning = .unsigned,
        transport: RegistryTransport = .httpsOnly,
        effect: PublishEffect = .publish
    ) {
        self.identity = identity
        self.version = version
        self.registryURL = registryURL
        self.scratchDirectory = scratchDirectory
        self.metadataPath = metadataPath
        self.signing = signing
        self.transport = transport
        self.effect = effect
    }
}

/// What `swx publish` did.
public enum PublishOutcome: Sendable, Equatable {
    /// `--dry-run`: the archive (and signatures) are in `directory`.
    case prepared(directory: URL)
    case published(registry: URL, location: URL?)
    case processing(registry: URL, status: URL)
}

extension Workspace {
    private enum Publishing {
        static let metadataFile = "package-metadata.json"
        static let identitySeparator: Character = "."
        /// SwiftPM 6.4 stopped labelling the metadata part `quoted-printable`.
        static let unlabeledMetadataSince = ToolsVersion(6, 4, 0)
        static let scratchComponents = ["registry", "publish"]
        static let sourceDirectory = "source"
        /// What SwiftPM leaves out of the copy it archives (top level only).
        static let ignored: Set<String> = [WellKnownFile.buildDirectory, ".git", ".gitignore", ".swiftpm"]
        static let archiveExtension = "zip"
        static let signatureExtension = "sig"
        static let metadataSignatureSuffix = "-metadata"
        static let zip = "zip"
        /// Recurse, and store symlinks as links (`zip -ry`).
        static let zipFlags = "-ry"
        static let httpsScheme = "https"
        static let httpScheme = "http"
    }

    /// Prepares a release as `swift package-registry publish` does (the package copied without
    /// `.build`, `.git`, `.gitignore` and `.swiftpm`, manifests signed in the copy, one zip with a
    /// `<scope>.<name>` top-level directory, detached CMS signatures), then uploads it.
    public func publish(_ request: PublishRequest) async throws -> PublishOutcome {
        guard case .package(let packageDirectory) = self.options.root else {
            throw WorkspaceError(description: "publishing works on a package directory")
        }

        // Validate the release's name and version.
        let parts = request.identity.split(separator: Publishing.identitySeparator, maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            throw WorkspaceError(description: "'\(request.identity)' is not a registry identity (scope.name)")
        }
        let (scope, name) = (parts[0], parts[1])
        if let problem = RegistryIdentityRules.problem(scope: scope) ?? RegistryIdentityRules.problem(name: name) {
            throw WorkspaceError(description: "'\(request.identity)' is not a valid registry identity: \(problem)")
        }
        guard Version(request.version) != nil else {
            throw WorkspaceError(description: "'\(request.version)' is not a semantic version")
        }

        // The registry: given, else the one configured for the scope; HTTPS unless allowed.
        let root = try await self.rootContext()
        guard let registry = request.registryURL ?? root.registries.registry(forScope: scope)?.url else {
            throw WorkspaceError(description: "no registry is configured for '\(scope)'; pass --url or run `swift package-registry set`")
        }
        let allowsHTTP = request.transport == .allowInsecureHTTP && root.registries.authentication(for: registry) == nil
        guard registry.scheme == Publishing.httpsScheme || (registry.scheme == Publishing.httpScheme && allowsHTTP) else {
            throw WorkspaceError(description: "invalid registry URL \(registry.absoluteString): use https (or --allow-insecure-http for a registry without authentication)")
        }

        // Working files, from a clean slate.
        if let custom = request.scratchDirectory, !FileSystem.isDirectory(custom) {
            throw WorkspaceError(description: "directory not found at '\(custom.path)'")
        }
        let working = request.scratchDirectory ?? Publishing.scratchComponents.reduce(packageDirectory.appendingPathComponent(WellKnownFile.buildDirectory, isDirectory: true)) {
            $0.appendingPathComponent($1, isDirectory: true)
        }
        try FileSystem.removeTree(working)
        try FileSystem.createDirectory(working)

        // Metadata: given (it must exist), else the package's own file.
        let metadataPath: URL?
        if let custom = request.metadataPath {
            guard FileSystem.exists(custom) else {
                throw WorkspaceError(description: "metadata file not found at '\(custom.path)'")
            }
            metadataPath = custom
        } else {
            let inPackage = packageDirectory.appendingPathComponent(Publishing.metadataFile)
            metadataPath = FileSystem.exists(inPackage) ? inPackage : nil
        }
        let metadata = try metadataPath.map(FileSystem.read)

        // Copy, sign the manifests in the copy, archive.
        let signer = try Self.signer(for: request.signing)
        let label = "\(request.identity)-\(request.version)"
        let source = working.appendingPathComponent(Publishing.sourceDirectory, isDirectory: true).appendingPathComponent(request.identity, isDirectory: true)
        try Self.copyPackage(packageDirectory, to: source)
        if let signer {
            for manifest in try Self.manifestNames(in: packageDirectory) {
                let signed = try signer.signedManifest(try FileSystem.read(packageDirectory.appendingPathComponent(manifest)))
                try FileSystem.writeAtomically(signed, to: working.appendingPathComponent(manifest))
                try FileSystem.writeAtomically(signed, to: source.appendingPathComponent(manifest))
            }
        }
        let archive = working.appendingPathComponent(label).appendingPathExtension(Publishing.archiveExtension)
        try await ProcessRunner.run([Publishing.zip, Publishing.zipFlags, archive.path, request.identity], in: source.deletingLastPathComponent())
        let archiveData = try FileSystem.read(archive)

        // Detached signatures of the archive and the metadata, saved as SwiftPM saves them.
        var upload = ReleaseUpload(archive: archiveData, archiveSignature: nil, metadata: metadata, metadataSignature: nil)
        if let signer {
            let archiveSignature = try signer.sign(archiveData)
            try FileSystem.writeAtomically(archiveSignature, to: working.appendingPathComponent(label).appendingPathExtension(Publishing.signatureExtension))
            let metadataSignature = try metadata.map(signer.sign)
            if let metadataSignature {
                try FileSystem.writeAtomically(metadataSignature, to: working.appendingPathComponent(label + Publishing.metadataSignatureSuffix).appendingPathExtension(Publishing.signatureExtension))
            }
            upload = ReleaseUpload(archive: archiveData, archiveSignature: archiveSignature, metadata: metadata, metadataSignature: metadataSignature)
        }
        guard request.effect == .publish else {
            return .prepared(directory: working)
        }

        // Upload.
        // The request of the SwiftPM this toolchain ships.
        let toolchain = try await Toolchain.detect(store: self.store)
        let encoding: MetadataPartEncoding = toolchain.toolsVersion < Publishing.unlabeledMetadataSince ? .quotedPrintableLabel : .unlabeled
        let publisher = RegistryPublisher(configuration: root.registries, credentials: RegistryCredentials(sources: self.options.swiftPM.credentials), metadataEncoding: encoding)
        switch try await publisher.publish(upload, scope: scope, name: name, version: request.version, to: registry) {
        case .published(let location):
            return .published(registry: registry, location: location)
        case .processing(let status, _):
            return .processing(registry: registry, status: status)
        }
    }

    private static func signer(for signing: PublishSigning) throws -> RegistrySigner? {
        guard case .certificate(let privateKey, let chain) = signing else { return nil }
        guard !chain.isEmpty else {
            throw WorkspaceError(description: "both --private-key-path and --cert-chain-paths are required when one of them is set")
        }
        return try RegistrySigner(privateKey: try FileSystem.read(privateKey), chain: try chain.map(FileSystem.read))
    }

    /// Everything at the top of the package but what SwiftPM leaves out.
    private static func copyPackage(_ directory: URL, to destination: URL) throws {
        try FileSystem.createDirectory(destination)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        for name in names.sorted() where !Publishing.ignored.contains(name) {
            try FileManager.default.copyItem(at: directory.appendingPathComponent(name), to: destination.appendingPathComponent(name))
        }
    }

    /// `Package.swift` (required) and every `Package@swift-X[.Y[.Z]].swift` beside it.
    static func manifestNames(in directory: URL) throws -> [String] {
        guard FileSystem.exists(directory.appendingPathComponent(WellKnownFile.manifest)) else {
            throw WorkspaceError(description: "no \(WellKnownFile.manifest) found at \(directory.path)")
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        return [WellKnownFile.manifest] + names.filter(ToolsVersion.isVersionSpecificManifestName).sorted()
    }
}
