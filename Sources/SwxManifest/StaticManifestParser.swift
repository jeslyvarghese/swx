import Foundation
import SwiftParser
import SwiftSyntax
import SwxCore
import SwxSystem

/// Reads declarative `Package.swift` files without compiling them.
///
/// The parser interprets only the expressions resolution needs: package name, dependencies,
/// products, targets with their dependencies and plugins, and traits. It is conservative by
/// construction: any statement or expression it does not fully understand, *in a position
/// that matters*, makes it return `nil` and the caller falls back to real evaluation.
/// Arguments that don't affect resolution (settings, resources, platforms…) are never evaluated.
public enum StaticManifestParser {
    private enum Name {
        static let package = "Package"
        static let version = "Version"
        static let foundation = "Foundation"
        static let packageDescription = "PackageDescription"
        static let defaultTrait = "default"
        static let platform = "Platform"
        static let customPlatform = "custom"
    }

    private enum Label {
        static let name = "name"
        static let dependencies = "dependencies"
        static let targets = "targets"
        static let products = "products"
        static let traits = "traits"
        static let url = "url"
        static let path = "path"
        static let id = "id"
        static let from = "from"
        static let exact = "exact"
        static let branch = "branch"
        static let revision = "revision"
        static let package = "package"
        static let condition = "condition"
        static let platforms = "platforms"
        static let plugins = "plugins"
        static let enabledTraits = "enabledTraits"
        static let checksum = "checksum"
    }

    private enum RangeOperator {
        static let halfOpen = "..<"
        static let closed = "..."
    }

    /// Imports a declarative manifest may use.
    /// `AppleProductTypes` (Xcode / Swift Playgrounds apps) can't be evaluated by the command-line
    /// SwiftPM at all, so reading it statically is the only way to resolve such packages.
    private static let allowedImports: Set<String> = [Name.packageDescription, Name.foundation, "CompilerPluginSupport", "AppleProductTypes"]

    /// Why the parser declined a manifest (for diagnostics; declining is always safe).
    public struct Decline: Error, Sendable, CustomStringConvertible {
        public let description: String
    }

    /// Parses `contents`; `packageDirectory` resolves relative `path:` dependencies (roots only).
    public static func parse(
        _ contents: String,
        packageDirectory: URL? = nil,
        environment: CompilationEnvironment = .host(compilerVersion: nil)
    ) -> Manifest? {
        try? self.analyze(contents, packageDirectory: packageDirectory, environment: environment).get()
    }

    /// Like `parse`, but explains a decline.
    public static func analyze(
        _ contents: String,
        packageDirectory: URL? = nil,
        environment: CompilationEnvironment = .host(compilerVersion: nil)
    ) -> Result<Manifest, Decline> {
        let file = Parser.parse(source: contents)
        let toolsVersion = ToolsVersion.parse(manifest: contents)
        var walker = TopLevelWalker(
            interpreter: Interpreter(packageDirectory: packageDirectory),
            conditions: ConditionEvaluator(environment: environment, toolsVersion: toolsVersion)
        )

        // Walk the top level (and active `#if` clauses), then build and patch the package.
        if let decline = walker.walk(file.statements) {
            return .failure(decline)
        }
        guard let packageCall = walker.packageCall else {
            return .failure(Decline(description: "no `let package = Package(…)`"))
        }
        return walker.interpreter.manifest(from: packageCall, toolsVersion: toolsVersion).flatMap { manifest in
            walker.interpreter.apply(walker.effects, to: manifest)
        }
    }

    /// Collects bindings and `package` mutations from top-level code.
    private struct TopLevelWalker {
        var interpreter: Interpreter
        let conditions: ConditionEvaluator
        var packageCall: FunctionCallExprSyntax?
        var effects: [Effect] = []

        /// Returns a decline, or `nil` when everything was understood or provably irrelevant.
        mutating func walk(_ items: CodeBlockItemListSyntax) -> Decline? {
            for item in items {
                if let decline = self.visit(item) {
                    return decline
                }
            }
            return nil
        }

        private mutating func visit(_ item: CodeBlockItemSyntax) -> Decline? {
            // Imports.
            if case .decl(let declaration) = item.item, let importDecl = declaration.as(ImportDeclSyntax.self) {
                guard let module = importDecl.path.first?.name.text, StaticManifestParser.allowedImports.contains(module) else {
                    return Decline(description: "import \(importDecl.path.trimmedDescription)")
                }
                return nil
            }

            // `#if`: only the clause the compiler would pick exists.
            if case .decl(let declaration) = item.item, let ifConfig = declaration.as(IfConfigDeclSyntax.self) {
                return self.visit(ifConfig)
            }

            // `let`/`var` with initializers become bindings; their values are evaluated only on demand.
            if case .decl(let declaration) = item.item, let variable = declaration.as(VariableDeclSyntax.self),
               variable.bindings.allSatisfy({ $0.initializer != nil && $0.pattern.is(IdentifierPatternSyntax.self) }) {
                return self.bind(variable)
            }

            // `package.targets.append(…)`, `package.dependencies += […]`, `targets.append(…)` on a top-level var.
            if case .expr(let expression) = item.item, let effect = Effect(expression) {
                switch effect.subject {
                case .packageMember:
                    self.effects.append(effect)
                    return nil
                case .variable(let name) where self.interpreter.isVariable(name):
                    // Arrays are values: only mutations before `Package(…)` reach the package.
                    if self.packageCall == nil {
                        self.interpreter.record(effect, on: name)
                    }
                    return nil
                case .variable:
                    break
                }
            }

            // Variables used by any other code can't be tracked: stop trusting them.
            self.interpreter.taint(MutationScanner.referencedNames(in: Syntax(item)))

            // Everything else (loops, `if`, functions, computed vars…) must not touch resolution inputs.
            if let token = MutationScanner.firstRelevantMutation(in: Syntax(item)) {
                return Decline(description: "may modify '\(token)': \(item.trimmedDescription.prefix(60))")
            }
            return nil
        }

