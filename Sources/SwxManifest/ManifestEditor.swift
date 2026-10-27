import SwiftParser
import SwiftSyntax
import SwxCore

/// Which dependency an edit is about: its identity, and the names targets may use for it in
/// `.product(name:package:)` (the identity, the `name:` argument, the last URL component).
public struct DependencyMatch: Sendable {
    public let identity: String
    public let referenceNames: Set<String>

    public init(identity: String, referenceNames: Set<String>) {
        self.identity = identity.lowercased()
        self.referenceNames = Set(referenceNames.map { $0.lowercased() } + [identity.lowercased()])
    }
}

/// How a `.package(…)` call states its version requirement.
public enum RequirementSyntax: Sendable, Equatable {
    /// `from: "1.2.0"` or `.upToNextMajor(from: "1.2.0")`.
    case upToNextMajor(String)
    /// `.upToNextMinor(from: "1.2.0")`.
    case upToNextMinor(String)
    /// `exact: "1.2.0"` or `.exact("1.2.0")`.
    case exact(String)
    /// `"1.0.0"..<"2.0.0"` and other ranges: left to the author.
    case range
    /// Branches, revisions, paths and anything not spelled with literals.
    case unversioned
}

public struct ManifestEditError: Error, CustomStringConvertible {
    public let description: String
}

/// Byte-preserving edits of `Package.swift` that SwiftPM's own editor doesn't offer: removing a
/// dependency, and changing the version of one. Only literal `.package(…)` calls are edited;
/// everything else in the file stays exactly as written.
public enum ManifestEditor {
    private enum Label {
        static let url = "url"
        static let path = "path"
        static let id = "id"
        static let package = "package"
        static let from = "from"
        static let exact = "exact"
    }

    private enum Member {
        static let package = "package"
        static let product = "product"
        static let upToNextMajor = "upToNextMajor"
        static let upToNextMinor = "upToNextMinor"
        static let exact = "exact"
    }

    /// Removes the dependency's `.package(…)` and every `.product(…, package:)` that uses it.
    public static func removingDependency(_ match: DependencyMatch, from source: String) throws -> String {
        let file = Parser.parse(source: source)
        let collector = ElementCollector(viewMode: .sourceAccurate) { call in
            Self.declares(call, match) || Self.usesProduct(call, of: match)
        }
        collector.walk(file)
        guard collector.elements.contains(where: { Self.declares($0.call, match) }) else {
            throw ManifestEditError(description: "no literal .package(…) for \(match.identity) in \(WellKnownFile.manifest); edit it by hand")
        }

        // Delete from the end so earlier offsets stay valid.
        var bytes = Array(source.utf8)
        for range in collector.elements.map(\.element).map(Self.removalRange).sorted(by: { $0.lowerBound > $1.lowerBound }) {
            bytes.removeSubrange(range)
        }
        return try Self.checked(String(decoding: bytes, as: UTF8.self))
    }

    /// How the dependency's requirement is written, or `nil` when there's no literal `.package(…)` for it.
    public static func requirement(of match: DependencyMatch, in source: String) -> RequirementSyntax? {
        guard let call = Self.declaration(of: match, in: source) else { return nil }
        return Self.versionLiteral(in: call)?.syntax ?? .unversioned
    }

    /// Replaces the version in the dependency's `from:`, `exact:`, `.upToNextMajor(from:)`,
    /// `.upToNextMinor(from:)` or `.exact(…)`, keeping the form.
    public static func settingVersion(_ version: String, of match: DependencyMatch, in source: String) throws -> String {
        guard let call = Self.declaration(of: match, in: source) else {
            throw ManifestEditError(description: "no literal .package(…) for \(match.identity) in \(WellKnownFile.manifest)")
        }
        guard let literal = Self.versionLiteral(in: call)?.literal else {
            throw ManifestEditError(description: "\(match.identity)'s requirement isn't a single version; edit it by hand")
        }

        // Replace the characters between the quotes.
        var bytes = Array(source.utf8)
        let start = literal.segments.positionAfterSkippingLeadingTrivia.utf8Offset
        let end = literal.segments.endPositionBeforeTrailingTrivia.utf8Offset
        bytes.replaceSubrange(start..<end, with: Array(version.utf8))
        return try Self.checked(String(decoding: bytes, as: UTF8.self))
    }

    /// An edit must leave valid Swift; otherwise the file is left alone.
    private static func checked(_ edited: String) throws -> String {
        guard !Parser.parse(source: edited).hasError else {
            throw ManifestEditError(description: "editing \(WellKnownFile.manifest) would leave invalid Swift; edit it by hand")
        }
        return edited
    }

    // MARK: Finding calls

    private static func declaration(of match: DependencyMatch, in source: String) -> FunctionCallExprSyntax? {
        let collector = ElementCollector(viewMode: .sourceAccurate) { Self.declares($0, match) }
        collector.walk(Parser.parse(source: source))
        return collector.elements.first?.call
    }

