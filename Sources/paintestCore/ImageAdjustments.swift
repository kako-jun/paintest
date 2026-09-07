import AppKit

/// Photoshop-equivalent per-pixel color adjustments (issue #12): tone curve,
/// brightness/contrast, hue/saturation, and levels. Every adjustment below is
/// modeled as a small, independently-testable value type exposing
/// `makeTransform()` — a pure `(r, g, b, a) -> (r, g, b, a)` RGB(A) closure,
/// alpha always passed through unchanged (none of Photoshop's four dialogs
/// touch transparency) — so `AdjustmentDialog` only ever has to turn live UI
/// state into one of these value types and hand its `makeTransform()` output
/// to `apply(transform:from:into:mask:)` below.
enum ImageAdjustments {
    // MARK: - Applying an adjustment to a canvas

    /// Rewrites every pixel of `destination` as `transform(sourcePixel)`,
    /// reading from `source` — a *separate* snapshot canvas, never
    /// `destination` itself — the same "snapshot on begin, re-derive on every
    /// change" shape `CanvasView.transformOriginalCanvas` already uses for
    /// its own live preview (see that property's doc comment). Reading from
    /// `destination` in place would double-apply the adjustment to pixels
    /// this same pass already overwrote earlier in the loop, and would make
    /// re-running `apply` with a changed setting (every live-preview tick)
    /// compound onto the *previous* tick's result instead of recomputing
    /// fresh from the pre-dialog pixels.
    ///
    /// `mask`, when non-nil, restricts the adjustment to selected pixels only
    /// (issue #12 depends on issue #11's `SelectionMask`): an unselected
    /// pixel of `destination` is written back with `source`'s own unchanged
    /// value rather than merely left alone, so repeated calls (one per live
    /// preview tick) always converge on the exact same result regardless of
    /// what `destination` happened to hold from a previous tick.
    ///
    /// Deliberately does *not* forward `mask` to `PixelCanvas.setPixel`'s own
    /// `mask:` parameter (considered, and passed on, in PR #35 self-review
    /// nit-1): that parameter *skips* the write for an unselected pixel
    /// instead of writing `source`'s value back — which happens to produce
    /// an identical result for every call site today (each one always
    /// re-applies from the same fixed `source`/`mask` pair onto a
    /// `destination` that only this function ever writes), but would make
    /// that convergence depend on the caller's usage pattern holding rather
    /// than being guaranteed by this function on its own, as documented
    /// above.
    static func apply(
        transform: (UInt8, UInt8, UInt8, UInt8) -> (UInt8, UInt8, UInt8, UInt8),
        from source: PixelCanvas,
        into destination: PixelCanvas,
        mask: SelectionMask?
    ) {
        for y in 0..<source.height {
            for x in 0..<source.width {
                guard let pixel = source.rawPixel(x: x, y: y) else { continue }
                let isSelected = mask == nil || mask!.contains(x: x, y: y)
                let (r0, g0, b0, a0) = pixel
                let (r, g, b, a) = isSelected ? transform(r0, g0, b0, a0) : (r0, g0, b0, a0)
                destination.setPixel(
                    x: x, y: y,
                    color: NSColor(
                        deviceRed: CGFloat(r) / 255,
                        green: CGFloat(g) / 255,
                        blue: CGFloat(b) / 255,
                        alpha: CGFloat(a) / 255
                    )
                )
            }
        }
    }

    // MARK: - RGB <-> HSB (shared by HueSaturationSettings only)

