import CoreGraphics

/// A projective transform (homography) mapping the unit square
/// `(0,0)→(1,0)→(1,1)→(0,1)` onto an arbitrary quadrilateral — the math
/// `LayerTransform`'s round-3 free-transform ("自由変形"/distort) corners
/// need, since a distorted transform's 4 corners no longer form a rectangle
/// (or even a parallelogram in general), and the rotation-only inverse
/// mapping `CanvasView.sourcePixel` used through round 2 can't represent
/// that.
///
/// Standard derivation (Paul Heckbert, "Fundamentals of Texture Mapping and
/// Image Warping", UC Berkeley, 1989 — the "mapping a unit square to a
/// quadrilateral" section): models the forward map as
/// ```
/// x = (a*u + b*v + c) / (g*u + h*v + 1)
/// y = (d*u + e*v + f) / (g*u + h*v + 1)
/// ```
/// which is the general 8-degree-of-freedom homography with its bottom-right
/// matrix entry normalized to `1`. `g`/`h` (the two "perspective" terms) are
/// solved first from a 2x2 linear system derived from the `(u,v) = (1,1)`
/// corner condition; `a,b,c,d,e,f` then follow directly by substitution —
/// see the doc comments on `init` and `inverse(x:y:)` for the two halves of
/// this used by `CanvasView`.
struct ProjectiveTransform {
    private let a, b, c, d, e, f, g, h: Double

    /// `topLeft`, `topRight`, `bottomRight`, `bottomLeft` map to unit-square
    /// corners `(0,0)`, `(1,0)`, `(1,1)`, `(0,1)` respectively — the same
    /// corner order and naming `LayerTransform.corners` already uses, so a
    /// call site can pass that tuple straight through without reordering
    /// anything.
    ///
    /// Degenerate quadrilaterals (zero area, or three-plus corners
    /// collinear) fall back to `g = h = 0` — a plain affine map through
    /// whichever 3 corners are left independent — rather than dividing by
    /// zero; `inverse(x:y:)` separately guards against a singular 2x2 system
    /// for the `a,b,c,d,e,f` solve, so a degenerate quad still won't crash,
    /// it'll just return `nil` for points it can't place.
    init(topLeft: CGPoint, topRight: CGPoint, bottomRight: CGPoint, bottomLeft: CGPoint) {
        let x0 = Double(topLeft.x), y0 = Double(topLeft.y)
        let x1 = Double(topRight.x), y1 = Double(topRight.y)
        let x2 = Double(bottomRight.x), y2 = Double(bottomRight.y)
        let x3 = Double(bottomLeft.x), y3 = Double(bottomLeft.y)

        // From the `(u,v) = (1,1)` corner condition `a+b+c = x2*(g+h+1)` (and
        // the same for `y`/`d,e,f`), substituting `a = x1-x0+g*x1`,
        // `b = x3-x0+h*x3`, `c = x0` (and likewise for `y`) reduces to the
        // 2x2 linear system `g*dx1 + h*dx2 = dx3` / `g*dy1 + h*dy2 = dy3`
        // below, solved via Cramer's rule.
        let dx1 = x1 - x2, dx2 = x3 - x2, dx3 = x0 - x1 + x2 - x3
        let dy1 = y1 - y2, dy2 = y3 - y2, dy3 = y0 - y1 + y2 - y3

        let epsilon = 1e-12
        let determinant = dx1 * dy2 - dy1 * dx2
        let gValue: Double
        let hValue: Double
        if (abs(dx3) < epsilon && abs(dy3) < epsilon) || abs(determinant) < epsilon {
            // Either already a parallelogram (`dx3 == dy3 == 0`, no
            // perspective term needed) or a degenerate system (collinear
            // corners) that can't be solved for a perspective term at all —
            // either way, falling back to a pure affine map (through
            // corners 0, 1, 3; corner 2 may not land exactly where asked)
            // is safer than dividing by a near-zero determinant.
            gValue = 0
            hValue = 0
        } else {
            gValue = (dx3 * dy2 - dy3 * dx2) / determinant
            hValue = (dx1 * dy3 - dy1 * dx3) / determinant
        }

        a = x1 - x0 + gValue * x1
        b = x3 - x0 + hValue * x3
        c = x0
        d = y1 - y0 + gValue * y1
        e = y3 - y0 + hValue * y3
        f = y0
        g = gValue
        h = hValue
    }

    /// Maps unit-square `(u,v)` to canvas-space `(x,y)` — the forward
    /// direction. `CanvasView`'s sampling never calls this (it only ever
    /// needs the inverse, below); this exists so tests can round-trip
    /// known corner/point pairs through both directions to check the math
    /// numerically instead of trusting it by inspection.
    func forward(u: Double, v: Double) -> CGPoint {
        let denominator = g * u + h * v + 1
        return CGPoint(x: (a * u + b * v + c) / denominator, y: (d * u + e * v + f) / denominator)
    }

    /// Maps canvas-space `(x,y)` back to unit-square `(u,v)` — the direction
    /// confirm-time rasterization actually needs: given a destination pixel,
    /// find where in the (unit-square-normalized) source image it samples
    /// from. Derived by clearing the forward map's denominator and solving
    /// the resulting 2x2 linear system in `(u,v)` via Cramer's rule. Returns
    /// `nil` when that system is singular (a degenerate, zero-area
    /// quadrilateral) — nothing sensible to sample.
    func inverse(x: Double, y: Double) -> (u: Double, v: Double)? {
        let a11 = a - x * g, a12 = b - x * h, b1 = x - c
        let a21 = d - y * g, a22 = e - y * h, b2 = y - f
        let determinant = a11 * a22 - a12 * a21
        guard abs(determinant) > 1e-12 else { return nil }
        let u = (b1 * a22 - a12 * b2) / determinant
        let v = (a11 * b2 - b1 * a21) / determinant
        return (u, v)
    }
}
