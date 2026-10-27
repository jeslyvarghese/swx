import Foundation
import SwxCore
import SwxManifest
import SwxSource
import SwxStore
import SwxSystem

/// SwiftPM 6.4's prebuilt swift-syntax for macros (`--[enable|disable]-experimental-prebuilts`).
public struct PrebuiltsOptions: Sendable {
    public enum Use: Sendable {
        case enabled
        case disabled
    }

    public var use: Use
    /// `--experimental-prebuilts-download-url`: a mirror of download.swift.org/prebuilts.
    public var downloadURL: URL?
    /// `--experimental-prebuilts-root-cert`: a root to trust instead of Apple's.
    public var rootCertificate: URL?

    public init(use: Use = .enabled, downloadURL: URL? = nil, rootCertificate: URL? = nil) {
        self.use = use
        self.downloadURL = downloadURL
        self.rootCertificate = rootCertificate
    }
}

extension Workspace {
    /// One `prebuilts` entry of workspace-state.json, field for field as SwiftPM stores it.
    private struct StoredPrebuilt: Encodable {
        let cModules: [String]
        let checkoutPath: String
        let identity: String
        let includePath: [String]?
        let libraryName: String
        let path: String
        let products: [String]
        let version: String
    }

    /// A pin SwiftPM would fetch prebuilts for: a known package at a released version.
    private struct PrebuiltCandidate {
        let identity: String
        let version: String
    }

    private static let prebuiltsDirectory = "prebuilts"

    /// Fields of a recorded entry that name it.
    private enum StateKey {
        static let identity = "identity"
        static let version = "version"
    }

    /// SwiftPM runs from a package directory; Xcode doesn't fetch prebuilts.
    private var fetchesPrebuilts: Bool {
        guard case .package = self.options.root else { return false }
        return self.options.prebuilts.use == .enabled && PrebuiltPlatform.host != nil
    }

    private static func prebuiltCandidates(_ pins: [Pin]) -> [PrebuiltCandidate] {
        pins.compactMap { pin in
            guard case .version(let version, _) = pin.state,
                  let url = pin.package.kind.sourceControlLocation,
                  PrebuiltSource.hasPrebuilts(identity: pin.package.identity.description, url: url) else {
                return nil
            }
            return PrebuiltCandidate(identity: pin.package.identity.description, version: version.description)
        }
    }

    /// Whether the state lacks prebuilts SwiftPM would record: then an otherwise up-to-date
    /// resolve still has to place them.
    func prebuiltsMissing(pins: [Pin], state: WorkspaceState) async -> Bool {
        guard self.fetchesPrebuilts else { return false }
        let recorded = Set(state.prebuilts.compactMap(Self.recordedPrebuilt))
        return Self.prebuiltCandidates(pins).contains { !recorded.contains("\($0.identity)@\($0.version)") }
    }

    /// `identity@version` of a recorded entry.
    private static func recordedPrebuilt(_ entry: JSONValue) -> String? {
        guard case .object(let fields) = entry, case .string(let identity)? = fields[StateKey.identity], case .string(let version)? = fields[StateKey.version] else {
            return nil
        }
        return "\(identity)@\(version)"
    }

    /// Places the pins' prebuilt libraries under `<state>/prebuilts/<identity>/<version>/` (the
    /// signed manifest, each archive, each extracted library) and returns their state entries,
    /// sorted as SwiftPM sorts them. Packages without prebuilts for this toolchain get none;
    /// `nil` when prebuilts are off, which leaves recorded entries alone, as SwiftPM does.
    func placePrebuilts(for pins: [Pin], layout: Layout) async -> [JSONValue]? {
        guard self.fetchesPrebuilts, let platform = PrebuiltPlatform.host else { return nil }
        let candidates = Self.prebuiltCandidates(pins)
        guard !candidates.isEmpty, let name = try? await Toolchain.prebuiltName(platform: platform, store: self.store) else { return [] }

        let source = PrebuiltSource(store: self.store, downloadURL: self.options.prebuilts.downloadURL, trustedRoot: self.options.prebuilts.rootCertificate)
        var entries: [(String, JSONValue)] = []
        for candidate in candidates {
            guard let release = await source.release(package: candidate.identity, version: candidate.version, prebuiltName: name, archiveExtension: platform.archiveExtension) else {
                self.log(.verbose, "no prebuilt \(candidate.identity) \(candidate.version) for \(name); SwiftPM builds it from source")
                continue
            }

            // SwiftPM's working copy: it re-reads the manifest on later resolves.
            let directory = layout.stateDirectory
                .appendingPathComponent(Self.prebuiltsDirectory, isDirectory: true)
                .appendingPathComponent(candidate.identity, isDirectory: true)
                .appendingPathComponent(candidate.version, isDirectory: true)
            do {
                try Self.placeFile(release.manifest, in: directory)
                for artifact in release.artifacts {
                    try Self.placeFile(artifact.archive, in: directory)
                    let destination = directory.appendingPathComponent(artifact.directory.lastPathComponent, isDirectory: true)
                    if !FileSystem.isDirectory(destination) {
                        // Writable, as SwiftPM's own extraction leaves it.
                        try Materializer.materialize(artifact.directory, at: destination)
                        FileSystem.makeWritable(destination)
                    }
                    let entry = StoredPrebuilt(
                        cModules: [],
                        checkoutPath: layout.pathStyle.spelling(of: layout.checkoutsDirectory.appendingPathComponent(candidate.identity)),
                        identity: candidate.identity,
                        includePath: artifact.library.includePath,
                        libraryName: artifact.library.name,
                        path: layout.pathStyle.spelling(of: destination),
                        products: artifact.library.products,
                        version: candidate.version
                    )
                    entries.append((candidate.identity, try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(entry))))
                }
            } catch {
                self.log(.verbose, "could not place prebuilt \(candidate.identity): \(error)")
            }
        }
        return entries.sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// A copy-on-write copy of a store file, unless one is already there.
    private static func placeFile(_ file: URL, in directory: URL) throws {
        let destination = directory.appendingPathComponent(file.lastPathComponent)
        guard !FileSystem.exists(destination) else { return }
        try FileSystem.createDirectory(directory)
        try FileManager.default.copyItem(at: file, to: destination)
    }
}
