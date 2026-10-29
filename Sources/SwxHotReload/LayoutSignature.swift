import SwiftParser
import SwiftSyntax

/// What a patch can't change in a running app: the memory layout of its types and its global
/// state. Objects and witness tables that already exist were laid out by the old code, so an edit
/// that changes these needs a rebuild and relaunch instead.
///
/// The signature of a file lists, in order:
/// - every type with its generic parameters and inheritance (conformances, superclass);
/// - stored properties (their order and types are the layout) and enum cases;
/// - the members of protocols (witness tables) and of non-final classes (vtables);
/// - global and static stored properties: a patch would get its own, empty copy of them.
///
/// Types that are new in the edit are fine: nothing that exists uses them yet.
public struct LayoutSignature: Sendable, Equatable {
    /// One layout-relevant declaration of a type (or of the file, for global state).
    struct Entry: Sendable, Equatable {
        let kind: String
        /// `Outer.Inner`; empty for the file itself.
        let owner: String
        let declaration: String
    }

    let entries: [Entry]

    public init(source: String) {
        let collector = Collector(viewMode: .sourceAccurate)
        collector.walk(Parser.parse(source: source))
        self.entries = collector.entries
    }

    /// Why going from `before` to this signature can't be patched; `nil` when it can.
    public func reasonToRelaunch(from before: LayoutSignature) -> String? {
        // A patch's copy of global state would start over beside the app's.
        if let global = self.entries.first(where: { $0.kind == Self.globalKind }) {
            let owner = global.owner.isEmpty ? "" : global.owner + "."
            return "it declares global or static state (\(owner)\(global.declaration))"
        }

        // Every type that existed before must be laid out exactly as before.
        let existing = Set(before.entries.map(\.owner)).intersection(self.entries.map(\.owner))
        for owner in existing.sorted() {
            let old = before.entries.filter { $0.owner == owner }
            let new = self.entries.filter { $0.owner == owner }
            guard old != new else { continue }
            let changed = new.first { !old.contains($0) } ?? old.first { !new.contains($0) }
            return "it changes the layout of \(owner)" + (changed.map { " (\($0.kind) \($0.declaration))" } ?? "")
        }
        return nil
    }

    static let globalKind = "global"
}

private final class Collector: SyntaxVisitor {
    private(set) var entries: [LayoutSignature.Entry] = []
    private var types: [String] = []

    private enum Kind {
        static let vtable = "vtable"
        static let requirement = "requirement"
        static let enumCase = "case"
        static let stored = "stored"
    }

    private enum Keyword {
        static let staticModifier = "static"
        static let classModifier = "class"
        static let finalModifier = "final"
        static let willSet = "willSet"
        static let didSet = "didSet"
    }

