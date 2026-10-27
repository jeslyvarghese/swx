import SwxCore
@testable import SwxGraph
import SwxManifest
import Testing

// MARK: - Fixtures

private func dependency(_ name: String, from lower: String = "1.0.0", to upper: String = "2.0.0") -> Manifest.Dependency {
    Manifest.Dependency(identity: name, explicitName: nil, location: .remote(url: "https://example.com/\(name)"), requirement: .range(lowerBound: lower, upperBound: upper), traits: [Manifest.defaultTrait])
}

private func package(_ identity: String, _ manifest: Manifest, version: String? = "1.0.0", role: GraphPackage.Role = .dependency) -> GraphPackage {
    GraphPackage(identity: identity, manifest: manifest, location: "https://example.com/\(identity)", version: role == .root ? nil : version, path: "/work/\(identity)", role: role)
}

/// app (App, AppTests) → web → core; app → core. `core` has targets Core and CoreInternals.
private func graph(appImports: Set<String> = []) -> PackageGraph {
    let core = Manifest(
        name: "Core", toolsVersion: "6.0.0", dependencies: [],
        targets: [
            Manifest.Target(name: "Core", dependencies: [.target(name: "CoreInternals", condition: nil)], pluginUsages: []),
            Manifest.Target(name: "CoreInternals", dependencies: [], pluginUsages: []),
        ],
        products: [Manifest.Product(name: "Core", targets: ["Core"])],
        traits: []
    )
    let web = Manifest(
        name: "Web", toolsVersion: "6.0.0", dependencies: [dependency("core", from: "1.2.0")],
        targets: [Manifest.Target(name: "Web", dependencies: [.product(name: "Core", package: "core", condition: nil)], pluginUsages: [])],
        products: [Manifest.Product(name: "Web", targets: ["Web"])],
        traits: []
    )
    let app = Manifest(
        name: "App", toolsVersion: "6.0.0", dependencies: [dependency("web"), dependency("core")],
        targets: [
            Manifest.Target(name: "App", kind: .executable, dependencies: [.product(name: "Web", package: "web", condition: nil), .product(name: "Core", package: "core", condition: nil)], pluginUsages: []),
            Manifest.Target(name: "AppTests", kind: .test, dependencies: [.target(name: "App", condition: nil)], pluginUsages: []),
        ],
        products: [],
        traits: []
    )
    return PackageGraphBuilder.build(
        root: package("app", app, role: .root),
        dependencies: [package("web", web, version: "1.4.0"), package("core", core, version: "1.3.0")],
        identify: { $0.identity }
    )
}

// MARK: - why

