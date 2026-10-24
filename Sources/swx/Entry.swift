import SwxCLI

/// Process entry point; all behaviour lives in SwxCLI.
@main
struct Entry {
    static func main() async {
        await SwxCommand.main(nil)
    }
}