    // MARK: Types

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        self.enter("struct", node.name, node.genericParameterClause, node.inheritanceClause)
    }

    override func visitPost(_ node: StructDeclSyntax) {
        self.types.removeLast()
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        let isFinal = node.modifiers.contains { $0.name.text == Keyword.finalModifier }
        let kind = isFinal ? "final class" : "class"
        _ = self.enter(kind, node.name, node.genericParameterClause, node.inheritanceClause)

        // Calls to an open class's members go through vtable slots the old metadata fixed.
        if !isFinal {
            for member in node.memberBlock.members {
                guard let signature = Self.memberSignature(member.decl) else { continue }
                self.record(Kind.vtable, signature)
            }
        }
        return .visitChildren
    }

    override func visitPost(_ node: ClassDeclSyntax) {
        self.types.removeLast()
    }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        self.enter("actor", node.name, node.genericParameterClause, node.inheritanceClause)
    }

    override func visitPost(_ node: ActorDeclSyntax) {
        self.types.removeLast()
    }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        self.enter("enum", node.name, node.genericParameterClause, node.inheritanceClause)
    }

    override func visitPost(_ node: EnumDeclSyntax) {
        self.types.removeLast()
    }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        _ = self.enter("protocol", node.name, nil, node.inheritanceClause)

        // Requirements are witness table slots.
        for member in node.memberBlock.members {
            self.record(Kind.requirement, Self.normalized(member.decl))
        }
        return .skipChildren
    }

    override func visitPost(_ node: ProtocolDeclSyntax) {
        self.types.removeLast()
    }

    override func visit(_ node: EnumCaseDeclSyntax) -> SyntaxVisitorContinueKind {
        self.record(Kind.enumCase, Self.normalized(node.elements))
        return .skipChildren
    }

    // MARK: Stored state

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        let isStatic = node.modifiers.contains { [Keyword.staticModifier, Keyword.classModifier].contains($0.name.text) }
        let isGlobal = self.types.isEmpty && !Self.isInsideFunction(node)
        for binding in node.bindings where Self.isStored(binding) {
            // Observer bodies are code; the name, type and initial value are what's stored.
            let stored = Self.normalized(binding.pattern) + Self.normalized(binding.typeAnnotation) + [Self.normalized(binding.initializer)].filter { !$0.isEmpty }.map { " " + $0 }.joined()
            let declaration = [Self.normalized(node.attributes), node.bindingSpecifier.text, stored].filter { !$0.isEmpty }.joined(separator: " ")
            if isGlobal || isStatic {
                self.record(LayoutSignature.globalKind, declaration)
            } else if !self.types.isEmpty, !Self.isInsideFunction(node) {
                self.record(Kind.stored, declaration)
            }
        }
        return .skipChildren
    }

    // Function bodies are code: a patch replaces them freely.
    override func visit(_ node: CodeBlockSyntax) -> SyntaxVisitorContinueKind {
        .skipChildren
    }

    override func visit(_ node: AccessorBlockSyntax) -> SyntaxVisitorContinueKind {
        .skipChildren
    }

    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        .skipChildren
    }

    // MARK: Helpers

    private func enter(_ kind: String, _ name: TokenSyntax, _ generics: GenericParameterClauseSyntax?, _ inheritance: InheritanceClauseSyntax?) -> SyntaxVisitorContinueKind {
        self.types.append(name.text)
        let generic = generics.map { Self.normalized($0) } ?? ""
        let inherits = inheritance.map { " " + Self.normalized($0) } ?? ""
        self.entries.append(LayoutSignature.Entry(kind: kind, owner: self.types.joined(separator: "."), declaration: generic + inherits))
        return .visitChildren
    }

    private func record(_ kind: String, _ declaration: String) {
        self.entries.append(LayoutSignature.Entry(kind: kind, owner: self.types.joined(separator: "."), declaration: declaration))
    }

    /// A stored property has no accessors other than observers.
    private static func isStored(_ binding: PatternBindingSyntax) -> Bool {
        guard let block = binding.accessorBlock else { return true }
        guard case .accessors(let accessors) = block.accessors else { return false }
        return accessors.allSatisfy { [Keyword.willSet, Keyword.didSet].contains($0.accessorSpecifier.text) }
    }

    private static func isInsideFunction(_ node: some SyntaxProtocol) -> Bool {
        var parent = node.parent
        while let current = parent {
            if current.is(CodeBlockSyntax.self) || current.is(AccessorBlockSyntax.self) || current.is(ClosureExprSyntax.self) {
                return true
            }
            parent = current.parent
        }
        return false
    }

    /// The declaration without its body: what callers and slots depend on.
    private static func memberSignature(_ declaration: DeclSyntax) -> String? {
        if let function = declaration.as(FunctionDeclSyntax.self) {
            return "func \(function.name.text)\(Self.normalized(function.signature))"
        }
        if let initializer = declaration.as(InitializerDeclSyntax.self) {
            return "init\(Self.normalized(initializer.signature))"
        }
        if let subscriptDeclaration = declaration.as(SubscriptDeclSyntax.self) {
            return "subscript\(Self.normalized(subscriptDeclaration.parameterClause)) \(Self.normalized(subscriptDeclaration.returnClause))"
        }
        if let variable = declaration.as(VariableDeclSyntax.self), !variable.bindings.allSatisfy(Self.isStored) {
            return "var \(variable.bindings.map { Self.normalized($0.pattern) + Self.normalized($0.typeAnnotation) }.joined(separator: ", "))"
        }
        return nil
    }

    /// Source text with comments dropped and any run of whitespace as one space.
    private static func normalized(_ node: (some SyntaxProtocol)?) -> String {
        guard let node else { return "" }
        var text = ""
        var pendingSpace = false
        for token in node.tokens(viewMode: .sourceAccurate) {
            if (pendingSpace || !token.leadingTrivia.isEmpty), !text.isEmpty {
                text += " "
            }
            text += token.text
            pendingSpace = !token.trailingTrivia.isEmpty
        }
        return text
    }
}
