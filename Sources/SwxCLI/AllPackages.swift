import ArgumentParser
import Foundation
import SwxWorkspace

/// `--all`: one command for every package of a monorepo, all sharing one store.
enum AllPackages {
    static let flag = "--all"
    static let help: ArgumentHelp = "Every package under --package-path (nested ones too), sharing one store."

    /// Packages resolved at once: their git work overlaps, and the store fetches each repository once.
    private static let concurrency = 4

    /// The packages under `global`'s package path; an error when there are none.
    static func packages(_ global: GlobalOptions) throws -> [URL] {
        let packages = try CommandSupport.reportingErrors { try PackageDiscovery.packages(under: global.packageURL) }
        guard !packages.isEmpty else {
            throw ValidationError("no Package.swift under \(global.packageURL.path)")
        }
        return packages
    }

    /// Runs `body` for each package, a few at a time, and prints each result under the
    /// package's path. Fails (after all ran) when any did.
    static func forEach(_ global: GlobalOptions, _ body: @escaping @Sendable (GlobalOptions) async throws -> [String]) async throws {
        let root = global.packageURL
        let packages = try Self.packages(global)
        // In batches: every task of a batch is added before any result is read.
        var failures = 0
        var batchStart = packages.startIndex
        while batchStart < packages.endIndex {
            let batch = packages[batchStart..<min(batchStart + Self.concurrency, packages.endIndex)]
            batchStart = batch.endIndex

            let results = await withTaskGroup(of: (String, PackageResult).self, returning: [(String, PackageResult)].self) { group in
                for package in batch {
                    var options = global
                    options.packagePath = package.path
                    let name = PackageDiscovery.relativePath(of: package, to: root)
                    group.addTask {
                        do {
                            // Awaited on its own line: in release builds (Swift 6.4), awaiting
                            // inside the enum payload dropped the child's result.
                            let lines = try await body(options)
                            return (name, .succeeded(lines))
                        } catch {
                            return (name, .failed(Self.describe(error)))
                        }
                    }
                }
                var results: [(String, PackageResult)] = []
                for await result in group {
                    results.append(result)
                }
                return results
            }

            // Each package's lines under its path, in the order they finished.
            for (name, result) in results {
                switch result {
                case .succeeded(let lines):
                    for line in lines {
                        print("\(name): \(line)")
                    }
                case .failed(let message):
                    failures += 1
                    FileHandle.standardError.write(Data("\(name): error: \(message)\n".utf8))
                }
            }
        }

        print("\(packages.count - failures) of \(packages.count) packages succeeded")
        guard failures == 0 else { throw ExitCode.failure }
    }

    /// Runs `body` for each package in turn (builds and tests stream their output), then
    /// summarizes; fails when any package failed.
    static func sequentially(_ arguments: [String], _ body: (_ arguments: [String]) async throws -> Void) async throws {
        var remaining = arguments
        let root = FileSystemPaths.absolute(Passthrough.packagePath(in: remaining))
        Passthrough.removePackagePath(from: &remaining)
        let packages = try CommandSupport.reportingErrors { try PackageDiscovery.packages(under: root) }
        guard !packages.isEmpty else {
            throw ValidationError("no Package.swift under \(root.path)")
        }

        var failed: [String] = []
        for package in packages {
            let name = PackageDiscovery.relativePath(of: package, to: root)
            CommandSupport.status("== \(name)")
            do {
                try await body(remaining + [Passthrough.packagePathFlag, package.path])
            } catch {
                failed.append(name)
            }
        }

        print("\(packages.count - failed.count) of \(packages.count) packages succeeded" + (failed.isEmpty ? "" : "; failed: \(failed.joined(separator: ", "))"))
        guard failed.isEmpty else { throw ExitCode.failure }
    }

    /// One package's outcome, as plain values: the error is described in the child task.
    private enum PackageResult: Sendable {
        case succeeded([String])
        case failed(String)
    }

    private static func describe(_ error: Error) -> String {
        guard let exit = error as? ExitCode else { return "\(error)" }
        return "exited with status \(exit.rawValue)"
    }
}
