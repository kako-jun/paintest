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
    func setPixel(x: Int, y: Int, color: NSColor) {
        guard x >= 0, x < width, y >= 0, y < height else { return }
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
    func drawLine(from p0: (x: Int, y: Int), to p1: (x: Int, y: Int), color: NSColor) {
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
            setPixel(x: x0, y: y0, color: color)
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