    /// `.package(url: "…")`, `.package(path: "…")` or `.package(id: "…")` naming the dependency.
    private static func declares(_ call: FunctionCallExprSyntax, _ match: DependencyMatch) -> Bool {
        guard Self.memberName(of: call) == Member.package else { return false }
        for argument in call.arguments {
            guard let label = argument.label?.text, let value = Self.stringValue(argument.expression) else { continue }
            switch label {
            case Label.url, Label.path:
                return PackageIdentity(location: value).description == match.identity
            case Label.id:
                return value.lowercased() == match.identity
            default:
                continue
            }
        }
        return false
    }

    /// `.product(name: "…", package: "<one of the dependency's names>")`.
    private static func usesProduct(_ call: FunctionCallExprSyntax, of match: DependencyMatch) -> Bool {
        guard Self.memberName(of: call) == Member.product else { return false }
        let package = call.arguments.first { $0.label?.text == Label.package }.flatMap { Self.stringValue($0.expression) }
        return package.map { match.referenceNames.contains($0.lowercased()) } ?? false
    }

    /// A `.package(…)` call's requirement: its form, and the literal holding the version when
    /// there is exactly one.
    private static func versionLiteral(in call: FunctionCallExprSyntax) -> (literal: StringLiteralExprSyntax?, syntax: RequirementSyntax)? {
        for argument in call.arguments {
            // `from: "1.2.0"`, `exact: "1.2.0"`.
            if let label = argument.label?.text, let literal = argument.expression.as(StringLiteralExprSyntax.self), let value = Self.stringValue(literal) {
                switch label {
                case Label.from:
                    return (literal, .upToNextMajor(value))
                case Label.exact:
                    return (literal, .exact(value))
                default:
                    continue
                }
            }

            // `.upToNextMajor(from: "1.2.0")`, `.upToNextMinor(from: "1.2.0")`, `.exact("1.2.0")`.
            if argument.label == nil, let inner = argument.expression.as(FunctionCallExprSyntax.self),
               let literal = inner.arguments.first?.expression.as(StringLiteralExprSyntax.self),
               let value = Self.stringValue(literal) {
                switch Self.memberName(of: inner) {
                case Member.upToNextMajor:
                    return (literal, .upToNextMajor(value))
                case Member.upToNextMinor:
                    return (literal, .upToNextMinor(value))
                case Member.exact:
                    return (literal, .exact(value))
                default:
                    continue
                }
            }

            // `"1.0.0"..<"2.0.0"`, unfolded: a sequence of literal, operator, literal.
            if argument.label == nil, argument.expression.is(SequenceExprSyntax.self) || argument.expression.is(InfixOperatorExprSyntax.self) {
                return (nil, .range)
            }
        }
        return nil
    }

    private static func memberName(of call: FunctionCallExprSyntax) -> String? {
        call.calledExpression.as(MemberAccessExprSyntax.self)?.declName.baseName.text
    }

    /// The value of a string literal without interpolation.
    private static func stringValue(_ expression: some ExprSyntaxProtocol) -> String? {
        guard let literal = expression.as(StringLiteralExprSyntax.self) else { return nil }
        var value = ""
        for segment in literal.segments {
            guard let text = segment.as(StringSegmentSyntax.self) else { return nil }
            value += text.content.text
        }
        return value
    }

    // MARK: Removing elements

    /// The bytes an array element occupies: its own lines in a multi-line array (comments above it
    /// included); in a one-line array, itself and the comma that separates it from its neighbour.
    private static func removalRange(_ element: ArrayElementSyntax) -> Range<Int> {
        var start = element.position.utf8Offset
        let end = element.endPosition.utf8Offset

        // The last element of a one-line array takes the previous element's comma with it.
        let isOnItsOwnLine = element.leadingTrivia.contains { $0.isNewline }
        if element.trailingComma == nil, !isOnItsOwnLine,
           let list = element.parent?.as(ArrayElementListSyntax.self),
           let index = list.index(of: element), index != list.startIndex {
            let previous = list[list.index(before: index)]
            if let comma = previous.trailingComma {
                start = comma.position.utf8Offset
            }
        }
        return start..<end
    }
}

private extension TriviaPiece {
    var isNewline: Bool {
        switch self {
        case .newlines, .carriageReturns, .carriageReturnLineFeeds:
            return true
        default:
            return false
        }
    }
}

/// Array elements that are calls matching a predicate, outermost first.
private final class ElementCollector: SyntaxVisitor {
    let matches: (FunctionCallExprSyntax) -> Bool
    var elements: [(element: ArrayElementSyntax, call: FunctionCallExprSyntax)] = []

    init(viewMode: SyntaxTreeViewMode, matches: @escaping (FunctionCallExprSyntax) -> Bool) {
        self.matches = matches
        super.init(viewMode: viewMode)
    }

    override func visit(_ node: ArrayElementSyntax) -> SyntaxVisitorContinueKind {
        guard let call = node.expression.as(FunctionCallExprSyntax.self), self.matches(call) else { return .visitChildren }
        self.elements.append((node, call))
        // A matched element is removed whole; nothing inside it needs looking at.
        return .skipChildren
    }
}
