import XCTest
@testable import paintestCore

/// Covers `CommandLineArguments.parseInitialFileURL(from:)` (issue #72) —
/// the `paintest <path>` launch-argument rule `main.swift` forwards to
/// `runPaintestApp(initialFileURL:)`.
final class CommandLineArgumentsTests: XCTestCase {
    func testParseInitialFileURL_noArguments_returnsNil() {
        XCTAssertNil(CommandLineArguments.parseInitialFileURL(from: []))
    }

    func testParseInitialFileURL_onlyExecutablePath_returnsNil() {
        XCTAssertNil(CommandLineArguments.parseInitialFileURL(from: ["/usr/local/bin/paintest"]))
    }

    func testParseInitialFileURL_oneExtraArgument_returnsItsFileURL() {
        let result = CommandLineArguments.parseInitialFileURL(
            from: ["/usr/local/bin/paintest", "/tmp/example.paintestdoc"]
        )
        XCTAssertEqual(result, URL(fileURLWithPath: "/tmp/example.paintestdoc"))
    }

    func testParseInitialFileURL_extraTrailingArguments_areIgnored() {
        // Only `arguments[1]` is ever consumed — anything from index 2
        // onward is neither used nor treated as an error.
        let result = CommandLineArguments.parseInitialFileURL(
            from: ["/usr/local/bin/paintest", "/tmp/example.paintestdoc", "--verbose", "extra"]
        )
        XCTAssertEqual(result, URL(fileURLWithPath: "/tmp/example.paintestdoc"))
    }

    func testParseInitialFileURL_emptyPathString_pinsFileURLWithEmptyPathBehavior() {
        // `URL(fileURLWithPath: "")` doesn't crash or return nil — Foundation
        // resolves an empty path relative to the current working directory,
        // same as `""` would on the command line. This pins that observed
        // behavior rather than asserting a specific path (which would
        // otherwise make the test depend on the test runner's cwd).
        let result = CommandLineArguments.parseInitialFileURL(from: ["/usr/local/bin/paintest", ""])
        XCTAssertEqual(result, URL(fileURLWithPath: ""))
    }

    func testParseInitialFileURL_relativePathString_isNotAbsolutized() {
        // `parseInitialFileURL` performs no absolutization of its own — the
        // raw relative string is handed straight to `URL(fileURLWithPath:)`,
        // which resolves it against the *process's* cwd. This pins that
        // pass-through: if `parseInitialFileURL` ever grew its own base
        // directory (e.g. resolving against the app bundle instead), this
        // would diverge from the plain `URL(fileURLWithPath:)` call below
        // and fail.
        let result = CommandLineArguments.parseInitialFileURL(from: ["/usr/local/bin/paintest", "relative/path.png"])
        XCTAssertEqual(result, URL(fileURLWithPath: "relative/path.png"))
        XCTAssertTrue(result!.path.hasSuffix("/relative/path.png"))
    }
}
