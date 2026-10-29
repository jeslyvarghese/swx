import ArgumentParser
import Foundation
import SwxWorkspace

/// `swx add <package>[@version]`: like `uv add`, one step from a name to a resolved dependency.
struct Add: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Add a package dependency and one of its products to a target, then resolve.",
        discussion: """
        <package> is a URL, owner/repo on GitHub, or a name from the Swift Package Index
        (swift-argument-parser, Alamofire, …). Append @version to start from a release other than
        the newest: swx add swift-nio@2.60.0.
        """
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "A URL, owner/repo, or package name, optionally with @version.")
    var package: String

    @Option(help: "The product to use (default: the package's only library, or the one named like it).")
    var product: String?

    @Option(help: "The target that uses it (default: the package's only non-test target).")
    var target: String?

    @Flag(help: "Require exactly @version instead of up to the next major version.")
    var exact = false

    @Option(help: "Track a branch instead of releases.")
    var branch: String?

    @Option(help: "text or json (default: $SWX_FORMAT, else text).")
    var format: ReportFormat = .preferred

    private static let versionSeparator: Character = "@"

    func validate() throws {
        let (_, version) = self.parsedPackage
        if self.exact && version == nil {
            throw ValidationError("--exact needs a version: \(self.package)@1.2.3")
        }
        if self.branch != nil && version != nil {
            throw ValidationError("use either @version or --branch")
        }
    }

    /// `name@1.2.3` → (`name`, `1.2.3`). An `@` that isn't followed by a version (as in
    /// `git@github.com:…`) is part of the package.
    private var parsedPackage: (String, String?) {
        guard let separator = self.package.lastIndex(of: Self.versionSeparator) else { return (self.package, nil) }
        let version = String(self.package[self.package.index(after: separator)...])
        guard version.first?.isNumber == true else { return (self.package, nil) }
        return (String(self.package[..<separator]), version)
    }

    private var requirement: AddRequirement {
        let (_, version) = self.parsedPackage
        if let branch = self.branch {
            return .branch(branch)
        }
        guard let version else { return .latest }
        return self.exact ? .exact(version) : .from(version)
    }

    func run() async throws {
        try await CommandSupport.prepareToolchain(for: self.global)
        let workspace = self.global.makeWorkspace()
        let request = AddRequest(package: self.parsedPackage.0, requirement: self.requirement, product: self.product, target: self.target)
        let result = try await CommandSupport.reportingErrors {
            try await workspace.add(request) { CommandSupport.status($0) }
        }

        // `--format json`: the edit and the resolve in one object.
        if self.format == .json {
            try await self.printJSON(result, workspace: workspace)
            return
        }

        // What changed in Package.swift, then the resolve that follows from it.
        if result.alreadyPresent {
            print("\(result.target) already uses \(result.product) from \(result.identity)")
        } else if let requirement = result.requirement {
            print("Added \(result.url) (\(requirement)); \(result.target) uses \(result.product)")
        } else {
            print("\(result.target) now uses \(result.product) from \(result.identity)")
        }
        try await ResolveRunner.run(mode: .respectPins, global: self.global, workspace: workspace)
    }
}

extension Add {
    private struct Summary: Encodable {
        let status = "succeeded"
        let url: String
        let identity: String
        let requirement: String?
        let product: String
        let target: String
        let alreadyPresent: Bool
        let resolve: ResolveRunner.ResolveSummary
    }

    private func printJSON(_ result: AddResult, workspace: Workspace) async throws {
        let clock = ContinuousClock()
        let started = clock.now
        let report = try await CommandSupport.reportingErrors { try await workspace.resolve(mode: .respectPins) }
        JSONOutput.print(Summary(
            url: result.url,
            identity: result.identity,
            requirement: result.requirement,
            product: result.product,
            target: result.target,
            alreadyPresent: result.alreadyPresent,
            resolve: ResolveRunner.ResolveSummary(report, elapsed: clock.now - started)
        ))
    }
}
