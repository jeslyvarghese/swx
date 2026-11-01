import Foundation
import SwxManifest

/// `swx-xcode.json`: what an app needs from its Xcode project that `Package.swift` can't say —
/// entitlements, extra Info.plist keys, a widget extension and a watchOS companion app. Read next
/// to the manifest by `swx xcode generate` and by the private project of `swx build|run|hot`.
///
/// Parsed, not validated: once a value exists, every target, app and bundle identifier it names is
/// known to be consistent with the manifest.
public struct XcodeOverlay: Sendable, Equatable {
    public static let fileName = "swx-xcode.json"

    /// Overlays of `.iOSApplication` products, by product name.
    public let applications: [String: ApplicationOverlay]

    /// Extra targets, sorted by name so the generated spec is stable.
    public let targets: [ExtraTarget]

    /// No overlay file: the project is exactly what the manifest describes.
    public static let none = XcodeOverlay(applications: [:], targets: [])

    init(applications: [String: ApplicationOverlay], targets: [ExtraTarget]) {
        self.applications = applications
        self.targets = targets
    }

    /// What the overlay adds to an app product's own target.
    public struct ApplicationOverlay: Sendable, Equatable {
        public let entitlements: [String: PlistValue]
        public let infoPlist: [String: PlistValue]
    }

    /// A target with no SwiftPM equivalent, built from SwiftPM targets' sources.
    public struct ExtraTarget: Sendable, Equatable {
        public let name: String
        public let kind: Kind
        /// SwiftPM targets whose sources make up this target (never empty).
        public let sources: [String]
        public let bundleIdentifier: String
        /// The app product that embeds it.
        public let embedIn: String
        public let deploymentTarget: String?
        public let entitlements: [String: PlistValue]
        public let infoPlist: [String: PlistValue]
    }

    /// The kinds of extra targets swx knows how to build and embed.
    public enum Kind: String, Sendable, Equatable, CaseIterable {
        /// A WidgetKit extension (widgets, Live Activities), embedded in the app's PlugIns.
        case widgetExtension
        /// A single-target watchOS app, embedded in the iOS app as its companion.
        case watchApp

        /// The platform the target is built for.
        var platform: XcodeProjectGenerator.TargetPlatform {
            switch self {
            case .widgetExtension: .iOS
            case .watchApp: .watchOS
            }
        }
    }

    /// A property-list value: what entitlements and Info.plist entries can hold.
    public enum PlistValue: Sendable, Equatable {
        case bool(Bool)
        case integer(Int)
        case real(Double)
        case string(String)
        case array([PlistValue])
        case dictionary([String: PlistValue])

        /// The JSON value XcodeGen writes back into a plist.
        var json: Any {
            switch self {
            case .bool(let value): value
            case .integer(let value): value
            case .real(let value): value
            case .string(let value): value
            case .array(let values): values.map(\.json)
            case .dictionary(let values): values.mapValues(\.json)
            }
        }
    }
}

// MARK: - Parsing (pure)

extension XcodeOverlay {
    /// Keys of the overlay file, so a misspelt key is an error instead of silently ignored.
    private enum Key {
        static let applications = "applications"
        static let targets = "targets"
        static let entitlements = "entitlements"
        static let infoPlist = "infoPlist"
        static let kind = "kind"
        static let sources = "sources"
        static let bundleIdentifier = "bundleIdentifier"
        static let embedIn = "embedIn"
        static let deploymentTarget = "deploymentTarget"

        static let root: Set<String> = [applications, targets]
        static let application: Set<String> = [entitlements, infoPlist]
        static let target: Set<String> = [kind, sources, bundleIdentifier, embedIn, deploymentTarget, entitlements, infoPlist]
    }

    private static let bundleIdentifierSeparator = "."
    private static let versionComponentSeparator: Character = "."

    /// Parses `data` (the contents of `swx-xcode.json`) against the package it sits in.
    public static func parse(_ data: Data, manifest: Manifest) throws -> XcodeOverlay {
        let root = try Self.object(Self.json(data), at: [])
        try Self.rejectUnknownKeys(of: root, allowed: Key.root, at: [])

        // Apps are known before targets, since targets are embedded in them.
        let appProducts = Dictionary(uniqueKeysWithValues: manifest.products.filter { $0.kind == .application }.map { ($0.name, $0) })
        let applications = try Self.applications(root[Key.applications], products: appProducts)
        let targets = try Self.targets(root[Key.targets], manifest: manifest, products: appProducts)
        try Self.checkBundleIdentifiers(targets: targets, products: appProducts)
        return XcodeOverlay(applications: applications, targets: targets)
    }