    /// Converts 0...255 RGB to hue (`0..<360` degrees), saturation (`0...1`)
    /// and brightness/value (`0...1`) — the HSV/HSB model Photoshop's own
    /// Hue/Saturation dialog is built on (not HSL).
    static func rgbToHSB(r: UInt8, g: UInt8, b: UInt8) -> (h: Double, s: Double, v: Double) {
        let rd = Double(r) / 255, gd = Double(g) / 255, bd = Double(b) / 255
        let maxV = max(rd, gd, bd)
        let minV = min(rd, gd, bd)
        let delta = maxV - minV

        var h: Double = 0
        if delta > 0 {
            if maxV == rd {
                h = 60 * (((gd - bd) / delta).truncatingRemainder(dividingBy: 6))
            } else if maxV == gd {
                h = 60 * (((bd - rd) / delta) + 2)
            } else {
                h = 60 * (((rd - gd) / delta) + 4)
            }
        }
        if h < 0 { h += 360 }

        let s = maxV == 0 ? 0 : delta / maxV
        return (h, s, maxV)
    }

    /// The inverse of `rgbToHSB` — `h` is normalized modulo 360 first (via
    /// `normalizedHue`) so a hue that drifted outside `0..<360` (e.g. after
    /// adding a `-180...180` hue-shift slider value) still maps back
    /// correctly instead of picking the wrong 60°-wide color sector.
    static func hsbToRGB(h: Double, s: Double, v: Double) -> (r: UInt8, g: UInt8, b: UInt8) {
        let hue = normalizedHue(h)
        let c = v * s
        let hPrime = hue / 60
        let x = c * (1 - abs(hPrime.truncatingRemainder(dividingBy: 2) - 1))

        let (r1, g1, b1): (Double, Double, Double)
        switch hPrime {
        case 0..<1: (r1, g1, b1) = (c, x, 0)
        case 1..<2: (r1, g1, b1) = (x, c, 0)
        case 2..<3: (r1, g1, b1) = (0, c, x)
        case 3..<4: (r1, g1, b1) = (0, x, c)
        case 4..<5: (r1, g1, b1) = (x, 0, c)
        default: (r1, g1, b1) = (c, 0, x)
        }

        let m = v - c
        let r = UInt8(max(0, min(255, ((r1 + m) * 255).rounded())))
        let g = UInt8(max(0, min(255, ((g1 + m) * 255).rounded())))
        let b = UInt8(max(0, min(255, ((b1 + m) * 255).rounded())))
        return (r, g, b)
    }

    /// Wraps an arbitrary hue value (degrees) into `0..<360` — `Double`'s own
    /// `truncatingRemainder` follows the sign of its dividend, so a negative
    /// `h` (e.g. `10 - 180 = -170`) needs the extra `+ 360, remainder again`
    /// step below rather than a single `truncatingRemainder` call.
    static func normalizedHue(_ h: Double) -> Double {
        let wrapped = h.truncatingRemainder(dividingBy: 360)
        return wrapped < 0 ? wrapped + 360 : wrapped
    }

    // MARK: - Brightness / Contrast

    /// Photoshop's "legacy" brightness/contrast model: a flat additive
    /// `brightness` offset plus a `contrast` factor that scales every
    /// channel's distance from the 128 midpoint, applied identically to R,
    /// G, and B (unlike tone curve/levels, brightness/contrast has no
    /// per-channel mode in Photoshop).
    struct BrightnessContrastSettings {
        /// `-150...150`, Photoshop's own slider range.
        var brightness: Int = 0
        /// `-100...100`, Photoshop's own slider range.
        var contrast: Int = 0

        static let identity = BrightnessContrastSettings()

        /// The 256-entry lookup table applied to every channel. Uses the
        /// widely-cited "contrast factor" formula
        /// (`factor = 259*(c+255) / (255*(259-c))`, `c` in `-255...255`) —
        /// `contrast` here is first rescaled from this type's `-100...100`
        /// slider range up to that formula's `-255...255` input range. The
        /// formula's denominator `259 - c` only reaches its smallest
        /// (`259 - 255 = 4`) at `contrast == 100`, never zero, so this never
        /// divides by zero.
        func lut() -> [UInt8] {
            let clampedBrightness = Double(max(-150, min(150, brightness)))
            let clampedContrast = Double(max(-100, min(100, contrast)))
            let contrastScaled = clampedContrast * 255 / 100
            let factor = (259 * (contrastScaled + 255)) / (255 * (259 - contrastScaled))

            var table = [UInt8](repeating: 0, count: 256)
            for v in 0...255 {
                let adjusted = factor * (Double(v) - 128) + 128 + clampedBrightness
                table[v] = UInt8(max(0, min(255, adjusted.rounded())))
            }
            return table
        }