        private mutating func bind(_ variable: VariableDeclSyntax) -> Decline? {
            let isConstant = variable.bindingSpecifier.tokenKind == .keyword(.let)
            for binding in variable.bindings {
                guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                      let value = binding.initializer?.value else { continue }

                // `Package` is a class, so `var package` behaves like `let` unless reassigned
                // (reassignment is flagged by the mutation scanner).
                if name == Label.package {
                    self.packageCall = StaticManifestParser.packageCall(value)
                    continue
                }
                // A binding that touches `package` could mutate it while initializing.
                guard !MutationScanner.referencesPackage(value) else {
                    return Decline(description: "binding '\(name)' references package")
                }
                self.interpreter.bind(name, value, constant: isConstant)
            }
            return nil
        }

        private mutating func visit(_ ifConfig: IfConfigDeclSyntax) -> Decline? {
            for clause in ifConfig.clauses {
                // `#else` has no condition and always matches.
                if let condition = clause.condition {
                    guard let isActive = self.conditions.evaluate(condition) else {
                        return Decline(description: "#if condition: \(condition.trimmedDescription)")
                    }
                    guard isActive else { continue }
                }
                guard let elements = clause.elements else { return nil }
                guard case .statements(let statements) = elements else {
                    return Decline(description: "#if clause with non-statement elements")
                }
                return self.walk(statements)
            }
            return nil
        }
    }

    private static func packageCall(_ expression: ExprSyntax) -> FunctionCallExprSyntax? {
        guard let call = expression.as(FunctionCallExprSyntax.self),
              call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text == Name.package,
              call.trailingClosure == nil else {
            return nil
        }
        return call
    }

    // MARK: - Interpreter

    /// Evaluates the small, pure subset of Swift used by declarative manifests.
    private struct Interpreter {
        private struct Binding {
            let value: ExprSyntax
            let isConstant: Bool
            /// Appends recorded on a `var` before the package was created.
            var mutations: [Effect] = []
            /// Set when other code mentions a `var`: its value is then unknowable.
            var isTainted = false

            var isTrusted: Bool {
                self.isConstant || !self.isTainted
            }
        }

        private var bindings: [String: Binding] = [:]
        private let packageDirectory: URL?

        /// Guards against `let a = b; let b = a`.
        private static let maximumReferenceDepth = 16
        private static let initializer = "init"
        private static let initializableTypes: Set<String> = ["Trait"]

        init(packageDirectory: URL?) {
            self.packageDirectory = packageDirectory
        }

        mutating func bind(_ name: String, _ value: ExprSyntax, constant: Bool) {
            self.bindings[name] = Binding(value: value, isConstant: constant)
        }

        func isVariable(_ name: String) -> Bool {
            self.bindings[name].map { !$0.isConstant } ?? false
        }

        mutating func record(_ effect: Effect, on name: String) {
            self.bindings[name]?.mutations.append(effect)
        }

        mutating func taint(_ names: Set<String>) {
            for name in names where self.isVariable(name) {
                self.bindings[name]?.isTainted = true
            }
        }

        // MARK: Package

        func manifest(from call: FunctionCallExprSyntax, toolsVersion: ToolsVersion) -> Result<Manifest, Decline> {
            let arguments = Arguments(call)
            guard let nameExpression = arguments[Label.name], let name = self.string(nameExpression) else {
                return .failure(Decline(description: "package name"))
            }

            // Each relevant argument is optional, but must be understood when present.
            guard let dependencies = self.required(arguments, Label.dependencies, self.dependency) else {
                return .failure(self.decline(arguments, Label.dependencies, self.dependency))
            }
            guard let products = self.required(arguments, Label.products, self.product) else {
                return .failure(self.decline(arguments, Label.products, self.product))
            }
            guard let targets = self.required(arguments, Label.targets, self.target) else {
                return .failure(self.decline(arguments, Label.targets, self.target))
            }
            guard let traits = self.required(arguments, Label.traits, self.packageTrait) else {
                return .failure(self.decline(arguments, Label.traits, self.packageTrait))
            }

            return .success(Manifest(
                name: name,
                toolsVersion: toolsVersion.description,
                dependencies: dependencies,
                targets: targets,
                products: products,
                traits: traits.sorted { $0.name < $1.name }
            ))
        }

        /// Applies top-level `package.X` mutations in source order.
        func apply(_ effects: [Effect], to manifest: Manifest) -> Result<Manifest, Decline> {
            var manifest = manifest
            for effect in effects {
                guard self.apply(effect, to: &manifest) else {
                    return .failure(Decline(description: "package.\(effect.member) mutation: \(effect.value.trimmedDescription.prefix(80))"))
                }
            }
            manifest.traits.sort { $0.name < $1.name }
            return .success(manifest)
        }

        private func apply(_ effect: Effect, to manifest: inout Manifest) -> Bool {
            switch effect.member {
            case Label.dependencies:
                return Self.apply(effect, to: &manifest.dependencies, element: self.dependency, list: { self.list($0, self.dependency) })
            case Label.targets:
                return Self.apply(effect, to: &manifest.targets, element: self.target, list: { self.list($0, self.target) })
            case Label.products:
                return Self.apply(effect, to: &manifest.products, element: self.product, list: { self.list($0, self.product) })
            case Label.traits:
                // A set: inserting an existing name keeps the original.
                var traits = manifest.traits
                guard Self.apply(effect, to: &traits, element: self.packageTrait, list: { self.list($0, self.packageTrait) }) else { return false }
                var seen: Set<String> = []
                manifest.traits = traits.filter { seen.insert($0.name).inserted }
                return true
            default:
                return false
            }
        }

