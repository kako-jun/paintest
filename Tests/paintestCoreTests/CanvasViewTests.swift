import AppKit
import XCTest
@testable import paintestCore

final class CanvasViewTests: XCTestCase {
    private func makeView() -> CanvasView {
        CanvasView(layerStack: LayerStack(width: 8, height: 8))
    }

    // MARK: - Zoom transitions (decision table 2-2, all 12 states)

    func testZoom_1_zoomIn_becomes2() {
        let view = makeView()
        view.zoomOut() // 4 -> 2
        view.zoomOut() // 2 -> 1
        XCTAssertEqual(view.zoomScale, 1, "precondition: driven down to the floor")
        view.zoomIn()
        XCTAssertEqual(view.zoomScale, 2)
    }

    func testZoom_1_zoomOut_staysAt1_lowerBound() {
        let view = makeView()
        view.zoomOut()
        view.zoomOut()
        // Drive down to the floor first (default scale is 4).
        XCTAssertEqual(view.zoomScale, 1)
        view.zoomOut()
        XCTAssertEqual(view.zoomScale, 1, "zoomOut at the floor should stay at 1")
    }

    func testZoom_2_zoomIn_becomes4() {
        let view = makeView()
        view.zoomOut() // 4 -> 2
        XCTAssertEqual(view.zoomScale, 2)
        view.zoomIn()
        XCTAssertEqual(view.zoomScale, 4)
    }

    func testZoom_2_zoomOut_becomes1() {
        let view = makeView()
        view.zoomOut() // 4 -> 2
        view.zoomOut() // 2 -> 1
        XCTAssertEqual(view.zoomScale, 1)
    }

    func testZoom_4_zoomIn_becomes8() {
        let view = makeView()
        XCTAssertEqual(view.zoomScale, 4, "default scale is 4")
        view.zoomIn()
        XCTAssertEqual(view.zoomScale, 8)
    }

    func testZoom_4_zoomOut_becomes2() {
        let view = makeView()
        view.zoomOut()
        XCTAssertEqual(view.zoomScale, 2)
    }

    func testZoom_8_zoomIn_becomes16() {
        let view = makeView()
        view.zoomIn() // 4 -> 8
        view.zoomIn() // 8 -> 16
        XCTAssertEqual(view.zoomScale, 16)
    }

    func testZoom_8_zoomOut_becomes4() {
        let view = makeView()
        view.zoomIn() // 4 -> 8
        view.zoomOut() // 8 -> 4
        XCTAssertEqual(view.zoomScale, 4)
    }

    func testZoom_16_zoomIn_becomes32() {
        let view = makeView()
        view.zoomIn() // 4 -> 8
        view.zoomIn() // 8 -> 16
        view.zoomIn() // 16 -> 32
        XCTAssertEqual(view.zoomScale, 32)
    }

    func testZoom_16_zoomOut_becomes8() {
        let view = makeView()
        view.zoomIn() // 4 -> 8
        view.zoomIn() // 8 -> 16
        view.zoomOut() // 16 -> 8
        XCTAssertEqual(view.zoomScale, 8)
    }

    func testZoom_32_zoomIn_staysAt32_upperBound() {
        let view = makeView()
        view.zoomIn() // 4 -> 8
        view.zoomIn() // 8 -> 16
        view.zoomIn() // 16 -> 32
        XCTAssertEqual(view.zoomScale, 32)
        view.zoomIn()
        XCTAssertEqual(view.zoomScale, 32, "zoomIn at the ceiling should stay at 32")
    }

    func testZoom_32_zoomOut_becomes16() {
        let view = makeView()
        view.zoomIn() // 4 -> 8
        view.zoomIn() // 8 -> 16
        view.zoomIn() // 16 -> 32
        view.zoomOut() // 32 -> 16
        XCTAssertEqual(view.zoomScale, 16)
    }

    // MARK: - onZoomChanged callback

    func testOnZoomChanged_firesOnceWithNewScale_onZoomIn() {
        let view = makeView()
        var receivedScales: [Int] = []
        view.onZoomChanged = { receivedScales.append($0) }

        view.zoomIn()

        XCTAssertEqual(receivedScales, [8])
    }

    func testOnZoomChanged_firesOnceWithNewScale_onZoomOut() {
        let view = makeView()
        var receivedScales: [Int] = []
        view.onZoomChanged = { receivedScales.append($0) }

        view.zoomOut()

        XCTAssertEqual(receivedScales, [2])
    }

    func testOnZoomChanged_doesNotFire_whenZoomInIsClampedAtCeiling() {
        let view = makeView()
        view.zoomIn() // 4 -> 8
        view.zoomIn() // 8 -> 16
        view.zoomIn() // 16 -> 32
        var receivedScales: [Int] = []
        view.onZoomChanged = { receivedScales.append($0) }

        view.zoomIn() // clamped, no-op

        XCTAssertTrue(receivedScales.isEmpty, "callback should not fire when zoom is already at the ceiling")
    }

    // MARK: - pixelCoordinate(forPoint:zoomScale:) — pure coordinate math

    func testPixelCoordinate_originAtScale1_mapsToPixelZeroZero() {
        let result = CanvasView.pixelCoordinate(forPoint: NSPoint(x: 0, y: 0), zoomScale: 1)
        XCTAssertEqual(result.x, 0)
        XCTAssertEqual(result.y, 0)
    }

    func testPixelCoordinate_scale4_flooredIntoCorrectCell() {
        // At 4x zoom, view-space x in [8, 12) should map to pixel column 2.
        let result = CanvasView.pixelCoordinate(forPoint: NSPoint(x: 9, y: 9), zoomScale: 4)
        XCTAssertEqual(result.x, 2)
        XCTAssertEqual(result.y, 2)
    }

    func testPixelCoordinate_exactCellBoundary_roundsDownToNextCell() {
        // x = 8 at 4x zoom is exactly the start of pixel column 2, not the
        // end of column 1 — floor(8/4) == 2.
        let result = CanvasView.pixelCoordinate(forPoint: NSPoint(x: 8, y: 8), zoomScale: 4)
        XCTAssertEqual(result.x, 2)
        XCTAssertEqual(result.y, 2)
    }

    func testPixelCoordinate_justBelowCellBoundary_staysInPreviousCell() {
        let result = CanvasView.pixelCoordinate(forPoint: NSPoint(x: 7.9, y: 7.9), zoomScale: 4)
        XCTAssertEqual(result.x, 1)
        XCTAssertEqual(result.y, 1)
    }

    func testPixelCoordinate_xAndYAreNotSwapped() {
        // Asymmetric point catches an x/y transposition bug.
        let result = CanvasView.pixelCoordinate(forPoint: NSPoint(x: 40, y: 12), zoomScale: 4)
        XCTAssertEqual(result.x, 10)
        XCTAssertEqual(result.y, 3)
    }
}
