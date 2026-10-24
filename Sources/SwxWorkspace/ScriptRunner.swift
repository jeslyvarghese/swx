import Foundation
import SwxCore
import SwxManifest
import SwxStore
import SwxSystem

/// Runs single-file Swift scripts that declare their own dependencies (like PEP 723 for Python).
///
/// ```swift
/// #!/usr/bin/env -S swx run
/// // swx-dependencies:
/// // .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0")
///
/// import ArgumentParser
/// ```
/// Every comment line after the `swx-dependencies:` marker is one `.package(…)` entry, written
/// exactly as in `Package.swift`. Products are inferred from the script's `import`s. The script is
/// compiled once into a cached package keyed by its contents and the toolchain.
public struct ScriptRunner: Sendable {
    private enum Marker {
        static let dependencies = "swx-dependencies:"
        static let comment = "//"
        static let shebang = "#!"
        static let importKeyword = "import"
    }

    private enum Layout {
        static let targetName = "Script"
        static let sources = "Sources"
        static let mainFile = "main.swift"
        static let toolsVersion = "6.0"
        static let platform = ".macOS(.v13)"
    }

    private let store: Store
    private let options: WorkspaceOptions

    /// - Parameter options: `root` is ignored; cache, concurrency and verbosity are used.
    public init(options: WorkspaceOptions) {
        self.options = options
        self.store = options.cacheDirectory.map(Store.init(root:)) ?? Store.default()
    }

    /// Whether `argument` names a script rather than an executable product.
    public static func isScript(_ argument: String) -> Bool {
        argument.hasSuffix(WellKnownFile.swiftExtension) && FileManager.default.fileExists(atPath: argument)
    }

    /// Builds (or reuses) the script's executable.
    public func prepare(script: URL, configuration: BuildConfiguration) async throws -> URL {
        let source = try String(contentsOf: script, encoding: .utf8)
        let key = ContentHash.sha256([source, configuration.rawValue, try await Toolchain.detect(store: self.store).key].joined(separator: "\u{0}"))
        let package = self.store.scriptPath(key: key)
        let marker = package.appendingPathComponent(Layout.targetName)

        // Cached: the binary path is recorded next to the package.
        if let recorded = FileSystem.readIfPresent(marker).map({ String(decoding: $0, as: UTF8.self) }), FileSystem.exists(URL(fileURLWithPath: recorded)) {
            return URL(fileURLWithPath: recorded)
        }

        // Lay out a package around the script.
        let dependencies = Self.dependencyDeclarations(in: source)
        let mainFile = package.appendingPathComponent(Layout.sources).appendingPathComponent(Layout.targetName).appendingPathComponent(Layout.mainFile)
        try FileSystem.writeAtomically(Data(source.utf8), to: mainFile)

        // Resolve once without target dependencies to learn which products provide the imports.
        try self.writeManifest(in: package, dependencies: dependencies, products: [])
        if !dependencies.isEmpty {
            let workspace = Workspace(options: WorkspaceOptions(root: .package(package), cacheDirectory: self.options.cacheDirectory, maximumConcurrency: self.options.maximumConcurrency, verbosity: self.options.verbosity))
            let report = try await workspace.resolve(mode: .respectPins)
            let products = try await self.products(for: Self.imports(in: source), pins: report.pins, package: package)
            try self.writeManifest(in: package, dependencies: dependencies, products: products)
            _ = try await workspace.resolve(mode: .respectPins)
        }

        let binary = try await ProductBuilder.build(product: Layout.targetName, in: package, configuration: configuration)
        try FileSystem.writeAtomically(Data(binary.path.utf8), to: marker)
        return binary
    }

    // MARK: Header

    /// The `.package(…)` lines after the `swx-dependencies:` marker.
    static func dependencyDeclarations(in source: String) -> [String] {
        var declarations: [String] = []
        var inBlock = false

        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(Marker.shebang) {
                continue
            }
            guard trimmed.hasPrefix(Marker.comment) else {
                // The block ends at the first non-comment line.
                if inBlock { break }
                continue
            }

            let content = trimmed.dropFirst(Marker.comment.count).trimmingCharacters(in: .whitespaces)
            if content == Marker.dependencies {
                inBlock = true
                continue
            }
            if inBlock && !content.isEmpty {
                declarations.append(content.hasSuffix(",") ? String(content.dropLast()) : content)
            }
        }
        return declarations
    }

    /// Modules imported by the script (`import X`, `@testable import X`, `import struct X.Y`).
    static func imports(in source: String) -> Set<String> {
        var modules: Set<String> = []
        for line in source.split(separator: "\n") {
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let index = words.firstIndex(where: { $0 == Marker.importKeyword }), index + 1 < words.count else { continue }

            // Skip an optional kind (`struct`, `func`, …) after `import`.
            var moduleWord = words[index + 1]
            if index + 2 < words.count, moduleWord.first?.isLowercase == true {
                moduleWord = words[index + 2]
            }
            if let module = moduleWord.split(separator: ".").first {
                modules.insert(String(module))
            }
        }
        return modules
    }

    // MARK: Products

    private struct ProductReference: Hashable {
        let product: String
        let package: String
    }

    /// Maps each imported module to the library product that provides it.
    private func products(for imports: Set<String>, pins: [Pin], package: URL) async throws -> [ProductReference] {
        let toolchain = try await Toolchain.detect(store: self.store)
        let loader = ManifestLoader(store: self.store, toolchain: toolchain, maximumConcurrency: self.options.maximumConcurrency)
        let checkouts = package.appendingPathComponent(WellKnownFile.buildDirectory).appendingPathComponent(WellKnownFile.checkoutsDirectory)

        var result: Set<ProductReference> = []
        for pin in pins {
            let manifest = try await loader.load(packageAt: checkouts.appendingPathComponent(pin.package.name))
            for product in manifest.products where product.kind == .library {
                // A product provides each of its targets as a module.
                for module in product.targets where imports.contains(module) {
                    result.insert(ProductReference(product: product.name, package: pin.package.identity.description))
                }
            }
        }
        return result.sorted { ($0.package, $0.product) < ($1.package, $1.product) }
    }

    private func writeManifest(in package: URL, dependencies: [String], products: [ProductReference]) throws {
        let dependencyLines = dependencies.map { "        \($0)," }.joined(separator: "\n")
        let productLines = products.map { "            .product(name: \"\($0.product)\", package: \"\($0.package)\")," }.joined(separator: "\n")
        let manifest = """
        // swift-tools-version: \(Layout.toolsVersion)
        import PackageDescription

        let package = Package(
            name: "\(Layout.targetName)",
            platforms: [\(Layout.platform)],
            dependencies: [
        \(dependencyLines)
            ],
            targets: [
                .executableTarget(name: "\(Layout.targetName)", dependencies: [
        \(productLines)
                ]),
            ]
        )

        """
        let url = package.appendingPathComponent(WellKnownFile.manifest)
        guard FileSystem.readIfPresent(url) != Data(manifest.utf8) else { return }
        try FileSystem.writeAtomically(Data(manifest.utf8), to: url)
    }
}