        func makeTransform() -> (UInt8, UInt8, UInt8, UInt8) -> (UInt8, UInt8, UInt8, UInt8) {
            let table = lut()
            return { r, g, b, a in (table[Int(r)], table[Int(g)], table[Int(b)], a) }
        }
    }

    // MARK: - Hue / Saturation

    /// Photoshop's Hue/Saturation dialog: a hue rotation (degrees) plus
    /// saturation/lightness scaling, all computed in HSB space per pixel.
    struct HueSaturationSettings {
        /// Degrees, `-180...180`.
        var hue: Int = 0
        /// Percent, `-100...100`. Positive values move saturation toward
        /// fully saturated (`1.0`); negative values scale it toward `0`
        /// (fully desaturated at `-100`).
        var saturation: Int = 0
        /// Percent, `-100...100`. Same "move toward the ceiling / scale
        /// toward the floor" shape as `saturation`, applied to brightness
        /// (value) instead.
        var lightness: Int = 0

        static let identity = HueSaturationSettings()

        func apply(r: UInt8, g: UInt8, b: UInt8) -> (r: UInt8, g: UInt8, b: UInt8) {
            guard hue != 0 || saturation != 0 || lightness != 0 else { return (r, g, b) }

            let (h, s, v) = ImageAdjustments.rgbToHSB(r: r, g: g, b: b)
            let newHue = ImageAdjustments.normalizedHue(h + Double(hue))

            let clampedSaturation = Double(max(-100, min(100, saturation))) / 100
            let newSaturation: Double = clampedSaturation >= 0
                ? s + (1 - s) * clampedSaturation
                : s * (1 + clampedSaturation)

            let clampedLightness = Double(max(-100, min(100, lightness))) / 100
            let newValue: Double = clampedLightness >= 0
                ? v + (1 - v) * clampedLightness
                : v * (1 + clampedLightness)

            let result = ImageAdjustments.hsbToRGB(
                h: newHue,
                s: max(0, min(1, newSaturation)),
                v: max(0, min(1, newValue))
            )
            return result
        }

        func makeTransform() -> (UInt8, UInt8, UInt8, UInt8) -> (UInt8, UInt8, UInt8, UInt8) {
            return { r, g, b, a in
                let result = apply(r: r, g: g, b: b)
                return (result.r, result.g, result.b, a)
            }
        }
    }

    // MARK: - Tone curve

    /// One draggable control point on a tone curve, in `0...255` input/output
    /// space (a pixel's byte value on each axis).
    struct ToneCurvePoint {
        var input: Int
        var output: Int

        init(_ input: Int, _ output: Int) {
            self.input = input
            self.output = output
        }
    }

    /// A single channel's tone curve: an ordered list of control points,
    /// smoothly interpolated (issue #12: "グラフUIでの入出力レベル調整").
    struct ToneCurve {
        /// Must contain at least 2 points. Not required to already be sorted
        /// by `input` — `lut()`/`clampedInput` both sort/consult neighbors
        /// defensively — but a caller that lets two points share the same
        /// `input` will get whichever one `lut()`'s stable sort happens to
        /// place first for that column; `ToneCurveGraphView`'s own drag
        /// clamping (see `clampedInput`) and new-point clamping (see
        /// `clampedInputForNewPoint`) are what actually prevent that from
        /// happening during normal editing.
        var points: [ToneCurvePoint]

        /// A straight diagonal line, output == input — Photoshop's own
        /// starting curve for a channel nobody has touched yet.
        static let identity = ToneCurve(points: [ToneCurvePoint(0, 0), ToneCurvePoint(255, 255)])