    private static func json(_ data: Data) throws -> Any {
        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            throw Self.error("is not valid JSON (\(error.localizedDescription))", at: [])
        }
    }

    private static func applications(_ value: Any?, products: [String: Manifest.Product]) throws -> [String: ApplicationOverlay] {
        guard let value else { return [:] }

        let path = [Key.applications]
        var applications: [String: ApplicationOverlay] = [:]
        for (name, body) in try Self.object(value, at: path) {
            let appPath = path + [name]
            guard products[name] != nil else {
                throw Self.error("names no .iOSApplication product of the package (apps: \(Self.list(products.keys)))", at: appPath)
            }

            let object = try Self.object(body, at: appPath)
            try Self.rejectUnknownKeys(of: object, allowed: Key.application, at: appPath)
            applications[name] = ApplicationOverlay(
                entitlements: try Self.plistDictionary(object[Key.entitlements], at: appPath + [Key.entitlements]),
                infoPlist: try Self.plistDictionary(object[Key.infoPlist], at: appPath + [Key.infoPlist])
            )
        }
        return applications
    }

    private static func targets(_ value: Any?, manifest: Manifest, products: [String: Manifest.Product]) throws -> [ExtraTarget] {
        guard let value else { return [] }

        let path = [Key.targets]
        let packageTargets = Set(manifest.targets.map(\.name))
        var targets: [ExtraTarget] = []
        for (name, body) in try Self.object(value, at: path).sorted(by: { $0.key < $1.key }) {
            let targetPath = path + [name]

            // Extra targets share XcodeGen's namespace with apps and the libraries made of SwiftPM targets.
            guard !packageTargets.contains(name), products[name] == nil else {
                throw Self.error("is already the name of a target or app of the package; pick another name", at: targetPath)
            }

            let object = try Self.object(body, at: targetPath)
            try Self.rejectUnknownKeys(of: object, allowed: Key.target, at: targetPath)

            // The kind decides how the target is built and where the app embeds it.
            let kindName = try Self.string(object[Key.kind], at: targetPath + [Key.kind])
            guard let kind = Kind(rawValue: kindName) else {
                throw Self.error("'\(kindName)' is not a known kind (expected \(Self.list(Kind.allCases.map(\.rawValue))))", at: targetPath + [Key.kind])
            }

            // Sources are SwiftPM targets of this package, at least one.
            let sourcesPath = targetPath + [Key.sources]
            let sources = try Self.strings(object[Key.sources], at: sourcesPath)
            guard !sources.isEmpty else {
                throw Self.error("needs at least one SwiftPM target", at: sourcesPath)
            }
            for source in sources where !packageTargets.contains(source) {
                throw Self.error("'\(source)' is not a target of the package", at: sourcesPath)
            }

            // The embedding app must exist; its own targets can't double as extension sources.
            let embedPath = targetPath + [Key.embedIn]
            let embedIn = try Self.string(object[Key.embedIn], at: embedPath)
            guard let app = products[embedIn] else {
                throw Self.error("'\(embedIn)' is not an .iOSApplication product of the package (apps: \(Self.list(products.keys)))", at: embedPath)
            }
            for source in sources where app.targets.contains(source) {
                throw Self.error("'\(source)' is already the app's own target", at: sourcesPath)
            }

            let deploymentTarget = try object[Key.deploymentTarget].map { try Self.version($0, at: targetPath + [Key.deploymentTarget]) }
            targets.append(ExtraTarget(
                name: name,
                kind: kind,
                sources: sources,
                bundleIdentifier: try Self.string(object[Key.bundleIdentifier], at: targetPath + [Key.bundleIdentifier]),
                embedIn: embedIn,
                deploymentTarget: deploymentTarget,
                entitlements: try Self.plistDictionary(object[Key.entitlements], at: targetPath + [Key.entitlements]),
                infoPlist: try Self.plistDictionary(object[Key.infoPlist], at: targetPath + [Key.infoPlist])
            ))
        }
        try Self.checkOneWatchAppPerApp(targets)
        return targets
    }

    /// An iOS app has at most one watch companion.
    private static func checkOneWatchAppPerApp(_ targets: [ExtraTarget]) throws {
        var appsWithWatch: Set<String> = []
        for target in targets where target.kind == .watchApp {
            guard appsWithWatch.insert(target.embedIn).inserted else {
                throw Self.error("'\(target.embedIn)' already embeds a watch app", at: [Key.targets, target.name, Key.embedIn])
            }
        }
    }

    /// Bundle identifiers are unique, and embedded targets live under their app's identifier,
    /// as App Store validation and the watch companion pairing require.
    private static func checkBundleIdentifiers(targets: [ExtraTarget], products: [String: Manifest.Product]) throws {
        var owners: [String: String] = [:]
        for (name, product) in products {
            guard let identifier = product.application?.bundleIdentifier else { continue }
            owners[identifier] = name
        }

        for target in targets {
            let path = [Key.targets, target.name, Key.bundleIdentifier]
            if let owner = owners[target.bundleIdentifier] {
                throw Self.error("'\(target.bundleIdentifier)' is already the bundle identifier of \(owner)", at: path)
            }
            owners[target.bundleIdentifier] = target.name

            guard let appIdentifier = products[target.embedIn]?.application?.bundleIdentifier else {
                throw Self.error("\(target.embedIn) has no bundleIdentifier in Package.swift; targets embedded in it need one to derive theirs from", at: path)
            }
            guard target.bundleIdentifier.hasPrefix(appIdentifier + Self.bundleIdentifierSeparator) else {
                throw Self.error("'\(target.bundleIdentifier)' must start with '\(appIdentifier)\(Self.bundleIdentifierSeparator)', the identifier of \(target.embedIn)", at: path)
            }
        }
    }

    // MARK: JSON helpers

    private static func object(_ value: Any, at path: [String]) throws -> [String: Any] {
        guard let object = value as? [String: Any] else { throw Self.error("must be an object", at: path) }
        return object
    }

    private static func string(_ value: Any?, at path: [String]) throws -> String {
        guard let value else { throw Self.error("is required", at: path) }
        guard let string = value as? String, !string.isEmpty else { throw Self.error("must be a non-empty string", at: path) }
        return string
    }

    private static func strings(_ value: Any?, at path: [String]) throws -> [String] {
        guard let value else { throw Self.error("is required", at: path) }
        guard let strings = value as? [String] else { throw Self.error("must be an array of strings", at: path) }
        return strings
    }

    /// A version like `11` or `17.4`.
    private static func version(_ value: Any, at path: [String]) throws -> String {
        let version = try Self.string(value, at: path)
        let components = version.split(separator: Self.versionComponentSeparator, omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) else {
            throw Self.error("'\(version)' is not a version like 11.0", at: path)
        }
        return version
    }

    private static func rejectUnknownKeys(of object: [String: Any], allowed: Set<String>, at path: [String]) throws {
        let unknown = Set(object.keys).subtracting(allowed)
        guard unknown.isEmpty else {
            throw Self.error("has unknown key(s) \(Self.list(unknown)) (allowed: \(Self.list(allowed)))", at: path)
        }
    }

    private static func plistDictionary(_ value: Any?, at path: [String]) throws -> [String: PlistValue] {
        guard let value else { return [:] }
        return try Self.object(value, at: path).reduce(into: [:]) { result, entry in
            result[entry.key] = try Self.plistValue(entry.value, at: path + [entry.key])
        }
    }

    private static func plistValue(_ value: Any, at path: [String]) throws -> PlistValue {
        switch value {
        case let number as NSNumber:
            // JSON booleans arrive as NSNumber too; tell them apart before numbers.
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            if CFNumberIsFloatType(number) { return .real(number.doubleValue) }
            return .integer(number.intValue)
        case let string as String:
            return .string(string)
        case let array as [Any]:
            return .array(try array.enumerated().map { try Self.plistValue($0.element, at: path + ["\($0.offset)"]) })
        case let object as [String: Any]:
            return .dictionary(try Self.plistDictionary(object, at: path))
        default:
            throw Self.error("null can't be stored in a property list", at: path)
        }
    }

    private static func list(_ names: some Sequence<String>) -> String {
        let sorted = names.sorted()
        return sorted.isEmpty ? "none" : sorted.joined(separator: ", ")
    }

    /// Errors name the file and the dotted key path, e.g. `swx-xcode.json: targets.Widget.kind: …`.
    private static func error(_ message: String, at path: [String]) -> WorkspaceError {
        let location = path.isEmpty ? Self.fileName : "\(Self.fileName): \(path.joined(separator: "."))"
        return WorkspaceError(description: "\(location) \(message)", code: .invalidXcodeOverlay, fix: "edit \(Self.fileName) next to Package.swift")
    }
}
