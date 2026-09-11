import AppKit

/// A raw pixel grid backed directly by an `NSBitmapImageRep`'s byte buffer.
///
/// All mutation happens through direct byte writes (no `CGContext` fill/stroke
/// paths), which guarantees dot-exact edits with zero anti-aliasing regardless
/// of how the pixel coordinates were derived.
final class PixelCanvas {
    private(set) var bitmap: NSBitmapImageRep
    let width: Int
    let height: Int

    init(width: Int, height: Int, background: NSColor = .white) {
        self.width = max(1, width)
        self.height = max(1, height)
        self.bitmap = PixelCanvas.makeBitmap(width: self.width, height: self.height)
        fill(with: background)
    }

    private init(bitmap: NSBitmapImageRep, width: Int, height: Int) {
        self.bitmap = bitmap
        self.width = width
        self.height = height
    }

    private static func makeBitmap(width: Int, height: Int) -> NSBitmapImageRep {
        // `.alphaNonpremultiplied` must be declared explicitly: without it,
        // AppKit's PNG encoder assumes the raw bytes we write are
        // premultiplied alpha and un-premultiplies them (dividing each
        // channel by alpha/255) while writing straight-alpha PNG data. That
        // silently drifts every non-opaque, non-black/white color and
        // zeroes RGB entirely when alpha is 0.
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [.alphaNonpremultiplied],
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            fatalError("Failed to allocate pixel bitmap \(width)x\(height)")
        }
        return rep
    }

    // MARK: - Pixel access

    private func components(of color: NSColor) -> (UInt8, UInt8, UInt8, UInt8) {
        // Falling back to `color` itself when the `.deviceRGB` conversion
        // fails only works because every caller today passes a color we
        // built ourselves (already RGB-based). A color from a non-RGB space
        // (e.g. a pattern color from a color picker) would have no
        // `redComponent`/`greenComponent`/etc. and this fallback would be
        // wrong; revisit if `NSColor` values start flowing in from UI.
        let rgba = color.usingColorSpace(.deviceRGB) ?? color
        let r = UInt8(max(0, min(255, (rgba.redComponent * 255).rounded())))
        let g = UInt8(max(0, min(255, (rgba.greenComponent * 255).rounded())))
        let b = UInt8(max(0, min(255, (rgba.blueComponent * 255).rounded())))
        let a = UInt8(max(0, min(255, (rgba.alphaComponent * 255).rounded())))
        return (r, g, b, a)
    }

    func fill(with color: NSColor) {
        guard let data = bitmap.bitmapData else { return }
        let (r, g, b, a) = components(of: color)
        let bytesPerRow = bitmap.bytesPerRow
        let bpp = bitmap.bitsPerPixel / 8
        for y in 0..<height {
            let rowStart = y * bytesPerRow
            for x in 0..<width {
                let offset = rowStart + x * bpp
                data[offset] = r
                data[offset + 1] = g
                data[offset + 2] = b
                data[offset + 3] = a
            }
        }
    }

    /// Sets a single pixel. Coordinates are in bitmap space: (0,0) is top-left.
    ///
    /// `mask` restricts the write to a selection (issue #11): when non-nil
    /// and the pixel falls outside it, the call is a no-op. Defaults to
    /// `nil` (no restriction) so every pre-existing call site — and every
    /// pre-existing test — keeps working unmodified.
    func setPixel(x: Int, y: Int, color: NSColor, mask: SelectionMask? = nil) {
        guard x >= 0, x < width, y >= 0, y < height else { return }
        guard mask == nil || mask!.contains(x: x, y: y) else { return }
        guard let data = bitmap.bitmapData else { return }
        let (r, g, b, a) = components(of: color)
        let bytesPerRow = bitmap.bytesPerRow
        let bpp = bitmap.bitsPerPixel / 8
        let offset = y * bytesPerRow + x * bpp
        data[offset] = r
        data[offset + 1] = g
        data[offset + 2] = b
        data[offset + 3] = a
    }

    /// Draws a 1px line between two pixel coordinates using Bresenham's
    /// algorithm, writing every intermediate pixel directly (no interpolation).
    ///
    /// `mask` is forwarded straight to each visited pixel's `setPixel` call
    /// (issue #11), so a pixel the line passes through is simply skipped
    /// when it falls outside the selection — the line's shape (which
    /// pixels it visits) is unaffected, only which of those get written.
    func drawLine(from p0: (x: Int, y: Int), to p1: (x: Int, y: Int), color: NSColor, mask: SelectionMask? = nil) {
        var x0 = p0.x
        var y0 = p0.y
        let x1 = p1.x
        let y1 = p1.y

        let dx = abs(x1 - x0)
        let sx = x0 < x1 ? 1 : -1
        let dy = -abs(y1 - y0)
        let sy = y0 < y1 ? 1 : -1
        var err = dx + dy

        while true {
            setPixel(x: x0, y: y0, color: color, mask: mask)
            if x0 == x1 && y0 == y1 { break }
            let e2 = 2 * err
            if e2 >= dy {
                err += dy
                x0 += sx
            }
            if e2 <= dx {
                err += dx
                y0 += sy
            }
        }
    }

    // MARK: - Antialiased drawing (pen tool, issue #10)
    //
    // Unlike `setPixel`/`drawLine` above (nearest-neighbor, dot-exact, no
    // anti-aliasing — kept untouched for the pencil/eraser), these two
    // methods go through a real `CGContext` fill/stroke path so the pen
    // tool can produce smooth, anti-aliased strokes. This intentionally
    // does NOT touch `setPixel`/`drawLine`: the pencil/eraser's byte-exact
    // guarantee must not regress.
    //
    // `NSGraphicsContext(bitmapImageRep: bitmap)?.cgContext` — drawing
    // straight onto `self.bitmap`'s own context — turned out NOT to work:
    // it returns `nil` for `bitmap`, because `bitmap` is deliberately
    // `.alphaNonpremultiplied` (see `makeBitmap`'s doc comment, needed for
    // correct straight-alpha PNG round-tripping) and Core Graphics bitmap
    // contexts only support premultiplied alpha for drawing. Confirmed by
    // hand: `NSGraphicsContext(bitmapImageRep:)` returns a real context for
    // an equivalent bitmap with the default (premultiplied) format, and
    // `nil` once `.alphaNonpremultiplied` is set — so instead, the shape is
    // drawn into a scratch premultiplied overlay bitmap of the same size,
    // then manually alpha-composited ("over") onto `bitmap`'s own
    // straight-alpha buffer.

    /// Same pixel layout as `makeBitmap`, minus `.alphaNonpremultiplied`,
    /// so `NSGraphicsContext(bitmapImageRep:)` can actually vend a
    /// `CGContext` for it.
    private func makePremultipliedOverlay() -> NSBitmapImageRep? {
        NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
    }

    /// Draws into a transparent, premultiplied scratch overlay the size of
    /// this canvas via `draw`, then alpha-composites ("source over") the
    /// result onto `bitmap`'s own straight-alpha buffer.
    ///
    /// The overlay's `CGContext` is oriented so CG's (0, 0) matches
    /// `setPixel`'s top-left-origin pixel-space convention: Core Graphics'
    /// native origin is bottom-left with y increasing upward, while
    /// `setPixel`/`rawPixel` treat row 0 of the buffer as the top row.
    /// Without the translate+flip below, a dot drawn "at (0, 0)" would land
    /// in the bottom-left corner instead of the top-left — verified
    /// empirically (not assumed) by
    /// `PixelCanvasTests.testDrawAntialiasedDot_atOrigin_paintsTopLeftCorner_notBottomLeft`,
    /// which fails without this flip and passes with it.
    private func drawAntialiased(mask: SelectionMask?, _ draw: (CGContext) -> Void) {
        guard let overlay = makePremultipliedOverlay(),
              let overlayData = overlay.bitmapData,
              let context = NSGraphicsContext(bitmapImageRep: overlay)?.cgContext,
              let destData = bitmap.bitmapData else { return }

        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.setShouldAntialias(true)
        draw(context)

        let overlayBytesPerRow = overlay.bytesPerRow
        let overlayBpp = overlay.bitsPerPixel / 8
        let destBytesPerRow = bitmap.bytesPerRow
        let destBpp = bitmap.bitsPerPixel / 8

        for y in 0..<height {
            let overlayRowStart = y * overlayBytesPerRow
            let destRowStart = y * destBytesPerRow
            for x in 0..<width {
                let srcOffset = overlayRowStart + x * overlayBpp
                let srcAlphaByte = overlayData[srcOffset + 3]
                guard srcAlphaByte > 0 else { continue }
                // issue #11: skip pixels outside the selection, same as
                // `setPixel`'s guard — this is the final write-back point
                // for the alpha-composited result, so the mask check has to
                // live here rather than in `drawFillEllipse`/`strokePath`
                // above (those draw into the scratch overlay, not `bitmap`
                // itself).
                guard mask == nil || mask!.contains(x: x, y: y) else { continue }

                let srcAlpha = Double(srcAlphaByte) / 255.0
                // Un-premultiply: the overlay stores each channel as
                // component * alpha, so dividing by alpha recovers the
                // straight (0-255) component.
                let srcR = Double(overlayData[srcOffset]) / srcAlpha
                let srcG = Double(overlayData[srcOffset + 1]) / srcAlpha
                let srcB = Double(overlayData[srcOffset + 2]) / srcAlpha

                let destOffset = destRowStart + x * destBpp
                let destAlpha = Double(destData[destOffset + 3]) / 255.0
                let destR = Double(destData[destOffset])
                let destG = Double(destData[destOffset + 1])
                let destB = Double(destData[destOffset + 2])

                // Standard "source over destination" compositing on
                // straight-alpha buffers.
                let outAlpha = srcAlpha + destAlpha * (1 - srcAlpha)
                let blend: (Double, Double) -> Double = { src, dst in
                    guard outAlpha > 0 else { return 0 }
                    return (src * srcAlpha + dst * destAlpha * (1 - srcAlpha)) / outAlpha
                }

                destData[destOffset] = UInt8(max(0, min(255, blend(srcR, destR).rounded())))
                destData[destOffset + 1] = UInt8(max(0, min(255, blend(srcG, destG).rounded())))
                destData[destOffset + 2] = UInt8(max(0, min(255, blend(srcB, destB).rounded())))
                destData[destOffset + 3] = UInt8(max(0, min(255, (outAlpha * 255).rounded())))
            }
        }
    }

    /// Paints a filled, anti-aliased circle centered on `point`, in
    /// `setPixel`'s top-left-origin pixel-space coordinates.
    ///
    /// Superseded as the pen tool's own paint path by `drawPenDab` (issue
    /// #20's dab-stamping model, with hardness/flow); `CanvasView` no longer
    /// calls this. Kept rather than deleted — nothing else in the app used
    /// this single-shot "one anti-aliased circle, no hardness falloff"
    /// primitive, but it stays well covered by `PixelCanvasTests` in its own
    /// right (alpha compositing, masking, coordinate flipping) and remains
    /// available if a future tool wants a plain anti-aliased stamp again.
    func drawAntialiasedDot(at point: (x: Int, y: Int), color: NSColor, diameter: CGFloat, mask: SelectionMask? = nil) {
        drawAntialiased(mask: mask) { context in
            context.setFillColor(color.cgColor)
            let radius = diameter / 2
            let rect = CGRect(
                x: CGFloat(point.x) + 0.5 - radius,
                y: CGFloat(point.y) + 0.5 - radius,
                width: diameter,
                height: diameter
            )
            context.fillEllipse(in: rect)
        }
    }

    /// Strokes an anti-aliased, round-capped/joined line between two points,
    /// in `setPixel`'s top-left-origin pixel-space coordinates.
    ///
    /// Same "superseded, kept for its own test coverage" status as
    /// `drawAntialiasedDot` above — see its doc comment. The pen tool now
    /// draws a dragged stroke as a series of `drawPenDab` stamps
    /// (`CanvasView.stampPenDabs(from:to:)`) instead of one continuous
    /// stroked path.
    func drawAntialiasedLine(from p0: (x: Int, y: Int), to p1: (x: Int, y: Int), color: NSColor, lineWidth: CGFloat, mask: SelectionMask? = nil) {
        drawAntialiased(mask: mask) { context in
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.setLineWidth(lineWidth)
            context.setStrokeColor(color.cgColor)
            context.beginPath()
            context.move(to: CGPoint(x: CGFloat(p0.x) + 0.5, y: CGFloat(p0.y) + 0.5))
            context.addLine(to: CGPoint(x: CGFloat(p1.x) + 0.5, y: CGFloat(p1.y) + 0.5))
            context.strokePath()
        }
    }

    // MARK: - Pen brush dabs (issue #20)
    //
    // The pen tool's real paint path post-#20: a stroke is built out of
    // discrete circular "dabs" (`drawPenDab`) instead of one continuous
    // fill/stroke, so `hardness` (per-dab radial falloff) and `flow`
    // (per-dab alpha, building up across overlapping dabs) can both apply.
    // `CanvasView` stamps dabs into a temporary per-stroke accumulation
    // buffer — itself just another `PixelCanvas` — and merges that buffer
    // onto the real active layer exactly once, via `compositeOverlay`, when
    // the stroke ends; see `CanvasView.flushPenStroke()`'s doc comment for
    // why that split is what makes `opacity` behave as a whole-stroke cap
    // rather than a per-dab one.

    /// Paints one pen dab centered on `point`, in `setPixel`'s
    /// top-left-origin pixel-space coordinates: a radial-gradient disc,
    /// solid at `color`/`alpha` from the center out to `hardness * radius`,
    /// then fading linearly to fully transparent at the (anti-aliased)
    /// circle edge. `alpha` is the dab's own opacity (issue #20: callers
    /// pass `flow` here, the per-dab knob, kept separate from the
    /// stroke-level `opacity` cap `compositeOverlay` applies once at
    /// stroke end).
    ///
    /// `hardness == 1` collapses the fade region to zero width — the two
    /// gradient stops land on top of each other at the very edge, so
    /// `.drawsBeforeStartLocation` (below) paints the first stop's solid
    /// color across the entire disc interior, and only the circle's own
    /// (already anti-aliased, via `context.clip()`) boundary softens the
    /// edge — making this visually identical to the pre-#20
    /// `drawAntialiasedDot`'s plain `fillEllipse`. `hardness == 0` is a
    /// gradient across the dab's *entire* radius, from solid at dead center
    /// to transparent at the edge — "fades out smoothly from the center",
    /// per the issue.
    func drawPenDab(at point: (x: Int, y: Int), color: NSColor, diameter: CGFloat, hardness: Double, alpha: Double, mask: SelectionMask? = nil) {
        let clampedAlpha = max(0, min(1, alpha))
        guard diameter > 0, clampedAlpha > 0 else { return }
        let clampedHardness = max(0, min(1, hardness))

        drawAntialiased(mask: mask) { context in
            let radius = diameter / 2
            let center = CGPoint(x: CGFloat(point.x) + 0.5, y: CGFloat(point.y) + 0.5)

            context.saveGState()
            context.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: diameter, height: diameter))
            context.clip()

            // `CGColorSpaceCreateDeviceRGB()` (not `LayerStack`'s own
            // `CGColorSpace(name: CGColorSpace.sRGB)`) matches the device
            // RGB components `solidColor`/`transparentColor` are actually
            // built from below (`color.usingColorSpace(.deviceRGB)`) —
            // avoids a needless space mismatch between the gradient's own
            // color space and the colors handed to it.
            let rgba = color.usingColorSpace(.deviceRGB) ?? color
            let solidColor = NSColor(deviceRed: rgba.redComponent, green: rgba.greenComponent, blue: rgba.blueComponent, alpha: CGFloat(clampedAlpha)).cgColor
            let transparentColor = NSColor(deviceRed: rgba.redComponent, green: rgba.greenComponent, blue: rgba.blueComponent, alpha: 0).cgColor
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [solidColor, transparentColor] as CFArray, locations: [CGFloat(clampedHardness), 1.0]) else {
                context.restoreGState()
                return
            }

            // `.drawsBeforeStartLocation` matters specifically for
            // `hardness == 1` (see this method's own doc comment above):
            // without it, the region before the first stop (the whole disc,
            // when both stops sit at `t == 1`) would be left fully
            // transparent instead of solid. `.drawsAfterEndLocation` is
            // symmetric/defensive — nothing currently falls past `t == 1`
            // since `endRadius` below already equals the clip circle's own
            // radius, but it costs nothing to keep both directions clamped.
            context.drawRadialGradient(
                gradient,
                startCenter: center, startRadius: 0,
                endCenter: center, endRadius: radius,
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
            context.restoreGState()
        }
    }

    /// Composites `overlay`'s entire contents onto this canvas in one pass,
    /// at `alpha` (issue #20) — the pen stroke's stroke-end merge step: see
    /// this file's "Pen brush dabs" section comment and
    /// `CanvasView.flushPenStroke()` for the full picture of why `opacity`
    /// is applied here, once, rather than per dab.
    ///
    /// `overlay` must be the same size as this canvas (true by construction
    /// for `CanvasView`'s per-stroke accumulation buffer, which is always
    /// built via `PixelCanvas(width: layerStack.width, height:
    /// layerStack.height, ...)`) — a mismatched size draws `overlay`
    /// stretched to fill `width`x`height` rather than failing outright,
    /// since `CGContext.draw(_:in:)` itself has no notion of "wrong size".
    ///
    /// Reuses `drawAntialiased(mask:_:)`'s same premultiplied-scratch-overlay
    /// technique as `drawPenDab` above (`overlay` is `.alphaNonpremultiplied`
    /// like every `PixelCanvas`, so — same reasoning as that method's own
    /// doc comment — it can't vend a `CGContext` of its own either); here the
    /// "draw" step is just `context.draw(overlay.cgImage, ...)` under
    /// `context.setAlpha(alpha)`, instead of a CG fill/stroke/gradient path.
    /// No `mask` parameter: `overlay`'s own pixels were already masked at
    /// dab-stamping time (`drawPenDab`'s own `mask` argument), so any pixel
    /// outside the selection is already fully transparent here and
    /// contributes nothing to the composite regardless.
    func compositeOverlay(_ overlay: PixelCanvas, alpha: Double) {
        let clampedAlpha = max(0, min(1, alpha))
        guard clampedAlpha > 0, let overlayImage = overlay.cgImage else { return }
        drawAntialiased(mask: nil) { context in
            context.setAlpha(CGFloat(clampedAlpha))
            context.draw(overlayImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    /// Composites an already-rendered image onto this canvas at `origin`
    /// (top-left corner, in `setPixel`'s pixel-space coordinates) — the
    /// text tool's rasterization step (issue #42:
    /// `CanvasView.rasterizeText(_:at:)`, which builds `image` from an
    /// offscreen `NSTextView`'s `cacheDisplay(in:to:)` output). Reuses
    /// `drawAntialiased(mask:_:)`'s same premultiplied-scratch-overlay
    /// alpha-compositing technique as `compositeOverlay`/`drawPenDab`
    /// above, so `image`'s own per-pixel alpha (an anti-aliased glyph edge,
    /// for instance) blends onto the canvas the same "source over"
    /// straight-alpha way those do, rather than `setPixel`'s
    /// fully-opaque-only write.
    ///
    /// `origin` is not clamped or bounds-checked up front — a rectangle
    /// partially or fully outside `0..<width`/`0..<height` is simply
    /// clipped by the loop in `drawAntialiased(mask:_:)`, which already
    /// only ever visits `0..<width`/`0..<height`.
    func compositeImage(_ image: CGImage, at origin: (x: Int, y: Int), mask: SelectionMask? = nil) {
        drawAntialiased(mask: mask) { context in
            let rect = CGRect(x: origin.x, y: origin.y, width: image.width, height: image.height)
            context.draw(image, in: rect)
        }
    }

    // MARK: - Rendering

    var cgImage: CGImage? {
        bitmap.cgImage
    }

    /// Reads the raw RGBA bytes written at a pixel, bypassing `NSColor`
    /// conversion so tests can assert byte-exact values (no anti-aliasing,
    /// no premultiplication, no rounding surprises from color-space
    /// conversion). Returns `nil` if the coordinate is out of bounds.
    func rawPixel(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8)? {
        guard x >= 0, x < width, y >= 0, y < height else { return nil }
        guard let data = bitmap.bitmapData else { return nil }
        let bytesPerRow = bitmap.bytesPerRow
        let bpp = bitmap.bitsPerPixel / 8
        let offset = y * bytesPerRow + x * bpp
        return (data[offset], data[offset + 1], data[offset + 2], data[offset + 3])
    }

    // MARK: - Duplication

    /// Returns a byte-for-byte independent copy of this canvas (same pixel
    /// data, no shared storage with the original). Used by
    /// `LayerStack.duplicateLayer(at:)` so editing the copy never mutates
    /// the source layer.
    func copy() -> PixelCanvas {
        let duplicate = PixelCanvas(bitmap: PixelCanvas.makeBitmap(width: width, height: height), width: width, height: height)
        if let sourceData = bitmap.bitmapData, let destData = duplicate.bitmap.bitmapData {
            let byteCount = bitmap.bytesPerRow * height
            destData.update(from: sourceData, count: byteCount)
        }
        return duplicate
    }

    // MARK: - PNG I/O

    func pngData() -> Data? {
        bitmap.representation(using: .png, properties: [:])
    }

    /// Loads a PNG into a fresh pixel-exact canvas.
    ///
    /// Pixels are copied byte-for-byte straight out of the decoded
    /// `NSBitmapImageRep`'s buffer whenever its layout is the common 8-bit,
    /// non-planar, 3- or 4-samples-per-pixel RGB(A) case (which is what our
    /// own `pngData()` always produces). Grayscale PNGs (1 or 2 samples per
    /// pixel) are deliberately excluded from this fast path — their
    /// `bitsPerPixel / 8` stride is 1 or 2 bytes, not 3 or 4, so reading
    /// `r`/`g`/`b` at `srcOffset`/`+1`/`+2` would read into neighboring
    /// pixels (and past the end of the last row) and fall through to the
    /// slow path below instead. This avoids `colorAt(x:y:)`, which returns
    /// an `NSColor` in the *source* rep's own color space (`calibratedRGB`
    /// after a PNG round trip) — routing that through `setPixel`'s `.deviceRGB`
    /// conversion is a second, unnecessary color-space conversion that
    /// drifts channel values on top of the byte-copy above.
    static func load(from data: Data) -> PixelCanvas? {
        guard let sourceRep = NSBitmapImageRep(data: data) else { return nil }
        let width = sourceRep.pixelsWide
        let height = sourceRep.pixelsHigh
        let canvas = PixelCanvas(bitmap: makeBitmap(width: width, height: height), width: width, height: height)

        if sourceRep.bitsPerSample == 8, !sourceRep.isPlanar,
           sourceRep.samplesPerPixel == 3 || sourceRep.samplesPerPixel == 4,
           let sourceData = sourceRep.bitmapData, let destData = canvas.bitmap.bitmapData {
            let sourceBpp = sourceRep.bitsPerPixel / 8
            let sourceBytesPerRow = sourceRep.bytesPerRow
            let destBpp = canvas.bitmap.bitsPerPixel / 8
            let destBytesPerRow = canvas.bitmap.bytesPerRow
            // `samplesPerPixel >= 4` is equivalent to `== 4` here (grayscale
            // and grayscale+alpha are excluded above by the RGB/RGBA gate,
            // so the only two layouts that reach this point are 3-channel
            // RGB and 4-channel RGBA).
            let sourceHasAlpha = sourceRep.samplesPerPixel >= 4
            // PNG itself only stores straight alpha, but be defensive about
            // any decoder that hands back a premultiplied buffer anyway.
            let isPremultiplied = sourceHasAlpha && !sourceRep.bitmapFormat.contains(.alphaNonpremultiplied)

            for y in 0..<height {
                let srcRowStart = y * sourceBytesPerRow
                let dstRowStart = y * destBytesPerRow
                for x in 0..<width {
                    let srcOffset = srcRowStart + x * sourceBpp
                    let dstOffset = dstRowStart + x * destBpp
                    var r = sourceData[srcOffset]
                    var g = sourceData[srcOffset + 1]
                    var b = sourceData[srcOffset + 2]
                    let a: UInt8 = sourceHasAlpha ? sourceData[srcOffset + 3] : 255
                    if isPremultiplied, a > 0, a < 255 {
                        r = UInt8(max(0, min(255, (Double(r) * 255.0 / Double(a)).rounded())))
                        g = UInt8(max(0, min(255, (Double(g) * 255.0 / Double(a)).rounded())))
                        b = UInt8(max(0, min(255, (Double(b) * 255.0 / Double(a)).rounded())))
                    }
                    destData[dstOffset] = r
                    destData[dstOffset + 1] = g
                    destData[dstOffset + 2] = b
                    destData[dstOffset + 3] = a
                }
            }
            return canvas
        }

        // Fallback for layouts we don't special-case (16-bit samples,
        // planar, indexed, etc. — not something our own writer produces).
        for y in 0..<height {
            for x in 0..<width {
                let color = sourceRep.colorAt(x: x, y: y) ?? .white
                canvas.setPixel(x: x, y: y, color: color)
            }
        }
        return canvas
    }
}