        private static func apply<T>(_ effect: Effect, to values: inout [T], element: (ExprSyntax) -> T?, list: (ExprSyntax) -> [T]?) -> Bool {
            switch effect.operation {
            case .appendElement:
                guard let value = element(effect.value) else { return false }
                values.append(value)
            case .appendContents:
                guard let more = list(effect.value) else { return false }
                values += more
            case .replace:
                guard let replacement = list(effect.value) else { return false }
                values = replacement
            }
            return true
        }

        /// An optional list argument: absent is empty, present must be fully understood.
        private func required<T>(_ arguments: Arguments, _ label: String, _ element: (ExprSyntax) -> T?) -> [T]? {
            guard let expression = arguments[label] else { return [] }
            return self.list(expression, element)
        }

        /// Names the first element of `label` that wasn't understood.
        private func decline<T>(_ arguments: Arguments, _ label: String, _ element: (ExprSyntax) -> T?) -> Decline {
            guard let expression = arguments[label], let elements = self.array(expression) else {
                return Decline(description: "\(label): not a list literal: \(arguments[label]?.trimmedDescription.prefix(60) ?? "")")
            }
            let failing = elements.first { element($0) == nil }
            return Decline(description: "\(label): \(failing?.trimmedDescription.prefix(120) ?? "?")")
        }

        // MARK: Dependencies

        private func dependency(_ expression: ExprSyntax) -> Manifest.Dependency? {
            guard let (member, arguments) = self.call(expression), member == Label.package else { return nil }
            let explicitName = arguments[Label.name].flatMap { self.string($0) }
            if arguments[Label.name] != nil && explicitName == nil { return nil }
            guard let (traits, traitConditions) = self.dependencyTraits(arguments[Label.traits]) else { return nil }

            // Local path.
            if let pathExpression = arguments[Label.path] {
                guard let path = self.string(pathExpression), let resolved = self.resolve(path: path) else { return nil }
                return Manifest.Dependency(
                    identity: PackageIdentity(location: resolved).description,
                    explicitName: explicitName,
                    location: .local(path: resolved),
                    requirement: .none,
                    traits: traits,
                    traitConditions: traitConditions
                )
            }

            // Registry.
            if let idExpression = arguments[Label.id] {
                guard let id = self.string(idExpression), let requirement = self.requirement(arguments) else { return nil }
                // Registry identities keep their spelling (`dump-package` does too).
                return Manifest.Dependency(identity: id, explicitName: nil, location: .registry(identity: id), requirement: requirement, traits: traits, traitConditions: traitConditions)
            }

            // Source control.
            guard let urlExpression = arguments[Label.url], let url = self.string(urlExpression),
                  let requirement = self.requirement(arguments),
                  let kind = PackageKind.sourceControl(location: url) else { return nil }
            let location: Manifest.Dependency.Location
            switch kind {
            case .localSourceControl(let path):
                location = .localSourceControl(path: path)
            default:
                location = .remote(url: url)
            }
            return Manifest.Dependency(
                identity: PackageIdentity(location: url).description,
                explicitName: explicitName,
                location: location,
                requirement: requirement,
                traits: traits,
                traitConditions: traitConditions
            )
        }

        /// All `.package(…)` requirement spellings from PackageDescription 4.0 to 6.x.
        private func requirement(_ arguments: Arguments) -> Manifest.Dependency.Requirement? {
            if let from = arguments[Label.from] {
                return self.version(from).map(Self.upToNextMajor)
            }
            if let exact = arguments[Label.exact] {
                return self.version(exact).map { .exact($0.description) }
            }
            if let branch = arguments[Label.branch] {
                return self.string(branch).map { .branch($0) }
            }
            if let revision = arguments[Label.revision] {
                return self.string(revision).map { .revision($0) }
            }

            // Positional: a range, or a requirement factory (`.upToNextMinor(from:)`, `.branch("x")`…).
            guard let positional = arguments.unlabeled.first else { return nil }
            if let range = self.versionRange(positional) {
                return range
            }
            guard let (member, inner) = self.call(positional) else { return nil }
            switch member {
            case "upToNextMajor":
                return inner[Label.from].flatMap { self.version($0) }.map(Self.upToNextMajor)
            case "upToNextMinor":
                return inner[Label.from].flatMap { self.version($0) }.map(Self.upToNextMinor)
            case Label.exact:
                return inner.unlabeled.first.flatMap { self.version($0) }.map { .exact($0.description) }
            case Label.branch:
                return inner.unlabeled.first.flatMap { self.string($0) }.map { .branch($0) }
            case Label.revision:
                return inner.unlabeled.first.flatMap { self.string($0) }.map { .revision($0) }
            default:
                return nil
            }
        }

        private static func upToNextMajor(_ version: Version) -> Manifest.Dependency.Requirement {
            .range(lowerBound: version.description, upperBound: Version(version.major + 1, 0, 0).description)
        }

        private static func upToNextMinor(_ version: Version) -> Manifest.Dependency.Requirement {
            .range(lowerBound: version.description, upperBound: Version(version.major, version.minor + 1, 0).description)
        }

        /// `"1.0.0"..<"2.0.0"` or `"1.0.0"..."1.2.6"` (closed ranges bump the upper patch, like PackageDescription).
        private func versionRange(_ expression: ExprSyntax) -> Manifest.Dependency.Requirement? {
            guard let sequence = expression.as(SequenceExprSyntax.self) else { return nil }
            let elements = Array(sequence.elements)
            guard elements.count == 3,
                  let operatorText = elements[1].as(BinaryOperatorExprSyntax.self)?.operator.text,
                  let lower = self.version(elements[0]),
                  let upper = self.version(elements[2]) else {
                return nil
            }
            switch operatorText {
            case RangeOperator.halfOpen:
                return .range(lowerBound: lower.description, upperBound: upper.description)
            case RangeOperator.closed:
                let bumped = Version(upper.major, upper.minor, upper.patch + 1, prereleaseIdentifiers: upper.prereleaseIdentifiers, buildMetadataIdentifiers: upper.buildMetadataIdentifiers)
                return .range(lowerBound: lower.description, upperBound: bumped.description)
            default:
                return nil
            }
        }

