import AppKit
import XCTest
@testable import paintestCore

/// Pure-logic tests for `ImageAdjustments` (issue #12: "トーンカーブ・色調補正").
///
/// `AdjustmentDialog.swift` (the AppKit UI half of issue #12) is deliberately
/// untested here, matching this suite's existing "no `NSAlert`/`NSPanel`
/// modal loop in XCTest" convention: every function in that file is either
/// `private` or depends directly on `NSPanel`/`NSSlider`/`NSEvent`, with no
/// pure function left to extract and test in isolation. Everything below
/// only ever touches `ImageAdjustments` itself (plus `PixelCanvas` and
/// `SelectionMask` as plain data, for the `apply` tests) — no dialog, no
/// window, no modal loop.
final class ImageAdjustmentsTests: XCTestCase {
    // MARK: - Test helpers (pixel setup/readback via NSColor, matching
    // `PixelCanvasTests`' own convention of building colors with
    // `NSColor(deviceRed:green:blue:alpha:)` and reading back via `rawPixel`)

    private func makeCanvas(width: Int, height: Int, background: (r: UInt8, g: UInt8, b: UInt8, a: UInt8) = (255, 255, 255, 255)) -> PixelCanvas {
        PixelCanvas(width: width, height: height, background: color(background))
    }

    private func color(_ c: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> NSColor {
        NSColor(deviceRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: CGFloat(c.a) / 255)
    }

    private func setPixel(_ canvas: PixelCanvas, x: Int, y: Int, _ c: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) {
        canvas.setPixel(x: x, y: y, color: color(c))
    }

    /// Inverts R/G/B, passes alpha through unchanged — a transform with an
    /// obviously non-identity, easy-to-hand-verify effect.
    private let invert: (UInt8, UInt8, UInt8, UInt8) -> (UInt8, UInt8, UInt8, UInt8) = { r, g, b, a in
        (255 - r, 255 - g, 255 - b, a)
    }

    /// Adds 10 to each channel (clamped at 255), passes alpha through
    /// unchanged — a second, different-from-`invert` transform used to prove
    /// `apply` recomputes fresh from `source` rather than compounding onto
    /// whatever `destination` already held.
    private let addTen: (UInt8, UInt8, UInt8, UInt8) -> (UInt8, UInt8, UInt8, UInt8) = { r, g, b, a in
        let bump: (UInt8) -> UInt8 = { UInt8(min(255, Int($0) + 10)) }
        return (bump(r), bump(g), bump(b), a)
    }

    // MARK: - apply(transform:from:into:mask:) — decision table 1

    func testApply_maskNil_appliesTransformToEveryPixel() {
        let source = makeCanvas(width: 2, height: 2)
        setPixel(source, x: 0, y: 0, (10, 20, 30, 255))
        setPixel(source, x: 1, y: 0, (40, 50, 60, 200))
        setPixel(source, x: 0, y: 1, (70, 80, 90, 150))
        setPixel(source, x: 1, y: 1, (100, 110, 120, 50))
        let destination = makeCanvas(width: 2, height: 2)

        ImageAdjustments.apply(transform: invert, from: source, into: destination, mask: nil)

        XCTAssertEqual(destination.rawPixel(x: 0, y: 0)?.r, 245)
        XCTAssertEqual(destination.rawPixel(x: 0, y: 0)?.g, 235)
        XCTAssertEqual(destination.rawPixel(x: 0, y: 0)?.b, 225)
        XCTAssertEqual(destination.rawPixel(x: 1, y: 0)?.r, 215)
        XCTAssertEqual(destination.rawPixel(x: 0, y: 1)?.r, 185)
        XCTAssertEqual(destination.rawPixel(x: 1, y: 1)?.r, 155)
        XCTAssertEqual(destination.rawPixel(x: 1, y: 1)?.a, 50, "alpha must reach the destination unchanged even with mask: nil")
    }

    func testApply_maskNonNilSelectedPixel_appliesTransform() {
        let source = makeCanvas(width: 1, height: 1)
        setPixel(source, x: 0, y: 0, (50, 60, 70, 255))
        let destination = makeCanvas(width: 1, height: 1)
        let mask = SelectionMask.rectangle(x0: 0, y0: 0, x1: 0, y1: 0, width: 1, height: 1)

        ImageAdjustments.apply(transform: invert, from: source, into: destination, mask: mask)

        XCTAssertEqual(destination.rawPixel(x: 0, y: 0)?.r, 205)
        XCTAssertEqual(destination.rawPixel(x: 0, y: 0)?.g, 195)
        XCTAssertEqual(destination.rawPixel(x: 0, y: 0)?.b, 185)
    }

    func testApply_maskNonNilUnselectedPixel_overwrittenWithSourceUnchangedValue_notLeftAlone() {
        // (0,0) is excluded by the mask (only (1,1) is selected). `destination`
        // is pre-"poisoned" with a value that matches neither the source nor
        // a transformed source, so the assertion below can only pass if
        // `apply` actively overwrites the unselected pixel with `source`'s
        // own value — leaving it alone (the poison surviving) would fail it.
        let source = makeCanvas(width: 2, height: 2)
        setPixel(source, x: 0, y: 0, (50, 60, 70, 255))
        setPixel(source, x: 1, y: 1, (10, 10, 10, 255))
        let destination = makeCanvas(width: 2, height: 2, background: (1, 2, 3, 4))
        let mask = SelectionMask.rectangle(x0: 1, y0: 1, x1: 1, y1: 1, width: 2, height: 2)

        ImageAdjustments.apply(transform: invert, from: source, into: destination, mask: mask)

        let result = destination.rawPixel(x: 0, y: 0)
        XCTAssertEqual(result?.r, 50, "unselected pixel must be overwritten with source's own value, not left as the poison value")
        XCTAssertEqual(result?.g, 60)
        XCTAssertEqual(result?.b, 70)
        XCTAssertEqual(result?.a, 255)
    }

    func testApply_repeatedCallsWithDifferentTransform_convergesFreshFromSourceEachTime_doesNotCompound() {
        let source = makeCanvas(width: 1, height: 1)
        setPixel(source, x: 0, y: 0, (100, 100, 100, 255))
        let destination = makeCanvas(width: 1, height: 1)

        // First tick: a strong transform (invert: 100 -> 155).
        ImageAdjustments.apply(transform: invert, from: source, into: destination, mask: nil)
        XCTAssertEqual(destination.rawPixel(x: 0, y: 0)?.r, 155, "precondition: first apply landed the expected inverted value")

        // Second tick: a different, weaker transform, same source, same
        // (already-155) destination. If `apply` read from `destination`
        // instead of `source`, this would compound to addTen(155) = 165.
        ImageAdjustments.apply(transform: addTen, from: source, into: destination, mask: nil)

        XCTAssertEqual(destination.rawPixel(x: 0, y: 0)?.r, 110, "must equal addTen(source) == 110, not addTen(previous destination) == 165")
    }

    func testApply_alphaChannel_alwaysPassedThroughUnchanged() {
        let source = makeCanvas(width: 2, height: 1)
        setPixel(source, x: 0, y: 0, (10, 20, 30, 77)) // selected
        setPixel(source, x: 1, y: 0, (40, 50, 60, 200)) // unselected
        let destination = makeCanvas(width: 2, height: 1)
        let mask = SelectionMask.rectangle(x0: 0, y0: 0, x1: 0, y1: 0, width: 2, height: 1)

        ImageAdjustments.apply(transform: invert, from: source, into: destination, mask: mask)

        XCTAssertEqual(destination.rawPixel(x: 0, y: 0)?.a, 77, "selected pixel: alpha passed through the transform unchanged")
        XCTAssertEqual(destination.rawPixel(x: 1, y: 0)?.a, 200, "unselected pixel: alpha copied from source unchanged")
    }

    // MARK: - RGB <-> HSB (rgbToHSB / hsbToRGB / normalizedHue)

    func testRgbToHsb_hsbToRgb_roundTrip_arbitraryColor() {
        // (200, 100, 50): hand-verified via exact fractions (h=20°, s=0.75,
        // v=200/255) to round-trip back to the exact original bytes.
        let hsb = ImageAdjustments.rgbToHSB(r: 200, g: 100, b: 50)
        XCTAssertEqual(hsb.h, 20, accuracy: 1e-9)
        XCTAssertEqual(hsb.s, 0.75, accuracy: 1e-9)

        let rgb = ImageAdjustments.hsbToRGB(h: hsb.h, s: hsb.s, v: hsb.v)
        XCTAssertEqual(rgb.r, 200)
        XCTAssertEqual(rgb.g, 100)
        XCTAssertEqual(rgb.b, 50)
    }

    func testRgbToHsb_redIsMaxButGreenLessThanBlue_negativeHueCorrectedTo360Range() {
        // r=200 (max), g=50, b=100: g < b makes the raw `60*((g-b)/delta)`
        // term negative (-20°) before the `h < 0 { h += 360 }` correction;
        // hand-verified via exact fractions to land at exactly 340°.
        let hsb = ImageAdjustments.rgbToHSB(r: 200, g: 50, b: 100)
        XCTAssertGreaterThanOrEqual(hsb.h, 0, "hue must always be corrected into the non-negative range")
        XCTAssertEqual(hsb.h, 340, accuracy: 1e-9)
    }

    func testHsbToRgb_sectorBoundaries_hue0_60_120_180_240_300_mapToCorrectCase() {
        // Full saturation/value pure colors at each 60°-wide switch
        // boundary, hand-derived from the standard HSB color wheel.
        XCTAssertEqual(ImageAdjustments.hsbToRGB(h: 0, s: 1, v: 1).r, 255)
        XCTAssertEqual(ImageAdjustments.hsbToRGB(h: 0, s: 1, v: 1).g, 0)
        XCTAssertEqual(ImageAdjustments.hsbToRGB(h: 0, s: 1, v: 1).b, 0)

        // Tuples aren't `Equatable` (no generic conformance, even though a
        // same-arity `==` operator exists), so `XCTAssertEqual` can't take
        // them directly — `XCTAssertTrue(... == ...)` uses that `==`
        // operator as a plain `Bool` expression instead.
        let at60 = ImageAdjustments.hsbToRGB(h: 60, s: 1, v: 1)
        XCTAssertTrue((at60.r, at60.g, at60.b) == (255, 255, 0), "hue 60 (yellow) falls in the 1..<2 case")

        let at120 = ImageAdjustments.hsbToRGB(h: 120, s: 1, v: 1)
        XCTAssertTrue((at120.r, at120.g, at120.b) == (0, 255, 0), "hue 120 (green) falls in the 2..<3 case")

        let at180 = ImageAdjustments.hsbToRGB(h: 180, s: 1, v: 1)
        XCTAssertTrue((at180.r, at180.g, at180.b) == (0, 255, 255), "hue 180 (cyan) falls in the 3..<4 case")

        let at240 = ImageAdjustments.hsbToRGB(h: 240, s: 1, v: 1)
        XCTAssertTrue((at240.r, at240.g, at240.b) == (0, 0, 255), "hue 240 (blue) falls in the 4..<5 case")

        let at300 = ImageAdjustments.hsbToRGB(h: 300, s: 1, v: 1)
        XCTAssertTrue((at300.r, at300.g, at300.b) == (255, 0, 255), "hue 300 (magenta) falls in the default case")
    }

    func testNormalizedHue_zero_isZero() {
        XCTAssertEqual(ImageAdjustments.normalizedHue(0), 0)
    }

    func testNormalizedHue_negative170_wrapsTo190() {
        XCTAssertEqual(ImageAdjustments.normalizedHue(-170), 190, accuracy: 1e-9)
    }

    func testNormalizedHue_exactly360_wrapsToZero_notItself() {
        XCTAssertEqual(ImageAdjustments.normalizedHue(360), 0, accuracy: 1e-9)
    }

    func testNormalizedHue_exactlyNegative360_isZero_notNegativeZeroSemantically() {
        XCTAssertEqual(ImageAdjustments.normalizedHue(-360), 0, accuracy: 1e-9)
    }

    // MARK: - BrightnessContrastSettings

    func testBrightnessContrast_identity_isExactNoOp() {
        let table = ImageAdjustments.BrightnessContrastSettings.identity.lut()
        for v in 0...255 {
            XCTAssertEqual(table[v], UInt8(v), "identity brightness/contrast must be a byte-exact no-op at \(v)")
        }
    }

    func testBrightnessContrast_brightnessClampedAt150Boundary() {
        var atLimit = ImageAdjustments.BrightnessContrastSettings.identity
        atLimit.brightness = 150
        var beyondLimit = ImageAdjustments.BrightnessContrastSettings.identity
        beyondLimit.brightness = 999

        XCTAssertEqual(atLimit.lut(), beyondLimit.lut(), "brightness beyond +150 must clamp to the same result as exactly +150")
    }

    func testBrightnessContrast_contrastClampedAt100Boundary_noDivideByZero() {
        var atLimit = ImageAdjustments.BrightnessContrastSettings.identity
        atLimit.contrast = 100
        var beyondLimit = ImageAdjustments.BrightnessContrastSettings.identity
        beyondLimit.contrast = 1000

        // Also exercises the "denominator never reaches 0" guarantee from
        // the doc comment: at contrast == 100 the formula's denominator is
        // 259 - 255 == 4, never 0, so this must not crash/produce garbage.
        XCTAssertEqual(atLimit.lut(), beyondLimit.lut(), "contrast beyond +100 must clamp to the same result as exactly +100")
    }

    func testBrightnessContrast_negativeContrastMinus100_collapsesTowardMidpoint128() {
        // At contrast == -100 the formula's factor is exactly 0 (hand-
        // verified: contrastScaled = -255, factor = 259*0 / (255*514) = 0),
        // so every input collapses to the flat midpoint 128 (plus brightness,
        // here 0).
        var settings = ImageAdjustments.BrightnessContrastSettings.identity
        settings.contrast = -100
        let table = settings.lut()

        XCTAssertEqual(table[0], 128)
        XCTAssertEqual(table[50], 128)
        XCTAssertEqual(table[128], 128)
        XCTAssertEqual(table[200], 128)
        XCTAssertEqual(table[255], 128)
    }

    func testBrightnessContrast_alphaUnchanged() {
        var settings = ImageAdjustments.BrightnessContrastSettings.identity
        settings.brightness = 40
        settings.contrast = 30
        let transform = settings.makeTransform()

        let result = transform(10, 20, 30, 77)
        XCTAssertEqual(result.3, 77, "alpha must pass through makeTransform() unchanged regardless of brightness/contrast")
    }

    // MARK: - HueSaturationSettings

    func testHueSaturation_allZero_returnsExactOriginalRGB_noHsbRoundTripDrift() {
        // hue/saturation/lightness all 0 must short-circuit the guard clause
        // entirely and never touch the HSB round trip, so a color that would
        // otherwise be at risk of rounding drift (1, 2, 3) comes back
        // byte-exact.
        let result = ImageAdjustments.HueSaturationSettings.identity.apply(r: 1, g: 2, b: 3)
        XCTAssertEqual(result.r, 1)
        XCTAssertEqual(result.g, 2)
        XCTAssertEqual(result.b, 3)
    }

    func testHueSaturation_saturationPositive_movesTowardFullSaturation() {
        // (150, 100, 100) has hue 0°, s = 1/3, v = 150/255. Hand-derived via
        // exact fractions: saturation +50 moves s to 1/3 + (2/3)*0.5 = 2/3,
        // which converts back to the exact byte triple (150, 50, 50) — g/b
        // pulled down, away from r, i.e. more saturated.
        var settings = ImageAdjustments.HueSaturationSettings.identity
        settings.saturation = 50
        let result = settings.apply(r: 150, g: 100, b: 100)
        XCTAssertEqual(result.r, 150)
        XCTAssertEqual(result.g, 50)
        XCTAssertEqual(result.b, 50)
    }

    func testHueSaturation_saturationNegative_movesTowardDesaturated() {
        // Same starting color; saturation -50 moves s to (1/3)*0.5 = 1/6,
        // hand-derived to the exact byte triple (150, 125, 125) — g/b pulled
        // up toward r, i.e. less saturated (grayer).
        var settings = ImageAdjustments.HueSaturationSettings.identity
        settings.saturation = -50
        let result = settings.apply(r: 150, g: 100, b: 100)
        XCTAssertEqual(result.r, 150)
        XCTAssertEqual(result.g, 125)
        XCTAssertEqual(result.b, 125)
    }

    func testHueSaturation_lightnessPositive_movesTowardWhite() {
        // Same starting color, saturation left at 0 to isolate lightness.
        // Hand-derived: v = 150/255 -> newValue = (v+1)/2 = 27/34, which
        // converts back to (203, 135, 135) (203 from the exact half-value
        // 202.5 rounding away from zero) — brighter, moving toward white.
        var settings = ImageAdjustments.HueSaturationSettings.identity
        settings.lightness = 50
        let result = settings.apply(r: 150, g: 100, b: 100)
        XCTAssertEqual(result.r, 203)
        XCTAssertEqual(result.g, 135)
        XCTAssertEqual(result.b, 135)
    }

    func testHueSaturation_lightnessNegative_movesTowardBlack() {
        // Same starting color; lightness -50 halves v (10/17 * 0.5 = 5/17),
        // hand-derived to the exact byte triple (75, 50, 50) — darker,
        // moving toward black.
        var settings = ImageAdjustments.HueSaturationSettings.identity
        settings.lightness = -50
        let result = settings.apply(r: 150, g: 100, b: 100)
        XCTAssertEqual(result.r, 75)
        XCTAssertEqual(result.g, 50)
        XCTAssertEqual(result.b, 50)
    }

    func testHueSaturation_saturationClampedAt100AndMinus100Boundaries() {
        // `apply`'s result is a labeled `(r: UInt8, g: UInt8, b: UInt8)`
        // tuple, which (like the HSB sector tuples above) isn't `Equatable`
        // for `XCTAssertEqual` — compare via the tuple `==` operator inside
        // `XCTAssertTrue` instead.
        var atPositiveLimit = ImageAdjustments.HueSaturationSettings.identity
        atPositiveLimit.saturation = 100
        var beyondPositiveLimit = ImageAdjustments.HueSaturationSettings.identity
        beyondPositiveLimit.saturation = 999
        XCTAssertTrue(
            atPositiveLimit.apply(r: 150, g: 100, b: 100) == beyondPositiveLimit.apply(r: 150, g: 100, b: 100),
            "saturation beyond +100 must clamp to the same result as exactly +100"
        )

        var atNegativeLimit = ImageAdjustments.HueSaturationSettings.identity
        atNegativeLimit.saturation = -100
        var beyondNegativeLimit = ImageAdjustments.HueSaturationSettings.identity
        beyondNegativeLimit.saturation = -999
        XCTAssertTrue(
            atNegativeLimit.apply(r: 150, g: 100, b: 100) == beyondNegativeLimit.apply(r: 150, g: 100, b: 100),
            "saturation beyond -100 must clamp to the same result as exactly -100"
        )
    }

    func testHueSaturation_pureRedHueRotate120_becomesExactPureGreen() {
        var settings = ImageAdjustments.HueSaturationSettings.identity
        settings.hue = 120
        let result = settings.apply(r: 255, g: 0, b: 0)
        XCTAssertEqual(result.r, 0)
        XCTAssertEqual(result.g, 255)
        XCTAssertEqual(result.b, 0)
    }

    func testHueSaturation_hueBeyondSliderRange540_stillWrapsCorrectlyViaNormalizedHue() {
        // Regression pin (found by code reading): unlike saturation/lightness
        // (both defensively clamped to -100...100 inside `apply`), `hue` has
        // no equivalent clamp — it flows straight into `normalizedHue`,
        // whatever its magnitude. 0° + 540° wraps (via `normalizedHue`) to
        // exactly 180°, which for a pure red input converts back to exact
        // pure cyan. This pins today's actual (unclamped, wrap-based)
        // behavior so a future accidental clamp would be caught as a
        // regression.
        var settings = ImageAdjustments.HueSaturationSettings.identity
        settings.hue = 540
        let result = settings.apply(r: 255, g: 0, b: 0)
        XCTAssertEqual(result.r, 0)
        XCTAssertEqual(result.g, 255)
        XCTAssertEqual(result.b, 255)
    }

    // MARK: - ToneCurve.lut()

    func testToneCurve_zeroPoints_fallsBackToIdentity() {
        let table = ImageAdjustments.ToneCurve(points: []).lut()
        XCTAssertEqual(table[0], 0)
        XCTAssertEqual(table[128], 128)
        XCTAssertEqual(table[255], 255)
    }

    func testToneCurve_onePoint_fallsBackToIdentity() {
        // The single point's own (50, 200) value must be ignored entirely —
        // table[50] must read 50 (identity), not 200.
        let table = ImageAdjustments.ToneCurve(points: [ImageAdjustments.ToneCurvePoint(50, 200)]).lut()
        XCTAssertEqual(table[50], 50)
        XCTAssertEqual(table[0], 0)
        XCTAssertEqual(table[255], 255)
    }

    func testToneCurve_exactlyTwoPoints_usesLinearInterpolation_notSpline() {
        let curve = ImageAdjustments.ToneCurve(points: [ImageAdjustments.ToneCurvePoint(0, 0), ImageAdjustments.ToneCurvePoint(100, 50)])
        let table = curve.lut()
        XCTAssertEqual(table[0], 0)
        XCTAssertEqual(table[100], 50)
        XCTAssertEqual(table[50], 25, "midpoint of a straight line from (0,0) to (100,50)")
    }

    func testToneCurve_threePoints_usesCatmullRomSpline_notLinear() {
        // Points (0,0), (128,64), (255,255): a straight line through just
        // the first two points would put x=64 at y=32. Catmull-Rom's
        // curvature (pulled by the third point) instead lands at y≈20.0625,
        // hand-derived from the spline formula — rounds to 20, clearly not
        // the linear value.
        let curve = ImageAdjustments.ToneCurve(points: [
            ImageAdjustments.ToneCurvePoint(0, 0),
            ImageAdjustments.ToneCurvePoint(128, 64),
            ImageAdjustments.ToneCurvePoint(255, 255)
        ])
        let table = curve.lut()
        XCTAssertEqual(table[64], 20, "Catmull-Rom curvature, not the linear-segment value of 32")
    }

    func testToneCurve_identityCurve_lutIsExactByteIdentity_noBowing() {
        let table = ImageAdjustments.ToneCurve.identity.lut()
        for v in 0...255 {
            XCTAssertEqual(table[v], UInt8(v), "the default 2-point identity curve must be byte-exact, not bowed, at \(v)")
        }
    }

    func testToneCurve_twoPointsSameInput_fallsBackToFlatValue_noDivideByZero() {
        // Both points share input 100; the stable sort preserves their
        // original order, so (x2 > x1) is false (100 > 100) and the curve
        // falls back to a flat line at the *first* point's own output (30),
        // for every x, with no division by (x2 - x1) == 0.
        let curve = ImageAdjustments.ToneCurve(points: [ImageAdjustments.ToneCurvePoint(100, 30), ImageAdjustments.ToneCurvePoint(100, 200)])
        let table = curve.lut()
        XCTAssertEqual(table[0], 30)
        XCTAssertEqual(table[100], 30)
        XCTAssertEqual(table[255], 30)
    }

    func testToneCurve_unsortedInputPoints_sortedBeforeInterpolation() {
        // Given out of order ((255,255) before (0,0)): if `lut()` failed to
        // sort first, the 2-point branch would treat (255,255) as (x1,y1)
        // and (0,0) as (x2,y2), see x2 > x1 fail (0 > 255 is false), and
        // fall back to a flat line at 255 for every x. Sorting first
        // recovers the ordinary identity line instead.
        let curve = ImageAdjustments.ToneCurve(points: [ImageAdjustments.ToneCurvePoint(255, 255), ImageAdjustments.ToneCurvePoint(0, 0)])
        let table = curve.lut()
        XCTAssertEqual(table[0], 0)
        XCTAssertEqual(table[100], 100)
        XCTAssertEqual(table[255], 255)
    }

    func testToneCurve_valuesOutsideFirstLastPoint_holdFlat_noExtrapolation() {
        // 3+ points: `catmullRomInterpolate` explicitly holds flat past the
        // first/last control point rather than extrapolating (unlike the
        // 2-point linear branch, which does extrapolate).
        let curve = ImageAdjustments.ToneCurve(points: [
            ImageAdjustments.ToneCurvePoint(50, 80),
            ImageAdjustments.ToneCurvePoint(128, 128),
            ImageAdjustments.ToneCurvePoint(200, 180)
        ])
        let table = curve.lut()
        XCTAssertEqual(table[0], 80, "below the first point's input must hold flat at its output")
        XCTAssertEqual(table[255], 180, "above the last point's input must hold flat at its output")
    }

    // MARK: - ToneCurve.clampedInput(forPointAt:proposedInput:in:)

    func testClampedInput_indexZero_hasNoLeftNeighbor_minIsZero() {
        let points = [ImageAdjustments.ToneCurvePoint(5, 0), ImageAdjustments.ToneCurvePoint(50, 0)]
        let clamped = ImageAdjustments.ToneCurve.clampedInput(forPointAt: 0, proposedInput: -20, in: points)
        XCTAssertEqual(clamped, 0, "index 0 has no left neighbor, so the floor is 0 regardless of how negative the proposal is")
    }

    func testClampedInput_lastIndex_hasNoRightNeighbor_maxIs255() {
        let points = [ImageAdjustments.ToneCurvePoint(5, 0), ImageAdjustments.ToneCurvePoint(50, 0)]
        let clamped = ImageAdjustments.ToneCurve.clampedInput(forPointAt: 1, proposedInput: 300, in: points)
        XCTAssertEqual(clamped, 255, "the last index has no right neighbor, so the ceiling is 255 regardless of how large the proposal is")
    }

    func testClampedInput_adjacentNeighborsGap1_noRoom_returnsOriginalInputUnchanged() {
        // Neighbors at input 50 and 51 (gap of 1) leave minInput (51) >
        // maxInput (50): no integer sits strictly between them. The
        // degenerate fallback returns the *point's own current* input (999,
        // a deliberately implausible sentinel) rather than anything derived
        // from the neighbors or from `proposedInput`.
        let points = [
            ImageAdjustments.ToneCurvePoint(50, 0),
            ImageAdjustments.ToneCurvePoint(999, 0),
            ImageAdjustments.ToneCurvePoint(51, 0)
        ]
        let clamped = ImageAdjustments.ToneCurve.clampedInput(forPointAt: 1, proposedInput: 12345, in: points)
        XCTAssertEqual(clamped, 999, "no room between adjacent neighbors: must fall back to the point's own current input")
    }

    func testClampedInput_gap2_exactlyOneSlot_clampsToThatSingleValue() {
        // Neighbors at 10 and 12 (gap of 2) leave exactly one legal slot: 11.
        let points = [
            ImageAdjustments.ToneCurvePoint(10, 0),
            ImageAdjustments.ToneCurvePoint(999, 0),
            ImageAdjustments.ToneCurvePoint(12, 0)
        ]
        XCTAssertEqual(ImageAdjustments.ToneCurve.clampedInput(forPointAt: 1, proposedInput: 999999, in: points), 11)
        XCTAssertEqual(ImageAdjustments.ToneCurve.clampedInput(forPointAt: 1, proposedInput: -999999, in: points), 11)
    }

    func testClampedInput_gap3_normalRange_clampsWithinOpenInterval() {
        // Neighbors at 10 and 13 (gap of 3) leave a 2-value open range: 11...12.
        let points = [
            ImageAdjustments.ToneCurvePoint(10, 0),
            ImageAdjustments.ToneCurvePoint(999, 0),
            ImageAdjustments.ToneCurvePoint(13, 0)
        ]
        XCTAssertEqual(ImageAdjustments.ToneCurve.clampedInput(forPointAt: 1, proposedInput: 11, in: points), 11, "within range must pass through unchanged")
        XCTAssertEqual(ImageAdjustments.ToneCurve.clampedInput(forPointAt: 1, proposedInput: 0, in: points), 11, "below range clamps to the floor")
        XCTAssertEqual(ImageAdjustments.ToneCurve.clampedInput(forPointAt: 1, proposedInput: 100, in: points), 12, "above range clamps to the ceiling")
    }

    func testClampedInput_invalidIndex_returnsProposedInputUnchanged() {
        let points = [ImageAdjustments.ToneCurvePoint(0, 0), ImageAdjustments.ToneCurvePoint(255, 255)]
        XCTAssertEqual(ImageAdjustments.ToneCurve.clampedInput(forPointAt: 5, proposedInput: 123, in: points), 123)
        XCTAssertEqual(ImageAdjustments.ToneCurve.clampedInput(forPointAt: -1, proposedInput: 456, in: points), 456)
    }

    // MARK: - ToneCurveSettings / LevelsSettings composition order

    func testToneCurveSettings_compositionOrder_isChannelLUTOfMasterLUT_notReversed() {
        // master: (0,0)-(255,200) linear scale-down. red: (0,50)-(255,255)
        // linear lift. Hand-derived: correct order (red(master(128))) is
        // red(100) = 130. The reversed order (master(red(128))) would
        // instead be master(153) = 120 — different, so this actually
        // distinguishes the two orderings rather than coincidentally
        // agreeing.
        var settings = ImageAdjustments.ToneCurveSettings.identity
        settings.master = ImageAdjustments.ToneCurve(points: [ImageAdjustments.ToneCurvePoint(0, 0), ImageAdjustments.ToneCurvePoint(255, 200)])
        settings.red = ImageAdjustments.ToneCurve(points: [ImageAdjustments.ToneCurvePoint(0, 50), ImageAdjustments.ToneCurvePoint(255, 255)])
        let transform = settings.makeTransform()

        let result = transform(128, 128, 128, 255)
        XCTAssertEqual(result.0, 130, "must equal red.lut()[master.lut()[128]]")
        XCTAssertNotEqual(result.0, 120, "must not equal the reversed-order master.lut()[red.lut()[128]]")
        XCTAssertEqual(result.3, 255, "alpha must pass through ToneCurveSettings.makeTransform() unchanged regardless of master/channel composition")

        // A second alpha value too, so this isn't merely pinning "255 in,
        // 255 out" as a coincidence of both being the input's own value.
        XCTAssertEqual(transform(128, 128, 128, 128).3, 128, "alpha must pass through unchanged for a non-255 value too")
    }

    func testLevelsSettings_compositionOrder_isChannelLUTOfMasterLUT_notReversed() {
        // Same hand-derived numbers as the ToneCurveSettings composition
        // test above, expressed via LevelsChannel's linear (gamma == 1) case
        // instead of a tone curve: master maps 0...255 -> 0...200, red maps
        // 0...255 -> 50...255.
        var settings = ImageAdjustments.LevelsSettings.identity
        settings.master = ImageAdjustments.LevelsChannel(inputBlack: 0, inputWhite: 255, gamma: 1, outputBlack: 0, outputWhite: 200)
        settings.red = ImageAdjustments.LevelsChannel(inputBlack: 0, inputWhite: 255, gamma: 1, outputBlack: 50, outputWhite: 255)
        let transform = settings.makeTransform()

        let result = transform(128, 128, 128, 255)
        XCTAssertEqual(result.0, 130, "must equal red.lut()[master.lut()[128]]")
        XCTAssertNotEqual(result.0, 120, "must not equal the reversed-order master.lut()[red.lut()[128]]")
        XCTAssertEqual(result.3, 255, "alpha must pass through LevelsSettings.makeTransform() unchanged regardless of master/channel composition")

        // A second alpha value too, so this isn't merely pinning "255 in,
        // 255 out" as a coincidence of both being the input's own value.
        XCTAssertEqual(transform(128, 128, 128, 128).3, 128, "alpha must pass through unchanged for a non-255 value too")
    }

    func testToneCurveSettings_greenBlueUntouched_whenOnlyRedAndMasterSet() {
        // Same settings as the composition-order test above: green/blue are
        // left at `.identity`, so their result must equal master.lut()[128]
        // == 100 exactly (the master curve alone), never the red-curve's
        // 130 — proving the red-only curve doesn't leak into the other
        // channels.
        var settings = ImageAdjustments.ToneCurveSettings.identity
        settings.master = ImageAdjustments.ToneCurve(points: [ImageAdjustments.ToneCurvePoint(0, 0), ImageAdjustments.ToneCurvePoint(255, 200)])
        settings.red = ImageAdjustments.ToneCurve(points: [ImageAdjustments.ToneCurvePoint(0, 50), ImageAdjustments.ToneCurvePoint(255, 255)])
        let transform = settings.makeTransform()

        let result = transform(128, 128, 128, 255)
        XCTAssertEqual(result.1, 100, "green: master-only result")
        XCTAssertEqual(result.2, 100, "blue: master-only result")
        XCTAssertNotEqual(result.1, result.0, "green must not pick up the red channel's curve")
    }

    // MARK: - LevelsChannel.lut()

    func testLevels_inputBlackLessThanWhite_normalLinearGammaNormalize() {
        // inputBlack 50, inputWhite 200, gamma 2: at v=125 the normalized
        // input lands exactly on 0.5 ((125-50)/150), so gammaCorrected =
        // sqrt(0.5) ≈ 0.70710678, output ≈ 180.31 -> rounds to 180.
        let channel = ImageAdjustments.LevelsChannel(inputBlack: 50, inputWhite: 200, gamma: 2, outputBlack: 0, outputWhite: 255)
        let table = channel.lut()
        XCTAssertEqual(table[50], 0, "exactly at inputBlack must map to outputBlack")
        XCTAssertEqual(table[200], 255, "exactly at inputWhite must map to outputWhite")
        XCTAssertEqual(table[125], 180, "gamma-curved midtone, hand-derived from sqrt(0.5)")
        XCTAssertEqual(table[0], 0, "below inputBlack clamps to outputBlack")
        XCTAssertEqual(table[255], 255, "above inputWhite clamps to outputWhite")
    }

    func testLevels_inputBlackGreaterThanWhite_reversedDrag_sameResultAsNormalOrder() {
        let normalOrder = ImageAdjustments.LevelsChannel(inputBlack: 50, inputWhite: 200, gamma: 2, outputBlack: 0, outputWhite: 255)
        let reversedOrder = ImageAdjustments.LevelsChannel(inputBlack: 200, inputWhite: 50, gamma: 2, outputBlack: 0, outputWhite: 255)

        XCTAssertEqual(normalOrder.lut(), reversedOrder.lut(), "inputBlack/inputWhite given in either order must produce byte-identical LUTs")
    }

    func testLevels_inputBlackEqualsWhite_stepFunctionAtBoundary() {
        // inputBlack == inputWhite == 100 degenerates `range` to 0, which the
        // code special-cases as a hard step: below 100 -> 0, at-or-above
        // 100 -> 1 (then remapped to output range).
        let channel = ImageAdjustments.LevelsChannel(inputBlack: 100, inputWhite: 100, gamma: 1, outputBlack: 0, outputWhite: 255)
        let table = channel.lut()
        XCTAssertEqual(table[99], 0, "just below the degenerate boundary must read as fully black")
        XCTAssertEqual(table[100], 255, "exactly at (and above) the degenerate boundary must read as fully white")
    }

    func testLevels_gammaZeroOrNegative_clampedToFloor001_noDivideByZeroOrNaN() {
        let atFloor = ImageAdjustments.LevelsChannel(gamma: 0.01)
        let zero = ImageAdjustments.LevelsChannel(gamma: 0)
        let negative = ImageAdjustments.LevelsChannel(gamma: -5)

        XCTAssertEqual(atFloor.lut(), zero.lut(), "gamma == 0 must clamp to the same result as the 0.01 floor")
        XCTAssertEqual(atFloor.lut(), negative.lut(), "negative gamma must clamp to the same result as the 0.01 floor")
    }

    func testLevels_gammaLessThanOne_darkensMidtones_gammaGreaterThanOne_brightens() {
        // Full 0...255 input/output range isolates gamma's own effect. At
        // v=128 (normalized ≈ 0.501961): gamma 0.5 squares it (≈0.25196,
        // rounds to 64 — darker than 128); gamma 2 square-roots it
        // (≈0.708492, rounds to 181 — brighter than 128). Both hand-derived.
        let darkens = ImageAdjustments.LevelsChannel(gamma: 0.5)
        let brightens = ImageAdjustments.LevelsChannel(gamma: 2)

        XCTAssertEqual(darkens.lut()[128], 64, "gamma < 1 must darken the midtone below the identity value of 128")
        XCTAssertEqual(brightens.lut()[128], 181, "gamma > 1 must brighten the midtone above the identity value of 128")
    }

    func testLevels_inputOutOfRange_negativeOrAbove255_clampedTo0to255() {
        let outOfRange = ImageAdjustments.LevelsChannel(inputBlack: -50, inputWhite: 300, gamma: 1, outputBlack: 0, outputWhite: 255)
        let fullRange = ImageAdjustments.LevelsChannel(inputBlack: 0, inputWhite: 255, gamma: 1, outputBlack: 0, outputWhite: 255)

        XCTAssertEqual(outOfRange.lut(), fullRange.lut(), "out-of-0...255 input bounds must clamp to the same result as the already-full 0...255 range")
    }

    func testLevels_identity_isExactNoOp() {
        let table = ImageAdjustments.LevelsChannel.identity.lut()
        for v in 0...255 {
            XCTAssertEqual(table[v], UInt8(v), "identity levels must be a byte-exact no-op at \(v)")
        }
    }

    func testLevelsChannel_alphaUnchanged() {
        let channel = ImageAdjustments.LevelsChannel(inputBlack: 30, inputWhite: 200, gamma: 1, outputBlack: 0, outputWhite: 255)
        let transform = channel.makeTransform()

        let result = transform(50, 60, 70, 99)
        XCTAssertEqual(result.3, 99, "alpha must pass through makeTransform() unchanged regardless of the levels curve")
    }
}
