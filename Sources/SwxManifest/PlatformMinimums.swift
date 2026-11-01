import SwiftParser
import SwiftSyntax

/// The minimum Apple OS versions a manifest declares (`platforms: [.iOS("26.0"), .watchOS(.v10)]`).
///
/// Read straight from the source, separately from `Manifest`: only project generation needs it,
/// and keeping it out of `Manifest` leaves resolution, caching and parity untouched. Anything the
/// reader doesn't understand (a variable, a computed list) yields no minimum, never a guess.
public struct PlatformMinimums: Sendable, Equatable {
    public var iOS: String?
    public var watchOS: String?

    public static let none = PlatformMinimums(iOS: nil, watchOS: nil)

    public init(iOS: String?, watchOS: String?) {
        self.iOS = iOS
        self.watchOS = watchOS
    }

    private enum Name {
        static let package = "Package"
        static let platforms = "platforms"
        static let iOS = "iOS"
        static let watchOS = "watchOS"
        /// `.v17_4` spells version 17.4.
        static let versionPrefix = "v"
        static let componentSeparator = "_"
        static let versionSeparator = "."
        static let minorZero = ".0"
    }

    /// The minimums in `source`, a `Package.swift`.
    public static func read(manifestSource source: String) -> PlatformMinimums {
        let file = Parser.parse(source: source)
        let finder = PackageCallFinder(viewMode: .sourceAccurate)
        finder.walk(file)
        guard let call = finder.packageCall else { return .none }

        // The `platforms:` argument, when it's a literal array.
        guard let argument = call.arguments.first(where: { $0.label?.text == Name.platforms }),
              let array = argument.expression.as(ArrayExprSyntax.self) else {
            return .none
        }

        var minimums = PlatformMinimums.none
        for element in array.elements {
            guard let entry = element.expression.as(FunctionCallExprSyntax.self),
                  let platform = entry.calledExpression.as(MemberAccessExprSyntax.self)?.declName.baseName.text,
                  let version = entry.arguments.first.flatMap({ Self.version($0.expression) }) else {
                continue
            }

            switch platform {
            case Name.iOS:
                minimums.iOS = version
            case Name.watchOS:
                minimums.watchOS = version
            default:
                continue
            }
        }
        return minimums
    }

    /// `"26.0"` as written, or `.v17` / `.v17_4` as `17.0` / `17.4`.
    private static func version(_ expression: ExprSyntax) -> String? {
        if let literal = expression.as(StringLiteralExprSyntax.self) {
            guard literal.segments.count == 1, let segment = literal.segments.first?.as(StringSegmentSyntax.self) else { return nil }
            return segment.content.text
        }

        guard let member = expression.as(MemberAccessExprSyntax.self)?.declName.baseName.text,
              member.hasPrefix(Name.versionPrefix) else {
            return nil
        }
        let components = member.dropFirst(Name.versionPrefix.count).split(separator: Name.componentSeparator)
        guard !components.isEmpty, components.allSatisfy({ Int($0) != nil }) else { return nil }

        let version = components.joined(separator: Name.versionSeparator)
        return components.count == 1 ? version + Name.minorZero : version
    }

    /// Finds the first `Package(…)` call.
    private final class PackageCallFinder: SyntaxVisitor {
        var packageCall: FunctionCallExprSyntax?

        override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
            guard self.packageCall == nil else { return .skipChildren }
            if node.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text == Name.package {
                self.packageCall = node
                return .skipChildren
            }
            return .visitChildren
        }
    }
}