struct WhyTests {
    @Test func walksDependentsUpToTheRoot() throws {
        #expect(try graph().why("core", format: .text) == """
        core 1.3.0
        ├── App (root)
        └── web 1.4.0
            └── App (root)

        used directly by:
          App → Core

        """)
    }

    /// Products and package names find their package; unknown names suggest close ones.
    @Test func findsPackagesByProductAndSuggests() throws {
        #expect(try graph().package(named: "Web").identity == "web")
        #expect(throws: GraphError.self) { try graph().package(named: "cor") }
    }
}

// MARK: - licenses

struct LicenseTests {
    @Test func recognizesCommonLicenses() {
        #expect(LicenseDetector.identify("MIT License\n\nPermission is hereby granted, free of charge, to any person ... The above copyright notice and this\n permission notice shall be included in all copies") == "MIT")
        #expect(LicenseDetector.identify("Apache License\n Version 2.0, January 2004") == "Apache-2.0")
        #expect(LicenseDetector.identify("Apache License Version 2.0 ... ## Runtime Library Exception to the Apache 2.0 License") == "Apache-2.0 WITH Swift-exception")
        #expect(LicenseDetector.identify("Redistribution and use in source and binary forms ... Neither the name of the copyright holder") == "BSD-3-Clause")
        #expect(LicenseDetector.identify("Permission to use, copy, modify, and/or distribute this software for any purpose with or without fee is hereby granted.") == "0BSD")
        #expect(LicenseDetector.identify("GNU LESSER GENERAL PUBLIC LICENSE Version 3, 29 June 2007 ... GNU General Public License") == "LGPL-3.0")
        #expect(LicenseDetector.identify("All rights reserved.") == nil)
    }

    @Test func picksTheLicenseFile() {
        #expect(LicenseDetector.licenseFile(among: ["README.md", "LICENSE.txt", "Sources", "LICENSE"]) == "LICENSE")
        #expect(LicenseDetector.licenseFile(among: ["COPYING", "Package.swift"]) == "COPYING")
        #expect(LicenseDetector.licenseFile(among: ["Package.swift"]) == nil)
    }

    @Test func rendersCSVWithQuoting() {
        let report = [PackageLicense(identity: "a", version: "1.0.0", license: "MIT", file: "LICENSE"), PackageLicense(identity: "b", version: nil, license: nil, file: nil)]
        #expect(report.render(.csv) == "package,version,license,file\na,1.0.0,MIT,LICENSE\nb,,,\n")
    }
}

// MARK: - imports

struct ImportTests {
    @Test func extractsImportsFromEveryBranch() {
        let source = """
        import Foundation
        @testable import App
        import struct Web.Request
        #if canImport(Glibc)
        import Glibc
        #endif
        func f() { let x = 1 }
        """
        #expect(SourceImports.modules(in: source) == ["Foundation", "App", "Web", "Glibc"])
    }

    /// Importing a module another product pulls in is implicit; SDK modules are ignored.
    @Test func flagsImplicitAndUnused() {
        let report = graph().inspectImports([
            "App": ["Foundation", "Web", "CoreInternals"],
            "AppTests": ["Testing", "App"],
        ])
        let app = report.targets.first { $0.target == "App" }
        #expect(app?.implicit == [.init(module: "CoreInternals", package: "core", product: nil)])
        #expect(app?.unused == ["product Core (core)"])
        #expect(report.targets.first { $0.target == "AppTests" }?.implicit == [])
        #expect(report.hasImplicitImports)
    }

    @Test func namesModulesLikeSwiftPM() {
        #expect(PackageGraph.moduleName(of: "swift-nio-ssl") == "swift_nio_ssl")
        #expect(PackageGraph.moduleName(of: "NIOCore") == "NIOCore")
    }
}

// MARK: - outdated

struct OutdatedTests {
    private func versions(_ texts: [String]) -> [Version] {
        texts.compactMap { Version($0) }
    }

    /// Wanted honours every requirement in the graph (web needs core ≥ 1.2.0, app < 2.0.0).
    @Test func computesWantedAndLatest() throws {
        let graph = graph()
        let core = try #require(graph.packages["core"])
        let entry = graph.outdatedEntry(
            for: core,
            available: self.versions(["1.1.0", "1.3.0", "1.9.0", "2.0.0", "2.1.0-beta.1"]),
            requirements: graph.requirements()["core"] ?? []
        )
        #expect(entry == OutdatedEntry(package: "core", current: "1.3.0", wanted: "1.9.0", latest: "2.0.0", dependents: ["root", "web"]))
        #expect(entry.isOutdated)
    }

    @Test func listsOnlyOutdatedUnlessAsked() {
        let entries = [
            OutdatedEntry(package: "a", current: "1.0.0", wanted: "1.0.0", latest: "1.0.0", dependents: ["root"]),
            OutdatedEntry(package: "b", current: "1.0.0", wanted: "1.2.0", latest: "2.0.0", dependents: ["root"]),
        ]
        #expect(entries.render(.text, scope: .outdated) == """
        Package  Current  Wanted  Latest  Dependents
        b        1.0.0    1.2.0   2.0.0   root

        1 of 2 dependencies have newer versions; `swx package update` moves 1 to Wanted

        """)
    }
}

struct PolicyTests {
    private static func advisory(_ id: String, _ severity: String?, aliases: [String] = []) -> Advisory {
        Advisory(id: id, aliases: aliases, summary: "s", severity: severity, fixedIn: [])
    }

    private static let finding = AuditFinding(package: "swift-nio-http2", version: "1.19.1", advisories: [
        advisory("GHSA-a", "MODERATE"),
        advisory("GHSA-b", "HIGH", aliases: ["CVE-2023-1"]),
    ])

    /// Severity thresholds: at or above fails, below passes.
    @Test func failsAtTheThreshold() {
        #expect(AuditReport(findings: [Self.finding], checked: 1, unchecked: []).failed)
        #expect(AuditReport(findings: [Self.finding], checked: 1, unchecked: [], policy: AuditPolicy(failOn: .high)).failed)
        #expect(!AuditReport(findings: [Self.finding], checked: 1, unchecked: [], policy: AuditPolicy(failOn: .critical)).failed)
        #expect(AdvisorySeverity(rating: "MEDIUM") == .moderate)
    }

    /// Unrated advisories fail whatever the threshold.
    @Test func unratedAlwaysFails() {
        let unrated = AuditFinding(package: "p", version: "1.0.0", advisories: [Self.advisory("GHSA-c", nil)])
        #expect(AuditReport(findings: [unrated], checked: 1, unchecked: [], policy: AuditPolicy(failOn: .critical)).failed)
    }

    /// Ignored advisories (by id or alias) leave the findings but stay named in the report.
    @Test func ignoresByIdOrAlias() {
        let report = AuditReport(findings: [Self.finding], checked: 1, unchecked: [], policy: AuditPolicy(ignore: ["GHSA-a", "CVE-2023-1"]))
        #expect(report.findings.isEmpty)
        #expect(!report.failed)
        #expect(report.ignored == [IgnoredAdvisory(package: "swift-nio-http2", id: "GHSA-a"), IgnoredAdvisory(package: "swift-nio-http2", id: "GHSA-b")])
        #expect(report.render(.text).contains("ignored by policy: GHSA-a (swift-nio-http2), GHSA-b (swift-nio-http2)"))
    }

    @Test func outdatedThresholds() {
        let behind = OutdatedEntry(package: "a", current: "1.0.0", wanted: "1.2.0", latest: "1.2.0", dependents: ["root"])
        let capped = OutdatedEntry(package: "b", current: "1.0.0", wanted: "1.0.0", latest: "2.0.0", dependents: ["root"])
        #expect(!OutdatedPolicy().fails([behind, capped]))
        #expect(OutdatedPolicy(failOn: .wanted).fails([behind]))
        #expect(!OutdatedPolicy(failOn: .wanted).fails([capped]))
        #expect(OutdatedPolicy(failOn: .latest).fails([capped]))
        #expect(OutdatedPolicy(ignore: ["a"]).reported([behind, capped]) == [capped])
    }
}
