import Foundation
import paintestCore

// `paintest <path>` opens that file at launch (issue #72). Only the first
// extra argument is used — `CommandLine.arguments[0]` is always the
// executable path itself, never a file path, so a second element is the
// earliest a caller-supplied path can appear.
let initialFileURL = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : nil

runPaintestApp(initialFileURL: initialFileURL)
