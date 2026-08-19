import AppKit
import XCTest
@testable import paintestCore

final class PixelCanvasTests: XCTestCase {
    // MARK: - setPixel bounds (decision table 2-1 / boundary values 3)

    func testSetPixel_inBounds_originIsWritten() {
        let canvas = PixelCanvas(width: 8, height: 8, background: .white)
        canvas.setPixel(x: 0, y: 0, color: .black)
        XCTAssertEqual(canvas.rawPixel(x: 0, y: 0)?.r, 0)
    }

    func testSetPixel_inBounds_bottomRightCornerIsWritten() {
        let canvas = PixelCanvas(width: 8, height: 8, background: .white)
        canvas.setPixel(x: 7, y: 7, color: .black)
        XCTAssertEqual(canvas.rawPixel(x: 7, y: 7)?.r, 0)
    }

    func testSetPixel_xBelowZero_isIgnored() {
        let canvas = PixelCanvas(width: 8, height: 8, background: .white)
        canvas.setPixel(x: -1, y: 3, color: .black)
        // No crash, and nothing inside the canvas changed.
        for y in 0..<8 {
            for x in 0..<8 {
                XCTAssertEqual(canvas.rawPixel(x: x, y: y)?.r, 255, "pixel (\(x),\(y)) should remain untouched")
            }
        }
    }

    func testSetPixel_xEqualsWidth_isIgnored() {
        let canvas = PixelCanvas(width: 8, height: 8, background: .white)
        canvas.setPixel(x: 8, y: 3, color: .black)
        for y in 0..<8 {
            for x in 0..<8 {
                XCTAssertEqual(canvas.rawPixel(x: x, y: y)?.r, 255, "pixel (\(x),\(y)) should remain untouched")
            }
        }
    }

    func testSetPixel_yBelowZero_isIgnored() {
        let canvas = PixelCanvas(width: 8, height: 8, background: .white)
        canvas.setPixel(x: 3, y: -1, color: .black)
        for y in 0..<8 {
            for x in 0..<8 {
                XCTAssertEqual(canvas.rawPixel(x: x, y: y)?.r, 255, "pixel (\(x),\(y)) should remain untouched")
            }
        }
    }

    func testSetPixel_yEqualsHeight_isIgnored() {
        let canvas = PixelCanvas(width: 8, height: 8, background: .white)
        canvas.setPixel(x: 3, y: 8, color: .black)
        for y in 0..<8 {
            for x in 0..<8 {
                XCTAssertEqual(canvas.rawPixel(x: x, y: y)?.r, 255, "pixel (\(x),\(y)) should remain untouched")
            }
        }
    }

    func testSetPixel_bothOutOfBounds_isIgnored() {
        let canvas = PixelCanvas(width: 8, height: 8, background: .white)
        canvas.setPixel(x: -1, y: 8, color: .black)
        for y in 0..<8 {
            for x in 0..<8 {
                XCTAssertEqual(canvas.rawPixel(x: x, y: y)?.r, 255, "pixel (\(x),\(y)) should remain untouched")
            }
        }
    }

    func testSetPixel_doesNotBleedIntoAdjacentPixel() {
        let canvas = PixelCanvas(width: 8, height: 8, background: .white)
        canvas.setPixel(x: 4, y: 4, color: .black)
        // The written pixel is exact black...
        let written = canvas.rawPixel(x: 4, y: 4)
        XCTAssertEqual(written?.r, 0)
        XCTAssertEqual(written?.g, 0)
        XCTAssertEqual(written?.b, 0)
        XCTAssertEqual(written?.a, 255)
        // ...and every neighbor is untouched (no anti-aliasing bleed).
        let neighbors = [(3, 4), (5, 4), (4, 3), (4, 5), (3, 3), (5, 5)]
        for (x, y) in neighbors {
            let pixel = canvas.rawPixel(x: x, y: y)
            XCTAssertEqual(pixel?.r, 255, "neighbor (\(x),\(y)) r should stay untouched")
            XCTAssertEqual(pixel?.g, 255, "neighbor (\(x),\(y)) g should stay untouched")
            XCTAssertEqual(pixel?.b, 255, "neighbor (\(x),\(y)) b should stay untouched")
        }
    }

    // MARK: - drawLine

