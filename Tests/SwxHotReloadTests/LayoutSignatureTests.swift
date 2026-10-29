import SwxHotReload
import Testing

struct LayoutSignatureTests {
    private static let view = """
    import SwiftUI

    struct GreetingView: View {
        @State private var taps = 0
        let name: String

        var body: some View {
            Text("hello \\(name)")
        }
    }
    """

    private func reason(_ before: String, _ after: String) -> String? {
        LayoutSignature(source: after).reasonToRelaunch(from: LayoutSignature(source: before))
    }

    @Test func editingCodeIsPatchable() {
        let edited = Self.view.replacingOccurrences(of: "Text(\"hello \\(name)\")", with: "VStack { Text(\"hi\"); Text(name) }")
        #expect(self.reason(Self.view, edited) == nil)
    }

    @Test func newFunctionsAndTypesArePatchable() {
        let edited = Self.view + "\nfunc helper() -> Int { 1 }\nstruct Badge: View { var body: some View { Text(\"b\") } }\n"
        #expect(self.reason(Self.view, edited) == nil)
    }

    @Test func storedPropertiesNeedARelaunch() {
        let added = Self.view.replacingOccurrences(of: "    let name: String\n", with: "    let name: String\n    let age: Int\n")
        #expect(self.reason(Self.view, added) == "it changes the layout of GreetingView (stored let age: Int)")

        let retyped = Self.view.replacingOccurrences(of: "let name: String", with: "let name: Substring")
        #expect(self.reason(Self.view, retyped) != nil)
    }

    @Test func conformancesAndCasesNeedARelaunch() {
        let conforming = Self.view.replacingOccurrences(of: "GreetingView: View", with: "GreetingView: View, Equatable")
        #expect(self.reason(Self.view, conforming) != nil)

        let enumeration = "enum Mode { case light, dark }"
        #expect(self.reason(enumeration, "enum Mode { case light, dark, auto }") != nil)
    }

    @Test func openClassMembersNeedARelaunchButFinalOnesDont() {
        let open = "class Model { func load() {} }"
        #expect(self.reason(open, "class Model { func load() {}\n func save() {} }") != nil)
        #expect(self.reason(open, "class Model { func load() { print(1) } }") == nil)

        let final = "final class Model { func load() {} }"
        #expect(self.reason(final, "final class Model { func load() {}\n func save() {} }") == nil)
    }

    @Test func globalStateIsNeverPatched() {
        let singleton = "struct Store { static let shared = Store() }\nfunc f() {}"
        #expect(self.reason(singleton, singleton)?.contains("global or static state") == true)

        // Locals and computed properties are code.
        let code = "func f() { var count = 0; count += 1 }\nvar computed: Int { 1 }"
        #expect(self.reason(code, code) == nil)
    }

    @Test func observerBodiesAreCode() {
        let observed = "struct S { var x = 0 { didSet { print(1) } } }"
        #expect(self.reason(observed, "struct S { var x = 0 { didSet { print(2) } } }") == nil)
    }
}