        /// `traits:` on a dependency; absent means the package's defaults.
        /// A dependency's `traits:`: names (sorted, `default` when absent), plus the conditions of
        /// `.trait(name:condition: .when(traits:))` entries.
        private func dependencyTraits(_ expression: ExprSyntax?) -> (names: [String], conditions: [String: [String]])? {
            guard let expression else { return ([Name.defaultTrait], [:]) }
            guard let elements = self.array(expression) else { return nil }

            var names: [String] = []
            var conditions: [String: [String]] = [:]
            for element in elements {
                if let name = self.string(element) {
                    names.append(name)
                    continue
                }
                if element.as(MemberAccessExprSyntax.self)?.declName.baseName.text == "defaults" {
                    names.append(Name.defaultTrait)
                    continue
                }
                guard let (member, arguments) = self.call(element), member == "trait",
                      let name = arguments[Label.name].flatMap({ self.string($0) }) else { return nil }
                names.append(name)

                // Only trait conditions exist for dependency traits; anything else is not understood.
                guard let conditionExpression = arguments[Label.condition] else { continue }
                guard let condition = self.condition(conditionExpression), condition.platforms == nil,
                      let traits = condition.traits else { return nil }
                conditions[name] = traits
            }
            return (names.sorted(), conditions)
        }

        // MARK: Products and targets

        private static let productKinds: [String: Manifest.Product.Kind] = [
            "library": .library, "executable": .executable, "plugin": .plugin, "iOSApplication": .application,
        ]
        private static let targetKinds: [String: Manifest.Target.Kind] = [
            "target": .regular, "executableTarget": .executable, "testTarget": .test, "plugin": .plugin,
            "macro": .macro, "systemLibrary": .system, "binaryTarget": .binary,
        ]

        private func product(_ expression: ExprSyntax) -> Manifest.Product? {
            guard let (member, arguments) = self.call(expression), let kind = Self.productKinds[member],
                  let name = arguments[Label.name].flatMap({ self.string($0) }),
                  let targets = arguments[Label.targets].flatMap({ self.list($0, self.string) }) else {
                return nil
            }
            guard kind == .application else {
                return Manifest.Product(name: name, targets: targets, kind: kind)
            }
            guard let application = self.applicationSettings(arguments) else { return nil }
            return Manifest.Product(name: name, targets: targets, kind: kind, application: application)
        }

        private enum ApplicationLabel {
            static let bundleIdentifier = "bundleIdentifier"
            static let teamIdentifier = "teamIdentifier"
            static let displayVersion = "displayVersion"
            static let bundleVersion = "bundleVersion"
            static let deviceFamilies = "supportedDeviceFamilies"
            static let orientations = "supportedInterfaceOrientations"
        }

        /// `.iOSApplication` settings; any given but unreadable setting declines the manifest.
        private func applicationSettings(_ arguments: Arguments) -> Manifest.Product.ApplicationSettings? {
            func text(_ label: String) -> String?? {
                guard let expression = arguments[label] else { return .some(nil) }
                return self.string(expression).map { .some($0) }
            }
            func cases(_ label: String) -> [String]? {
                guard let expression = arguments[label] else { return [] }
                return self.list(expression, self.enumCaseName)
            }
            guard let bundleIdentifier = text(ApplicationLabel.bundleIdentifier),
                  let teamIdentifier = text(ApplicationLabel.teamIdentifier),
                  let displayVersion = text(ApplicationLabel.displayVersion),
                  let bundleVersion = text(ApplicationLabel.bundleVersion),
                  let deviceFamilies = cases(ApplicationLabel.deviceFamilies),
                  let orientations = cases(ApplicationLabel.orientations) else {
                return nil
            }
            return Manifest.Product.ApplicationSettings(
                bundleIdentifier: bundleIdentifier,
                teamIdentifier: teamIdentifier,
                displayVersion: displayVersion,
                bundleVersion: bundleVersion,
                deviceFamilies: deviceFamilies,
                interfaceOrientations: orientations
            )
        }

        /// `.phone`, or `.portrait(.when(…))`: the case name.
        private func enumCaseName(_ expression: ExprSyntax) -> String? {
            if let access = expression.as(MemberAccessExprSyntax.self), access.base == nil {
                return access.declName.baseName.text
            }
            guard let call = expression.as(FunctionCallExprSyntax.self),
                  let access = call.calledExpression.as(MemberAccessExprSyntax.self), access.base == nil else {
                return nil
            }
            return access.declName.baseName.text
        }

        private func target(_ expression: ExprSyntax) -> Manifest.Target? {
            guard let (member, arguments) = self.call(expression), let kind = Self.targetKinds[member],
                  let name = arguments[Label.name].flatMap({ self.string($0) }) else {
                return nil
            }
            let dependencies = arguments[Label.dependencies].map { self.list($0, self.targetDependency) } ?? []
            let plugins = arguments[Label.plugins].map { self.list($0, self.pluginUsage) } ?? []
            guard let dependencies, let plugins else { return nil }

            // Binary targets must name their artifact literally, or resolution can't fetch it.
            guard kind == .binary else {
                return Manifest.Target(name: name, kind: kind, dependencies: dependencies, pluginUsages: plugins)
            }
            guard let location = self.binaryLocation(arguments) else { return nil }
            return Manifest.Target(name: name, kind: kind, dependencies: dependencies, pluginUsages: plugins, binaryLocation: location)
        }

        private func binaryLocation(_ arguments: Arguments) -> Manifest.Target.BinaryLocation? {
            if let url = arguments[Label.url].flatMap({ self.string($0) }),
               let checksum = arguments[Label.checksum].flatMap({ self.string($0) }) {
                return .remote(url: url, checksum: checksum)
            }
            guard let path = arguments[Label.path].flatMap({ self.string($0) }) else { return nil }
            return .local(path: path)
        }

