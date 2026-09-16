import Foundation
import paintestCore

// `paintest <path>` opens that file at launch (issue #72). See
// `CommandLineArguments.parseInitialFileURL(from:)` for the parsing rule and
// why it's not inlined here (unit-testability — `main.swift` is top-level
// code and can't be `@testable import`ed).
let initialFileURL = CommandLineArguments.parseInitialFileURL(from: CommandLine.arguments)

runPaintestApp(initialFileURL: initialFileURL)
