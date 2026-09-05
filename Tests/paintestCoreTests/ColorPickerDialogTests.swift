import AppKit
import XCTest
@testable import paintestCore

/// Covers `ColorPickerDialog.parseHexColor`/`hexString(from:)`, the pure
/// parse/format helpers pulled out of `promptForColor` so they can be
/// exercised without `NSAlert`'s modal UI. `promptForColor` itself is not
/// tested here, for the same reason `NewCanvasDialogTests` skips
/// `promptForSize`: it blocks on `NSAlert.runModal()`, which has no
/// headless/programmatic way to drive a button click in an XCTest process.
final class ColorPickerDialogTests: XCTestCase {
    private func components(of color: NSColor) -> (r: Int, g: Int, b: Int) {
        let rgba = color.usingColorSpace(.deviceRGB) ?? color
        return (
            Int((rgba.redComponent * 255).rounded()),
            Int((rgba.greenComponent * 255).rounded()),
            Int((rgba.blueComponent * 255).rounded())
        )
    }

    // MARK: - parseHexColor

    func testParseHexColor_withLeadingHash_parsesCorrectly() {
        let color = ColorPickerDialog.parseHexColor("#FF8000")
        XCTAssertNotNil(color)
        XCTAssertEqual(components(of: color!).r, 0xFF)
        XCTAssertEqual(components(of: color!).g, 0x80)
        XCTAssertEqual(components(of: color!).b, 0x00)
    }

    func testParseHexColor_withoutLeadingHash_parsesCorrectly() {
        let color = ColorPickerDialog.parseHexColor("FF8000")
        XCTAssertNotNil(color)
        XCTAssertEqual(components(of: color!).r, 0xFF)
        XCTAssertEqual(components(of: color!).g, 0x80)
        XCTAssertEqual(components(of: color!).b, 0x00)
    }

    func testParseHexColor_surroundingWhitespace_isTrimmedBeforeParsing() {
        let color = ColorPickerDialog.parseHexColor("  #FF8000  ")
        XCTAssertNotNil(color, "leading/trailing whitespace must be trimmed, not treated as invalid input")
    }

    func testParseHexColor_lowercaseHex_parsesCorrectly() {
        let color = ColorPickerDialog.parseHexColor("#ffffff")
        XCTAssertNotNil(color)
        XCTAssertEqual(components(of: color!).r, 255)
        XCTAssertEqual(components(of: color!).g, 255)
        XCTAssertEqual(components(of: color!).b, 255)
    }

    func testParseHexColor_mixedCaseHex_parsesCorrectly() {
        let color = ColorPickerDialog.parseHexColor("#FfAaBb")
        XCTAssertNotNil(color)
        XCTAssertEqual(components(of: color!).r, 0xFF)
        XCTAssertEqual(components(of: color!).g, 0xAA)
        XCTAssertEqual(components(of: color!).b, 0xBB)
    }

    func testParseHexColor_fiveDigits_isNil() {
        XCTAssertNil(ColorPickerDialog.parseHexColor("#FFFFF"))
    }

    func testParseHexColor_sevenDigits_isNil() {
        XCTAssertNil(ColorPickerDialog.parseHexColor("#FFFFFFF"))
    }

    func testParseHexColor_threeDigitShorthand_isNil() {
        XCTAssertNil(ColorPickerDialog.parseHexColor("#FFF"))
    }

    func testParseHexColor_eightDigitsWithAlpha_isNil() {
        XCTAssertNil(ColorPickerDialog.parseHexColor("#FFFFFFFF"))
    }

    func testParseHexColor_nonHexCharacters_isNil() {
        XCTAssertNil(ColorPickerDialog.parseHexColor("#GGGGGG"))
    }

    func testParseHexColor_partiallyNonHexCharacters_isNil() {
        XCTAssertNil(ColorPickerDialog.parseHexColor("#12345G"))
    }

    func testParseHexColor_emptyString_isNil() {
        XCTAssertNil(ColorPickerDialog.parseHexColor(""))
    }

    func testParseHexColor_onlyHash_isNil() {
        XCTAssertNil(ColorPickerDialog.parseHexColor("#"))
    }

    func testParseHexColor_doubleHash_isNil() {
        XCTAssertNil(ColorPickerDialog.parseHexColor("##FFFFFF"))
    }

    func testParseHexColor_black_hasAllZeroComponents() {
        let color = ColorPickerDialog.parseHexColor("#000000")
        XCTAssertNotNil(color)
        let rgb = components(of: color!)
        XCTAssertEqual(rgb.r, 0)
        XCTAssertEqual(rgb.g, 0)
        XCTAssertEqual(rgb.b, 0)
    }

    func testParseHexColor_white_hasAll255Components() {
        let color = ColorPickerDialog.parseHexColor("#FFFFFF")
        XCTAssertNotNil(color)
        let rgb = components(of: color!)
        XCTAssertEqual(rgb.r, 255)
        XCTAssertEqual(rgb.g, 255)
        XCTAssertEqual(rgb.b, 255)
    }

    // MARK: - hexString(from:)

    func testHexString_black_isAllZeros() {
        XCTAssertEqual(ColorPickerDialog.hexString(from: .black), "#000000")
    }

    func testHexString_white_isAllFF() {
        XCTAssertEqual(ColorPickerDialog.hexString(from: .white), "#FFFFFF")
    }

    func testHexString_output_isAlwaysUppercase() {
        let color = ColorPickerDialog.parseHexColor("#abcdef")!
        XCTAssertEqual(ColorPickerDialog.hexString(from: color), "#ABCDEF")
    }

    func testHexString_midToneRed_roundsToCorrectTwoDigitHex() {
        // 0.5 * 255 = 127.5, which rounds to 128 (0x80), not 127 (0x7F).
        let color = NSColor(deviceRed: 0.5, green: 0, blue: 0, alpha: 1)
        XCTAssertEqual(ColorPickerDialog.hexString(from: color), "#800000")
    }

    // MARK: - Round trip

    func testRoundTrip_parseThenFormat_matchesOriginalInput() {
        let inputs = ["#000000", "#FFFFFF", "#FF0000", "#00FF00", "#0000FF", "#123ABC"]
        for input in inputs {
            guard let color = ColorPickerDialog.parseHexColor(input) else {
                XCTFail("\(input) should parse")
                continue
            }
            XCTAssertEqual(ColorPickerDialog.hexString(from: color), input, "round trip should reproduce the original hex string for \(input)")
        }
    }
}
