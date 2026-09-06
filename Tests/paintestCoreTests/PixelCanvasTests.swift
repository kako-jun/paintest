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

    // MARK: - drawAntialiasedDot / drawAntialiasedLine (pen tool, issue #10)
    //
    // `NSGraphicsContext(bitmapImageRep:).cgContext` is not flipped by
    // default (CG's native origin is bottom-left, y up), while
    // `setPixel`/`rawPixel` treat row 0 of the same buffer as the top row.
    // This test is the empirical proof (not an assumption) that
    // `PixelCanvas`'s antialiased-drawing context corrects for that: a dot
    // requested "at (0, 0)" must land in the canvas's top-left corner, not
    // its bottom-left. Before the translate+flip in
    // `makeAntialiasedContext()`, this test failed (the dot appeared at the
    // bottom-left instead).

    func testDrawAntialiasedDot_atOrigin_paintsTopLeftCorner_notBottomLeft() {
        let canvas = PixelCanvas(width: 20, height: 20, background: .white)
        canvas.drawAntialiasedDot(at: (x: 0, y: 0), color: .black, diameter: 3)

        let topLeft = canvas.rawPixel(x: 0, y: 0)
        XCTAssertNotNil(topLeft)
        XCTAssertLessThan(topLeft?.r ?? 255, 255, "the dot drawn at (0,0) should darken the top-left corner")

        let bottomLeft = canvas.rawPixel(x: 0, y: canvas.height - 1)
        XCTAssertEqual(bottomLeft?.r, 255, "the bottom-left corner must stay untouched background color")
        XCTAssertEqual(bottomLeft?.g, 255)
        XCTAssertEqual(bottomLeft?.b, 255)
    }

    func testDrawAntialiasedDot_producesSoftEdge_unlikeSetPixel() {
        // The defining difference from the pencil's `setPixel`: a wide
        // antialiased dot leaves partially-covered (non-0/255) alpha or
        // color values at its edge instead of a hard binary boundary.
        let canvas = PixelCanvas(width: 20, height: 20, background: .white)
        canvas.drawAntialiasedDot(at: (x: 10, y: 10), color: .black, diameter: 8)

        var foundPartialCoverage = false
        for y in 6...14 {
            for x in 6...14 {
                guard let pixel = canvas.rawPixel(x: x, y: y) else { continue }
                if pixel.r != 0, pixel.r != 255 {
                    foundPartialCoverage = true
                }
            }
        }
        XCTAssertTrue(foundPartialCoverage, "an antialiased dot should have partially-covered edge pixels, unlike the pencil's hard edges")
    }

    func testDrawAntialiasedLine_paintsBetweenEndpoints() {
        let canvas = PixelCanvas(width: 20, height: 20, background: .white)
        canvas.drawAntialiasedLine(from: (x: 2, y: 10), to: (x: 17, y: 10), color: .black, lineWidth: 3)

        // Midpoint of the stroke should be solidly painted.
        let midpoint = canvas.rawPixel(x: 10, y: 10)
        XCTAssertEqual(midpoint?.r, 0)

        // Far outside the stroke's line width should stay untouched.
        let farAbove = canvas.rawPixel(x: 10, y: 2)
        XCTAssertEqual(farAbove?.r, 255)
    }

    // MARK: - drawAntialiasedDot/Line alpha compositing (issue #10 follow-up)
    //
    // The tests above cover the coordinate flip and the basic soft-edge
    // shape; these cover `drawAntialiased`'s actual "source over
    // destination" compositing math and its boundary/degenerate inputs.
    //
    // Compositing math note: `drawAntialiasedDot`/`Line` fill/stroke with
    // `color.cgColor` directly, while `setPixel`'s `components(of:)` helper
    // goes through `color.usingColorSpace(.deviceRGB)` first. For the
    // colors used below (built via `NSColor(deviceRed:green:blue:alpha:)`,
    // already in the device RGB space, and plain black/white/gray values
    // that are invariant across common RGB profiles) the two paths were
    // empirically confirmed to agree to within a couple of 8-bit levels, so
    // assertions here use a small `accuracy` tolerance rather than exact
    // equality — matching how `CanvasViewTests` already tolerates
    // color-space rounding (`accuracy: 0.01` on a composited color sample)
    // instead of asserting byte-exact equality there.

    func testDrawAntialiasedDot_srcAlphaZero_leavesCanvasUnchanged() {
        let canvas = PixelCanvas(width: 12, height: 12, background: .white)
        let fullyTransparent = NSColor(deviceRed: 0.6, green: 0.2, blue: 0.8, alpha: 0)

        canvas.drawAntialiasedDot(at: (x: 6, y: 6), color: fullyTransparent, diameter: 8)

        for y in 0..<12 {
            for x in 0..<12 {
                let pixel = canvas.rawPixel(x: x, y: y)
                XCTAssertEqual(pixel?.r, 255, "pixel (\(x),\(y)) should be untouched by a fully transparent color")
                XCTAssertEqual(pixel?.g, 255, "pixel (\(x),\(y)) should be untouched by a fully transparent color")
                XCTAssertEqual(pixel?.b, 255, "pixel (\(x),\(y)) should be untouched by a fully transparent color")
                XCTAssertEqual(pixel?.a, 255, "pixel (\(x),\(y)) should be untouched by a fully transparent color")
            }
        }
    }

    func testDrawAntialiasedDot_translucentColorOverTransparentDestination_resultAlphaEqualsSrcAlpha() {
        // A fully transparent destination (alpha 0, arbitrary RGB) so
        // `destAlpha == 0` and the "source over" formula collapses to
        // "result == source" — the destination must contribute nothing.
        let canvas = PixelCanvas(width: 12, height: 12, background: NSColor(deviceWhite: 1, alpha: 0))
        let translucentBlack = NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 0.5)

        canvas.drawAntialiasedDot(at: (x: 6, y: 6), color: translucentBlack, diameter: 8)

        guard let center = canvas.rawPixel(x: 6, y: 6) else {
            XCTFail("expected a readable center pixel")
            return
        }
        XCTAssertEqual(Double(center.a), 0.5 * 255, accuracy: 3, "result alpha over a fully transparent destination should equal the source's own alpha")
        XCTAssertEqual(Double(center.r), 0, accuracy: 3, "result color should be exactly the source color; the transparent destination must not contribute")
    }

    func testDrawAntialiasedDot_translucentColorOverOpaqueBackground_blendsProportionally() {
        // Black at alpha 0.5 over opaque white: outAlpha = srcAlpha +
        // destAlpha*(1-srcAlpha) = 0.5 + 1*0.5 = 1.0 (still opaque), and the
        // resulting gray should sit halfway between black and white.
        let canvas = PixelCanvas(width: 12, height: 12, background: .white)
        let translucentBlack = NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 0.5)

        canvas.drawAntialiasedDot(at: (x: 6, y: 6), color: translucentBlack, diameter: 8)

        guard let center = canvas.rawPixel(x: 6, y: 6) else {
            XCTFail("expected a readable center pixel")
            return
        }
        XCTAssertEqual(center.a, 255, "compositing a 50%-alpha color over an opaque background must stay fully opaque")
        XCTAssertEqual(Double(center.r), 127.5, accuracy: 3, "expected outColor = srcAlpha*src + (1-srcAlpha)*dest = 0.5*0 + 0.5*255")
        XCTAssertEqual(center.r, center.g, "gray blend should keep channels equal")
        XCTAssertEqual(center.g, center.b, "gray blend should keep channels equal")
    }

    func testDrawAntialiasedDot_diameterZero_doesNotCrashAndPaintsNothingOrNegligible() {
        let canvas = PixelCanvas(width: 8, height: 8, background: .white)

        canvas.drawAntialiasedDot(at: (x: 4, y: 4), color: .black, diameter: 0)

        for y in 0..<8 {
            for x in 0..<8 {
                let pixel = canvas.rawPixel(x: x, y: y)
                XCTAssertGreaterThanOrEqual(pixel?.r ?? 0, 250, "a zero-diameter dot should paint nothing (or only negligible coverage) at (\(x),\(y))")
            }
        }
    }

    func testDrawAntialiasedLine_lineWidthZeroOrNegative_doesNotCrash() {
        let canvas = PixelCanvas(width: 8, height: 8, background: .white)

        canvas.drawAntialiasedLine(from: (x: 1, y: 4), to: (x: 6, y: 4), color: .black, lineWidth: 0)
        canvas.drawAntialiasedLine(from: (x: 1, y: 5), to: (x: 6, y: 5), color: .black, lineWidth: -3)

        // Reaching here without a crash/trap is the main assertion; confirm
        // the canvas is still a normal, usable canvas afterward.
        canvas.setPixel(x: 0, y: 0, color: .black)
        XCTAssertEqual(canvas.rawPixel(x: 0, y: 0)?.r, 0)
    }

    func testDrawAntialiasedDot_centeredOffCanvasEdge_doesNotCrashAndClipsToCanvas() {
        let canvas = PixelCanvas(width: 10, height: 10, background: .white)

        // Center is off the top-left corner, but the dot is wide enough to
        // overlap the canvas: should clip in cleanly, no crash, and darken
        // the corner it overlaps.
        canvas.drawAntialiasedDot(at: (x: -2, y: -2), color: .black, diameter: 10)
        let corner = canvas.rawPixel(x: 0, y: 0)
        XCTAssertLessThan(corner?.r ?? 255, 255, "the overlapping part of the off-canvas dot should still paint the corner it reaches")
        let farCorner = canvas.rawPixel(x: 9, y: 9)
        XCTAssertEqual(farCorner?.r, 255, "the far corner, well outside the dot's reach, must stay untouched")

        // Center is entirely outside the canvas with no overlap at all:
        // should be a no-op, not a crash.
        canvas.drawAntialiasedDot(at: (x: -100, y: -100), color: .black, diameter: 4)
        canvas.setPixel(x: 0, y: 0, color: .black) // canvas still usable afterward
        XCTAssertEqual(canvas.rawPixel(x: 0, y: 0)?.r, 0)
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

    // MARK: - load(from:) grayscale PNG (regression: fast path must reject
    // non-RGB(A) sample layouts, not just non-8-bit/non-planar ones)

    /// Builds a single-channel (no alpha), 8-bit grayscale PNG — the layout
    /// that used to slip into `load(from:)`'s fast RGB(A) byte-copy path
    /// because that path only checked `bitsPerSample == 8` and `!isPlanar`,
    /// not `samplesPerPixel`. With a 1-byte-per-pixel source stride, reading
    /// `r`/`g`/`b` at `srcOffset`/`+1`/`+2` pulled in neighboring pixels'
    /// gray values as the G/B channels instead of replicating the single
    /// gray sample across R/G/B.
    private func makeGrayscalePNGData(width: Int, height: Int, gray: UInt8) -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 1,
            hasAlpha: false,
            isPlanar: false,
            colorSpaceName: .deviceWhite,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let data = rep.bitmapData else { return nil }

        let bytesPerRow = rep.bytesPerRow
        for y in 0..<height {
            for x in 0..<width {
                data[y * bytesPerRow + x] = gray
            }
        }
        return rep.representation(using: .png, properties: [:])
    }

    /// Builds a 2-channel (gray + alpha), 8-bit grayscale+alpha PNG — a
    /// second layout excluded by the same `samplesPerPixel == 3 || == 4`
    /// gate that the single-channel grayscale fixture above exercises, but
    /// with `samplesPerPixel == 2` this time. This is a legal PNG color
    /// type (grayscale with alpha), so `load(from:)` must still fall back
    /// to the safe `colorAt(x:y:)` path for it instead of misreading the
    /// 2-byte-per-pixel source stride as 3/4 bytes per pixel.
    private func makeGrayscaleWithAlphaPNGData(width: Int, height: Int, gray: UInt8, alpha: UInt8) -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 2,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceWhite,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let data = rep.bitmapData else { return nil }

        let bytesPerRow = rep.bytesPerRow
        let bytesPerPixel = rep.bitsPerPixel / 8
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * bytesPerPixel
                data[offset] = gray
                data[offset + 1] = alpha
            }
        }
        return rep.representation(using: .png, properties: [:])
    }

    func testLoad_grayscaleWithAlphaPNG_everyPixelIsUniformGrayWithNoChannelBleed() {
        // Fully opaque and a non-uniform gray value, for the same reason as
        // the single-channel grayscale fixture: any bleed from a
        // neighboring pixel's bytes into G/B would be visible, and this
        // isn't a coincidental 0/255 result.
        let gray: UInt8 = 137
        let alpha: UInt8 = 255
        guard let data = makeGrayscaleWithAlphaPNGData(width: 4, height: 4, gray: gray, alpha: alpha) else {
            XCTFail("failed to build grayscale+alpha PNG fixture")
            return
        }
        guard let loaded = PixelCanvas.load(from: data) else {
            XCTFail("load(from:) returned nil for grayscale+alpha PNG")
            return
        }
        XCTAssertEqual(loaded.width, 4)
        XCTAssertEqual(loaded.height, 4)
        guard let anchor = loaded.rawPixel(x: 0, y: 0) else {
            XCTFail("expected pixel (0,0) to be readable")
            return
        }
        XCTAssertEqual(anchor.r, anchor.g, "pixel (0,0) should be a neutral gray: r should equal g")
        XCTAssertEqual(anchor.g, anchor.b, "pixel (0,0) should be a neutral gray: g should equal b")
        XCTAssertEqual(anchor.a, 255, "pixel (0,0) alpha should be fully opaque")
        for y in 0..<4 {
            for x in 0..<4 {
                let pixel = loaded.rawPixel(x: x, y: y)
                XCTAssertEqual(pixel?.r, anchor.r, "pixel (\(x),\(y)) red channel should match the uniform gray, not bleed from a neighbor")
                XCTAssertEqual(pixel?.g, anchor.g, "pixel (\(x),\(y)) green channel should match the uniform gray, not bleed from a neighbor")
                XCTAssertEqual(pixel?.b, anchor.b, "pixel (\(x),\(y)) blue channel should match the uniform gray, not bleed from a neighbor")
                XCTAssertEqual(pixel?.a, 255, "pixel (\(x),\(y)) alpha should be fully opaque")
            }
        }
    }

    func testLoad_grayscalePNG_everyPixelIsUniformGrayWithNoChannelBleed() {
        // A non-uniform gray value (not 0 or 255) makes any bleed from a
        // neighboring pixel's byte into G/B visible, since a real bug would
        // otherwise coincidentally still read 0/255 for an all-black or
        // all-white image.
        //
        // This intentionally does not assert the loaded byte equals the
        // literal 137 written into the source bitmap: the corrected code
        // path routes grayscale through `colorAt(x:y:)` and a `.deviceRGB`
        // color-space conversion (see `load(from:)`'s doc comment), which
        // is free to apply gamma/profile adjustment to the gray value. What
        // matters for this regression — that the fast RGB(A) byte-copy path
        // no longer misreads a 1-byte-per-pixel grayscale buffer as 3/4
        // bytes per pixel — is that every pixel decodes to the exact same
        // r==g==b gray, with no per-position drift from reading a
        // neighbor's byte as G or B.
        let gray: UInt8 = 137
        guard let data = makeGrayscalePNGData(width: 4, height: 4, gray: gray) else {
            XCTFail("failed to build grayscale PNG fixture")
            return
        }
        guard let loaded = PixelCanvas.load(from: data) else {
            XCTFail("load(from:) returned nil for grayscale PNG")
            return
        }
        XCTAssertEqual(loaded.width, 4)
        XCTAssertEqual(loaded.height, 4)
        guard let anchor = loaded.rawPixel(x: 0, y: 0) else {
            XCTFail("expected pixel (0,0) to be readable")
            return
        }
        XCTAssertEqual(anchor.r, anchor.g, "pixel (0,0) should be a neutral gray: r should equal g")
        XCTAssertEqual(anchor.g, anchor.b, "pixel (0,0) should be a neutral gray: g should equal b")
        XCTAssertEqual(anchor.a, 255, "pixel (0,0) alpha should be fully opaque")
        for y in 0..<4 {
            for x in 0..<4 {
                let pixel = loaded.rawPixel(x: x, y: y)
                XCTAssertEqual(pixel?.r, anchor.r, "pixel (\(x),\(y)) red channel should match the uniform gray, not bleed from a neighbor")
                XCTAssertEqual(pixel?.g, anchor.g, "pixel (\(x),\(y)) green channel should match the uniform gray, not bleed from a neighbor")
                XCTAssertEqual(pixel?.b, anchor.b, "pixel (\(x),\(y)) blue channel should match the uniform gray, not bleed from a neighbor")
                XCTAssertEqual(pixel?.a, 255, "pixel (\(x),\(y)) alpha should be fully opaque")
            }
        }
    }
}
