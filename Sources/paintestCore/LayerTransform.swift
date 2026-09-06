import CoreGraphics
import Foundation

/// The in-progress state of a layer transform gesture (issue #9): a
/// rectangle (center + size) plus a rotation angle, describing where the
/// original layer canvas should be re-rasterized onto once the transform is
/// confirmed.
///
/// Round 1 only wires up move + scale — nothing in `CanvasView` ever sets
/// `rotation` to anything but `0` yet — but the type itself models rotation
/// from the start so round 2 (rotation) and a later free-transform
/// (per-corner distortion) round can build on this shape without redesigning
/// it, per the Issue #9 plan.
struct LayerTransform {
    var centerX: Double
    var centerY: Double
    /// Always positive; callers (drag handlers, `identity`) are responsible
    /// for clamping to a sane minimum before storing.
    var width: Double
    /// Always positive; see `width`.
    var height: Double
    /// Radians. Stays `0` throughout round 1 — the UI never changes it — and
    /// starts being read/written from round 2 onward.
    var rotation: Double = 0

    /// The untransformed starting rectangle: centered on the layer, sized to
    /// exactly cover it, no rotation.
    static func identity(width: Int, height: Int) -> LayerTransform {
        LayerTransform(centerX: Double(width) / 2, centerY: Double(height) / 2, width: Double(width), height: Double(height))
    }

    /// This transform rectangle's 4 corners (top-left, top-right,
    /// bottom-right, bottom-left), rotated by `rotation` radians around
    /// (`centerX`, `centerY`), in canvas pixel-space coordinates (same
    /// top-left-origin, y-grows-downward convention as `PixelCanvas`/
    /// `CanvasView`).
    ///
    /// Round 1 never sets `rotation` away from `0`, so today this always
    /// comes out as a plain axis-aligned rectangle — but the rotation math
    /// itself (standard 2D rotation via `cos`/`sin`) is implemented properly
    /// now so round 2 can start reading real angles here without this
    /// property needing to change.
    var corners: (topLeft: CGPoint, topRight: CGPoint, bottomRight: CGPoint, bottomLeft: CGPoint) {
        let halfWidth = width / 2
        let halfHeight = height / 2
        let cosR = cos(rotation)
        let sinR = sin(rotation)

        // Rotates an offset from the rectangle's own center by `rotation`,
        // then places it back in canvas space.
        func point(dx: Double, dy: Double) -> CGPoint {
            let rotatedX = dx * cosR - dy * sinR
            let rotatedY = dx * sinR + dy * cosR
            return CGPoint(x: centerX + rotatedX, y: centerY + rotatedY)
        }

        return (
            topLeft: point(dx: -halfWidth, dy: -halfHeight),
            topRight: point(dx: halfWidth, dy: -halfHeight),
            bottomRight: point(dx: halfWidth, dy: halfHeight),
            bottomLeft: point(dx: -halfWidth, dy: halfHeight)
        )
    }
}
