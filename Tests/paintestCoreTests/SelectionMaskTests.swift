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

    // MARK: - magicWand (round 3 minimal sanity coverage; full observation-
    // point coverage — tolerance boundary values, disconnected same-color
    // islands, non-square canvases, etc. — is a follow-up test-writing
    // pass's job, same as this file's round-1/round-2 disclaimers above.)

    private func solidColorGrid(width: Int, height: Int, color: (r: UInt8, g: UInt8, b: UInt8, a: UInt8), except: [(x: Int, y: Int, color: (r: UInt8, g: UInt8, b: UInt8, a: UInt8))] = []) -> (Int, Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8)? {
        { x, y in
            guard x >= 0, x < width, y >= 0, y < height else { return nil }
            if let overridden = except.first(where: { $0.x == x && $0.y == y })?.color {
                return overridden
            }
            return color
        }
    }

    func testMagicWand_startOutOfColor_isEmpty_notACrash() {
        let colorAt: (Int, Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8)? = { _, _ in nil }
        let mask = SelectionMask.magicWand(startX: 0, startY: 0, colorAt: colorAt, tolerance: 32, width: 4, height: 4)
        XCTAssertTrue(mask.isEmpty)
    }

    func testMagicWand_solidColorCanvas_selectsEverything() {
        let colorAt = solidColorGrid(width: 4, height: 4, color: (r: 10, g: 20, b: 30, a: 255))
        let mask = SelectionMask.magicWand(startX: 0, startY: 0, colorAt: colorAt, tolerance: 0, width: 4, height: 4)
        for y in 0..<4 {
            for x in 0..<4 {
                XCTAssertTrue(mask.contains(x: x, y: y), "(\(x), \(y)) should be selected on a solid-color canvas")
            }
        }
    }

    func testMagicWand_withinTolerance_isIncluded_outsideTolerance_isExcluded() {
        // A 3x1 row: start pixel red, middle pixel slightly off (within
        // tolerance), last pixel far off (outside tolerance).
        let colorAt = solidColorGrid(
            width: 3, height: 1,
            color: (r: 100, g: 100, b: 100, a: 255),
            except: [(x: 2, y: 0, color: (r: 250, g: 250, b: 250, a: 255))]
        )
        let mask = SelectionMask.magicWand(startX: 0, startY: 0, colorAt: colorAt, tolerance: 20, width: 3, height: 1)
        XCTAssertTrue(mask.contains(x: 0, y: 0))
        XCTAssertTrue(mask.contains(x: 1, y: 0))
        XCTAssertFalse(mask.contains(x: 2, y: 0), "a far-off color beyond tolerance must not be selected")
    }

    func testMagicWand_doesNotFloodAcrossDiagonalGap() {
        // Two same-color pixels touching only diagonally (a checkerboard),
        // with the other two corners a different color — 4-connectivity must
        // not let the fill jump the diagonal gap.
        let colorAt: (Int, Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8)? = { x, y in
            let isCheckerA = (x + y) % 2 == 0
            return isCheckerA ? (r: 0, g: 0, b: 0, a: 255) : (r: 255, g: 255, b: 255, a: 255)
        }
        let mask = SelectionMask.magicWand(startX: 0, startY: 0, colorAt: colorAt, tolerance: 0, width: 2, height: 2)
        XCTAssertTrue(mask.contains(x: 0, y: 0))
        XCTAssertFalse(mask.contains(x: 1, y: 0), "diagonal neighbor of a different color must not be selected")
        XCTAssertFalse(mask.contains(x: 0, y: 1), "diagonal neighbor of a different color must not be selected")
        XCTAssertFalse(mask.contains(x: 1, y: 1), "the far diagonal same-color pixel must not be reached through a diagonal-only path")
    }

    // MARK: - Test-authoring follow-up pass (issue #11): full observation-point
    // coverage for rectangle/ellipse/polygon/magicWand/combine/boundaryEdges,
    // filling in the gaps the round-1/2/3 "minimal sanity" comments above
    // deliberately left for later.

    private func assertMasks(_ a: SelectionMask, equalTo b: SelectionMask, width: Int, height: Int, file: StaticString = #filePath, line: UInt = #line) {
        for y in 0..<height {
            for x in 0..<width {
                XCTAssertEqual(a.contains(x: x, y: y), b.contains(x: x, y: y), "mismatch at (\(x),\(y))", file: file, line: line)
            }
        }
    }

    // MARK: - rectangle

    func testRectangle_singlePointDrag_selectsExactlyOnePixel() {
        let mask = SelectionMask.rectangle(x0: 2, y0: 2, x1: 2, y1: 2, width: 5, height: 5)
        XCTAssertTrue(mask.contains(x: 2, y: 2))
        var selectedCount = 0
        for y in 0..<5 {
            for x in 0..<5 where mask.contains(x: x, y: y) { selectedCount += 1 }
        }
        XCTAssertEqual(selectedCount, 1, "a zero-size (x0==x1, y0==y1) drag must select exactly the one pixel it points at")
    }

    func testRectangle_partiallyOffCanvas_clipsToTheInCanvasPortionOnly() {
        // Dragged from (2,2) to (10,10) on a 6x6 canvas: the in-bounds
        // portion (2...5, 2...5) must be selected, the requested-but-off-canvas
        // portion silently clipped away rather than expanding the mask or
        // crashing.
        let mask = SelectionMask.rectangle(x0: 2, y0: 2, x1: 10, y1: 10, width: 6, height: 6)
        for y in 2...5 {
            for x in 2...5 {
                XCTAssertTrue(mask.contains(x: x, y: y), "(\(x),\(y)) is within both the drag and the canvas, must be selected")
            }
        }
        XCTAssertFalse(mask.contains(x: 1, y: 1), "outside the dragged rectangle entirely")
    }

    // MARK: - ellipse

    func testEllipse_pixelExactlyOnTheRadiusBoundary_isIncluded_justOutsideIsExcluded() {
        // center (2.5, 2.5), radius 2: pixel (4, 2)'s center is (4.5, 2.5),
        // exactly at normalized distance 1.0 from the center — the "<=1"
        // boundary test must include it, while the next pixel out (5, 2),
        // normalized distance 2.25, must not.
        let mask = SelectionMask.ellipse(centerX: 2.5, centerY: 2.5, radiusX: 2, radiusY: 2, width: 8, height: 8)
        XCTAssertTrue(mask.contains(x: 4, y: 2), "exactly on the radius boundary (normalized == 1.0) must be included")
        XCTAssertFalse(mask.contains(x: 5, y: 2), "just past the radius boundary must be excluded")
    }

    func testEllipse_radiusBelowOnePixel_doesNotDegenerateOrCrash_selectsJustTheCenter() {
        let mask = SelectionMask.ellipse(centerX: 2.5, centerY: 2.5, radiusX: 0.3, radiusY: 0.3, width: 5, height: 5)
        XCTAssertTrue(mask.contains(x: 2, y: 2), "the pixel exactly under the sub-pixel-radius center must still be selected")
        XCTAssertFalse(mask.contains(x: 1, y: 2), "a neighboring pixel is a full pixel-width away — far outside a <1px radius")
        XCTAssertFalse(mask.contains(x: 3, y: 2))
    }

    func testEllipse_centerOutsideCanvas_stillSelectsTheOverlappingInCanvasPortion() {
        // Center at x=10 (off the right edge of an 8-wide canvas), but the
        // radius is wide enough to reach back into the canvas.
        let mask = SelectionMask.ellipse(centerX: 10, centerY: 4, radiusX: 5, radiusY: 5, width: 8, height: 8)
        XCTAssertFalse(mask.isEmpty, "part of the ellipse still overlaps the canvas even though its center doesn't")
        XCTAssertTrue(mask.contains(x: 7, y: 4), "near the canvas's right edge, closest to the off-canvas center, should be reached")
        XCTAssertFalse(mask.contains(x: 0, y: 0), "far corner, well outside the ellipse's reach, must not be selected")
    }

    // MARK: - polygon: concave, self-intersecting, out-of-canvas, degenerate vertices

    func testPolygon_concaveUShape_excludesTheNotchButSelectsBothLegsAndBase() {
        // A "U" traced (0,0) -> (2,0) -> (2,2) -> (4,2) -> (4,0) -> (6,0) ->
        // (6,6) -> (0,6) -> close: a square with a notch cut out of its top
        // middle (columns 2..4, rows 0..2). The concave notch must stay
        // unselected while the rest of the U (legs + base) is selected.
        let vertices: [(x: Int, y: Int)] = [
            (0, 0), (2, 0), (2, 2), (4, 2), (4, 0), (6, 0), (6, 6), (0, 6)
        ]
        let mask = SelectionMask.polygon(vertices: vertices, width: 8, height: 8)
        XCTAssertFalse(mask.contains(x: 3, y: 1), "inside the concave notch must not be selected")
        XCTAssertTrue(mask.contains(x: 3, y: 4), "the U's base, below the notch, must be selected")
        XCTAssertTrue(mask.contains(x: 1, y: 1), "the U's left leg, beside the notch, must be selected")
    }

    func testPolygon_selfIntersectingBowtie_evenOddRuleDoesNotBreakDown() {
        // A self-intersecting ("figure-8"/bowtie) quadrilateral: (0,0) ->
        // (4,0) -> (0,4) -> (4,4) -> close. Hand-verified via the even-odd
        // crossing test: (1,1) falls inside the resulting shape, while
        // (3,1) and (3,3) fall outside it — the point isn't to pin the exact
        // shape (already covered by the simple square/triangle tests above)
        // but that a self-crossing path resolves to *some* consistent,
        // non-crashing, partially-selected result instead of e.g. selecting
        // everything or nothing.
        let vertices: [(x: Int, y: Int)] = [(0, 0), (4, 0), (0, 4), (4, 4)]
        let mask = SelectionMask.polygon(vertices: vertices, width: 8, height: 8)
        XCTAssertTrue(mask.contains(x: 1, y: 1))
        XCTAssertFalse(mask.contains(x: 3, y: 1))
        XCTAssertFalse(mask.contains(x: 3, y: 3))
        XCTAssertFalse(mask.isEmpty)
    }

    func testPolygon_farOutsideCanvasVertices_stillSelectsTheOverlappingInteriorCorrectly() {
        // A huge square, vastly larger than the canvas, entirely enclosing
        // it — the extreme out-of-range vertex coordinates must not crash,
        // and every in-canvas pixel ends up selected since the whole canvas
        // sits inside the polygon.
        let vertices: [(x: Int, y: Int)] = [(-100, -100), (100, -100), (100, 100), (-100, 100)]
        let mask = SelectionMask.polygon(vertices: vertices, width: 4, height: 4)
        for y in 0..<4 {
            for x in 0..<4 {
                XCTAssertTrue(mask.contains(x: x, y: y), "(\(x),\(y)) is inside the oversized enclosing polygon")
            }
        }
    }

    func testPolygon_duplicateConsecutiveVertex_doesNotDivideByZeroOrCrash() {
        // A repeated vertex (0,0) twice in a row creates a zero-length,
        // horizontal (yi == yj) edge. `straddles` is false whenever
        // yi == yj (since (yi > py) == (yj > py) always), so this edge never
        // reaches the `(py - yi) / (yj - yi)` division regardless — this
        // test pins that down empirically rather than just by inspection,
        // and confirms the shape still scan-converts the same as the
        // equivalent quad without the duplicate.
        let vertices: [(x: Int, y: Int)] = [(0, 0), (0, 0), (4, 0), (4, 4), (0, 4)]
        let mask = SelectionMask.polygon(vertices: vertices, width: 6, height: 6)
        XCTAssertTrue(mask.contains(x: 2, y: 2), "interior of the (otherwise ordinary) quad must still be selected")
        XCTAssertFalse(mask.contains(x: 5, y: 5), "well outside the quad must not be selected")
    }

    // MARK: - magicWand: tolerance boundaries, holes, and performance

    func testMagicWand_toleranceZero_onlyExactColorMatchIsSelected() {
        let colorAt = solidColorGrid(
            width: 3, height: 1,
            color: (r: 50, g: 50, b: 50, a: 255),
            except: [(x: 1, y: 0, color: (r: 51, g: 50, b: 50, a: 255))]
        )
        let mask = SelectionMask.magicWand(startX: 0, startY: 0, colorAt: colorAt, tolerance: 0, width: 3, height: 1)
        XCTAssertTrue(mask.contains(x: 0, y: 0))
        XCTAssertFalse(mask.contains(x: 1, y: 0), "a color off by just 1 in one channel must be excluded at tolerance 0")
    }

    func testMagicWand_toleranceExactlyAtColorDistance_isIncluded_onePastIt_isExcluded() {
        let startColor: (r: UInt8, g: UInt8, b: UInt8, a: UInt8) = (r: 100, g: 100, b: 100, a: 255)
        let atBoundary = solidColorGrid(width: 2, height: 1, color: startColor, except: [(x: 1, y: 0, color: (r: 110, g: 100, b: 100, a: 255))]) // distance 10
        let atBoundaryMask = SelectionMask.magicWand(startX: 0, startY: 0, colorAt: atBoundary, tolerance: 10, width: 2, height: 1)
        XCTAssertTrue(atBoundaryMask.contains(x: 1, y: 0), "colorDistance == tolerance must be included (the comparison is <=)")

        let pastBoundary = solidColorGrid(width: 2, height: 1, color: startColor, except: [(x: 1, y: 0, color: (r: 111, g: 100, b: 100, a: 255))]) // distance 11
        let pastBoundaryMask = SelectionMask.magicWand(startX: 0, startY: 0, colorAt: pastBoundary, tolerance: 10, width: 2, height: 1)
        XCTAssertFalse(pastBoundaryMask.contains(x: 1, y: 0), "colorDistance == tolerance + 1 must be excluded")
    }

    func testMagicWand_toleranceAtMaximum765_selectsEveryPixelRegardlessOfColor() {
        let colorAt: (Int, Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8)? = { x, y in
            switch (x, y) {
            case (0, 0): return (r: 0, g: 0, b: 0, a: 255)
            case (1, 0): return (r: 255, g: 255, b: 255, a: 255)
            case (0, 1): return (r: 255, g: 0, b: 0, a: 255)
            default: return (r: 0, g: 255, b: 0, a: 255)
            }
        }
        let mask = SelectionMask.magicWand(startX: 0, startY: 0, colorAt: colorAt, tolerance: 765, width: 2, height: 2)
        for y in 0..<2 {
            for x in 0..<2 {
                XCTAssertTrue(mask.contains(x: x, y: y), "(\(x),\(y)) must be selected: 765 is the maximum possible R+G+B distance")
            }
        }
    }

    func testMagicWand_negativeTolerance_excludesEvenTheStartPixelItself_isEmpty() {
        let colorAt = solidColorGrid(width: 3, height: 3, color: (r: 10, g: 10, b: 10, a: 255))
        let mask = SelectionMask.magicWand(startX: 1, startY: 1, colorAt: colorAt, tolerance: -1, width: 3, height: 3)
        XCTAssertTrue(mask.isEmpty, "colorDistance(start, start) == 0, and 0 <= -1 is false, so even the start pixel is excluded")
    }

    func testMagicWand_donutShape_holeOfDifferentColorIsNotSelected() {
        // A 5x5 grid of color A with a single-pixel hole of color B (far
        // outside tolerance) at its center.
        let colorAt = solidColorGrid(
            width: 5, height: 5,
            color: (r: 200, g: 200, b: 200, a: 255),
            except: [(x: 2, y: 2, color: (r: 0, g: 0, b: 0, a: 255))]
        )
        let mask = SelectionMask.magicWand(startX: 0, startY: 0, colorAt: colorAt, tolerance: 0, width: 5, height: 5)
        XCTAssertFalse(mask.contains(x: 2, y: 2), "the differently-colored hole must not be selected")
        XCTAssertTrue(mask.contains(x: 2, y: 1), "the ring surrounding the hole is the same color as the start and must be selected")
        XCTAssertTrue(mask.contains(x: 4, y: 4), "the outer ring, same color throughout, must be selected")
    }

    func testMagicWand_largeConnectedRegion_completesWithoutStackOverflow() {
        // A stack-based (not recursive) flood fill, per `magicWand`'s own
        // doc comment, so a large solid-color region shouldn't blow the
        // call stack the way a naive recursive implementation could. 300x300
        // = 90,000 pixels is enough to meaningfully exercise that without
        // making this test suite noticeably slower.
        let size = 300
        let colorAt: (Int, Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8)? = { x, y in
            guard x >= 0, x < size, y >= 0, y < size else { return nil }
            return (r: 5, g: 5, b: 5, a: 255)
        }
        let mask = SelectionMask.magicWand(startX: 0, startY: 0, colorAt: colorAt, tolerance: 0, width: size, height: size)
        XCTAssertFalse(mask.isEmpty)
        XCTAssertTrue(mask.contains(x: size - 1, y: size - 1), "flood fill must reach all the way to the far corner of a fully solid-color canvas")
    }

    // MARK: - combine operations: identity and disjoint edge cases

    func testUnioned_ofIdenticalMasks_isUnchanged() {
        let a = SelectionMask.rectangle(x0: 1, y0: 1, x1: 3, y1: 3, width: 5, height: 5)
        let b = SelectionMask.rectangle(x0: 1, y0: 1, x1: 3, y1: 3, width: 5, height: 5)
        assertMasks(a.unioned(with: b), equalTo: a, width: 5, height: 5)
    }

    func testSubtracting_disjointMask_isUnchanged() {
        let a = SelectionMask.rectangle(x0: 0, y0: 0, x1: 1, y1: 1, width: 5, height: 5)
        let b = SelectionMask.rectangle(x0: 3, y0: 3, x1: 4, y1: 4, width: 5, height: 5)
        assertMasks(a.subtracting(b), equalTo: a, width: 5, height: 5)
    }

    func testIntersected_ofIdenticalMasks_isUnchanged() {
        let a = SelectionMask.rectangle(x0: 1, y0: 1, x1: 3, y1: 3, width: 5, height: 5)
        let b = SelectionMask.rectangle(x0: 1, y0: 1, x1: 3, y1: 3, width: 5, height: 5)
        assertMasks(a.intersected(with: b), equalTo: a, width: 5, height: 5)
    }

    func testIntersected_disjointMasks_isEmpty() {
        let a = SelectionMask.rectangle(x0: 0, y0: 0, x1: 1, y1: 1, width: 5, height: 5)
        let b = SelectionMask.rectangle(x0: 3, y0: 3, x1: 4, y1: 4, width: 5, height: 5)
        XCTAssertTrue(a.intersected(with: b).isEmpty)
    }

    func testInverted_ofExplicitlyEmptyMask_selectsEverything() {
        let empty = SelectionMask(width: 3, height: 3)
        XCTAssertTrue(empty.isEmpty, "precondition")
        let inverted = empty.inverted()
        for y in 0..<3 {
            for x in 0..<3 {
                XCTAssertTrue(inverted.contains(x: x, y: y), "(\(x),\(y)) must be selected once an empty mask is inverted")
            }
        }
        XCTAssertFalse(inverted.isEmpty)
    }

    // MARK: - boundaryEdges: holes and disconnected regions

    func testBoundaryEdges_donutShape_hasOuterAndInnerRingButNoInternalEdges() {
        let outer = SelectionMask.rectangle(x0: 0, y0: 0, x1: 4, y1: 4, width: 5, height: 5) // full 5x5
        let hole = SelectionMask.rectangle(x0: 2, y0: 2, x1: 2, y1: 2, width: 5, height: 5) // single-pixel hole
        let donut = outer.subtracting(hole)
        // Outer 5x5 perimeter: 4 edges per side * 5 = 20. Inner hole,
        // isolated on all 4 sides by selected pixels: 4 more. 24 total, with
        // nothing extra from any pixel-to-pixel internal boundary.
        XCTAssertEqual(donut.boundaryEdges().count, 24)
    }

    func testBoundaryEdges_twoDisconnectedRegions_bothContributeIndependentBoundaries() {
        let a = SelectionMask.rectangle(x0: 0, y0: 0, x1: 0, y1: 0, width: 6, height: 6)
        let b = SelectionMask.rectangle(x0: 4, y0: 4, x1: 4, y1: 4, width: 6, height: 6)
        let both = a.unioned(with: b)
        // Two isolated single pixels, each with 4 exposed sides, and no
        // shared edge between them (they aren't adjacent) — 8 total.
        XCTAssertEqual(both.boundaryEdges().count, 8)
    }
}
