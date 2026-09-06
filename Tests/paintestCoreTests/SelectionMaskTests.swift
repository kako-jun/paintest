import AppKit
import XCTest
@testable import paintestCore

/// Minimal crash/sanity coverage for `SelectionMask` (issue #11, round 1).
/// Deliberately not exhaustive — full observation-point coverage (combine
/// edge cases, `boundaryEdges()` on non-trivial shapes, etc.) is a follow-up
/// test-writing pass's job, not this implementation round's.
final class SelectionMaskTests: XCTestCase {
    func testInit_startsWithNothingSelected() {
        let mask = SelectionMask(width: 4, height: 4)
        for y in 0..<4 {
            for x in 0..<4 {
                XCTAssertFalse(mask.contains(x: x, y: y))
            }
        }
        XCTAssertTrue(mask.isEmpty)
    }

    func testContains_outOfBounds_isFalse_notACrash() {
        let mask = SelectionMask(width: 4, height: 4)
        XCTAssertFalse(mask.contains(x: -1, y: 0))
        XCTAssertFalse(mask.contains(x: 0, y: -1))
        XCTAssertFalse(mask.contains(x: 4, y: 0))
        XCTAssertFalse(mask.contains(x: 0, y: 4))
    }

    func testSetSelected_outOfBounds_isIgnored_notACrash() {
        let mask = SelectionMask(width: 4, height: 4)
        mask.setSelected(true, x: -1, y: -1)
        mask.setSelected(true, x: 100, y: 100)
        XCTAssertTrue(mask.isEmpty)
    }

    func testSetSelectedAndContains_roundTrip() {
        let mask = SelectionMask(width: 4, height: 4)
        mask.setSelected(true, x: 2, y: 1)
        XCTAssertTrue(mask.contains(x: 2, y: 1))
        XCTAssertFalse(mask.isEmpty)
        mask.setSelected(false, x: 2, y: 1)
        XCTAssertFalse(mask.contains(x: 2, y: 1))
        XCTAssertTrue(mask.isEmpty)
    }

    func testRectangle_selectsExactlyTheGivenBounds_clippedToCanvas() {
        let mask = SelectionMask.rectangle(x0: 1, y0: 1, x1: 2, y1: 2, width: 4, height: 4)
        XCTAssertTrue(mask.contains(x: 1, y: 1))
        XCTAssertTrue(mask.contains(x: 2, y: 2))
        XCTAssertFalse(mask.contains(x: 0, y: 0))
        XCTAssertFalse(mask.contains(x: 3, y: 3))

        // Reversed corners (end point given as (x0,y0)) must select the same
        // region — the tool's drag can end above/left of where it started.
        let reversed = SelectionMask.rectangle(x0: 2, y0: 2, x1: 1, y1: 1, width: 4, height: 4)
        XCTAssertTrue(reversed.contains(x: 1, y: 1))
        XCTAssertTrue(reversed.contains(x: 2, y: 2))
    }

    func testRectangle_fullyOutOfBounds_isEmpty_notACrash() {
        let mask = SelectionMask.rectangle(x0: 10, y0: 10, x1: 20, y1: 20, width: 4, height: 4)
        XCTAssertTrue(mask.isEmpty)
    }

    func testEllipse_selectsCenterButNotFarCorners() {
        let mask = SelectionMask.ellipse(centerX: 2, centerY: 2, radiusX: 2, radiusY: 2, width: 4, height: 4)
        XCTAssertTrue(mask.contains(x: 2, y: 2), "the exact center pixel must be selected")
        XCTAssertFalse(mask.contains(x: 0, y: 0), "a corner well outside the ellipse must not be selected")
    }

    func testEllipse_nonPositiveRadius_isEmpty_notACrash() {
        XCTAssertTrue(SelectionMask.ellipse(centerX: 2, centerY: 2, radiusX: 0, radiusY: 2, width: 4, height: 4).isEmpty)
        XCTAssertTrue(SelectionMask.ellipse(centerX: 2, centerY: 2, radiusX: 2, radiusY: 0, width: 4, height: 4).isEmpty)
        XCTAssertTrue(SelectionMask.ellipse(centerX: 2, centerY: 2, radiusX: -1, radiusY: -1, width: 4, height: 4).isEmpty)
    }

    func testUnioned_combinesBothMasks() {
        let a = SelectionMask.rectangle(x0: 0, y0: 0, x1: 0, y1: 0, width: 4, height: 4)
        let b = SelectionMask.rectangle(x0: 3, y0: 3, x1: 3, y1: 3, width: 4, height: 4)
        let union = a.unioned(with: b)
        XCTAssertTrue(union.contains(x: 0, y: 0))
        XCTAssertTrue(union.contains(x: 3, y: 3))
        XCTAssertFalse(union.contains(x: 1, y: 1))
    }

