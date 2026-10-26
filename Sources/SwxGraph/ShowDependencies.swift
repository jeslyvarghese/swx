/// `swift package show-dependencies --format …`.
public enum ShowDependenciesFormat: String, Sendable, CaseIterable {
    case text
    case dot
    case json
    case flatlist
}

/// SwiftPM's dependency dumpers (`DependenciesSerializer.swift`), ported line for line so the
/// output is byte-identical to `swift package show-dependencies`.
extension PackageGraph {
    private static let unspecifiedVersion = "unspecified"
    private static let noDependencies = "No external dependencies found\n"

    public func showDependencies(_ format: ShowDependenciesFormat) -> String {
        switch format {
        case .text:
            return self.plainText()
        case .dot:
            return self.dot()
        case .json:
            return self.json()
        case .flatlist:
            return self.flatList()
        }
    }

    private func versionText(_ package: GraphPackage) -> String {
        package.version ?? Self.unspecifiedVersion
    }

    private func hasDependencies(_ package: GraphPackage) -> Bool {
        !(self.dependencies[package.identity] ?? []).isEmpty
    }

    // MARK: text

    private enum Tree {
        static let branch = "├── "
        static let lastBranch = "└── "
        static let continuation = "│   "
        static let lastContinuation = "    "
        static let traitsOpen = "(traits: "
        static let traitsSeparator = ", "
        static let traitsClose = ")"
    }

    private func plainText() -> String {
        guard self.hasDependencies(self.root) else { return Self.noDependencies }

        var output = ".\n"
        func walk(_ packages: [GraphPackage], prefix: String) {
            for (index, package) in packages.enumerated() {
                let isLast = index == packages.count - 1
                let hanger = prefix + (isLast ? Tree.lastBranch : Tree.branch)

                // SwiftPM prints traits as a `Set` joins them; swx sorts, so only the order of 2+ traits can differ.
                let traits = self.enabledTraits[package.identity] ?? []
                let suffix = traits.isEmpty ? "" : Tree.traitsOpen + traits.joined(separator: Tree.traitsSeparator) + Tree.traitsClose
                output += "\(hanger)\(package.identity)<\(package.location)@\(self.versionText(package))>\(suffix)\n"

                guard self.hasDependencies(package) else { continue }
                walk(self.directDependencies(of: package), prefix: prefix + (isLast ? Tree.lastContinuation : Tree.continuation))
            }
        }
        walk(self.directDependencies(of: self.root), prefix: "")
        return output
    }

    // MARK: flatlist

    private func flatList() -> String {
        var output = ""
        func walk(_ packages: [GraphPackage]) {
            for package in packages {
                output += package.identity + "\n"
                if self.hasDependencies(package) {
                    walk(self.directDependencies(of: package))
                }
            }
        }
        if self.hasDependencies(self.root) {
            walk(self.directDependencies(of: self.root))
        }
        return output
    }

    // MARK: dot

    private func dot() -> String {
        guard self.hasDependencies(self.root) else { return Self.noDependencies }

        var output = "digraph DependenciesGraph {\nnode [shape = box]\n"
        var printedNodes: Set<String> = []
        var printedEdges: Set<[String]> = []

        func printNode(_ package: GraphPackage) {
            guard printedNodes.insert(package.location).inserted else { return }
            output += "\"\(package.location)\" [label=\"\(package.identity)\\n\(package.location)\\n\(self.versionText(package))\"]\n"
        }

        // Each edge once; a package is walked again only through an edge not printed before.
        func walk(_ package: GraphPackage) {
            printNode(package)
            for dependency in self.directDependencies(of: package) {
                guard printedEdges.insert([package.location, dependency.location]).inserted else { continue }
                printNode(dependency)
                output += "\"\(package.location)\" -> \"\(dependency.location)\"\n"
                if self.hasDependencies(dependency) {
                    walk(dependency)
                }
            }
        }
        walk(self.root)
        return output + "}\n"
    }

    // MARK: json

    /// `JSONDumper`'s keys, in its order.
    private enum JSONKey {
        static let identity = "identity"
        static let name = "name"
        static let url = "url"
        static let version = "version"
        static let path = "path"
        static let traits = "traits"
        static let dependencies = "dependencies"
    }

    private func json() -> String {
        func convert(_ package: GraphPackage) -> TSCJSON {
            .object([
                (JSONKey.identity, .string(package.identity)),
                (JSONKey.name, .string(package.manifest.name)),
                (JSONKey.url, .string(package.location)),
                (JSONKey.version, .string(self.versionText(package))),
                (JSONKey.path, .string(package.path)),
                (JSONKey.traits, .array((self.enabledTraits[package.identity] ?? []).map(TSCJSON.string))),
                (JSONKey.dependencies, .array(self.directDependencies(of: package).map(convert))),
            ])
        }

        // `toString(prettyPrint: true)` ends in a newline, and the dumper adds another.
        return convert(self.root).prettyPrinted() + "\n\n"
    }
}

/// The subset of TSCBasic's `JSON` SwiftPM's dumpers use, printed exactly as it prints them.
enum TSCJSON {
    case string(String)
    case array([TSCJSON])
    case object([(String, TSCJSON)])

    private static let step = 2

    func prettyPrinted(indent: Int = 0) -> String {
        let padding = String(repeating: " ", count: indent)
        let inner = String(repeating: " ", count: indent + Self.step)

        switch self {
        case .string(let value):
            return Self.quoted(value)

        // Empty containers still get their line breaks: `[`, blank line, `]`.
        case .array(let values):
            let items = values.map { inner + $0.prettyPrinted(indent: indent + Self.step) }
            return "[\n" + items.joined(separator: ",\n") + "\n" + padding + "]"
        case .object(let entries):
            let items = entries.map { inner + Self.quoted($0.0) + ": " + $0.1.prettyPrinted(indent: indent + Self.step) }
            return "{\n" + items.joined(separator: ",\n") + "\n" + padding + "}"
        }
    }

    /// `writeJSONEscaped`: RFC 7159 escapes, and no escaping of `/` or non-ASCII.
    private static func quoted(_ string: String) -> String {
        var bytes: [UInt8] = [UInt8(ascii: "\"")]
        for byte in string.utf8 {
            switch byte {
            case UInt8(ascii: "\""):
                bytes += [UInt8(ascii: "\\"), UInt8(ascii: "\"")]
            case UInt8(ascii: "\\"):
                bytes += [UInt8(ascii: "\\"), UInt8(ascii: "\\")]
            case 0x08:
                bytes += [UInt8(ascii: "\\"), UInt8(ascii: "b")]
            case 0x0C:
                bytes += [UInt8(ascii: "\\"), UInt8(ascii: "f")]
            case 0x0A:
                bytes += [UInt8(ascii: "\\"), UInt8(ascii: "n")]
            case 0x0D:
                bytes += [UInt8(ascii: "\\"), UInt8(ascii: "r")]
            case 0x09:
                bytes += [UInt8(ascii: "\\"), UInt8(ascii: "t")]
            case 0x00..<0x20:
                bytes += Array("\\u00".utf8) + [Self.hexDigit(byte >> 4), Self.hexDigit(byte & 0xF)]
            default:
                bytes.append(byte)
            }
        }
        bytes.append(UInt8(ascii: "\""))
        return String(decoding: bytes, as: UTF8.self)
    }

    private static let decimalDigits: UInt8 = 10

    /// Upper-case, as TSCBasic writes them.
    private static func hexDigit(_ value: UInt8) -> UInt8 {
        value < Self.decimalDigits ? UInt8(ascii: "0") + value : UInt8(ascii: "A") + value - Self.decimalDigits
    }
}
