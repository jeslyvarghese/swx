import SwxCore
import Testing

struct RegistryIdentityRulesTests {
    /// SwiftPM's rules: scopes take single inner hyphens, names hyphens or underscores too.
    @Test func checksScopesAndNames() {
        #expect(RegistryIdentityRules.problem(scope: "mona") == nil)
        #expect(RegistryIdentityRules.problem(scope: "mona-lisa") == nil)
        #expect(RegistryIdentityRules.problem(scope: "") != nil)
        #expect(RegistryIdentityRules.problem(scope: "-mona") != nil)
        #expect(RegistryIdentityRules.problem(scope: "mona-") != nil)
        #expect(RegistryIdentityRules.problem(scope: "mo--na") != nil)
        #expect(RegistryIdentityRules.problem(scope: "mona_lisa") != nil)
        #expect(RegistryIdentityRules.problem(scope: String(repeating: "a", count: 40)) != nil)

        #expect(RegistryIdentityRules.problem(name: "Linked_List-2") == nil)
        #expect(RegistryIdentityRules.problem(name: "_List") != nil)
        #expect(RegistryIdentityRules.problem(name: "List_") != nil)
        #expect(RegistryIdentityRules.problem(name: "Li-_st") != nil)
        #expect(RegistryIdentityRules.problem(name: "Lïst") != nil)
        #expect(RegistryIdentityRules.problem(name: String(repeating: "a", count: 101)) != nil)
    }
}
