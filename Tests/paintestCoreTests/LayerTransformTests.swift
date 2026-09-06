import CoreGraphics
import XCTest
@testable import paintestCore

/// Direct, pure-value tests of `LayerTransform` itself (issue #9) — separate
/// from `CanvasViewTests.swift`'s existing `LayerTransform`/`sourcePixel`
/// coverage, which drives the type through `CanvasView`'s gesture pipeline
/// (mouse events, hit-testing, rasterization). This file only ever
/// constructs `LayerTransform` values directly and reads their computed
/// properties (`identity`, `corners`, `hasDistortion`) — no `CanvasView`, no
/// `NSEvent`, no rasterization.
final class LayerTransformTests: XCTestCase {
    // MARK: - identity(width:height:)

    func testIdentity_centerWidthHeightRotationZero_hasDistortionFalse() {
        let transform = LayerTransform.identity(width: 8, height: 6)

        XCTAssertEqual(transform.centerX, 4)
        XCTAssertEqual(transform.centerY, 3)
        XCTAssertEqual(transform.width, 8)
        XCTAssertEqual(transform.height, 6)
        XCTAssertEqual(transform.rotation, 0)
        XCTAssertFalse(transform.hasDistortion)
    }

    // MARK: - corners

    /// `corners`' own doc comment describes the design exactly: "the
    /// rectangle rotated by `rotation` ... then each corner nudged by its
    /// own `distort*` offset" — i.e. the offset is applied in canvas space,
    /// *after* rotation, not as a pre-rotation local offset that would then
    /// itself get rotated. This test sets both a 90° rotation and a
    /// `distortTopLeft` offset at once and hand-derives the expected result
    /// from that stated design, independent of the implementation:
    ///
    /// A 4x4 identity transform (`centerX == centerY == 2`) has an
    /// unrotated top-left corner at local offset `(-2, -2)` from center.
    /// Rotating that offset by 90° (`cos ≈ 0`, `sin == 1`) via the same
    /// rotation matrix `corners` uses (`rotatedX = dx*cos - dy*sin`,
    /// `rotatedY = dx*sin + dy*cos`) gives `rotatedX = 2`, `rotatedY = -2`,
    /// placing the rotated-but-undistorted corner at canvas `(4, 0)`
    /// (working out the same rotation for the other 3 corners by hand:
    /// `topRight` -> `(4, 4)`, `bottomRight` -> `(0, 4)`, `bottomLeft` ->
    /// `(0, 0)` — a 90° turn cycles which physical corner each label sits
    /// at, same as the already-trusted `testLayerTransform_
    /// resizeCornerAfterRotation_...` test in `CanvasViewTests.swift` relies
    /// on). Adding `distortTopLeft = (1, 0)` on top of *that* (not before
    /// the rotation) lands the final `topLeft` corner at `(5, 0)`.
    func testCorners_rotation90DegreesWithDistortTopLeft_isRotatedRawCornerPlusUnrotatedOffset() {
        var transform = LayerTransform.identity(width: 4, height: 4)
        transform.rotation = .pi / 2
        transform.distortTopLeft = CGVector(dx: 1, dy: 0)

        let corners = transform.corners

        XCTAssertEqual(corners.topLeft.x, 5, accuracy: 1e-9)
        XCTAssertEqual(corners.topLeft.y, 0, accuracy: 1e-9)
        // The other 3 corners carry no distort offset, so they must still
        // land exactly where a plain 90°-rotated (undistorted) rectangle
        // would put them.
        XCTAssertEqual(corners.topRight.x, 4, accuracy: 1e-9)
        XCTAssertEqual(corners.topRight.y, 4, accuracy: 1e-9)
        XCTAssertEqual(corners.bottomRight.x, 0, accuracy: 1e-9)
        XCTAssertEqual(corners.bottomRight.y, 4, accuracy: 1e-9)
        XCTAssertEqual(corners.bottomLeft.x, 0, accuracy: 1e-9)
        XCTAssertEqual(corners.bottomLeft.y, 0, accuracy: 1e-9)
    }

    // MARK: - hasDistortion

    /// `testLayerTransform_hasDistortion_trueOnlyWhenSomeCornerOffsetIsNonZero`
    /// in `CanvasViewTests.swift` already covers each corner going non-zero
    /// *one at a time*. This locks in the case that test doesn't: several
    /// corners non-zero *simultaneously*, and that clearing one while
    /// another stays non-zero still reads as `true` (not, say, an
    /// accidentally-AND'd condition that only fires when every corner is
    /// set).
    func testHasDistortion_multipleCornersNonzeroSimultaneously_isTrue() {
        var transform = LayerTransform.identity(width: 8, height: 8)
        XCTAssertFalse(transform.hasDistortion, "precondition: no distortion yet")

        transform.distortTopLeft = CGVector(dx: 1, dy: 1)
        transform.distortBottomRight = CGVector(dx: -1, dy: 2)
        XCTAssertTrue(transform.hasDistortion, "two simultaneous non-zero offsets must count")

        transform.distortTopLeft = .zero
        XCTAssertTrue(transform.hasDistortion, "bottomRight's offset alone must still count once topLeft's is cleared")

        transform.distortBottomRight = .zero
        XCTAssertFalse(transform.hasDistortion, "clearing every offset must go back to false")
    }
}
