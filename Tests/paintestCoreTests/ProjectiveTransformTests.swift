import CoreGraphics
import XCTest
@testable import paintestCore

/// Direct tests of `ProjectiveTransform` itself (issue #9, round 3), plus a
/// couple of `CanvasView.sourcePixel` edge cases that only make sense
/// alongside this math (self-intersecting quads, the `sourcePixel` epsilon
/// nudge near a `u`/`v` boundary). `CanvasViewTests.swift` already has
/// `testProjectiveTransform_noDistortion_matchesPlainRectangleSourcePixel_...`
/// and `testSourcePixel_singleCornerPulledInward_matchesHandDerivedProjectiveMapping`
/// covering the "well-behaved quadrilateral" numerical cases — this file is
/// about the degenerate/pathological inputs `ProjectiveTransform.init`'s own
/// doc comment calls out as needing a graceful (non-crashing) fallback.
final class ProjectiveTransformTests: XCTestCase {
    // MARK: - forward/inverse round-trip on a genuine (non-parallelogram) quad

    /// A hand-picked quadrilateral where no pair of opposite sides is
    /// parallel (unlike a parallelogram, whose `g`/`h` perspective terms are
    /// both exactly zero — see `ProjectiveTransform.init`'s doc comment) —
    /// `topRight - topLeft == (10, 0)` but `bottomRight - bottomLeft ==
    /// (7, -4)`, so this genuinely exercises the perspective (`g`/`h`
    /// nonzero) code path, not just the simpler affine one.
    private static let quad = (
        topLeft: CGPoint(x: 0, y: 0),
        topRight: CGPoint(x: 10, y: 0),
        bottomRight: CGPoint(x: 8, y: 10),
        bottomLeft: CGPoint(x: 1, y: 9)
    )

