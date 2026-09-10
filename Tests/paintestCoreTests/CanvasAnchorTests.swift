import XCTest
@testable import paintestCore

/// Covers `CanvasAnchor`'s pure `horizontalFraction`/`verticalFraction`
/// mapping (issue #39) — the 9-point anchor grid `CanvasSizeDialog`'s UI
/// exposes and `LayerStack.resized(toWidth:toHeight:anchor:)` consumes.
final class CanvasAnchorTests: XCTestCase {
    func testHorizontalFraction_leftColumn_isZero() {
        XCTAssertEqual(CanvasAnchor.topLeft.horizontalFraction, 0)
        XCTAssertEqual(CanvasAnchor.left.horizontalFraction, 0)
        XCTAssertEqual(CanvasAnchor.bottomLeft.horizontalFraction, 0)
    }

    func testHorizontalFraction_centerColumn_isOneHalf() {
        XCTAssertEqual(CanvasAnchor.top.horizontalFraction, 0.5)
        XCTAssertEqual(CanvasAnchor.center.horizontalFraction, 0.5)
        XCTAssertEqual(CanvasAnchor.bottom.horizontalFraction, 0.5)
    }

    func testHorizontalFraction_rightColumn_isOne() {
        XCTAssertEqual(CanvasAnchor.topRight.horizontalFraction, 1)
        XCTAssertEqual(CanvasAnchor.right.horizontalFraction, 1)
        XCTAssertEqual(CanvasAnchor.bottomRight.horizontalFraction, 1)
    }

    func testVerticalFraction_topRow_isZero() {
        XCTAssertEqual(CanvasAnchor.topLeft.verticalFraction, 0)
        XCTAssertEqual(CanvasAnchor.top.verticalFraction, 0)
        XCTAssertEqual(CanvasAnchor.topRight.verticalFraction, 0)
    }

    func testVerticalFraction_middleRow_isOneHalf() {
        XCTAssertEqual(CanvasAnchor.left.verticalFraction, 0.5)
        XCTAssertEqual(CanvasAnchor.center.verticalFraction, 0.5)
        XCTAssertEqual(CanvasAnchor.right.verticalFraction, 0.5)
    }

    func testVerticalFraction_bottomRow_isOne() {
        XCTAssertEqual(CanvasAnchor.bottomLeft.verticalFraction, 1)
        XCTAssertEqual(CanvasAnchor.bottom.verticalFraction, 1)
        XCTAssertEqual(CanvasAnchor.bottomRight.verticalFraction, 1)
    }

    func testAllCases_hasExactlyNineAnchors() {
        XCTAssertEqual(CanvasAnchor.allCases.count, 9)
    }
}