    func testDrawLine_horizontal_fillsExactRunAndNothingElse() {
        let canvas = PixelCanvas(width: 10, height: 10, background: .white)
        canvas.drawLine(from: (x: 2, y: 5), to: (x: 6, y: 5), color: .black)
        for x in 2...6 {
            XCTAssertEqual(canvas.rawPixel(x: x, y: 5)?.r, 0, "expected black at (\(x),5)")
        }
        XCTAssertEqual(canvas.rawPixel(x: 1, y: 5)?.r, 255)
        XCTAssertEqual(canvas.rawPixel(x: 7, y: 5)?.r, 255)
        XCTAssertEqual(canvas.rawPixel(x: 2, y: 4)?.r, 255)
        XCTAssertEqual(canvas.rawPixel(x: 2, y: 6)?.r, 255)
    }

    func testDrawLine_vertical_fillsExactRunAndNothingElse() {
        let canvas = PixelCanvas(width: 10, height: 10, background: .white)
        canvas.drawLine(from: (x: 5, y: 1), to: (x: 5, y: 4), color: .black)
        for y in 1...4 {
            XCTAssertEqual(canvas.rawPixel(x: 5, y: y)?.r, 0, "expected black at (5,\(y))")
        }
        XCTAssertEqual(canvas.rawPixel(x: 5, y: 0)?.r, 255)
        XCTAssertEqual(canvas.rawPixel(x: 5, y: 5)?.r, 255)
        XCTAssertEqual(canvas.rawPixel(x: 4, y: 2)?.r, 255)
        XCTAssertEqual(canvas.rawPixel(x: 6, y: 2)?.r, 255)
    }

    func testDrawLine_diagonal45Degrees_fillsExactStaircase() {
        let canvas = PixelCanvas(width: 10, height: 10, background: .white)
        canvas.drawLine(from: (x: 0, y: 0), to: (x: 4, y: 4), color: .black)
        for i in 0...4 {
            XCTAssertEqual(canvas.rawPixel(x: i, y: i)?.r, 0, "expected black at (\(i),\(i))")
        }
        // Off the diagonal should be untouched.
        XCTAssertEqual(canvas.rawPixel(x: 1, y: 0)?.r, 255)
        XCTAssertEqual(canvas.rawPixel(x: 0, y: 1)?.r, 255)
    }

    func testDrawLine_startEqualsEnd_paintsExactlyOnePixel() {
        let canvas = PixelCanvas(width: 8, height: 8, background: .white)
        canvas.drawLine(from: (x: 3, y: 3), to: (x: 3, y: 3), color: .black)
        XCTAssertEqual(canvas.rawPixel(x: 3, y: 3)?.r, 0)
        var blackCount = 0
        for y in 0..<8 {
            for x in 0..<8 where canvas.rawPixel(x: x, y: y)?.r == 0 {
                blackCount += 1
            }
        }
        XCTAssertEqual(blackCount, 1)
    }

    func testDrawLine_partiallyOutOfBounds_doesNotCrashAndClipsToCanvas() {
        let canvas = PixelCanvas(width: 8, height: 8, background: .white)
        // Runs from inside the canvas to well outside it.
        canvas.drawLine(from: (x: 5, y: 5), to: (x: 20, y: 20), color: .black)
        // In-bounds portion of the path was painted.
        XCTAssertEqual(canvas.rawPixel(x: 5, y: 5)?.r, 0)
        XCTAssertEqual(canvas.rawPixel(x: 7, y: 7)?.r, 0)
        // No crash reaching here is itself the main assertion; canvas is still usable.
        canvas.setPixel(x: 0, y: 0, color: .black)
        XCTAssertEqual(canvas.rawPixel(x: 0, y: 0)?.r, 0)
    }

    // MARK: - fill

    func testFill_setsEveryPixelToTheSameByteLayoutAsSetPixel() {
        let canvas = PixelCanvas(width: 4, height: 4, background: .white)
        canvas.fill(with: .black)
        for y in 0..<4 {
            for x in 0..<4 {
                let pixel = canvas.rawPixel(x: x, y: y)
                XCTAssertEqual(pixel?.r, 0)
                XCTAssertEqual(pixel?.g, 0)
                XCTAssertEqual(pixel?.b, 0)
                XCTAssertEqual(pixel?.a, 255)
            }
        }
    }

    // MARK: - Constructor clamping (decision table: 0/negative -> 1)

    func testInit_zeroWidthAndHeight_areClampedToOne() {
        let canvas = PixelCanvas(width: 0, height: 0)
        XCTAssertEqual(canvas.width, 1)
        XCTAssertEqual(canvas.height, 1)
    }

