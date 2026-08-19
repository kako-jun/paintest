import XCTest
@testable import paintestCore

/// Covers `NewCanvasDialog.parseSize`, the pure parse/clamp helper pulled
/// out of `promptForSize` so it can be exercised without `NSAlert`'s modal
/// UI. `promptForSize` itself is not tested here: it blocks on
/// `NSAlert.runModal()`, which has no headless/programmatic way to drive a
/// button click in an XCTest process.
final class NewCanvasDialogTests: XCTestCase {
    func testParseSize_emptyStrings_fallBackToDefaults() {
        let result = NewCanvasDialog.parseSize(widthText: "", heightText: "", defaultWidth: 64, defaultHeight: 48)
        XCTAssertEqual(result.width, 64)
        XCTAssertEqual(result.height, 48)
    }

    func testParseSize_nonNumericText_fallsBackToDefaults() {
        let result = NewCanvasDialog.parseSize(widthText: "abc", heightText: "abc", defaultWidth: 64, defaultHeight: 64)
        XCTAssertEqual(result.width, 64)
        XCTAssertEqual(result.height, 64)
    }

    func testParseSize_zero_isClampedToOne() {
        let result = NewCanvasDialog.parseSize(widthText: "0", heightText: "0", defaultWidth: 64, defaultHeight: 64)
        XCTAssertEqual(result.width, 1)
        XCTAssertEqual(result.height, 1)
    }

    func testParseSize_negative_isClampedToOne() {
        let result = NewCanvasDialog.parseSize(widthText: "-10", heightText: "-10", defaultWidth: 64, defaultHeight: 64)
        XCTAssertEqual(result.width, 1)
        XCTAssertEqual(result.height, 1)
    }

    func testParseSize_aboveMaximum_isClampedTo4096() {
        let result = NewCanvasDialog.parseSize(widthText: "4097", heightText: "4097", defaultWidth: 64, defaultHeight: 64)
        XCTAssertEqual(result.width, 4096)
        XCTAssertEqual(result.height, 4096)
    }

    func testParseSize_one_isNotClamped() {
        let result = NewCanvasDialog.parseSize(widthText: "1", heightText: "1", defaultWidth: 64, defaultHeight: 64)
        XCTAssertEqual(result.width, 1)
        XCTAssertEqual(result.height, 1)
    }

    func testParseSize_4096_isNotClamped() {
        let result = NewCanvasDialog.parseSize(widthText: "4096", heightText: "4096", defaultWidth: 64, defaultHeight: 64)
        XCTAssertEqual(result.width, 4096)
        XCTAssertEqual(result.height, 4096)
    }

    /// `Int("６４")` (full-width digits) returns `nil`, so this should hit
    /// the same fallback path as non-numeric text rather than silently
    /// truncating or crashing. Regression guard for i18n input mishandling.
    func testParseSize_fullWidthDigits_fallBackToDefaults() {
        let result = NewCanvasDialog.parseSize(widthText: "\u{FF16}\u{FF14}", heightText: "\u{FF16}\u{FF14}", defaultWidth: 64, defaultHeight: 64)
        XCTAssertEqual(result.width, 64)
        XCTAssertEqual(result.height, 64)
    }
}
