import Foundation
import SwxBuild
import SwxSystem
import Testing

struct XcodeBuildLogTests {
    private static let log = """
    SwiftDriver\\ Compilation Hot normal arm64 com.apple.xcode.tools.swift.compiler (in target 'Hot' from project 'Hot')
        cd /work/Hot
        builtin-Swift-Compilation -- /usr/bin/swiftc -module-name Wrong
    SwiftDriver Hot normal arm64 com.apple.xcode.tools.swift.compiler (in target 'Hot' from project 'Hot')
        cd /work/My\\ Hot
        builtin-SwiftDriver -- /usr/bin/swiftc -module-name Hot @/build/Hot.SwiftFileList -DDEBUG -target arm64-apple-ios17.0-simulator -sdk /SDKs/iPhoneSimulator.sdk -Xcc -DX\\=1

    SwiftDriver Kit normal x86_64 com.apple.xcode.tools.swift.compiler (in target 'Kit' from project 'Hot')
        cd /work
        builtin-SwiftDriver -- /usr/bin/swiftc -module-name Kit '/work/Kit/A file.swift'
    """

    @Test func readsEachModulesDriverCommand() {
        let commands = XcodeBuildLog.swiftModuleCommands(in: Self.log)
        #expect(commands.map(\.module) == ["Hot", "Kit"])
        #expect(commands.map(\.architecture) == ["arm64", "x86_64"])

        let hot = commands[0]
        #expect(hot.workingDirectory == "/work/My Hot")
        #expect(hot.target == "arm64-apple-ios17.0-simulator")
        #expect(hot.sdk == "/SDKs/iPhoneSimulator.sdk")
        #expect(hot.arguments.last == "-DX=1")
        #expect(commands[1].sourceFiles().map(\.path) == ["/work/Kit/A file.swift"])
    }

    @Test func splitsLikeAShell() {
        #expect(ShellWords.split(#"a 'b c' "d \"e\"" f\ g h\=i"#) == ["a", "b c", #"d "e""#, "f g", "h=i"])
        #expect(ShellWords.split("  ") == [])
        #expect(ShellWords.split("''") == [""])
    }
}
