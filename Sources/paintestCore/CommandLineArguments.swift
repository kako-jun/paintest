import Foundation

/// Parsing for `paintest`'s own command-line arguments (issue #72): today
/// just "open this file at launch" (`paintest <path>`), pulled out of
/// `main.swift` so it's covered by `paintestCoreTests` — `main.swift` itself
/// is top-level code and can't be unit tested (see `runPaintestApp`'s own
/// doc comment in `AppDelegate.swift` for why top-level code is avoided
/// elsewhere too).
public enum CommandLineArguments {
    /// `arguments[0]` is always the executable path itself (never a
    /// caller-supplied path), so `arguments[1]` — when present — is the
    /// earliest a file path can appear; anything from `arguments[2]` onward
    /// is ignored. Doesn't validate that the path exists or is readable —
    /// `AppDelegate.applicationDidFinishLaunching` hands the result to the
    /// same `openDocument(from:)` as "開く…"/drag-and-drop, which already
    /// handles a missing/unreadable file with an error alert.
    public static func parseInitialFileURL(from arguments: [String]) -> URL? {
        guard arguments.count > 1 else { return nil }
        return URL(fileURLWithPath: arguments[1])
    }
}