    func testForwardThenInverse_roundTripsBackToTheOriginalUnitSquareCoordinate() {
        let quad = Self.quad
        let projective = ProjectiveTransform(topLeft: quad.topLeft, topRight: quad.topRight, bottomRight: quad.bottomRight, bottomLeft: quad.bottomLeft)

        for (u, v) in [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0), (0.3, 0.4), (0.7, 0.2), (0.5, 0.5)] {
            let point = projective.forward(u: u, v: v)
            guard let roundTripped = projective.inverse(x: Double(point.x), y: Double(point.y)) else {
                XCTFail("inverse should not fail for a point this transform itself just produced (u=\(u) v=\(v))")
                continue
            }
            XCTAssertEqual(roundTripped.u, u, accuracy: 1e-9, "u=\(u) v=\(v)")
            XCTAssertEqual(roundTripped.v, v, accuracy: 1e-9, "u=\(u) v=\(v)")
        }
    }

    func testInverseThenForward_roundTripsBackToTheOriginalCanvasPoint() {
        let quad = Self.quad
        let projective = ProjectiveTransform(topLeft: quad.topLeft, topRight: quad.topRight, bottomRight: quad.bottomRight, bottomLeft: quad.bottomLeft)

        for point in [CGPoint(x: 2, y: 2), CGPoint(x: 5, y: 5), CGPoint(x: 7, y: 3), CGPoint(x: 1.5, y: 8.2)] {
            guard let (u, v) = projective.inverse(x: Double(point.x), y: Double(point.y)) else {
                XCTFail("inverse unexpectedly failed for \(point)")
                continue
            }
            let roundTripped = projective.forward(u: u, v: v)
            XCTAssertEqual(Double(roundTripped.x), Double(point.x), accuracy: 1e-9, "\(point)")
            XCTAssertEqual(Double(roundTripped.y), Double(point.y), accuracy: 1e-9, "\(point)")
        }
    }

    // MARK: - Degenerate quadrilaterals: init must not crash (doc comment's
    // own "g = h = 0" fallback)

    /// The 4 corners collapse into just 2 distinct points (`topLeft ==
    /// topRight`, `bottomRight == bottomLeft`) — a zero-area, zero-width
    /// "line" quadrilateral. `init` must fall back to the affine `g = h = 0`
    /// path (both `dx3`/`dy3` land at exactly `0` for this input) rather
    /// than producing `NaN`/`inf` from a division by a near-zero
    /// determinant.
    func testInit_fourCornersCollapseToTwoPoints_doesNotCrash_fallsBackToFiniteAffineMap() {
        let projective = ProjectiveTransform(
            topLeft: CGPoint(x: 0, y: 0),
            topRight: CGPoint(x: 0, y: 0),
            bottomRight: CGPoint(x: 5, y: 5),
            bottomLeft: CGPoint(x: 5, y: 5)
        )

        let midpoint = projective.forward(u: 0.5, v: 0.5)
        XCTAssertTrue(midpoint.x.isFinite, "must not produce NaN/inf")
        XCTAssertTrue(midpoint.y.isFinite, "must not produce NaN/inf")
        // With g=h=0 the forward map through corners 0 (topLeft), 1
        // (topRight, identical to topLeft here) and 3 (bottomLeft) is purely
        // affine: `x = b*v`, `y = e*v`, which for this input works out to
        // `(5v, 5v)` — checked here as proof the fallback is a *sane* affine
        // map, not just "some finite number".
        XCTAssertEqual(midpoint.x, 2.5, accuracy: 1e-9)
        XCTAssertEqual(midpoint.y, 2.5, accuracy: 1e-9)
    }

    /// Three of the four corners (`topRight`, `bottomRight`, `bottomLeft`)
    /// sit on a single straight line (slope `-1` through all three) while
    /// `topLeft` sits off it — a genuinely degenerate quadrilateral (zero
    /// enclosed area on one side) distinct from the "corners collapse to 2
    /// points" case above. This drives `init`'s *other* fallback trigger
    /// (`abs(determinant) < epsilon`, not the `dx3`/`dy3`-near-zero one).
    func testInit_threeCornersCollinear_doesNotCrash_fallsBackToFiniteAffineMap() {
        let projective = ProjectiveTransform(
            topLeft: CGPoint(x: 0, y: 0),
            topRight: CGPoint(x: 10, y: 0),
            bottomRight: CGPoint(x: 5, y: 5),
            bottomLeft: CGPoint(x: 0, y: 10)
        )

        let midpoint = projective.forward(u: 0.5, v: 0.5)
        XCTAssertTrue(midpoint.x.isFinite, "must not produce NaN/inf")
        XCTAssertTrue(midpoint.y.isFinite, "must not produce NaN/inf")
        XCTAssertEqual(midpoint.x, 5, accuracy: 1e-9)
        XCTAssertEqual(midpoint.y, 5, accuracy: 1e-9)
    }

    // MARK: - inverse(x:y:) on a singular quad returns nil, not a crash

    /// The "corners collapse to 2 points" quad from the `init` test above is
    /// singular for *every* destination point, not just one: since `g == h
    /// == 0` and `a == d == 0` for this particular degenerate input, the
    /// `a11*a22 - a12*a21` determinant `inverse` guards against reduces to
    /// `0` regardless of `x`/`y`. `inverse` must recognize that and return
    /// `nil` rather than dividing by (near-)zero.
    func testInverse_singularDegenerateQuad_returnsNilRatherThanDividingByZero() {
        let projective = ProjectiveTransform(
            topLeft: CGPoint(x: 0, y: 0),
            topRight: CGPoint(x: 0, y: 0),
            bottomRight: CGPoint(x: 5, y: 5),
            bottomLeft: CGPoint(x: 5, y: 5)
        )

        for point in [CGPoint(x: 0, y: 0), CGPoint(x: 2.5, y: 2.5), CGPoint(x: 100, y: 100)] {
            XCTAssertNil(projective.inverse(x: Double(point.x), y: Double(point.y)), "\(point)")
        }
    }

    // MARK: - Self-intersecting (bow-tie) quadrilateral

    /// A "bow-tie": going `topLeft` → `topRight` → `bottomRight` →
    /// `bottomLeft` → back to `topLeft` crosses itself, because
    /// `bottomRight`/`bottomLeft` are the *diagonal* opposite corners of
    /// what a non-self-intersecting quad would have there (i.e. this is the
    /// plain unit square with its bottom two corners swapped). Neither
    /// `ProjectiveTransform.inverse` nor `CanvasView.sourcePixel` (which
    /// builds one of these from a `LayerTransform` whose corners have been
    /// dragged into a bow-tie via extreme distort offsets) is specified to
    /// reject this shape outright — the requirement is just that neither
    /// crashes, and that `sourcePixel`'s own `u`/`v` range guard still keeps
    /// every returned index inside the source canvas.
    func testInverse_selfIntersectingBowTieQuad_doesNotCrash_returnsFiniteOrNil() {
        let projective = ProjectiveTransform(
            topLeft: CGPoint(x: 0, y: 0),
            topRight: CGPoint(x: 10, y: 10),
            bottomRight: CGPoint(x: 10, y: 0),
            bottomLeft: CGPoint(x: 0, y: 10)
        )

        for y in stride(from: -5, through: 15, by: 5) {
            for x in stride(from: -5, through: 15, by: 5) {
                if let (u, v) = projective.inverse(x: Double(x), y: Double(y)) {
                    XCTAssertTrue(u.isFinite, "x=\(x) y=\(y)")
                    XCTAssertTrue(v.isFinite, "x=\(x) y=\(y)")
                }
            }
        }
    }

    func testSourcePixel_selfIntersectingBowTieQuad_doesNotCrash_neverReturnsAnOutOfBoundsIndex() {
        // Identity's plain corners are (0,0)/(8,0)/(8,8)/(0,8); swapping the
        // bottom two corners' positions via distort offsets (each moved to
        // where the *other* one started) turns this into the same kind of
        // bow-tie as the `ProjectiveTransform`-level test above, but reached
        // the way an actual (extreme) distort drag would produce one.
        var transform = LayerTransform.identity(width: 8, height: 8)
        transform.distortBottomRight = CGVector(dx: -8, dy: 0) // (8,8) -> (0,8), bottomLeft's spot
        transform.distortBottomLeft = CGVector(dx: 8, dy: 0) // (0,8) -> (8,8), bottomRight's spot

        for y in 0..<8 {
            for x in 0..<8 {
                if let sample = CanvasView.sourcePixel(forDestination: (x, y), transform: transform, sourceWidth: 8, sourceHeight: 8) {
                    XCTAssertTrue((0..<8).contains(sample.x), "x=\(x) y=\(y) sample.x=\(sample.x)")
                    XCTAssertTrue((0..<8).contains(sample.y), "x=\(x) y=\(y) sample.y=\(sample.y)")
                }
            }
        }
    }

    // MARK: - sourcePixel's epsilon nudge near the u/v == 1 boundary

    /// `sourcePixel`'s doc comment explains the `epsilon` nudge exists to
    /// stop an exact-boundary `u`/`v` from mis-flooring *short* by one
    /// (landing one row/column below the intended source pixel). This is
    /// the opposite edge: a `u` close enough to (but still under) `1` that
    /// adding `epsilon` *after* scaling by `sourceWidth` pushes the result
    /// up to (or past) `sourceWidth` itself — an invalid, one-past-the-end
    /// index.
    ///
    /// Constructed by solving `sourcePixel`'s own formula backward for a
    /// `centerX` that lands `u` at exactly `1 - 5e-11` (chosen so
    /// `(1 - u) * sourceWidth`, `5e-10`, is smaller than `epsilon`, `1e-9` —
    /// the exact condition under which the nudge can overshoot):
    /// `u = (pixel.x - centerX + halfWidth) / width`, so `centerX = pixel.x
    /// + halfWidth - u * width`. With `pixel.x = 5`, `width = 10` (so
    /// `halfWidth = 5`), that's `centerX = 5e-10`.
    ///
    /// Correctness test (issue #9 review should-4 — this used to be a
    /// CHARACTERIZATION test pinning down an actual bug: with this
    /// adversarial `centerX`, `sourcePixel` used to return `sourceX == 10`,
    /// one past the last valid index (`0..<10`) of a width-10 source
    /// canvas. That never crashed — `rasterizeTransform`'s
    /// `source.rawPixel(x: 10, ...)` call safely returns `nil` and that
    /// destination pixel was just left transparent (see
    /// `PixelCanvas.rawPixel`'s bounds guard) — but the correct source pixel
    /// (index 9) never got sampled. `sourcePixel` now clamps `sourceX`/
    /// `sourceY` to `sourceWidth - 1`/`sourceHeight - 1`, so this adversarial
    /// `centerX` correctly samples the last column instead of overflowing
    /// past it. The trigger window is astronomically narrow (`centerX` has
    /// to land within `5e-10` of a specific value), so this was never
    /// expected to occur from any real mouse drag — but the clamp is cheap
    /// and makes the guarantee unconditional rather than probabilistic.
    func testSourcePixel_uJustBelowOneByLessThanEpsilon_clampsToLastValidSourceColumn() {
        var transform = LayerTransform.identity(width: 10, height: 10)
        transform.centerX = 5e-10
        transform.centerY = 5 // keeps v comfortably inside 0..<1, only u is under test

        let sample = CanvasView.sourcePixel(forDestination: (5, 5), transform: transform, sourceWidth: 10, sourceHeight: 10)

        XCTAssertNotNil(sample, "must not crash / return nil outright — u is still < 1, so the range guard lets it through")
        XCTAssertEqual(sample?.x, 9, "clamped to the last valid column, not sourceWidth itself")
    }
}