    func testSubtracting_removesOverlap() {
        let a = SelectionMask.rectangle(x0: 0, y0: 0, x1: 2, y1: 2, width: 4, height: 4)
        let b = SelectionMask.rectangle(x0: 1, y0: 1, x1: 1, y1: 1, width: 4, height: 4)
        let result = a.subtracting(b)
        XCTAssertTrue(result.contains(x: 0, y: 0))
        XCTAssertFalse(result.contains(x: 1, y: 1))
    }

    func testIntersected_keepsOnlyOverlap() {
        let a = SelectionMask.rectangle(x0: 0, y0: 0, x1: 2, y1: 2, width: 4, height: 4)
        let b = SelectionMask.rectangle(x0: 2, y0: 2, x1: 3, y1: 3, width: 4, height: 4)
        let result = a.intersected(with: b)
        XCTAssertTrue(result.contains(x: 2, y: 2))
        XCTAssertFalse(result.contains(x: 0, y: 0))
        XCTAssertFalse(result.contains(x: 3, y: 3))
    }

    func testInverted_flipsEveryPixel() {
        let mask = SelectionMask.rectangle(x0: 0, y0: 0, x1: 0, y1: 0, width: 2, height: 2)
        let inverted = mask.inverted()
        XCTAssertFalse(inverted.contains(x: 0, y: 0))
        XCTAssertTrue(inverted.contains(x: 1, y: 0))
        XCTAssertTrue(inverted.contains(x: 0, y: 1))
        XCTAssertTrue(inverted.contains(x: 1, y: 1))
    }

    func testInverted_ofFull_isEmpty() {
        let full = SelectionMask.rectangle(x0: 0, y0: 0, x1: 3, y1: 3, width: 4, height: 4)
        XCTAssertTrue(full.inverted().isEmpty)
    }

    func testBoundaryEdges_singlePixelMask_hasExactlyFourEdges() {
        let mask = SelectionMask.rectangle(x0: 1, y0: 1, x1: 1, y1: 1, width: 4, height: 4)
        let edges = mask.boundaryEdges()
        XCTAssertEqual(edges.count, 4, "an isolated single-pixel selection has 4 exposed sides")
    }

    func testBoundaryEdges_emptyMask_hasNoEdges_notACrash() {
        let mask = SelectionMask(width: 4, height: 4)
        XCTAssertTrue(mask.boundaryEdges().isEmpty)
    }

    // MARK: - polygon (round 2 minimal sanity coverage; full observation-point
    // coverage — concave/self-intersecting shapes, exact edge-pixel
    // boundaries, etc. — is a follow-up test-writing pass's job, same as the
    // rest of this file's round-1 disclaimer above.)

    func testPolygon_fewerThanThreeVertices_isEmpty_notACrash() {
        XCTAssertTrue(SelectionMask.polygon(vertices: [], width: 4, height: 4).isEmpty)
        XCTAssertTrue(SelectionMask.polygon(vertices: [(x: 0, y: 0)], width: 4, height: 4).isEmpty)
        XCTAssertTrue(SelectionMask.polygon(vertices: [(x: 0, y: 0), (x: 1, y: 1)], width: 4, height: 4).isEmpty)
    }

    func testPolygon_square_selectsInteriorNotOutside() {
        // A closed square from (1,1) to (3,3) via its four corners.
        let mask = SelectionMask.polygon(
            vertices: [(x: 1, y: 1), (x: 3, y: 1), (x: 3, y: 3), (x: 1, y: 3)],
            width: 6, height: 6
        )
        XCTAssertTrue(mask.contains(x: 2, y: 2), "the square's center pixel must be selected")
        XCTAssertFalse(mask.contains(x: 0, y: 0), "well outside the square must not be selected")
        XCTAssertFalse(mask.contains(x: 5, y: 5), "well outside the square must not be selected")
    }

    func testPolygon_implicitlyClosesPath() {
        // Only 3 vertices given, none repeated — the polygon must still
        // close the last edge back to the first vertex on its own.
        let mask = SelectionMask.polygon(
            vertices: [(x: 0, y: 0), (x: 4, y: 0), (x: 0, y: 4)],
            width: 5, height: 5
        )
        XCTAssertTrue(mask.contains(x: 1, y: 1), "inside the implied triangle must be selected")
        XCTAssertFalse(mask.contains(x: 4, y: 4), "outside the implied triangle must not be selected")
    }

    func testBoundaryEdges_adjacentSelectedPixelsShareNoInternalEdge() {
        // Two side-by-side selected pixels: the shared internal edge between
        // them must not be emitted, only the 6 outer sides of the 2x1 block.
        let mask = SelectionMask.rectangle(x0: 0, y0: 0, x1: 1, y1: 0, width: 4, height: 4)
        let edges = mask.boundaryEdges()
        XCTAssertEqual(edges.count, 6)
    }
}