    func testInit_negativeWidthAndHeight_areClampedToOne() {
        let canvas = PixelCanvas(width: -10, height: -20)
        XCTAssertEqual(canvas.width, 1)
        XCTAssertEqual(canvas.height, 1)
    }

    // MARK: - components(of:) rounding boundary

    func testComponentsRounding_halfwayValueRoundsToNearestByte() {
        // 127.5 / 255 lands exactly on the 0.5 rounding boundary for the red
        // channel; NSColor's `.rounded()` uses round-half-away-from-zero,
        // so 127.5 should round up to 128, not down to 127.
        let color = NSColor(deviceRed: 127.5 / 255.0, green: 0, blue: 0, alpha: 1)
        let canvas = PixelCanvas(width: 1, height: 1, background: color)
        XCTAssertEqual(canvas.rawPixel(x: 0, y: 0)?.r, 128)
    }

    // MARK: - PNG round-trip (decision table 2-4)

    private func assertRoundTrip(r: UInt8, g: UInt8, b: UInt8, a: UInt8, file: StaticString = #filePath, line: UInt = #line) {
        let color = NSColor(deviceRed: CGFloat(r) / 255.0, green: CGFloat(g) / 255.0, blue: CGFloat(b) / 255.0, alpha: CGFloat(a) / 255.0)
        let original = PixelCanvas(width: 2, height: 2, background: color)
        guard let data = original.pngData() else {
            XCTFail("pngData() returned nil", file: file, line: line)
            return
        }
        guard let loaded = PixelCanvas.load(from: data) else {
            XCTFail("load(from:) returned nil", file: file, line: line)
            return
        }
        let pixel = loaded.rawPixel(x: 0, y: 0)
        XCTAssertEqual(pixel?.r, r, "red channel mismatch after round trip", file: file, line: line)
        XCTAssertEqual(pixel?.g, g, "green channel mismatch after round trip", file: file, line: line)
        XCTAssertEqual(pixel?.b, b, "blue channel mismatch after round trip", file: file, line: line)
        XCTAssertEqual(pixel?.a, a, "alpha channel mismatch after round trip", file: file, line: line)
    }

    func testPNGRoundTrip_alpha255Black() {
        assertRoundTrip(r: 0, g: 0, b: 0, a: 255)
    }

    func testPNGRoundTrip_alpha255White() {
        assertRoundTrip(r: 255, g: 255, b: 255, a: 255)
    }

    func testPNGRoundTrip_alpha255ArbitraryColor() {
        assertRoundTrip(r: 37, g: 128, b: 201, a: 255)
    }

    func testPNGRoundTrip_alpha128SemiTransparentColor() {
        assertRoundTrip(r: 200, g: 50, b: 10, a: 128)
    }

    /// Highest-risk case from the test design: if the PNG encoder or
    /// `NSBitmapImageRep.colorAt(x:y:)` treats the buffer as premultiplied
    /// alpha anywhere in the round trip, a fully-transparent pixel with
    /// non-zero RGB would come back as (0,0,0,0) instead of preserving the
    /// original RGB. This is the test that would catch that bug.
    ///
    /// This intentionally uses a *mixed* 2x2 canvas (one opaque anchor
    /// pixel alongside the transparent target pixel) instead of routing
    /// through `assertRoundTrip`, which fills the entire canvas with a
    /// single color. When literally every pixel in the whole image is
    /// alpha=0, macOS's ImageIO PNG decoder discards RGB data on decode as
    /// a platform-level optimization for fully-invisible images — verified
    /// by manually zlib-inflating and PNG-filter-reconstructing the
    /// encoded bytes (the file itself *does* store the original RGB
    /// correctly) while `NSBitmapImageRep(data:)`,
    /// `CGImageSourceCreateImageAtIndex`, and even the raw `CGImage` data
    /// provider all hand back zeroed bytes for that all-transparent case.
    /// That is an OS decoder limitation this app cannot work around
    /// without a from-scratch PNG decoder, not the double-conversion bug
    /// this test targets, and it only affects a canvas that is 100%
    /// invisible end-to-end. A mixed canvas — the realistic "erased one
    /// pixel over painted content" case — avoids that OS fast path and
    /// still exercises the exact premultiply bug this test exists to
    /// catch (confirmed: before the `PixelCanvas` fix, this mixed-canvas
    /// version failed the same way).
    func testPNGRoundTrip_alpha0WithNonZeroRGB_preservesRGB() {
        let canvas = PixelCanvas(width: 2, height: 2, background: .white)
        canvas.setPixel(
            x: 0, y: 0,
            color: NSColor(deviceRed: 200.0 / 255.0, green: 50.0 / 255.0, blue: 10.0 / 255.0, alpha: 0)
        )

        guard let data = canvas.pngData(), let loaded = PixelCanvas.load(from: data) else {
            XCTFail("round trip failed")
            return
        }

        let pixel = loaded.rawPixel(x: 0, y: 0)
        XCTAssertEqual(pixel?.r, 200, "red channel mismatch after round trip")
        XCTAssertEqual(pixel?.g, 50, "green channel mismatch after round trip")
        XCTAssertEqual(pixel?.b, 10, "blue channel mismatch after round trip")
        XCTAssertEqual(pixel?.a, 0, "alpha channel mismatch after round trip")
    }

