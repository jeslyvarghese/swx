import Foundation

/// Opt-in timeline for performance work: `SWX_TRACE=1 swx …` prints timestamped events to stderr.
public enum Trace {
    private static let environmentVariable = "SWX_TRACE"
    private static let enabledValue = "1"
    private static let millisecondsPerSecond = 1000.0

    public static let isEnabled = ProcessInfo.processInfo.environment[Self.environmentVariable] == Self.enabledValue
    private static let start = Date()

    public static func event(_ message: @autoclosure () -> String) {
        guard Self.isEnabled else { return }
        let elapsed = Date().timeIntervalSince(Self.start) * Self.millisecondsPerSecond
        FileHandle.standardError.write(Data(String(format: "[%7.1fms] %@\n", elapsed, message()).utf8))
    }
}