        /// Builds a 256-entry output lookup table, one entry per possible
        /// input byte value.
        ///
        /// Exactly 2 points is special-cased to plain linear interpolation
        /// rather than routed through the general Catmull-Rom spline below:
        /// Catmull-Rom's usual "duplicate the endpoint" trick for missing
        /// neighbor tangents does **not** reduce to a straight line for just
        /// two points (verified by hand — e.g. the default identity curve's
        /// `(0,0)`→`(255,255)` would otherwise bow away from `y = x`), and a
        /// bowed "identity" curve the first time this dialog opens (before
        /// the user has dragged anything) would be an obviously-wrong
        /// starting point. 3+ points use the spline for the smooth,
        /// Photoshop-like curve shape a real tone-curve editor is expected to
        /// have.
        func lut() -> [UInt8] {
            guard points.count >= 2 else { return (0...255).map { UInt8($0) } }
            let sorted = points
                .map { ToneCurvePoint(max(0, min(255, $0.input)), max(0, min(255, $0.output))) }
                .sorted { $0.input < $1.input }

            var table = [UInt8](repeating: 0, count: 256)
            if sorted.count == 2 {
                let x1 = Double(sorted[0].input), y1 = Double(sorted[0].output)
                let x2 = Double(sorted[1].input), y2 = Double(sorted[1].output)
                for x in 0...255 {
                    let value: Double
                    if x2 > x1 {
                        let t = (Double(x) - x1) / (x2 - x1)
                        value = y1 + t * (y2 - y1)
                    } else {
                        value = y1
                    }
                    table[x] = UInt8(max(0, min(255, value.rounded())))
                }
                return table
            }

            for x in 0...255 {
                let value = ToneCurve.catmullRomInterpolate(Double(x), sorted)
                table[x] = UInt8(max(0, min(255, value.rounded())))
            }
            return table
        }

        /// Catmull-Rom spline through 3+ sorted control points. Values
        /// outside the first/last point's `input` hold flat at that
        /// endpoint's `output` (matching Photoshop, which doesn't
        /// extrapolate past the curve's own ends).
        private static func catmullRomInterpolate(_ x: Double, _ sorted: [ToneCurvePoint]) -> Double {
            let first = sorted[0]
            let last = sorted[sorted.count - 1]
            if x <= Double(first.input) { return Double(first.output) }
            if x >= Double(last.input) { return Double(last.output) }

            var segmentIndex = 0
            for i in 0..<(sorted.count - 1) {
                if x >= Double(sorted[i].input) && x <= Double(sorted[i + 1].input) {
                    segmentIndex = i
                    break
                }
            }
            let p1 = sorted[segmentIndex]
            let p2 = sorted[segmentIndex + 1]
            let p0 = segmentIndex > 0 ? sorted[segmentIndex - 1] : p1
            let p3 = segmentIndex + 2 < sorted.count ? sorted[segmentIndex + 2] : p2

            let x1 = Double(p1.input), x2 = Double(p2.input)
            guard x2 > x1 else { return Double(p1.output) }
            let t = (x - x1) / (x2 - x1)
            let t2 = t * t
            let t3 = t2 * t

            let y0 = Double(p0.output), y1 = Double(p1.output), y2 = Double(p2.output), y3 = Double(p3.output)
            return 0.5 * (
                (2 * y1)
                    + (-y0 + y2) * t
                    + (2 * y0 - 5 * y1 + 4 * y2 - y3) * t2
                    + (-y0 + 3 * y1 - 3 * y2 + y3) * t3
            )
        }

        /// Clamps a dragged control point's proposed `input` so it can never
        /// cross past its immediate neighbor on either side (issue #12) —
        /// `lut()`'s spline walk assumes `points` stays strictly increasing
        /// by `input`; letting a drag push one point's `input` past a
        /// neighbor's would let two points tie or invert their order, which
        /// `lut()` doesn't handle predictably. Only `input` is clamped;
        /// `output` is always accepted as proposed (Photoshop lets a point's
        /// output swing anywhere in `0...255` regardless of its neighbors).
        ///
        /// Falls back to the point's own current `input` (no-op) in the
        /// degenerate case where its neighbors already leave no room to move
        /// (`minInput > maxInput` — only possible if two neighbors are
        /// already adjacent bytes apart).
        static func clampedInput(forPointAt index: Int, proposedInput: Int, in points: [ToneCurvePoint]) -> Int {
            guard points.indices.contains(index) else { return proposedInput }
            let bounds = neighborBounds(
                left: index > 0 ? points[index - 1] : nil,
                right: index < points.count - 1 ? points[index + 1] : nil
            )
            guard bounds.min <= bounds.max else { return points[index].input }
            return max(bounds.min, min(bounds.max, proposedInput))
        }

