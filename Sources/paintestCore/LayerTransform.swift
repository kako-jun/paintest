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

    /// Per-corner offsets from the rectangle's own (rotated) corner position
    /// (round 3, free transform / distort) — each defaults to `.zero`, which
    /// leaves `corners` byte-for-byte identical to round 1/2's plain
    /// "center + size + rotation" rectangle. Non-zero offsets turn the
    /// rectangle into an arbitrary quadrilateral (see `corners`), which is
    /// what makes a distorted transform's confirm-time rasterization need
    /// `ProjectiveTransform` instead of the simple rotation-only inverse
    /// mapping `CanvasView.sourcePixel` used through round 2.
    var distortTopLeft: CGVector = .zero
    var distortTopRight: CGVector = .zero
    var distortBottomRight: CGVector = .zero
    var distortBottomLeft: CGVector = .zero

    /// Whether any of the 4 per-corner distort offsets is non-zero — the
    /// switch `CanvasView.sourcePixel` and the live-preview drawing use to
    /// pick between round 1/2's rectangle-only math and round 3's
    /// projective-transform math. `false` for every transform round 1/2 ever
    /// produced (they never touch `distort*`), so anything gated on this
    /// stays on the old code path unless a distort drag has actually
    /// happened.
    var hasDistortion: Bool {
        distortTopLeft != .zero || distortTopRight != .zero || distortBottomRight != .zero || distortBottomLeft != .zero
    }

    /// The untransformed starting rectangle: centered on the layer, sized to
    /// exactly cover it, no rotation.
    static func identity(width: Int, height: Int) -> LayerTransform {
        LayerTransform(centerX: Double(width) / 2, centerY: Double(height) / 2, width: Double(width), height: Double(height))
    }

    /// This transform's 4 corners (top-left, top-right, bottom-right,
    /// bottom-left), in canvas pixel-space coordinates (same
    /// top-left-origin, y-grows-downward convention as `PixelCanvas`/
    /// `CanvasView`): first the rectangle rotated by `rotation` radians
    /// around (`centerX`, `centerY`) — round 1/2's math, unchanged — then
    /// each corner nudged by its own `distort*` offset (round 3).
    ///
    /// Round 1 never sets `rotation` away from `0`, and round 1/2 never set
    /// any `distort*` offset away from `.zero`, so for every transform they
    /// ever produce this still comes out as the exact same axis-aligned (or
    /// rotated) rectangle as before — round 3's distortion only shows up
    /// once a `distort*` offset actually goes non-zero, and then only turns
    /// the *specific* corner it belongs to into a quadrilateral vertex,
    /// leaving the other three (and everything else about the rectangle)
    /// alone.
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

        func offset(_ point: CGPoint, by vector: CGVector) -> CGPoint {
            CGPoint(x: point.x + vector.dx, y: point.y + vector.dy)
        }

        return (
            topLeft: offset(point(dx: -halfWidth, dy: -halfHeight), by: distortTopLeft),
            topRight: offset(point(dx: halfWidth, dy: -halfHeight), by: distortTopRight),
            bottomRight: offset(point(dx: halfWidth, dy: halfHeight), by: distortBottomRight),
            bottomLeft: offset(point(dx: -halfWidth, dy: halfHeight), by: distortBottomLeft)
        )
    }
}
