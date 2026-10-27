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
        let packages = PackageDiscovery.packages(under: global.packageURL)
        guard !packages.isEmpty else {
            throw ValidationError("no Package.swift under \(global.packageURL.path)")
        }
        return packages
    }

    /// Runs `body` for each package, a few at a time, and prints each result under the
    /// package's path as it finishes. Fails (after all ran) when any did.
    static func forEach(_ global: GlobalOptions, _ body: @escaping @Sendable (GlobalOptions) async throws -> [String]) async throws {
        let root = global.packageURL
        let packages = try Self.packages(global)
        let failures = await withTaskGroup(of: (String, Result<[String], Error>).self) { group in
            var pending = packages[...]
            var failures = 0

            // Keep a fixed number in flight.
            func startNext() {
                guard let package = pending.popFirst() else { return }
                var options = global
                options.packagePath = package.path
                group.addTask {
                    let name = PackageDiscovery.relativePath(of: package, to: root)
                    do {
                        return (name, .success(try await body(options)))
                    } catch {
                        return (name, .failure(error))
                    }
                }
            }
            for _ in 0..<Self.concurrency {
                startNext()
            }
            while let (name, result) = await group.next() {
                switch result {
                case .success(let lines):
                    for line in lines {
                        print("\(name): \(line)")
                    }
                case .failure(let error):
                    failures += 1
                    FileHandle.standardError.write(Data("\(name): error: \(Self.describe(error))\n".utf8))
                }
                startNext()
            }
            return failures
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
        let packages = PackageDiscovery.packages(under: root)
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

    private static func describe(_ error: Error) -> String {
        guard let exit = error as? ExitCode else { return "\(error)" }
        return "exited with status \(exit.rawValue)"
    }
}