        private func targetDependency(_ expression: ExprSyntax) -> Manifest.TargetDependency? {
            // A bare string is `.byName`.
            if let name = self.string(expression) {
                return .byName(name: name, condition: nil)
            }
            guard let (member, arguments) = self.call(expression),
                  let name = arguments[Label.name].flatMap({ self.string($0) }) else { return nil }

            let condition: Manifest.Condition?
            if let conditionExpression = arguments[Label.condition] {
                guard let parsed = self.condition(conditionExpression) else { return nil }
                condition = parsed
            } else {
                condition = nil
            }

            switch member {
            case "target":
                return .target(name: name, condition: condition)
            case "byName":
                return .byName(name: name, condition: condition)
            case "product":
                guard let packageExpression = arguments[Label.package] else {
                    return .product(name: name, package: nil, condition: condition)
                }
                if packageExpression.is(NilLiteralExprSyntax.self) {
                    return .product(name: name, package: nil, condition: condition)
                }
                guard let package = self.string(packageExpression) else { return nil }
                return .product(name: name, package: package, condition: condition)
            default:
                return nil
            }
        }

        /// `.when(platforms: […], traits: […])`; traits matter for resolution, platforms label graphs.
        private func condition(_ expression: ExprSyntax) -> Manifest.Condition? {
            guard let (member, arguments) = self.call(expression), member == "when" else { return nil }

            // Platforms, spelled as PackageDescription names them (`.macOS` is "macos").
            var platforms: [String]?
            if let platformsExpression = arguments[Label.platforms] {
                guard let names = self.list(platformsExpression, self.platformName) else { return nil }
                platforms = names.isEmpty ? nil : names
            }

            guard let traitsExpression = arguments[Label.traits] else {
                return Manifest.Condition(platforms: platforms, traits: nil)
            }
            guard let traits = self.list(traitsExpression, self.string) else { return nil }
            return Manifest.Condition(platforms: platforms, traits: traits.sorted())
        }

        /// `.linux`, `.macOS`, `.custom("name")` → PackageDescription's `Platform.name`.
        private func platformName(_ expression: ExprSyntax) -> String? {
            // `.linux` or `Platform.linux`.
            if let member = expression.as(MemberAccessExprSyntax.self) {
                let base = member.base.flatMap { $0.as(DeclReferenceExprSyntax.self)?.baseName.text }
                guard member.base == nil || base == Name.platform else { return nil }
                return member.declName.baseName.text.lowercased()
            }

            // `.custom("name")` keeps the name as written.
            guard let (member, arguments) = self.call(expression), member == Name.customPlatform,
                  let name = arguments.unlabeled.first.flatMap({ self.string($0) }) else { return nil }
            return name
        }

        private func pluginUsage(_ expression: ExprSyntax) -> Manifest.PluginUsage? {
            guard let (member, arguments) = self.call(expression), member == "plugin",
                  let name = arguments[Label.name].flatMap({ self.string($0) }) else { return nil }
            guard let packageExpression = arguments[Label.package] else {
                return Manifest.PluginUsage(name: name, package: nil)
            }
            guard let package = self.string(packageExpression) else { return nil }
            return Manifest.PluginUsage(name: name, package: package)
        }

        // MARK: Traits

        private func packageTrait(_ expression: ExprSyntax) -> Manifest.Trait? {
            if let name = self.string(expression) {
                return Manifest.Trait(name: name, enabledTraits: [])
            }
            guard let (member, arguments) = self.call(expression) else { return nil }
            let enabled = arguments[Label.enabledTraits].map { self.list($0, self.string) } ?? []
            guard let enabled else { return nil }

            switch member {
            case "default":
                return Manifest.Trait(name: Name.defaultTrait, enabledTraits: enabled.sorted())
            case "trait", "init":
                guard let name = arguments[Label.name].flatMap({ self.string($0) }) else { return nil }
                return Manifest.Trait(name: name, enabledTraits: enabled.sorted())
            default:
                return nil
            }
        }

        // MARK: Primitive values

        /// A list where every element must be understood.
        private func list<T>(_ expression: ExprSyntax, _ element: (ExprSyntax) -> T?) -> [T]? {
            guard let elements = self.array(expression) else { return nil }
            var result: [T] = []
            for item in elements {
                guard let value = element(item) else { return nil }
                result.append(value)
            }
            return result
        }

        /// Array literals, constant references, and `+` concatenation.
        private func array(_ expression: ExprSyntax, depth: Int = 0) -> [ExprSyntax]? {
            guard depth < Self.maximumReferenceDepth else { return nil }
            let expression = Self.unwrapParentheses(expression)

            if let literal = expression.as(ArrayExprSyntax.self) {
                return literal.elements.map(\.expression)
            }
            if let reference = expression.as(DeclReferenceExprSyntax.self),
               let binding = self.bindings[reference.baseName.text], binding.isTrusted {
                // Start from the initializer, then replay recorded appends.
                guard var elements = self.array(binding.value, depth: depth + 1) else { return nil }
                for mutation in binding.mutations {
                    switch mutation.operation {
                    case .appendElement:
                        elements.append(mutation.value)
                    case .appendContents:
                        guard let more = self.array(mutation.value, depth: depth + 1) else { return nil }
                        elements += more
                    case .replace:
                        guard let replacement = self.array(mutation.value, depth: depth + 1) else { return nil }
                        elements = replacement
                    }
                }
                return elements
            }

            // `xs.map { x in …; return x }` that only adjusts irrelevant fields is `xs`.
            if let base = Self.identityMapBase(expression) {
                return self.array(base, depth: depth + 1)
            }

            // `a + b + …` arrives unfolded as a sequence of operands and `+` operators.
            guard let sequence = expression.as(SequenceExprSyntax.self) else { return nil }
            var result: [ExprSyntax] = []
            for (index, element) in sequence.elements.enumerated() {
                if index.isMultiple(of: 2) {
                    guard let part = self.array(element, depth: depth + 1) else { return nil }
                    result += part
                } else {
                    guard element.as(BinaryOperatorExprSyntax.self)?.operator.text == "+" else { return nil }
                }
            }
            return result
        }

