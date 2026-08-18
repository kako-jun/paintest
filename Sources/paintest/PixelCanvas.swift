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
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            fatalError("Failed to allocate pixel bitmap \(width)x\(height)")
        }
        return rep
    }

    // MARK: - Pixel access

    private func components(of color: NSColor) -> (UInt8, UInt8, UInt8, UInt8) {
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

    // MARK: - PNG I/O

    func pngData() -> Data? {
        bitmap.representation(using: .png, properties: [:])
    }

    /// Loads a PNG into a fresh pixel-exact canvas.
    ///
    /// Pixels are copied one at a time via `colorAt(x:y:)`, which is
    /// format-agnostic (works regardless of the source's bit depth, color
    /// space, or palette) and — unlike drawing through a `CGContext` — has no
    /// ambiguity about which edge row 0 corresponds to. This keeps the
    /// save/load round trip byte-exact without any flip bookkeeping.
    static func load(from data: Data) -> PixelCanvas? {
        guard let sourceRep = NSBitmapImageRep(data: data) else { return nil }
        let width = sourceRep.pixelsWide
        let height = sourceRep.pixelsHigh
        let canvas = PixelCanvas(bitmap: makeBitmap(width: width, height: height), width: width, height: height)

        for y in 0..<height {
            for x in 0..<width {
                let color = sourceRep.colorAt(x: x, y: y) ?? .white
                canvas.setPixel(x: x, y: y, color: color)
            }
        }
        return canvas
    }
}
