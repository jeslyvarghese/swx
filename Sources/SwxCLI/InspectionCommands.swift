import ArgumentParser
import Foundation
import SwxWorkspace

/// `text` or `json`, for reports.
enum ReportFormat: String, ExpressibleByArgument, CaseIterable {
    case text
    case json
}

extension OutdatedThreshold: ExpressibleByArgument {}
extension AdvisorySeverity: ExpressibleByArgument {}

/// `swx why <package>`: who depends on a package, up to the root.
struct Why: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show why a package is in the graph: who depends on it, up to the root."
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "A package identity or name, or one of its products.")
    var package: String

    @Option(help: "text or json.")
    var format: ReportFormat = .text

    func run() async throws {
        try await CommandSupport.prepareToolchain(for: self.global)
        let workspace = self.global.makeWorkspace()
        try await GraphSupport.resolve(workspace)

        let format: WhyFormat = self.format == .json ? .json : .text
        let text = try await CommandSupport.reportingErrors { try await workspace.why(self.package, format: format) }
        try GraphSupport.emit(text, to: nil)
    }
}

/// `swx outdated`: dependencies with newer versions.
struct Outdated: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List dependencies with newer versions: pinned, wanted (what the requirements allow) and latest."
    )

    @OptionGroup var global: GlobalOptions

    @Option(help: "text or json.")
    var format: ReportFormat = .text

    @Flag(help: "List every dependency, not only outdated ones.")
    var all = false

    @Option(help: "A dependency to leave out of the report (repeatable; adds to .swx/policy.json).")
    var ignore: [String] = []

    @Option(help: "Fail when a dependency is behind: never, wanted (the requirements allow newer) or latest (any newer release). Overrides .swx/policy.json.")
    var failOn: OutdatedThreshold?

    func run() async throws {
        try await CommandSupport.prepareToolchain(for: self.global)
        let workspace = self.global.makeWorkspace()
        try await GraphSupport.resolve(workspace)

        // The policy file, with the flags on top.
        var policy = try CommandSupport.reportingErrors { try workspace.policy() }.outdated
        policy.ignore.formUnion(self.ignore.map { $0.lowercased() })
        policy.failOn = self.failOn ?? policy.failOn

        let entries = policy.reported(try await CommandSupport.reportingErrors { try await workspace.outdated() })
        let format: OutdatedFormat = self.format == .json ? .json : .text
        let scope: OutdatedScope = self.all ? .all : .outdated
        try GraphSupport.emit(entries.render(format, scope: scope), to: nil)
        if policy.fails(entries) {
            throw ExitCode.failure
        }
    }
}

/// `swx audit`: known vulnerabilities in the pinned dependencies.
struct Audit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check pinned dependencies for known vulnerabilities (GitHub's advisory database, through OSV.dev). Fails when any is found."
    )

    @OptionGroup var global: GlobalOptions

    @Option(help: "text or json.")
    var format: ReportFormat = .text

    @Option(help: "An advisory id or alias to accept (repeatable; adds to .swx/policy.json).")
    var ignore: [String] = []

    @Option(help: "The mildest severity that fails: low, moderate, high or critical. Unrated advisories always fail. Overrides .swx/policy.json.")
    var failOn: AdvisorySeverity?

    func run() async throws {
        try await CommandSupport.prepareToolchain(for: self.global)
        let workspace = self.global.makeWorkspace()
        try await GraphSupport.resolve(workspace)

        // The policy file, with the flags on top.
        var policy = try CommandSupport.reportingErrors { try workspace.policy() }.audit
        policy.ignore.formUnion(self.ignore)
        policy.failOn = self.failOn ?? policy.failOn

        let report = try await CommandSupport.reportingErrors { try await workspace.audit(policy: policy) }
        try GraphSupport.emit(report.render(self.format == .json ? .json : .text), to: nil)
        if report.failed {
            throw ExitCode.failure
        }
    }
}

/// `swx licenses`: the license of every dependency.
struct Licenses: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List the license of every dependency, from its license file."
    )

    enum Format: String, ExpressibleByArgument, CaseIterable {
        case text
        case json
        case csv

        var licenseFormat: LicenseFormat {
            switch self {
            case .text:
                return .text
            case .json:
                return .json
            case .csv:
                return .csv
            }
        }
    }

    @OptionGroup var global: GlobalOptions

    @Option(help: "text, json or csv.")
    var format: Format = .text

    func run() async throws {
        try await CommandSupport.prepareToolchain(for: self.global)
        let workspace = self.global.makeWorkspace()
        try await GraphSupport.resolve(workspace)

        let text = try await CommandSupport.reportingErrors { try await workspace.licenses(format: self.format.licenseFormat) }
        try GraphSupport.emit(text, to: nil)
    }
}

/// `swx inspect …`: checks of the package's sources against its manifest.
struct Inspect: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check the package's sources against its manifest.",
        subcommands: [Imports.self]
    )

    /// `swx inspect imports`: imports of undeclared modules, and unused dependencies.
    struct Imports: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Find imports of modules a target doesn't declare (they break clean builds) and dependencies nothing imports. Fails on the first."
        )

        @OptionGroup var global: GlobalOptions

        @Option(help: "text or json.")
        var format: ReportFormat = .text

        func run() async throws {
            try await CommandSupport.prepareToolchain(for: self.global)
            let workspace = self.global.makeWorkspace()
            try await GraphSupport.resolve(workspace)

            let report = try await CommandSupport.reportingErrors { try await workspace.inspectImports() }
            try GraphSupport.emit(report.render(self.format == .json ? .json : .text), to: nil)

            // Undeclared imports fail (CI); unused dependencies are reported only.
            if report.hasImplicitImports {
                throw ExitCode.failure
            }
        }
    }
}