        /// String literals without interpolation or escapes, and constant references.
        private func string(_ expression: ExprSyntax) -> String? {
            self.string(expression, depth: 0)
        }

        private func string(_ expression: ExprSyntax, depth: Int) -> String? {
            guard depth < Self.maximumReferenceDepth else { return nil }
            let expression = Self.unwrapParentheses(expression)

            if let referenced = self.constant(expression) {
                return self.string(referenced, depth: depth + 1)
            }
            guard let literal = expression.as(StringLiteralExprSyntax.self) else { return nil }

            var text = ""
            for segment in literal.segments {
                guard case .stringSegment(let piece) = segment else { return nil }
                text += piece.content.text
            }
            // Escapes would need unescaping; they never appear in names, URLs or versions.
            guard !text.contains("\\") else { return nil }
            return text
        }

        /// `"1.2.3"`, `Version(1, 2, 3)`, or a constant holding one.
        private func version(_ expression: ExprSyntax) -> Version? {
            let expression = Self.unwrapParentheses(expression)
            if let text = self.string(expression) {
                return Version(text)
            }
            if let referenced = self.constant(expression) {
                return self.version(referenced)
            }
            guard let call = expression.as(FunctionCallExprSyntax.self),
                  call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text == Name.version else {
                return nil
            }
            let numbers = call.arguments.compactMap { Int($0.expression.as(IntegerLiteralExprSyntax.self)?.literal.text ?? "") }
            guard call.arguments.count == 3, numbers.count == 3 else { return nil }
            return Version(numbers[0], numbers[1], numbers[2])
        }

        /// `.member(args)` or `Type.member(args)`; trailing closures are never understood.
        private func call(_ expression: ExprSyntax) -> (String, Arguments)? {
            let expression = Self.unwrapParentheses(expression)
            if let referenced = self.constant(expression) {
                return self.call(referenced)
            }
            guard let call = expression.as(FunctionCallExprSyntax.self), call.trailingClosure == nil,
                  call.additionalTrailingClosures.isEmpty else {
                return nil
            }
            // `Trait(name: …)` is `.init(name: …)`.
            if let type = call.calledExpression.as(DeclReferenceExprSyntax.self), Self.initializableTypes.contains(type.baseName.text) {
                return (Self.initializer, Arguments(call))
            }
            guard let member = call.calledExpression.as(MemberAccessExprSyntax.self) else {
                return nil
            }
            return (member.declName.baseName.text, Arguments(call))
        }

        /// The value of a `let` constant referenced by name.
        private func constant(_ expression: ExprSyntax) -> ExprSyntax? {
            guard let reference = expression.as(DeclReferenceExprSyntax.self),
                  let binding = self.bindings[reference.baseName.text],
                  binding.isTrusted, binding.mutations.isEmpty else {
                return nil
            }
            return binding.value
        }

        /// Recognizes `base.map { item in <settings tweaks>; return item }`.
        ///
        /// Targets are classes, so such closures hand back the same objects; as long as the body
        /// never mentions a resolution input, the mapped list is the original as far as we care.
        private static func identityMapBase(_ expression: ExprSyntax) -> ExprSyntax? {
            guard let call = expression.as(FunctionCallExprSyntax.self), call.arguments.isEmpty,
                  let method = call.calledExpression.as(MemberAccessExprSyntax.self),
                  method.declName.baseName.text == Self.mapMethod,
                  let base = method.base,
                  let closure = call.trailingClosure,
                  call.additionalTrailingClosures.isEmpty else {
                return nil
            }

            // One named parameter, returned unchanged as the last statement.
            guard let parameters = closure.signature?.parameterClause?.as(ClosureShorthandParameterListSyntax.self),
                  parameters.count == 1, let parameter = parameters.first?.name.text,
                  let last = closure.statements.last,
                  let returned = last.item.as(ReturnStmtSyntax.self)?.expression?.as(DeclReferenceExprSyntax.self),
                  returned.baseName.text == parameter else {
                return nil
            }
            guard MutationScanner.firstRelevantMutation(in: Syntax(closure.statements)) == nil else {
                return nil
            }
            return base
        }

        private static let mapMethod = "map"

        private static func unwrapParentheses(_ expression: ExprSyntax) -> ExprSyntax {
            guard let tuple = expression.as(TupleExprSyntax.self), tuple.elements.count == 1,
                  let only = tuple.elements.first, only.label == nil else {
                return expression
            }
            return Self.unwrapParentheses(only.expression)
        }

        /// Joins lexically, like SwiftPM's `AbsolutePath` (no symlink resolution, `/private` kept).
        private func resolve(path: String) -> String? {
            guard let packageDirectory = self.packageDirectory else { return nil }
            return FileSystem.normalize(path, relativeTo: packageDirectory.path)
        }
    }

    /// Labeled and positional arguments of a call.
    private struct Arguments {
        private let labeled: [String: ExprSyntax]
        let unlabeled: [ExprSyntax]

        init(_ call: FunctionCallExprSyntax) {
            var labeled: [String: ExprSyntax] = [:]
            var unlabeled: [ExprSyntax] = []
            for argument in call.arguments {
                if let label = argument.label?.text {
                    labeled[label] = argument.expression
                } else {
                    unlabeled.append(argument.expression)
                }
            }
            self.labeled = labeled
            self.unlabeled = unlabeled
        }

        subscript(label: String) -> ExprSyntax? {
            self.labeled[label]
        }
    }
}

// MARK: - Package mutations

