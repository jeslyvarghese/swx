import Foundation
import SwxSystem

/// Turns command-line paths into absolute URLs the way SwiftPM does (lexically).
enum FileSystemPaths {
    static func absolute(_ path: String) -> URL {
        FileSystem.absoluteURL(path)
    }
}
