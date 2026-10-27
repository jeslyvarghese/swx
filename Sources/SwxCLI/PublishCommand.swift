import ArgumentParser
import Foundation
import SwxWorkspace

/// `swx publish`: `swift package-registry publish`, with the same arguments and results.
struct Publish: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Publish a release of this package to a registry (SE-0391).",
        discussion: """
        Takes `swift package-registry publish`'s arguments and prepares the same archive: the package
        without .build, .git, .gitignore and .swiftpm, zipped under <scope>.<name>/. With
        --private-key-path and --cert-chain-paths, the manifests in the archive, the archive and the
        metadata are signed (cms-1.0.0). The registry is --url, or the one configured for the scope;
        credentials come from the netrc file or the keychain, as for resolving.
        """
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: .init("The package identifier.", valueName: "package-id"))
    var identity: String

    @Argument(help: .init("The package release version being created.", valueName: "package-version"))
    var version: String

    @Option(name: [.customLong("url"), .customLong("registry-url")], help: "The registry URL.")
    var registryURL: String?

    @Option(name: .customLong("scratch-directory"), help: "The path to the directory for working files.")
    var scratchDirectory: String?

    @Option(name: .customLong("metadata-path"), help: "The path to the package metadata JSON file if it is not 'package-metadata.json' in the package directory.")
    var metadataPath: String?

    @Option(help: "The label of the signing identity to be retrieved from the system's identity store if supported.")
    var signingIdentity: String?

    @Option(help: "The path to the certificate's PKCS#8 private key (DER-encoded).")
    var privateKeyPath: String?

    @Option(name: .customLong("cert-chain-paths"), parsing: .upToNextOption, help: "Path(s) to the signing certificate (DER-encoded) and optionally the rest of the certificate chain, leaf first.")
    var certificateChainPaths: [String] = []

    @Flag(name: .customLong("allow-insecure-http"), help: "Use a non-HTTPS registry URL.")
    var allowInsecureHTTP = false

    @Flag(help: "Prepare and sign the archive without publishing it to the registry.")
    var dryRun = false

    func run() async throws {
        let request = try self.request()
        let outcome = try await CommandSupport.reportingErrors { try await self.global.makeWorkspace().publish(request) }

        // SwiftPM's wording, so scripts reading it keep working.
        switch outcome {
        case .prepared(let directory):
            print("\(self.identity)@\(self.version) was successfully prepared for publishing but was not published due to dry run flag. Artifacts available at '\(directory.path)'.")
        case .published(let registry, nil):
            print("\(self.identity) version \(self.version) was successfully published to \(registry.absoluteString)")
        case .published(let registry, let location?):
            print("\(self.identity) version \(self.version) was successfully published to \(registry.absoluteString) and is available at '\(location.absoluteString)'")
        case .processing(let registry, let status):
            print("\(self.identity) version \(self.version) was successfully submitted to \(registry.absoluteString) and is being processed. Publishing status is available at '\(status.absoluteString)'.")
        }
    }

    private func request() throws -> PublishRequest {
        // SwiftPM's rules: a Keychain label alone, or a key file with its chain.
        let signing: PublishSigning
        switch (self.signingIdentity, self.privateKeyPath, self.certificateChainPaths.isEmpty) {
        case (nil, nil, true):
            signing = .unsigned
        case (let label?, nil, true):
            signing = .keychain(label: label)
        case (nil, let key?, false):
            signing = .certificate(privateKey: FileSystemPaths.absolute(key), chain: self.certificateChainPaths.map(FileSystemPaths.absolute))
        case (nil, _, _):
            throw ValidationError("Both 'private-key-path' and 'cert-chain-paths' are required when one of them is set.")
        default:
            throw ValidationError("Either 'signing-identity' or 'private-key-path' (together with 'cert-chain-paths') must be provided.")
        }
        let registry = try self.registryURL.map { text -> URL in
            guard let url = URL(string: text) else { throw ValidationError("invalid registry URL: \(text)") }
            return url
        }
        return PublishRequest(
            identity: self.identity,
            version: self.version,
            registryURL: registry,
            scratchDirectory: self.scratchDirectory.map(FileSystemPaths.absolute),
            metadataPath: self.metadataPath.map(FileSystemPaths.absolute),
            signing: signing,
            transport: self.allowInsecureHTTP ? .allowInsecureHTTP : .httpsOnly,
            effect: self.dryRun ? .dryRun : .publish
        )
    }
}