/// A top-level `package.<member>` mutation the interpreter can replay.
struct Effect {
    enum Operation {
        /// `.append(x)` / `.insert(x)`
        case appendElement
        /// `.append(contentsOf: xs)` / `+= xs` / `.formUnion(xs)`
        case appendContents
        /// `= xs`
        case replace
    }

    /// What is being mutated.
    enum Subject: Equatable {
        /// `package.<member>`
        case packageMember(String)
        /// A top-level `var` holding an array.
        case variable(String)
    }

    private static let packageGlobal = "package"
    private static let mutableMembers: Set<String> = ["dependencies", "targets", "products", "traits"]

    let subject: Subject
    let operation: Operation
    let value: ExprSyntax

    /// The package member name, for package mutations.
    var member: String {
        switch self.subject {
        case .packageMember(let member), .variable(let member):
            return member
        }
    }

    init?(_ expression: ExprSyntax) {
        // `package.X.append(…)`
        if let call = expression.as(FunctionCallExprSyntax.self), call.trailingClosure == nil,
           let method = call.calledExpression.as(MemberAccessExprSyntax.self),
           let subject = Self.subject(method.base),
           call.arguments.count == 1, let argument = call.arguments.first {
            let label = argument.label?.text
            switch (method.declName.baseName.text, label) {
            case ("append", nil), ("insert", nil):
                self.init(subject: subject, operation: .appendElement, value: argument.expression)
            case ("append", "contentsOf"?), ("formUnion", nil):
                self.init(subject: subject, operation: .appendContents, value: argument.expression)
            default:
                return nil
            }
            return
        }

        // `package.X += […]` / `package.X = […]`
        guard let sequence = expression.as(SequenceExprSyntax.self) else { return nil }
        let elements = Array(sequence.elements)
        guard elements.count == 3, let subject = Self.subject(elements[0]) else { return nil }
        if elements[1].as(BinaryOperatorExprSyntax.self)?.operator.text == "+=" {
            self.init(subject: subject, operation: .appendContents, value: elements[2])
        } else if elements[1].is(AssignmentExprSyntax.self) {
            self.init(subject: subject, operation: .replace, value: elements[2])
        } else {
            return nil
        }
    }

    init(subject: Subject, operation: Operation, value: ExprSyntax) {
        self.subject = subject
        self.operation = operation
        self.value = value
    }

    /// `package.dependencies` → `.packageMember("dependencies")`; `deps` → `.variable("deps")`.
    private static func subject(_ expression: ExprSyntax?) -> Subject? {
        if let reference = expression?.as(DeclReferenceExprSyntax.self), reference.baseName.text != Self.packageGlobal {
            return .variable(reference.baseName.text)
        }
        guard let access = expression?.as(MemberAccessExprSyntax.self),
              access.base?.as(DeclReferenceExprSyntax.self)?.baseName.text == Self.packageGlobal else {
            return nil
        }
        let name = access.declName.baseName.text
        return Self.mutableMembers.contains(name) ? .packageMember(name) : nil
    }
}

// MARK: - Compilation conditions

/// The facts `#if` can test, as seen when SwiftPM compiles a manifest on this machine.
public struct CompilationEnvironment: Sendable {
    public let operatingSystem: String
    public let architecture: String
    public let importableModules: Set<String>
    public let unimportableModules: Set<String>
    /// The running compiler (`swift --version`); `nil` makes version checks undecidable.
    public let compilerVersion: ToolsVersion?

    /// The machine `swx` runs on, which is also where SwiftPM would evaluate the manifest.
    public static func host(compilerVersion: ToolsVersion?) -> CompilationEnvironment {
        #if os(macOS)
        let operatingSystem = "macOS"
        // Probed with `swiftc -typecheck` the way SwiftPM compiles manifests (no test frameworks).
        let importable: Set<String> = ["Darwin", "Foundation", "Dispatch", "ObjectiveC", "PackageDescription", "Synchronization", "os"]
        let unimportable: Set<String> = [
            "Glibc", "Musl", "WinSDK", "Android", "Bionic", "WASILibc", "ucrt", "CRT",
            "FoundationEssentials", "FoundationInternationalization", "XCTest", "Testing",
        ]
        #elseif os(Linux)
        let operatingSystem = "Linux"
        let importable: Set<String> = ["Glibc", "Foundation", "Dispatch", "PackageDescription"]
        let unimportable: Set<String> = ["Darwin", "ObjectiveC", "WinSDK", "Android", "Bionic", "WASILibc", "ucrt", "CRT", "Musl"]
        #else
        let operatingSystem = "unknown"
        let importable: Set<String> = []
        let unimportable: Set<String> = []
        #endif

        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif

        return CompilationEnvironment(
            operatingSystem: operatingSystem,
            architecture: architecture,
            importableModules: importable,
            unimportableModules: unimportable,
            compilerVersion: compilerVersion
        )
    }
}

/// Evaluates `#if` conditions; `nil` means "can't tell", which makes the parser decline.
struct ConditionEvaluator {
    let environment: CompilationEnvironment
    let toolsVersion: ToolsVersion

    /// Manifests are compiled in language mode 6 from tools 6.0, mode 5 before.
    private static let languageModeSixToolsVersion = ToolsVersion(6, 0)
    /// Language versions every supported toolchain satisfies in Swift 5 mode.
    private static let swiftFiveModeCeiling = ToolsVersion(5, 9)

    func evaluate(_ expression: ExprSyntax) -> Bool? {
        // `(…)`
        if let tuple = expression.as(TupleExprSyntax.self), tuple.elements.count == 1, let inner = tuple.elements.first {
            return self.evaluate(inner.expression)
        }
        // `!x`
        if let prefix = expression.as(PrefixOperatorExprSyntax.self), prefix.operator.text == "!" {
            return self.evaluate(prefix.expression).map { !$0 }
        }
        if let literal = expression.as(BooleanLiteralExprSyntax.self) {
            return literal.literal.tokenKind == .keyword(.true)
        }
        // Custom `-D` flags: manifests are compiled without any.
        if expression.is(DeclReferenceExprSyntax.self) {
            return false
        }
        if let sequence = expression.as(SequenceExprSyntax.self) {
            return self.evaluate(sequence)
        }
        if let call = expression.as(FunctionCallExprSyntax.self) {
            return self.evaluate(call)
        }
        return nil
    }

