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

    // MARK: - setZoomScale(_:) — direct zoom assignment (issue #15 follow-up)

    func testSetZoomScale_validValueInZoomLevels_isAccepted() {
        let view = makeView()

        view.setZoomScale(16)

        XCTAssertEqual(view.zoomScale, 16)
    }

    func testSetZoomScale_invalidValueNotInZoomLevels_isIgnored() {
        let view = makeView()
        XCTAssertEqual(view.zoomScale, 4, "precondition: default zoom")

        view.setZoomScale(3) // not in CanvasView.zoomLevels [1, 2, 4, 8, 16, 32]

        XCTAssertEqual(view.zoomScale, 4, "an invalid zoom value must be ignored, not clamped or applied")
    }

    // MARK: - Per-document zoom independence across tab switches (issue #15 follow-up)
    //
    // `CanvasView` itself only ever holds one `zoomScale` at a time — the
    // per-document memory lives on `Document.zoomScale`, and it's
    // `AppDelegate.activateActiveDocument()` that writes the outgoing
    // document's zoom back before applying the incoming one's. That method
    // is private on `AppDelegate` (a whole `NSApplicationDelegate` that
    // builds a real window/menu bar, not practical to unit test directly),
    // so this test reproduces its exact write-back-then-apply protocol
    // directly against `Document` + `CanvasView` to pin down the contract
    // those two types must honor for tab switching to keep zoom independent.

    private func activate(_ incoming: Document, previouslyDisplayed: Document?, on view: CanvasView) {
        previouslyDisplayed?.zoomScale = view.zoomScale
        view.replaceLayerStack(incoming.layerStack)
        view.setZoomScale(incoming.zoomScale)
    }

    func testZoom_perDocument_staysIndependentAcrossTabSwitches() {
        let docA = Document(layerStack: LayerStack(width: 8, height: 8), displayName: "a")
        let docB = Document(layerStack: LayerStack(width: 8, height: 8), displayName: "b")
        let view = CanvasView(layerStack: docA.layerStack)

        view.setZoomScale(8) // "a" zoomed to 200% while it's the displayed document

        activate(docB, previouslyDisplayed: docA, on: view) // switch to "b"
        XCTAssertEqual(view.zoomScale, CanvasView.defaultZoomScale, "\"b\" has never been zoomed and must show its own default, not \"a\"'s 200%")

        activate(docA, previouslyDisplayed: docB, on: view) // switch back to "a"
        XCTAssertEqual(view.zoomScale, 8, "\"a\"'s 200% zoom must be restored, not reset to the default")
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

    // MARK: - mouseDown routes to the active layer only (test list 44-45)
    //
    // Driving `mouseDown(with:)` for real requires an actual `NSEvent` and
    // an `NSWindow` (the view's `convert(_:from:)` needs a window to
    // resolve coordinates), which is more than the rest of this file's
    // pure-function tests need. It is NOT "impossible to unit test" in the
    // sense this project's CLAUDE.md carves out for e.g. `NSAlert.runModal`
    // — it just needs a headless, off-screen window, built here once.
    //
    // Coordinate math: `CanvasView.isFlipped == true` (origin top-left, y
    // grows downward), but `NSEvent.locationInWindow` is always in the
    // window's own bottom-left-origin coordinate system. Since this test's
    // view fills its window exactly, `convert(_:from: nil)` maps a window
    // point (wx, wy) to the flipped view point (wx, viewHeight - wy).
    // `windowPoint(forPixelCol:row:)` below inverts that so the caller can
    // specify the *target pixel*, not the window-space point.

    private func makeViewInWindow(width: Int, height: Int, zoomScale: Int = 4) -> CanvasView {
        let stack = LayerStack(width: width, height: height, background: .white)
        let view = CanvasView(layerStack: stack)
        let viewSize = NSSize(width: width * zoomScale, height: height * zoomScale)
        view.frame = NSRect(origin: .zero, size: viewSize)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        return view
    }

    private func windowPoint(forPixelCol col: Int, row: Int, zoomScale: Int, viewHeight: CGFloat) -> NSPoint {
        let x = CGFloat(col * zoomScale) + 1 // +1: anywhere inside the target pixel's cell, not on its edge
        let y = viewHeight - CGFloat(row * zoomScale) - 1
        return NSPoint(x: x, y: y)
    }

    private func mouseDownEvent(at windowPoint: NSPoint, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: windowPoint,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }

    private func mouseDraggedEvent(at windowPoint: NSPoint, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: windowPoint,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }

    func testMouseDown_paintsOnlyTheActiveLayer_leavesOtherLayersUntouched() {
        let zoomScale = 4
        let view = makeViewInWindow(width: 8, height: 8, zoomScale: zoomScale)
        view.layerStack.addLayer() // index 1, becomes active; bottom layer (index 0) is white
        view.foregroundColor = .black

        let targetPoint = windowPoint(forPixelCol: 2, row: 2, zoomScale: zoomScale, viewHeight: view.frame.height)
        view.mouseDown(with: mouseDownEvent(at: targetPoint, in: view.window!))

        let activePixel = view.layerStack.activeLayer.canvas.rawPixel(x: 2, y: 2)
        XCTAssertEqual(activePixel?.r, 0, "mouseDown should paint onto the active layer")

        let bottomLayerPixel = view.layerStack.layers[0].canvas.rawPixel(x: 2, y: 2)
        XCTAssertEqual(bottomLayerPixel?.r, 255, "the non-active bottom layer must be left untouched")
    }

    func testMouseDown_onHiddenActiveLayer_writesThePixelButCompositeIsUnaffected() {
        let zoomScale = 4
        let view = makeViewInWindow(width: 8, height: 8, zoomScale: zoomScale)
        view.layerStack.addLayer() // index 1, becomes active
        view.layerStack.setVisibility(false, at: view.layerStack.activeLayerIndex)
        view.foregroundColor = .black

        let targetPoint = windowPoint(forPixelCol: 3, row: 3, zoomScale: zoomScale, viewHeight: view.frame.height)
        view.mouseDown(with: mouseDownEvent(at: targetPoint, in: view.window!))

        let activePixel = view.layerStack.activeLayer.canvas.rawPixel(x: 3, y: 3)
        XCTAssertEqual(activePixel?.r, 0, "the pixel write itself still happens on the hidden layer's own canvas")

        guard let composite = view.layerStack.compositeImage() else {
            XCTFail("compositeImage() returned nil")
            return
        }
        let rep = NSBitmapImageRep(cgImage: composite)
        let compositeColor = rep.colorAt(x: 3, y: 3)?.usingColorSpace(.deviceRGB)?.redComponent
        XCTAssertEqual(compositeColor ?? 0, 1, accuracy: 0.01, "a hidden layer's paint must not show up in the composite")
    }

    // MARK: - onLayerContentChanged callback (issue #8 review S4)
    //
    // Mirrors the `onZoomChanged` callback tests above: `onLayerContentChanged`
    // previously had no direct test at all, even though `LayerPanelView`'s
    // thumbnails depend entirely on it firing after every pixel-editing
    // gesture.

    func testMouseDown_notifiesOnLayerContentChanged() {
        let zoomScale = 4
        let view = makeViewInWindow(width: 8, height: 8, zoomScale: zoomScale)
        view.foregroundColor = .black
        var notifiedCount = 0
        view.onLayerContentChanged = { notifiedCount += 1 }

        let targetPoint = windowPoint(forPixelCol: 2, row: 2, zoomScale: zoomScale, viewHeight: view.frame.height)
        view.mouseDown(with: mouseDownEvent(at: targetPoint, in: view.window!))

        XCTAssertEqual(notifiedCount, 1, "onLayerContentChanged should fire once after a mouseDown paints a pixel")
    }

    func testMouseDragged_notifiesOnLayerContentChanged() {
        let zoomScale = 4
        let view = makeViewInWindow(width: 8, height: 8, zoomScale: zoomScale)
        view.foregroundColor = .black
        let startPoint = windowPoint(forPixelCol: 2, row: 2, zoomScale: zoomScale, viewHeight: view.frame.height)
        view.mouseDown(with: mouseDownEvent(at: startPoint, in: view.window!))
        var notifiedCount = 0
        view.onLayerContentChanged = { notifiedCount += 1 }

        let dragPoint = windowPoint(forPixelCol: 3, row: 2, zoomScale: zoomScale, viewHeight: view.frame.height)
        view.mouseDragged(with: mouseDraggedEvent(at: dragPoint, in: view.window!))

        XCTAssertEqual(notifiedCount, 1, "onLayerContentChanged should fire once after a mouseDragged paints along the stroke")
    }

    // MARK: - activeTool / paintColor (issue #5)
    //
    // The eraser is not a separate "make transparent" code path — it's the
    // pencil, but painting with `backgroundColor` instead of
    // `foregroundColor` (see `CanvasView.paintColor`). These tests drive
    // that through the real `mouseDown`/`mouseDragged` entry points, reusing
    // the off-screen-window helpers above.

    func testActiveTool_defaultIsPencil() {
        let view = makeView()
        XCTAssertEqual(view.activeTool, .pencil)
    }

    func testBackgroundColor_defaultIsWhite() {
        let view = makeView()
        XCTAssertEqual(view.backgroundColor, .white)
    }

    func testMouseDown_withPencilActive_paintsWithForegroundColor() {
        let zoomScale = 4
        let view = makeViewInWindow(width: 8, height: 8, zoomScale: zoomScale)
        view.activeTool = .pencil
        view.foregroundColor = .black
        view.backgroundColor = .white

        let targetPoint = windowPoint(forPixelCol: 2, row: 2, zoomScale: zoomScale, viewHeight: view.frame.height)
        view.mouseDown(with: mouseDownEvent(at: targetPoint, in: view.window!))

        let pixel = view.layerStack.activeLayer.canvas.rawPixel(x: 2, y: 2)
        XCTAssertEqual(pixel?.r, 0, "the pencil should paint with the foreground color")
    }

    func testMouseDown_withEraserActive_paintsWithBackgroundColorNotForeground() {
        let zoomScale = 4
        let view = makeViewInWindow(width: 8, height: 8, zoomScale: zoomScale)
        view.activeTool = .eraser
        view.foregroundColor = .black
        view.backgroundColor = NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1)

        let targetPoint = windowPoint(forPixelCol: 2, row: 2, zoomScale: zoomScale, viewHeight: view.frame.height)
        view.mouseDown(with: mouseDownEvent(at: targetPoint, in: view.window!))

        let pixel = view.layerStack.activeLayer.canvas.rawPixel(x: 2, y: 2)
        XCTAssertEqual(pixel?.r, 255, "the eraser should paint with the background color, not the foreground color")
        XCTAssertEqual(pixel?.g, 0)
        XCTAssertEqual(pixel?.b, 0)
    }

    func testMouseDragged_withEraserActive_paintsTheLineWithBackgroundColor() {
        let zoomScale = 4
        let view = makeViewInWindow(width: 8, height: 8, zoomScale: zoomScale)
        view.activeTool = .eraser
        view.foregroundColor = .black
        view.backgroundColor = NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1)

        let startPoint = windowPoint(forPixelCol: 2, row: 2, zoomScale: zoomScale, viewHeight: view.frame.height)
        view.mouseDown(with: mouseDownEvent(at: startPoint, in: view.window!))
        let dragPoint = windowPoint(forPixelCol: 4, row: 2, zoomScale: zoomScale, viewHeight: view.frame.height)
        view.mouseDragged(with: mouseDraggedEvent(at: dragPoint, in: view.window!))

        let midPixel = view.layerStack.activeLayer.canvas.rawPixel(x: 3, y: 2)
        XCTAssertEqual(midPixel?.r, 255, "the line drawn between mouseDown and mouseDragged must use the background color, not the foreground color")
        XCTAssertEqual(midPixel?.g, 0)
        XCTAssertEqual(midPixel?.b, 0)
    }
}