    func testPNGRoundTrip_alpha0WithZeroRGB() {
        assertRoundTrip(r: 0, g: 0, b: 0, a: 0)
    }

    func testPNGRoundTrip_asymmetricCornersStayInPlace() {
        let canvas = PixelCanvas(width: 2, height: 2, background: .white)
        canvas.setPixel(x: 0, y: 0, color: NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1)) // top-left: red
        canvas.setPixel(x: 1, y: 0, color: NSColor(deviceRed: 0, green: 1, blue: 0, alpha: 1)) // top-right: green
        canvas.setPixel(x: 0, y: 1, color: NSColor(deviceRed: 0, green: 0, blue: 1, alpha: 1)) // bottom-left: blue
        canvas.setPixel(x: 1, y: 1, color: NSColor(deviceRed: 1, green: 1, blue: 0, alpha: 1)) // bottom-right: yellow

        guard let data = canvas.pngData(), let loaded = PixelCanvas.load(from: data) else {
            XCTFail("round trip failed")
            return
        }

        XCTAssertEqual(loaded.rawPixel(x: 0, y: 0)?.r, 255) // red still top-left
        XCTAssertEqual(loaded.rawPixel(x: 0, y: 0)?.g, 0)
        XCTAssertEqual(loaded.rawPixel(x: 1, y: 0)?.g, 255) // green still top-right
        XCTAssertEqual(loaded.rawPixel(x: 0, y: 1)?.b, 255) // blue still bottom-left
        XCTAssertEqual(loaded.rawPixel(x: 1, y: 1)?.r, 255) // yellow still bottom-right
        XCTAssertEqual(loaded.rawPixel(x: 1, y: 1)?.g, 255)
    }

    func testPNGRoundTrip_oneByOneMinimumSize() {
        let canvas = PixelCanvas(width: 1, height: 1, background: NSColor(deviceRed: 0.5, green: 0.25, blue: 0.75, alpha: 1))
        guard let data = canvas.pngData(), let loaded = PixelCanvas.load(from: data) else {
            XCTFail("round trip failed")
            return
        }
        XCTAssertEqual(loaded.width, 1)
        XCTAssertEqual(loaded.height, 1)
        XCTAssertNotNil(loaded.rawPixel(x: 0, y: 0))
    }

    func testPNGRoundTrip_maximumSize4096Succeeds() {
        let canvas = PixelCanvas(width: 4096, height: 4096, background: .black)
        guard let data = canvas.pngData() else {
            XCTFail("pngData() returned nil for 4096x4096 canvas")
            return
        }
        guard let loaded = PixelCanvas.load(from: data) else {
            XCTFail("load(from:) returned nil for 4096x4096 PNG")
            return
        }
        XCTAssertEqual(loaded.width, 4096)
        XCTAssertEqual(loaded.height, 4096)
        XCTAssertEqual(loaded.rawPixel(x: 0, y: 0)?.r, 0)
        XCTAssertEqual(loaded.rawPixel(x: 4095, y: 4095)?.r, 0)
    }

    // MARK: - load(from:) invalid input

    func testLoad_garbageBytes_returnsNil() {
        let garbage = Data([0x00, 0x01, 0x02, 0xFF, 0xAB, 0xCD])
        XCTAssertNil(PixelCanvas.load(from: garbage))
    }

    func testLoad_emptyData_returnsNil() {
        XCTAssertNil(PixelCanvas.load(from: Data()))
    }
}