        /// The `input` range a point may occupy given its immediate left/right
        /// neighbors (each pushed at least 1 byte away) — the one piece of
        /// arithmetic `clampedInput` (an existing point being dragged) and
        /// `clampedInputForNewPoint` (a not-yet-inserted point) both need, so
        /// a future change to the "neighbor ± 1" rule only has to happen once.
        private static func neighborBounds(left: ToneCurvePoint?, right: ToneCurvePoint?) -> (min: Int, max: Int) {
            (left.map { $0.input + 1 } ?? 0, right.map { $0.input - 1 } ?? 255)
        }

        /// Clamps the `input` a brand-new control point would need in order
        /// to be added to `points` without landing on the same `input` as an
        /// existing point (issue #12, PR #35 self-review should-1).
        ///
        /// `ToneCurveGraphView.mouseDown` used to append a click's raw
        /// `input` straight into `points` with no clamping at all. Two points
        /// sharing an `input` breaks `lut()`'s "strictly increasing by
        /// input" assumption (see `points`'s own doc comment) — and did so
        /// asymmetrically: clicking exactly at `input == 0` was harmless
        /// (the *original* `(0, 0)` survived as `sorted.first` purely because
        /// `Array.sort` is stable and the new point was appended, hence
        /// sorted, after it), while clicking at `input == 255` silently
        /// replaced the intended white point — `sorted.last` became the new,
        /// wrong point instead — because the exact same stable-sort tie
        /// resolution put the new point *after* the existing `(255, 255)`
        /// too, but "after" is now the very end of the array, not a safely
        /// interior position.
        ///
        /// This tries inserting the new point right after the correct sorted
        /// position first (mirroring `clampedInput`'s own neighbor-based
        /// math, just against a gap rather than an existing slot), then right
        /// before it if "after" left no room — trying both directions is what
        /// makes a collision at the curve's low end and one at its high end
        /// resolve by the exact same rule instead of one of them surviving
        /// only by accident of array position. Returns `nil` only when
        /// neither direction has room at all (e.g. every neighboring byte is
        /// already occupied by another point) — the caller is expected to
        /// simply not add a point rather than force one onto an existing
        /// `input`.
        static func clampedInputForNewPoint(proposedInput: Int, in points: [ToneCurvePoint]) -> Int? {
            let sorted = points.sorted { $0.input < $1.input }

            func attempt(insertingAfterCount count: Int) -> Int? {
                let bounds = neighborBounds(
                    left: count > 0 ? sorted[count - 1] : nil,
                    right: count < sorted.count ? sorted[count] : nil
                )
                guard bounds.min <= bounds.max else { return nil }
                return max(bounds.min, min(bounds.max, proposedInput))
            }

            let afterCount = sorted.filter { $0.input <= proposedInput }.count
            if let clamped = attempt(insertingAfterCount: afterCount) {
                return clamped
            }
            let beforeCount = sorted.filter { $0.input < proposedInput }.count
            return attempt(insertingAfterCount: beforeCount)
        }
    }

    /// A tone curve for every RGB channel plus one "master" curve applied to
    /// all three first (issue #12: matches Photoshop's own RGB / Red / Green
    /// / Blue channel picker) — output = channelCurve(masterCurve(input)),
    /// same composition order Photoshop's own combined curve uses.
    struct ToneCurveSettings {
        var master: ToneCurve = .identity
        var red: ToneCurve = .identity
        var green: ToneCurve = .identity
        var blue: ToneCurve = .identity

