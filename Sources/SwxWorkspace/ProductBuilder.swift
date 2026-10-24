import Foundation
import SwxSystem

/// SwiftPM's build configurations.
public enum BuildConfiguration: String, Sendable {
    case debug
    case release
}

/// Builds one product of an already-resolved package with SwiftPM and returns its binary.
enum ProductBuilder {
    private static let swift = "swift"

    static func build(product: String, in package: URL, configuration: BuildConfiguration) async throws -> URL {
        let common = ["--package-path", package.path, "-c", configuration.rawValue, "--disable-automatic-resolution"]

        // Output is only shown on failure: tools and scripts should feel instant once cached.
        let result = try await ProcessRunner.run([Self.swift, "build", "--product", product] + common, exitPolicy: .allowFailure)
        guard result.succeeded else {
            throw WorkspaceError(description: "building \(product) failed:\n\(result.output)\(result.errorOutput)")
        }

        let binPath = try await ProcessRunner.run([Self.swift, "build", "--show-bin-path"] + common)
        let binary = URL(fileURLWithPath: binPath.output.trimmingCharacters(in: .whitespacesAndNewlines)).appendingPathComponent(product)
        guard FileSystem.exists(binary) else {
            throw WorkspaceError(description: "built \(product) but found no binary at \(binary.path)")
        }
        return binary
    }

}
