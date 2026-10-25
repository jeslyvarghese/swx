import SwxSystem
import Testing

struct PathNormalizationTests {
    @Test(arguments: [
        ("../Local", "/private/tmp/app", "/private/tmp/Local"),
        ("./a/./b/../c", "/work", "/work/a/c"),
        ("/abs/../x", "/ignored", "/x"),
        ("Packages/Kit/", "/r", "/r/Packages/Kit"),
    ])
    func normalizesLexically(path: String, base: String, expected: String) {
        // `/private` must survive: SwiftPM writes it, Foundation would strip it.
        #expect(FileSystem.normalize(path, relativeTo: base) == expected)
    }
}
