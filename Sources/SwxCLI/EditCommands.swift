import ArgumentParser
import Foundation
import SwxWorkspace

/// `swx remove <package>`: the opposite of `swx add`.
struct Remove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Remove a package dependency, and every target's use of its products, then resolve."
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "The dependency's identity (swift-nio), name or URL.")
    var package: String

    func run() async throws {
        try await CommandSupport.prepareToolchain(for: self.global)
        let workspace = self.global.makeWorkspace()
        let result = try await CommandSupport.reportingErrors { try await workspace.remove(self.package) }
        print("Removed \(result.identity)")
        try await EditSupport.resolve(workspace, global: self.global, restoring: result.previousManifest)
    }
}

/// `swx upgrade [<package>…]`: widen requirements to the newest releases, then resolve.
struct Upgrade: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Move version requirements that exclude a dependency's newest release to that release, then resolve.",
        discussion: """
        Only requirements the newest release falls outside of change, and each keeps its form:
        from: "1.3.0" becomes from: "2.1.0". Updates within the requirements are `swx package update`.
        If the new versions don't resolve together, Package.swift is put back.
        """
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "Dependencies to upgrade (default: all).")
    var packages: [String] = []

    @Flag(help: "Show what would change without editing Package.swift.")
    var dryRun = false

    func run() async throws {
        try await CommandSupport.prepareToolchain(for: self.global)
        let workspace = self.global.makeWorkspace()
        let effect: EditEffect = self.dryRun ? .dryRun : .apply
        let result = try await CommandSupport.reportingErrors { try await workspace.upgrade(self.packages, effect: effect) }

        // Each change, then what couldn't change and why.
        let verb = self.dryRun ? "would move" : "moved"
        for change in result.changes {
            print("\(change.identity): \(verb) \(change.from) → \(change.to)")
        }
        for skip in result.skipped {
            print("\(skip.identity): not upgraded, \(skip.reason)")
        }
        if result.changes.isEmpty {
            print("every requirement already allows its dependency's newest release")
        }

        guard let previous = result.previousManifest else { return }
        try await EditSupport.resolve(workspace, global: self.global, restoring: previous)
    }
}

enum EditSupport {
    /// Resolves after a manifest edit; when that fails, the edit is undone so the package keeps building.
    static func resolve(_ workspace: Workspace, global: GlobalOptions, restoring previous: Data) async throws {
        do {
            try await ResolveRunner.run(mode: .respectPins, global: global, workspace: workspace)
        } catch {
            try workspace.restoreManifest(previous)
            FileHandle.standardError.write(Data("the manifest was put back as it was\n".utf8))
            throw error
        }
    }
}