    /// `a && b || c`, honouring `&&` binding tighter than `||`.
    private func evaluate(_ sequence: SequenceExprSyntax) -> Bool? {
        var disjunction: [[ExprSyntax]] = [[]]
        for (index, element) in sequence.elements.enumerated() {
            guard !index.isMultiple(of: 2) else {
                disjunction[disjunction.count - 1].append(element)
                continue
            }
            switch element.as(BinaryOperatorExprSyntax.self)?.operator.text {
            case "&&":
                continue
            case "||":
                disjunction.append([])
            default:
                return nil
            }
        }

        var anyTrue = false
        for conjunction in disjunction {
            var allTrue = true
            for operand in conjunction {
                guard let value = self.evaluate(operand) else { return nil }
                allTrue = allTrue && value
            }
            anyTrue = anyTrue || allTrue
        }
        return anyTrue
    }

    private func evaluate(_ call: FunctionCallExprSyntax) -> Bool? {
        guard let function = call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text,
              call.arguments.count == 1, let argument = call.arguments.first?.expression else {
            return nil
        }
        switch function {
        case "os":
            return argument.as(DeclReferenceExprSyntax.self).map { $0.baseName.text == self.environment.operatingSystem }
        case "arch":
            return argument.as(DeclReferenceExprSyntax.self).map { $0.baseName.text == self.environment.architecture }
        case "canImport":
            let module = argument.trimmedDescription
            if self.environment.importableModules.contains(module) { return true }
            if self.environment.unimportableModules.contains(module) { return false }
            return nil
        case "swift":
            return self.compareVersion(argument, against: self.languageVersion)
        case "compiler":
            return self.compareVersion(argument, against: self.environment.compilerVersion)
        default:
            return nil
        }
    }

    /// The effective `swift(…)` version: the compiler's in mode 6; in mode 5 only "≥ 5.9" is certain.
    private var languageVersion: ToolsVersion? {
        guard self.toolsVersion >= Self.languageModeSixToolsVersion else { return nil }
        return self.environment.compilerVersion
    }

    /// `>=5.9` or `<6`.
    private func compareVersion(_ argument: ExprSyntax, against current: ToolsVersion?) -> Bool? {
        guard let prefix = argument.as(PrefixOperatorExprSyntax.self),
              let target = ToolsVersion.parse(versionText: prefix.expression.trimmedDescription)
                ?? Int(prefix.expression.trimmedDescription).map({ ToolsVersion($0, 0) }) else {
            return nil
        }

        // In language mode 5 we only know that every modern compiler is at least 5.9.
        guard let current else {
            guard target <= Self.swiftFiveModeCeiling else { return nil }
            switch prefix.operator.text {
            case ">=":
                return true
            case "<":
                return false
            default:
                return nil
            }
        }

        switch prefix.operator.text {
        case ">=":
            return current >= target
        case "<":
            return current < target
        default:
            return nil
        }
    }
}

// MARK: - Mutation safety

/// Conservative token-level checks that code cannot change what resolution reads.
enum MutationScanner {
    /// Members whose mention anywhere means the code might change a resolution input.
    private static let relevantMembers: Set<String> = [
        "dependencies", "products", "traits", "plugins", "pluginUsages", "requirement", "url", "path",
    ]
    /// Members that are read harmlessly, but are inputs when mutated.
    private static let guardedMembers: Set<String> = ["targets", "name", "package"]
    private static let mutatingMethods: Set<String> = [
        "append", "insert", "remove", "removeAll", "removeFirst", "removeLast", "replaceSubrange", "removeSubrange",
    ]
    private static let mutatingOperators: Set<String> = ["=", "+=", "-=", "["]
    private static let memberAccess = "."
    private static let packageGlobal = "package"

    /// The first token suggesting a mutation of resolution inputs, if any.
    static func firstRelevantMutation(in node: Syntax) -> String? {
        let tokens = node.tokens(viewMode: .sourceAccurate).map(\.text)

        for (index, token) in tokens.enumerated() {
            if Self.relevantMembers.contains(token) {
                return token
            }
            guard Self.guardedMembers.contains(token), index + 1 < tokens.count else { continue }

            // `targets = …`, `targets += …`, `targets[0] …`
            let next = tokens[index + 1]
            if Self.mutatingOperators.contains(next) {
                return token
            }
            // `targets.append(…)`
            if next == Self.memberAccess, index + 2 < tokens.count, Self.mutatingMethods.contains(tokens[index + 2]) {
                return token
            }
        }
        return nil
    }

    /// Every identifier token in the node (used to taint variables mentioned by opaque code).
    static func referencedNames(in node: Syntax) -> Set<String> {
        Set(node.tokens(viewMode: .sourceAccurate).compactMap { token in
            guard case .identifier(let name) = token.tokenKind else { return nil }
            return name
        })
    }

    /// Does the expression refer to the global `package` (as opposed to `.package(…)` members)?
    static func referencesPackage(_ expression: ExprSyntax) -> Bool {
        let visitor = PackageReferenceVisitor(viewMode: .sourceAccurate)
        visitor.walk(expression)
        return visitor.found
    }

    private final class PackageReferenceVisitor: SyntaxVisitor {
        var found = false

        override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
            // `.package(…)` is a member name, not a reference to the global.
            let isMemberName = node.parent?.as(MemberAccessExprSyntax.self)?.declName.id == node.id
            if node.baseName.text == MutationScanner.packageGlobal && !isMemberName {
                self.found = true
            }
            return .visitChildren
        }
    }
}