        static let identity = ToneCurveSettings()

        func makeTransform() -> (UInt8, UInt8, UInt8, UInt8) -> (UInt8, UInt8, UInt8, UInt8) {
            let masterLUT = master.lut()
            let redLUT = red.lut()
            let greenLUT = green.lut()
            let blueLUT = blue.lut()
            return { r, g, b, a in
                let r2 = redLUT[Int(masterLUT[Int(r)])]
                let g2 = greenLUT[Int(masterLUT[Int(g)])]
                let b2 = blueLUT[Int(masterLUT[Int(b)])]
                return (r2, g2, b2, a)
            }
        }
    }

    // MARK: - Levels

    /// One channel's levels adjustment: an input range (`inputBlack` maps to
    /// `outputBlack`, `inputWhite` maps to `outputWhite`) with a `gamma`
    /// midtone curve in between — Photoshop's own Levels dialog model.
    struct LevelsChannel {
        /// `0...255`.
        var inputBlack: Int = 0
        /// `0...255`.
        var inputWhite: Int = 255
        /// `0.01...9.99` (Photoshop's own gamma slider range, `0.1...9.99`,
        /// widened slightly at the floor purely so `lut()`'s `1/gamma`
        /// division never sees exactly `0`).
        var gamma: Double = 1.0
        /// `0...255`.
        var outputBlack: Int = 0
        /// `0...255`.
        var outputWhite: Int = 255

        static let identity = LevelsChannel()

        /// The 256-entry lookup table: normalize `v` into `inputBlack...
        /// inputWhite` (clamped to `0...1`), apply the gamma curve, then
        /// remap into `outputBlack...outputWhite`.
        func lut() -> [UInt8] {
            let inBlack = Double(max(0, min(255, min(inputBlack, inputWhite))))
            let inWhite = Double(max(0, min(255, max(inputBlack, inputWhite))))
            let outBlack = Double(max(0, min(255, outputBlack)))
            let outWhite = Double(max(0, min(255, outputWhite)))
            let range = inWhite - inBlack
            let safeGamma = max(0.01, gamma)

            var table = [UInt8](repeating: 0, count: 256)
            for v in 0...255 {
                let normalized: Double
                if range <= 0 {
                    normalized = Double(v) < inBlack ? 0 : 1
                } else {
                    normalized = max(0, min(1, (Double(v) - inBlack) / range))
                }
                let gammaCorrected = pow(normalized, 1.0 / safeGamma)
                let output = outBlack + gammaCorrected * (outWhite - outBlack)
                table[v] = UInt8(max(0, min(255, output.rounded())))
            }
            return table
        }

        func makeTransform() -> (UInt8, UInt8, UInt8, UInt8) -> (UInt8, UInt8, UInt8, UInt8) {
            let table = lut()
            return { r, g, b, a in (table[Int(r)], table[Int(g)], table[Int(b)], a) }
        }
    }

    /// A `LevelsChannel` for every RGB channel plus one "master" channel
    /// applied first (issue #12: same RGB/Red/Green/Blue channel picker and
    /// composition order as `ToneCurveSettings`).
    struct LevelsSettings {
        var master: LevelsChannel = .identity
        var red: LevelsChannel = .identity
        var green: LevelsChannel = .identity
        var blue: LevelsChannel = .identity

        static let identity = LevelsSettings()

        func makeTransform() -> (UInt8, UInt8, UInt8, UInt8) -> (UInt8, UInt8, UInt8, UInt8) {
            let masterLUT = master.lut()
            let redLUT = red.lut()
            let greenLUT = green.lut()
            let blueLUT = blue.lut()
            return { r, g, b, a in
                let r2 = redLUT[Int(masterLUT[Int(r)])]
                let g2 = greenLUT[Int(masterLUT[Int(g)])]
                let b2 = blueLUT[Int(masterLUT[Int(b)])]
                return (r2, g2, b2, a)
            }
        }
    }
}
