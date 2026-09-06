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

    // MARK: - bestFitZoomLevel(forPixelSize:viewportSize:levels:) — pure
    // zoom-selection math for the magnifier's drag-to-zoom (issue #13).
    // Minimal smoke coverage here; deeper test-case design is a follow-up
    // for a dedicated test-authoring pass.

    func testBestFitZoomLevel_picksLargestLevelThatFits() {
        // A 10x10 pixel selection in a 100x100 viewport fits at 8x (80x80)
        // but not at 16x (160x160).
        let level = CanvasView.bestFitZoomLevel(
            forPixelSize: (width: 10, height: 10),
            viewportSize: NSSize(width: 100, height: 100),
            levels: CanvasView.zoomLevels
        )
        XCTAssertEqual(level, 8)
    }

    func testBestFitZoomLevel_fallsBackToSmallestLevel_whenNothingFits() {
        // A selection larger than the viewport even at the smallest level
        // (1x) still returns that smallest level as a best-effort fallback,
        // rather than crashing or returning something outside `levels`.
        let level = CanvasView.bestFitZoomLevel(
            forPixelSize: (width: 500, height: 500),
            viewportSize: NSSize(width: 100, height: 100),
            levels: CanvasView.zoomLevels
        )
        XCTAssertEqual(level, CanvasView.zoomLevels.first)
    }

    func testBestFitZoomLevel_exactFit_isIncluded() {
        // Exactly filling the viewport at a given level should still count
        // as "fits" (`<=`, not `<`).
        let level = CanvasView.bestFitZoomLevel(
            forPixelSize: (width: 25, height: 25),
            viewportSize: NSSize(width: 100, height: 100),
            levels: CanvasView.zoomLevels
        )
        XCTAssertEqual(level, 4)
    }

    func testBestFitZoomLevel_nonSquareSelection_bindsToTheMoreRestrictiveDimension() {
        // A 5x10 selection in a 100x100 viewport: width alone would allow up
        // to 16x (5*16=80<=100, 5*32=160>100), but height alone only allows
        // up to 8x (10*8=80<=100, 10*16=160>100). Both dimensions must fit
        // simultaneously, so the tighter (height) constraint wins and the
        // answer is 8, not width's looser 16.
        let level = CanvasView.bestFitZoomLevel(
            forPixelSize: (width: 5, height: 10),
            viewportSize: NSSize(width: 100, height: 100),
            levels: CanvasView.zoomLevels
        )
        XCTAssertEqual(level, 8, "the level must fit BOTH dimensions, not just the looser one")
    }

    func testBestFitZoomLevel_gappyLevels_picksTheAvailableLevelBelowTheIdealOne() {
        // With a 2x2 selection in a 10x10 viewport, the ideal level would be
        // somewhere around 4-5x, but `levels` only offers 1, 4, and 32 here
        // (a gap where 2, 8, 16 would normally sit): 4x2=8<=10 fits, but the
        // next available level, 32, doesn't (32*2=64>10). The answer must be
        // the highest level that actually appears in `levels`, not an
        // interpolated value.
        let level = CanvasView.bestFitZoomLevel(
            forPixelSize: (width: 2, height: 2),
            viewportSize: NSSize(width: 10, height: 10),
            levels: [1, 4, 32]
        )
        XCTAssertEqual(level, 4)
    }

    func testBestFitZoomLevel_viewportNarrowInOneDimensionOnly_stillFitsBothAxes() {
        // A wide-but-short viewport (200x20): the width axis alone would
        // tolerate up to 16x (10*16=160<=200), but the short height axis
        // caps it at 2x (10*2=20<=20, 10*4=40>20). The fit check must apply
        // per-axis even when only one axis is actually the bottleneck.
        let level = CanvasView.bestFitZoomLevel(
            forPixelSize: (width: 10, height: 10),
            viewportSize: NSSize(width: 200, height: 20),
            levels: CanvasView.zoomLevels
        )
        XCTAssertEqual(level, 2)
    }

    func testBestFitZoomLevel_emptyLevels_fallsBackTo1_doesNotCrash() {
        // No supported zoom levels at all is a degenerate input this
        // function must survive without crashing, falling back to a sane
        // default of 1 rather than force-unwrapping `levels.first`.
        let level = CanvasView.bestFitZoomLevel(
            forPixelSize: (width: 10, height: 10),
            viewportSize: NSSize(width: 100, height: 100),
            levels: []
        )
        XCTAssertEqual(level, 1)
    }

    func testBestFitZoomLevel_singleLevelThatFits_returnsThatLevel() {
        let level = CanvasView.bestFitZoomLevel(
            forPixelSize: (width: 10, height: 10),
            viewportSize: NSSize(width: 100, height: 100),
            levels: [8]
        )
        XCTAssertEqual(level, 8)
    }

    func testBestFitZoomLevel_singleLevelThatDoesNotFit_stillReturnsThatLevelAsFallback() {
        let level = CanvasView.bestFitZoomLevel(
            forPixelSize: (width: 500, height: 500),
            viewportSize: NSSize(width: 100, height: 100),
            levels: [8]
        )
        XCTAssertEqual(level, 8, "with only one level offered, it must be returned even when it doesn't fit")
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

    private func mouseDownEvent(at windowPoint: NSPoint, in window: NSWindow, modifierFlags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: windowPoint,
            modifierFlags: modifierFlags,
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

    /// `mouseUp(with:)`'s magnifier branch (issue #13) never reads
    /// `event.locationInWindow` — only `event.modifierFlags` — since the
    /// drag rectangle's start/current points are already captured in
    /// `magnifierDragStart`/`magnifierDragCurrent` by prior `mouseDown`/
    /// `mouseDragged` calls. `windowPoint` here is therefore a required but
    /// functionally inert argument for this event type; `modifierFlags` is
    /// what actually matters for Option-click zoom-out.
    private func mouseUpEvent(at windowPoint: NSPoint, in window: NSWindow, modifierFlags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: windowPoint,
            modifierFlags: modifierFlags,
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

    // MARK: - Pen tool routes through the antialiased path (issue #10)
    //
    // `PixelCanvasTests` already covers `drawAntialiasedDot`/
    // `drawAntialiasedLine` in isolation, but before this pair, nothing
    // exercised `.pen` through `CanvasView`'s real `mouseDown`/
    // `mouseDragged` entry points at all — the integration wiring in
    // `CanvasView.paint(at:)`/`paintLine(from:to:)` that picks the
    // antialiased path for `.pen` (vs. `setPixel`/`drawLine` for
    // `.pencil`/`.eraser`) had no test of its own.

    func testMouseDown_withPenActive_paintsWithAntialiasing() {
        let zoomScale = 4
        let view = makeViewInWindow(width: 8, height: 8, zoomScale: zoomScale)
        view.activeTool = .pen
        view.foregroundColor = .black
        view.backgroundColor = .white

        let targetPoint = windowPoint(forPixelCol: 4, row: 4, zoomScale: zoomScale, viewHeight: view.frame.height)
        view.mouseDown(with: mouseDownEvent(at: targetPoint, in: view.window!))

        let center = view.layerStack.activeLayer.canvas.rawPixel(x: 4, y: 4)
        XCTAssertLessThan(center?.r ?? 255, 255, "the pen should have painted with the foreground color at the click point")

        // The defining signature of the antialiased path (vs. `setPixel`'s
        // hard 0/255 edges): somewhere around the dot's rim there must be a
        // partially-covered, non-binary value.
        var foundPartialCoverage = false
        for y in 3...5 {
            for x in 3...5 {
                guard let pixel = view.layerStack.activeLayer.canvas.rawPixel(x: x, y: y) else { continue }
                if pixel.r != 0, pixel.r != 255 {
                    foundPartialCoverage = true
                }
            }
        }
        XCTAssertTrue(foundPartialCoverage, "a pen dot should have a soft, anti-aliased edge — the setPixel path never produces this")
    }

    func testMouseDragged_withPenActive_paintsAntialiasedLine() {
        let zoomScale = 4
        let view = makeViewInWindow(width: 8, height: 8, zoomScale: zoomScale)
        view.activeTool = .pen
        view.foregroundColor = .black
        view.backgroundColor = .white

        let startPoint = windowPoint(forPixelCol: 1, row: 4, zoomScale: zoomScale, viewHeight: view.frame.height)
        view.mouseDown(with: mouseDownEvent(at: startPoint, in: view.window!))
        let dragPoint = windowPoint(forPixelCol: 6, row: 4, zoomScale: zoomScale, viewHeight: view.frame.height)
        view.mouseDragged(with: mouseDraggedEvent(at: dragPoint, in: view.window!))

        let midpoint = view.layerStack.activeLayer.canvas.rawPixel(x: 4, y: 4)
        XCTAssertLessThan(midpoint?.r ?? 255, 255, "the stroke should be painted along the dragged path")

        // `drawLine` (pencil/eraser) is exactly 1px wide with hard edges;
        // `drawAntialiasedLine` (pen) is round-capped and soft-edged
        // (issue #10's fixed pen line width), so around its rounded end
        // caps there should be partial (non-binary) coverage instead of
        // either staying untouched white or being hard-painted black.
        // (Empirically confirmed: along the straight middle of the stroke
        // the coverage is a hard 0/255 edge here too, since a horizontal
        // stroke's vertical extent happens to land exactly on the pixel
        // grid — it's specifically the round caps at the ends that expose
        // the anti-aliasing this test is after.)
        var foundPartialCoverage = false
        for (x, y) in [(1, 3), (1, 5), (6, 3), (6, 5)] {
            guard let pixel = view.layerStack.activeLayer.canvas.rawPixel(x: x, y: y) else { continue }
            if pixel.r != 0, pixel.r != 255 {
                foundPartialCoverage = true
            }
        }
        XCTAssertTrue(foundPartialCoverage, "an antialiased stroke's round end caps should show partial coverage — drawLine's hard 1px edge never does this")
    }

    // MARK: - Eyedropper tool (issue #14)
    //
    // The eyedropper is a "one-shot" tool (see `Tool.eyedropper`'s doc
    // comment): `mouseDown` samples the composite and fires
    // `onColorPicked`, `mouseDragged` is a deliberate no-op, and neither
    // ever reaches `paint(at:)`/`paintLine(from:to:)` or notifies
    // `onLayerContentChanged` — sampling a color is not an edit.

    /// Rounds an `NSColor` to byte-exact RGB, reading its components
    /// directly with no `usingColorSpace(_:)` conversion. `sampleColor(at:)`
    /// reads the picked color straight off an `NSBitmapImageRep`, and that
    /// color already comes back in an RGB-model color space with the exact
    /// same component values it was painted with (confirmed empirically:
    /// painting `NSColor(deviceRed: 1, green: 0, blue: 0)` and reading it
    /// straight back gives `(1, 0, 0)`). Explicitly converting to `.sRGB`
    /// or `.deviceRGB` first — as you would to compare two colors of
    /// *unknown* space — actually introduces drift here, because the
    /// picked color's own space ("Generic RGB") differs from both and a
    /// real gamut conversion isn't a no-op for saturated primaries like
    /// red (empirically off by ~38/255 on the green channel).
    private func byteRGB(of color: NSColor?) -> (r: UInt8, g: UInt8, b: UInt8)? {
        guard let color else { return nil }
        let r = UInt8(max(0, min(255, (color.redComponent * 255).rounded())))
        let g = UInt8(max(0, min(255, (color.greenComponent * 255).rounded())))
        let b = UInt8(max(0, min(255, (color.blueComponent * 255).rounded())))
        return (r, g, b)
    }

    private let eyedropperKnownColor = NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1) // pure red

    func testMouseDown_withEyedropperActive_firesOnColorPickedWithPixelColor() {
        let zoomScale = 4
        let view = makeViewInWindow(width: 8, height: 8, zoomScale: zoomScale)
        view.layerStack.activeLayer.canvas.setPixel(x: 2, y: 2, color: eyedropperKnownColor)
        view.activeTool = .eyedropper
        var pickedColors: [(color: NSColor, isSecondary: Bool)] = []
        view.onColorPicked = { pickedColors.append(($0, $1)) }

        let targetPoint = windowPoint(forPixelCol: 2, row: 2, zoomScale: zoomScale, viewHeight: view.frame.height)
        view.mouseDown(with: mouseDownEvent(at: targetPoint, in: view.window!))

        XCTAssertEqual(pickedColors.count, 1, "onColorPicked should fire exactly once")
        XCTAssertEqual(byteRGB(of: pickedColors.first?.color)?.r, 255)
        XCTAssertEqual(byteRGB(of: pickedColors.first?.color)?.g, 0)
        XCTAssertEqual(byteRGB(of: pickedColors.first?.color)?.b, 0)
        XCTAssertEqual(pickedColors.first?.isSecondary, false, "a plain click (no Option) must report the foreground slot")
    }

    func testMouseDown_withEyedropperActive_optionHeld_firesOnColorPickedWithIsSecondaryTrue() {
        let zoomScale = 4
        let view = makeViewInWindow(width: 8, height: 8, zoomScale: zoomScale)
        view.layerStack.activeLayer.canvas.setPixel(x: 2, y: 2, color: eyedropperKnownColor)
        view.activeTool = .eyedropper
        var isSecondary: Bool?
        view.onColorPicked = { _, secondary in isSecondary = secondary }

        let targetPoint = windowPoint(forPixelCol: 2, row: 2, zoomScale: zoomScale, viewHeight: view.frame.height)
        view.mouseDown(with: mouseDownEvent(at: targetPoint, in: view.window!, modifierFlags: [.option]))

        XCTAssertEqual(isSecondary, true, "Option-click must report the background slot")
    }

    func testMouseDown_withEyedropperActive_doesNotPaintOrNotifyLayerContentChanged() {
        let zoomScale = 4
        let view = makeViewInWindow(width: 8, height: 8, zoomScale: zoomScale)
        view.activeTool = .eyedropper
        view.foregroundColor = .black
        var notifiedCount = 0
        view.onLayerContentChanged = { notifiedCount += 1 }
        let before = view.layerStack.activeLayer.canvas.rawPixel(x: 2, y: 2)

        let targetPoint = windowPoint(forPixelCol: 2, row: 2, zoomScale: zoomScale, viewHeight: view.frame.height)
        view.mouseDown(with: mouseDownEvent(at: targetPoint, in: view.window!))

        let after = view.layerStack.activeLayer.canvas.rawPixel(x: 2, y: 2)
        XCTAssertEqual(before?.r, after?.r, "the eyedropper must never write a pixel")
        XCTAssertEqual(before?.g, after?.g)
        XCTAssertEqual(before?.b, after?.b)
        XCTAssertEqual(before?.a, after?.a)
        XCTAssertEqual(notifiedCount, 0, "sampling a color is not an edit and must not notify onLayerContentChanged")
    }

    func testMouseDown_withEyedropperActive_samplesCompositeAcrossLayers() {
        let zoomScale = 4
        let view = makeViewInWindow(width: 8, height: 8, zoomScale: zoomScale)
        // Bottom layer (index 0) carries the known color; the active
        // (top) layer added below stays fully transparent at that pixel.
        // If the eyedropper read the active layer alone instead of the
        // composite, it would pick up transparent/black here instead.
        view.layerStack.layers[0].canvas.setPixel(x: 2, y: 2, color: eyedropperKnownColor)
        view.layerStack.addLayer() // index 1, becomes active; transparent
        view.activeTool = .eyedropper
        var pickedColor: NSColor?
        view.onColorPicked = { color, _ in pickedColor = color }

        let targetPoint = windowPoint(forPixelCol: 2, row: 2, zoomScale: zoomScale, viewHeight: view.frame.height)
        view.mouseDown(with: mouseDownEvent(at: targetPoint, in: view.window!))

        XCTAssertEqual(byteRGB(of: pickedColor)?.r, 255, "the eyedropper must sample the visible composite, not just the active layer's own contents")
        XCTAssertEqual(byteRGB(of: pickedColor)?.g, 0)
        XCTAssertEqual(byteRGB(of: pickedColor)?.b, 0)
    }

    func testMouseDown_withEyedropperActive_samplesSemitransparentPixelCorrectly() {
        // `compositeImage()` composites into a `CGImageAlphaInfo.premultipliedLast`
        // context (see `LayerStack.compositeImage()`), and `PixelCanvas`'s own
        // bitmap is `.alphaNonpremultiplied` (see `PixelCanvas.makeBitmap`'s doc
        // comment) — so a semitransparent pixel goes through a premultiply (on
        // the way into the composite context) and an un-premultiply (`colorAt`
        // reading the resulting `CGImage` back out) round trip that a fully
        // opaque pixel (alpha 255) never exercises, since premultiplying by 1.0
        // is a no-op. With only a single visible layer and the composite
        // context starting out fully transparent (all-zero), source-over
        // blending contributes nothing from the (empty) destination, so the
        // math reduces to: premultiply(r, g, b, a) = (r*a/255, g*a/255, b*a/255,
        // a), then un-premultiply divides back out by the same alpha. This is
        // exactly the kind of premultiplied/non-premultiplied mismatch
        // `PixelCanvas.makeBitmap`'s `.alphaNonpremultiplied` doc comment
        // warns has bitten this codebase before — empirically confirmed here,
        // though, the round trip comes back byte-exact for alpha 128 (no
        // drift), unlike `byteRGB(of:)`'s documented ~38/255 color-space
        // drift on the green channel.
        let zoomScale = 4
        let view = makeViewInWindow(width: 8, height: 8, zoomScale: zoomScale)
        let semitransparentRed = NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 128.0 / 255.0)
        view.layerStack.activeLayer.canvas.setPixel(x: 2, y: 2, color: semitransparentRed)
        view.activeTool = .eyedropper
        var pickedColor: NSColor?
        view.onColorPicked = { color, _ in pickedColor = color }

        let targetPoint = windowPoint(forPixelCol: 2, row: 2, zoomScale: zoomScale, viewHeight: view.frame.height)
        view.mouseDown(with: mouseDownEvent(at: targetPoint, in: view.window!))

        let picked = byteRGB(of: pickedColor)
        let pickedAlpha = pickedColor.map { UInt8(max(0, min(255, ($0.alphaComponent * 255).rounded()))) }
        XCTAssertEqual(picked?.r, 255, "red channel must survive the premultiply/un-premultiply round trip")
        XCTAssertEqual(picked?.g, 0)
        XCTAssertEqual(picked?.b, 0)
        XCTAssertEqual(pickedAlpha, 128, "alpha itself must survive the round trip (un-premultiplying must not also divide down the alpha channel, nor leave it at the premultiplied source's own alpha unchanged by coincidence)")
    }

    func testMouseDown_withEyedropperActive_atTopLeftCorner_firesOnColorPicked() {
        let zoomScale = 4
        let view = makeViewInWindow(width: 8, height: 8, zoomScale: zoomScale)
        view.activeTool = .eyedropper
        var firedCount = 0
        view.onColorPicked = { _, _ in firedCount += 1 }

        let targetPoint = windowPoint(forPixelCol: 0, row: 0, zoomScale: zoomScale, viewHeight: view.frame.height)
        view.mouseDown(with: mouseDownEvent(at: targetPoint, in: view.window!))

        XCTAssertEqual(firedCount, 1, "the top-left corner pixel (0, 0) is in bounds and must fire")
    }

    func testMouseDown_withEyedropperActive_atBottomRightCorner_firesOnColorPicked() {
        let zoomScale = 4
        let width = 8
        let height = 8
        let view = makeViewInWindow(width: width, height: height, zoomScale: zoomScale)
        view.activeTool = .eyedropper
        var firedCount = 0
        view.onColorPicked = { _, _ in firedCount += 1 }

        let targetPoint = windowPoint(forPixelCol: width - 1, row: height - 1, zoomScale: zoomScale, viewHeight: view.frame.height)
        view.mouseDown(with: mouseDownEvent(at: targetPoint, in: view.window!))

        XCTAssertEqual(firedCount, 1, "the bottom-right corner pixel (width-1, height-1) is in bounds and must fire")
    }

    func testMouseDown_withEyedropperActive_atNegativeCoordinate_doesNotFireOnColorPicked() {
        let zoomScale = 4
        let view = makeViewInWindow(width: 8, height: 8, zoomScale: zoomScale)
        view.activeTool = .eyedropper
        var firedCount = 0
        view.onColorPicked = { _, _ in firedCount += 1 }

        let targetPoint = windowPoint(forPixelCol: -1, row: -1, zoomScale: zoomScale, viewHeight: view.frame.height)
        view.mouseDown(with: mouseDownEvent(at: targetPoint, in: view.window!))

        XCTAssertEqual(firedCount, 0, "a click resolving to pixel (-1, -1) is out of bounds and must not fire")
    }

    func testMouseDown_withEyedropperActive_atWidthHeightCoordinate_doesNotFireOnColorPicked() {
        let zoomScale = 4
        let width = 8
        let height = 8
        let view = makeViewInWindow(width: width, height: height, zoomScale: zoomScale)
        view.activeTool = .eyedropper
        var firedCount = 0
        view.onColorPicked = { _, _ in firedCount += 1 }

        let targetPoint = windowPoint(forPixelCol: width, row: height, zoomScale: zoomScale, viewHeight: view.frame.height)
        view.mouseDown(with: mouseDownEvent(at: targetPoint, in: view.window!))

        XCTAssertEqual(firedCount, 0, "a click resolving to pixel (width, height) is one past the last valid index and must not fire")
    }

    func testMouseDragged_withEyedropperActive_isNoOp_doesNotFireOnColorPickedAgainOrPaint() {
        let zoomScale = 4
        let view = makeViewInWindow(width: 8, height: 8, zoomScale: zoomScale)
        view.layerStack.activeLayer.canvas.setPixel(x: 2, y: 2, color: eyedropperKnownColor)
        view.activeTool = .eyedropper
        var firedCount = 0
        view.onColorPicked = { _, _ in firedCount += 1 }
        let startPoint = windowPoint(forPixelCol: 2, row: 2, zoomScale: zoomScale, viewHeight: view.frame.height)
        view.mouseDown(with: mouseDownEvent(at: startPoint, in: view.window!))
        XCTAssertEqual(firedCount, 1, "precondition: mouseDown already fired once")
        let dragTargetBefore = view.layerStack.activeLayer.canvas.rawPixel(x: 4, y: 2)

        let dragPoint = windowPoint(forPixelCol: 4, row: 2, zoomScale: zoomScale, viewHeight: view.frame.height)
        view.mouseDragged(with: mouseDraggedEvent(at: dragPoint, in: view.window!))

        XCTAssertEqual(firedCount, 1, "dragging with the eyedropper active must not fire onColorPicked again")
        let dragTargetAfter = view.layerStack.activeLayer.canvas.rawPixel(x: 4, y: 2)
        XCTAssertEqual(dragTargetBefore?.r, dragTargetAfter?.r, "dragging with the eyedropper active must not paint")
        XCTAssertEqual(dragTargetBefore?.g, dragTargetAfter?.g)
        XCTAssertEqual(dragTargetBefore?.b, dragTargetAfter?.b)
        XCTAssertEqual(dragTargetBefore?.a, dragTargetAfter?.a)
    }

    // MARK: - Magnifier tool: mouseUp click-vs-drag + zoom (issue #13)
    //
    // Option's role is deliberately narrow, matching Photoshop's own
    // magnifier: it only flips a *click*'s direction (in -> out).
    // `mouseUp(with:)` never reads `event.modifierFlags` in the drag
    // (rectangle-zoom) branch at all — a drag always best-fit-zooms in,
    // Option held or not. That is confirmed as intentional, not a gap, by
    // `testMouseUp_magnifierOptionDrag_optionIsIgnored_bestFitZoomStillApplies`
    // below.
    //
    // All views here come from `makeViewInWindow`, which (like real
    // `AppDelegate` construction is expected to, per `centerScroll`'s doc
    // comment) has no `NSScrollView` ancestor — so `enclosingScrollView` is
    // always `nil` in this section, exercising the `?? bounds.size` /
    // early-return fallbacks throughout `mouseUp`/`centerScroll` on every
    // single test below, not just the dedicated one at the end.
    //
    // Horizontal-only drags at window y = 16 (the exact vertical midpoint of
    // the 32pt-tall window) are used throughout so the view's y-flip
    // (`convert(_:from: nil)`) never has to be reasoned about: it maps
    // (x, 16) to the same (x, 16) in view space.

    private func makeMagnifierViewInWindow(zoomScale: Int = 4) -> CanvasView {
        let view = makeViewInWindow(width: 8, height: 8, zoomScale: zoomScale)
        view.activeTool = .magnifier
        return view
    }

    func testMouseUp_magnifierDragAtExactClickThreshold_isTreatedAsADrag_notAClick() {
        // `magnifierClickThreshold` is 4 view-points and the comparison is
        // `distance < threshold`, so a distance of exactly 4 must NOT count
        // as a click. Pins the `<` (not `<=`) direction of that comparison:
        // a plain click here would zoomIn() to 8, but the drag branch's
        // best-fit computation for this exact rectangle lands on 32 — a
        // value only reachable via the drag path.
        let view = makeMagnifierViewInWindow()
        let window = view.window!
        view.mouseDown(with: mouseDownEvent(at: NSPoint(x: 10, y: 16), in: window))
        view.mouseDragged(with: mouseDraggedEvent(at: NSPoint(x: 14, y: 16), in: window)) // distance == 4

        view.mouseUp(with: mouseUpEvent(at: NSPoint(x: 14, y: 16), in: window))

        XCTAssertEqual(view.zoomScale, 32, "distance == threshold must take the drag/best-fit branch (32), not the click/zoomIn branch (8)")
    }

    func testMouseUp_magnifierDragBelowClickThreshold_isTreatedAsAClick_zoomsIn() {
        let view = makeMagnifierViewInWindow()
        let window = view.window!
        view.mouseDown(with: mouseDownEvent(at: NSPoint(x: 10, y: 16), in: window))
        view.mouseDragged(with: mouseDraggedEvent(at: NSPoint(x: 13, y: 16), in: window)) // distance == 3, below threshold

        view.mouseUp(with: mouseUpEvent(at: NSPoint(x: 13, y: 16), in: window))

        XCTAssertEqual(view.zoomScale, 8, "a sub-threshold drag distance must be treated as a plain click and zoom in one step (4 -> 8)")
    }

    func testMouseUp_magnifierDragAboveClickThreshold_isTreatedAsADrag_bestFitZooms() {
        let view = makeMagnifierViewInWindow()
        let window = view.window!
        view.mouseDown(with: mouseDownEvent(at: NSPoint(x: 2, y: 16), in: window))
        view.mouseDragged(with: mouseDraggedEvent(at: NSPoint(x: 11, y: 16), in: window)) // distance == 9

        view.mouseUp(with: mouseUpEvent(at: NSPoint(x: 11, y: 16), in: window))

        XCTAssertEqual(view.zoomScale, 16, "a clearly-above-threshold drag must best-fit zoom to the dragged rectangle, not just zoomIn() one step")
    }

    func testMouseUp_magnifierOptionClick_zoomsOutOneStep() {
        let view = makeMagnifierViewInWindow()
        let window = view.window!
        view.mouseDown(with: mouseDownEvent(at: NSPoint(x: 10, y: 16), in: window))
        view.mouseDragged(with: mouseDraggedEvent(at: NSPoint(x: 13, y: 16), in: window)) // distance == 3, a click

        view.mouseUp(with: mouseUpEvent(at: NSPoint(x: 13, y: 16), in: window, modifierFlags: [.option]))

        XCTAssertEqual(view.zoomScale, 2, "Option-click must zoom out one step (4 -> 2), the reverse of a plain click")
    }

    func testMouseUp_magnifierPlainClick_zoomsInOneStep() {
        let view = makeMagnifierViewInWindow()
        let window = view.window!
        view.mouseDown(with: mouseDownEvent(at: NSPoint(x: 10, y: 16), in: window))
        view.mouseDragged(with: mouseDraggedEvent(at: NSPoint(x: 13, y: 16), in: window)) // distance == 3, a click

        view.mouseUp(with: mouseUpEvent(at: NSPoint(x: 13, y: 16), in: window)) // no Option

        XCTAssertEqual(view.zoomScale, 8, "a plain click with no modifier must zoom in one step (4 -> 8)")
    }

    func testMouseUp_magnifierOptionDrag_optionIsIgnored_bestFitZoomStillApplies() {
        // Confirmed-intentional spec (see this file's MARK comment above):
        // Photoshop's own magnifier tool only lets Option reverse a
        // *click*'s direction — it has no effect on a drag's rectangle
        // zoom. `mouseUp(with:)`'s drag branch never even reads
        // `event.modifierFlags`, so holding Option through a drag must
        // produce the exact same best-fit result as not holding it
        // (same rectangle as `testMouseUp_magnifierDragAboveClickThreshold_isTreatedAsADrag_bestFitZooms` -> 16).
        let view = makeMagnifierViewInWindow()
        let window = view.window!
        view.mouseDown(with: mouseDownEvent(at: NSPoint(x: 2, y: 16), in: window))
        view.mouseDragged(with: mouseDraggedEvent(at: NSPoint(x: 11, y: 16), in: window)) // distance == 9

        view.mouseUp(with: mouseUpEvent(at: NSPoint(x: 11, y: 16), in: window, modifierFlags: [.option]))

        XCTAssertEqual(view.zoomScale, 16, "Option held during a drag must be ignored — this is Photoshop's own magnifier behavior, not a bug")
    }

    func testMouseUp_magnifierZeroSizeDrag_startEqualsEnd_isTreatedAsAClick() {
        let view = makeMagnifierViewInWindow()
        let window = view.window!
        view.mouseDown(with: mouseDownEvent(at: NSPoint(x: 10, y: 16), in: window))
        // No mouseDragged call at all: magnifierDragCurrent stays exactly
        // equal to magnifierDragStart, as mouseDown itself set it.

        view.mouseUp(with: mouseUpEvent(at: NSPoint(x: 10, y: 16), in: window))

        XCTAssertEqual(view.zoomScale, 8, "a zero-distance drag (start == end) must be treated as a click and zoom in")
    }

    func testMouseUp_magnifierDragFromNegativeOutOfCanvasCoordinates_doesNotCrash() {
        let view = makeMagnifierViewInWindow()
        let window = view.window!
        // Window x = -20 / -12 both convert to negative pixel columns
        // (floor(-20/4) = -5, floor(-12/4) = -3), well outside the 8x8
        // canvas — the magnifier's drag math must tolerate this.
        view.mouseDown(with: mouseDownEvent(at: NSPoint(x: -20, y: 16), in: window))
        view.mouseDragged(with: mouseDraggedEvent(at: NSPoint(x: -12, y: 16), in: window)) // distance == 8

        view.mouseUp(with: mouseUpEvent(at: NSPoint(x: -12, y: 16), in: window))

        XCTAssertEqual(view.zoomScale, 16, "an out-of-canvas negative-coordinate drag must not crash and must still resolve to a valid best-fit zoom level")
    }

    func testMouseUp_magnifierWithNoEnclosingScrollView_clickAndDragBothUpdateZoomScaleWithoutCrashing() {
        // `makeViewInWindow` deliberately never wraps the view in an
        // `NSScrollView` (its own doc comment notes this is more than its
        // pure-function tests need) — every test above already runs in
        // this no-scroll-view environment, but this test makes the
        // assumption explicit and checks it directly for both gesture
        // kinds, since `centerScroll(onPixelPoint:)` silently no-ops
        // without one while `mouseUp` itself must still update `zoomScale`.
        let clickView = makeMagnifierViewInWindow()
        XCTAssertNil(clickView.enclosingScrollView, "precondition: no NSScrollView ancestor")
        let clickWindow = clickView.window!
        clickView.mouseDown(with: mouseDownEvent(at: NSPoint(x: 10, y: 16), in: clickWindow))
        clickView.mouseUp(with: mouseUpEvent(at: NSPoint(x: 10, y: 16), in: clickWindow))
        XCTAssertEqual(clickView.zoomScale, 8, "a click must still zoom in with no enclosing scroll view")

        let dragView = makeMagnifierViewInWindow()
        XCTAssertNil(dragView.enclosingScrollView, "precondition: no NSScrollView ancestor")
        let dragWindow = dragView.window!
        dragView.mouseDown(with: mouseDownEvent(at: NSPoint(x: 2, y: 16), in: dragWindow))
        dragView.mouseDragged(with: mouseDraggedEvent(at: NSPoint(x: 11, y: 16), in: dragWindow))
        dragView.mouseUp(with: mouseUpEvent(at: NSPoint(x: 11, y: 16), in: dragWindow))
        XCTAssertEqual(dragView.zoomScale, 16, "a drag must still best-fit zoom with no enclosing scroll view")
    }

    func testMouseUp_magnifierWithoutAPriorMouseDown_doesNotCrash_leavesZoomScaleUnchanged() {
        let view = makeMagnifierViewInWindow()
        let window = view.window!
        XCTAssertEqual(view.zoomScale, 4, "precondition: default zoom")

        view.mouseUp(with: mouseUpEvent(at: NSPoint(x: 10, y: 16), in: window))

        XCTAssertEqual(view.zoomScale, 4, "mouseUp with no magnifierDragStart/Current recorded must be a no-op, not a crash")
    }

    func testMouseUp_afterACompletedDrag_aFreshMouseDownDoesNotInheritTheOldDragsPoints() {
        // Indirect check on `magnifierDragStart`/`magnifierDragCurrent`
        // (both private) being correctly re-seeded by `mouseDown`, not left
        // over from the previous drag gesture: if the second `mouseDown`
        // below failed to overwrite the stale rectangle from the first
        // drag, the immediately-following zero-distance `mouseUp` would
        // still see the old, far-apart start/current pair and take the
        // drag/best-fit branch — instead it must see a fresh, equal
        // start/current pair and take the click/zoomIn branch.
        let view = makeMagnifierViewInWindow()
        let window = view.window!

        // First gesture: a real drag, established distance-9 rectangle from
        // the earlier best-fit tests (result: zoomScale 16).
        view.mouseDown(with: mouseDownEvent(at: NSPoint(x: 2, y: 16), in: window))
        view.mouseDragged(with: mouseDraggedEvent(at: NSPoint(x: 11, y: 16), in: window))
        view.mouseUp(with: mouseUpEvent(at: NSPoint(x: 11, y: 16), in: window))
        XCTAssertEqual(view.zoomScale, 16, "precondition: first drag completed as expected")

        // Second gesture: mouseDown at a brand-new point, then mouseUp with
        // no dragging in between at all — a plain click, provided
        // mouseDown correctly reset magnifierDragCurrent to this new point
        // rather than leaving it at the first drag's (11, 16).
        view.mouseDown(with: mouseDownEvent(at: NSPoint(x: 20, y: 20), in: window))
        view.mouseUp(with: mouseUpEvent(at: NSPoint(x: 20, y: 20), in: window))

        XCTAssertEqual(view.zoomScale, 32, "the second mouseDown must have reset the drag state to its own point: a zero-distance click must zoomIn() one step from 16, not re-run the stale first drag's best-fit result")
    }

    // MARK: - Selection tools: basic gesture -> selection (issue #11 test-authoring pass)
    //
    // All five selection tools driven through the same real mouseDown/
    // mouseDragged/mouseUp entry points as the pencil/eraser/pen/eyedropper/
    // magnifier tests above, using the same off-screen-window helpers.

    private func keyDownEvent(keyCode: UInt16, in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    func testMouseDown_rectangleSelect_dragThenUp_confirmsRectangleSelection() {
        let zoomScale = 4
        let view = makeViewInWindow(width: 8, height: 8, zoomScale: zoomScale)
        view.activeTool = .rectangleSelect
        let window = view.window!
        let start = windowPoint(forPixelCol: 2, row: 2, zoomScale: zoomScale, viewHeight: view.frame.height)
        let end = windowPoint(forPixelCol: 5, row: 5, zoomScale: zoomScale, viewHeight: view.frame.height)

        view.mouseDown(with: mouseDownEvent(at: start, in: window))
        view.mouseDragged(with: mouseDraggedEvent(at: end, in: window))
        view.mouseUp(with: mouseUpEvent(at: end, in: window))

        XCTAssertNotNil(view.selection)
        XCTAssertTrue(view.selection!.contains(x: 2, y: 2))
        XCTAssertTrue(view.selection!.contains(x: 5, y: 5))
        XCTAssertFalse(view.selection!.contains(x: 0, y: 0))
    }

    func testMouseDown_ellipseSelect_dragThenUp_confirmsEllipseSelection() {
        let zoomScale = 4
        let view = makeViewInWindow(width: 8, height: 8, zoomScale: zoomScale)
        view.activeTool = .ellipseSelect
        let window = view.window!
        let start = windowPoint(forPixelCol: 2, row: 2, zoomScale: zoomScale, viewHeight: view.frame.height)
        let end = windowPoint(forPixelCol: 5, row: 5, zoomScale: zoomScale, viewHeight: view.frame.height)

        view.mouseDown(with: mouseDownEvent(at: start, in: window))
        view.mouseDragged(with: mouseDraggedEvent(at: end, in: window))
        view.mouseUp(with: mouseUpEvent(at: end, in: window))

        XCTAssertNotNil(view.selection)
        XCTAssertTrue(view.selection!.contains(x: 4, y: 4), "the bounding box's center, well inside the ellipse, must be selected")
        XCTAssertFalse(view.selection!.contains(x: 0, y: 0), "far outside the ellipse's bounding box must not be selected")
    }

    func testMouseDown_lassoSelect_dragThroughMultiplePoints_confirmsFreeformSelection() {
        let zoomScale = 4
        let view = makeViewInWindow(width: 8, height: 8, zoomScale: zoomScale)
        view.activeTool = .lassoSelect
        let window = view.window!

        view.mouseDown(with: mouseDownEvent(at: windowPoint(forPixelCol: 1, row: 1, zoomScale: zoomScale, viewHeight: view.frame.height), in: window))
        view.mouseDragged(with: mouseDraggedEvent(at: windowPoint(forPixelCol: 6, row: 1, zoomScale: zoomScale, viewHeight: view.frame.height), in: window))
        view.mouseDragged(with: mouseDraggedEvent(at: windowPoint(forPixelCol: 6, row: 6, zoomScale: zoomScale, viewHeight: view.frame.height), in: window))
        view.mouseDragged(with: mouseDraggedEvent(at: windowPoint(forPixelCol: 1, row: 6, zoomScale: zoomScale, viewHeight: view.frame.height), in: window))
        view.mouseUp(with: mouseUpEvent(at: windowPoint(forPixelCol: 1, row: 6, zoomScale: zoomScale, viewHeight: view.frame.height), in: window))

        XCTAssertNotNil(view.selection)
        XCTAssertTrue(view.selection!.contains(x: 3, y: 3), "the interior of the dragged square path must be selected")
        XCTAssertFalse(view.selection!.contains(x: 0, y: 0), "outside the dragged path must not be selected")
    }

    func testMouseUp_lassoSelect_fewerThanThreePoints_leavesSelectionUnchanged() {
        let zoomScale = 4
        let view = makeViewInWindow(width: 8, height: 8, zoomScale: zoomScale)
        view.activeTool = .lassoSelect
        let window = view.window!
        let point = windowPoint(forPixelCol: 2, row: 2, zoomScale: zoomScale, viewHeight: view.frame.height)

        view.mouseDown(with: mouseDownEvent(at: point, in: window)) // 1 vertex
        view.mouseUp(with: mouseUpEvent(at: point, in: window)) // no drag at all -> still just 1 vertex

        XCTAssertNil(view.selection, "fewer than 3 points can't enclose an area; the selection must stay untouched")
    }

    // MARK: - Selection tools: polygon click-based gesture (issue #11 test-authoring pass)

    func testPolygonSelect_threeClicksThenClickNearFirstVertex_closesTheSelection() {
        let zoomScale = 4
        let view = makeViewInWindow(width: 8, height: 8, zoomScale: zoomScale)
        view.activeTool = .polygonSelect
        let window = view.window!
        let v1 = windowPoint(forPixelCol: 1, row: 1, zoomScale: zoomScale, viewHeight: view.frame.height)
        let v2 = windowPoint(forPixelCol: 6, row: 1, zoomScale: zoomScale, viewHeight: view.frame.height)
        let v3 = windowPoint(forPixelCol: 6, row: 6, zoomScale: zoomScale, viewHeight: view.frame.height)

        view.mouseDown(with: mouseDownEvent(at: v1, in: window))
        view.mouseUp(with: mouseUpEvent(at: v1, in: window))
        view.mouseDown(with: mouseDownEvent(at: v2, in: window))
        view.mouseUp(with: mouseUpEvent(at: v2, in: window))
        view.mouseDown(with: mouseDownEvent(at: v3, in: window))
        view.mouseUp(with: mouseUpEvent(at: v3, in: window))
        XCTAssertNil(view.selection, "precondition: the shape isn't closed yet after only 3 clicks")

        // Click back at (approximately) the first vertex to close the shape.
        view.mouseDown(with: mouseDownEvent(at: v1, in: window))

        XCTAssertNotNil(view.selection, "clicking near the first vertex with >=3 vertices placed must close and commit the selection")
        XCTAssertTrue(view.selection!.contains(x: 4, y: 2), "a point inside the closed triangle must be selected")
        XCTAssertFalse(view.selection!.contains(x: 0, y: 0), "well outside the triangle must not be selected")
    }

    func testPolygonSelect_closeClickExactlyAtCloseDistance_closesTheShape() {
        let view = makeViewInWindow(width: 20, height: 20, zoomScale: 1)
        view.activeTool = .polygonSelect
        let window = view.window!
        let first = NSPoint(x: 10, y: 16)

        view.mouseDown(with: mouseDownEvent(at: first, in: window))
        view.mouseUp(with: mouseUpEvent(at: first, in: window))
        view.mouseDown(with: mouseDownEvent(at: NSPoint(x: 15, y: 5), in: window))
        view.mouseUp(with: mouseUpEvent(at: NSPoint(x: 15, y: 5), in: window))
        view.mouseDown(with: mouseDownEvent(at: NSPoint(x: 15, y: 18), in: window))
        view.mouseUp(with: mouseUpEvent(at: NSPoint(x: 15, y: 18), in: window))

        // Exactly 6 view-points from the first click (polygonCloseDistance),
        // in an isometric (flip-preserves-distance) view/window coordinate
        // system: `<=` must close it, not leave it open for a 4th vertex.
        view.mouseDown(with: mouseDownEvent(at: NSPoint(x: first.x + 6, y: first.y), in: window))

        XCTAssertNotNil(view.selection, "a close-click exactly at polygonCloseDistance (6pt) must close the shape (the comparison is <=, not <)")
    }

    func testPolygonSelect_closeClickJustPastCloseDistance_doesNotClose_addsAFourthVertexInstead() {
        let view = makeViewInWindow(width: 20, height: 20, zoomScale: 1)
        view.activeTool = .polygonSelect
        let window = view.window!
        let first = NSPoint(x: 10, y: 16)

        view.mouseDown(with: mouseDownEvent(at: first, in: window))
        view.mouseUp(with: mouseUpEvent(at: first, in: window))
        view.mouseDown(with: mouseDownEvent(at: NSPoint(x: 15, y: 5), in: window))
        view.mouseUp(with: mouseUpEvent(at: NSPoint(x: 15, y: 5), in: window))
        view.mouseDown(with: mouseDownEvent(at: NSPoint(x: 15, y: 18), in: window))
        view.mouseUp(with: mouseUpEvent(at: NSPoint(x: 15, y: 18), in: window))

        // 7 view-points away — just past `polygonCloseDistance` (6) — must
        // be treated as placing a 4th vertex, not closing the shape.
        view.mouseDown(with: mouseDownEvent(at: NSPoint(x: first.x + 7, y: first.y), in: window))

        XCTAssertNil(view.selection, "a click just past polygonCloseDistance must not close the shape")
    }

    // MARK: - Selection tools: magic wand (issue #11 test-authoring pass)

    func testMouseDown_magicWandSelect_singleClick_confirmsSelectionImmediately_noDragNeeded() {
        let zoomScale = 4
        let view = makeViewInWindow(width: 8, height: 8, zoomScale: zoomScale)
        view.activeTool = .magicWandSelect
        view.magicWandTolerance = 0
        let window = view.window!
        let point = windowPoint(forPixelCol: 3, row: 3, zoomScale: zoomScale, viewHeight: view.frame.height)

        view.mouseDown(with: mouseDownEvent(at: point, in: window))

        XCTAssertNotNil(view.selection, "a single mouseDown, with no mouseDragged/mouseUp at all, must be the whole magic wand gesture")
        XCTAssertTrue(view.selection!.contains(x: 0, y: 0), "the whole solid-white canvas must be selected at tolerance 0")
    }

    func testMouseDown_magicWandSelect_samplesTheActiveLayersOwnCanvas_notTheComposite() {
        let zoomScale = 4
        let view = makeViewInWindow(width: 8, height: 8, zoomScale: zoomScale)
        // Bottom layer: opaque red everywhere.
        view.layerStack.layers[0].canvas.fill(with: NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1))
        view.layerStack.addLayer() // index 1, becomes active; starts fully transparent
        let activeCanvas = view.layerStack.activeLayer.canvas
        // (2,2): semi-transparent blue on the active layer -> composited
        // with the red beneath it, its visible color is a red/blue blend,
        // NOT plain blue.
        activeCanvas.setPixel(x: 2, y: 2, color: NSColor(deviceRed: 0, green: 0, blue: 1, alpha: 0.5))
        // (3,2): fully opaque blue on the active layer, adjacent to (2,2) —
        // same raw RGB as (2,2) (alpha is excluded from color distance), but
        // its *composited* appearance (plain opaque blue) differs sharply
        // from (2,2)'s blended composite.
        activeCanvas.setPixel(x: 3, y: 2, color: NSColor(deviceRed: 0, green: 0, blue: 1, alpha: 1))
        view.activeTool = .magicWandSelect
        view.magicWandTolerance = 0

        let targetPoint = windowPoint(forPixelCol: 2, row: 2, zoomScale: zoomScale, viewHeight: view.frame.height)
        view.mouseDown(with: mouseDownEvent(at: targetPoint, in: view.window!))

        XCTAssertTrue(view.selection?.contains(x: 3, y: 2) ?? false, "(3,2) shares (2,2)'s raw active-layer RGB and must be selected — if the wand instead sampled the composite, the two pixels' very different blended appearances would exclude it")
    }

    // MARK: - Selection combine modes: decision table (issue #11 test-authoring pass)
    //
    // Exercised through the rectangle-select tool's drag gesture (mouseDown
    // -> mouseDragged -> mouseUp) as the representative case; the "combine
    // modes across tools" section further down spot-checks the same
    // decision table through the lasso and magic wand tools too, briefly, to
    // catch a per-tool branch that might diverge from this shared logic.

    private func dragRectangleSelect(on view: CanvasView, fromCol: Int, fromRow: Int, toCol: Int, toRow: Int, zoomScale: Int, modifierFlags: NSEvent.ModifierFlags = []) {
        let window = view.window!
        let start = windowPoint(forPixelCol: fromCol, row: fromRow, zoomScale: zoomScale, viewHeight: view.frame.height)
        let end = windowPoint(forPixelCol: toCol, row: toRow, zoomScale: zoomScale, viewHeight: view.frame.height)
        view.mouseDown(with: mouseDownEvent(at: start, in: window, modifierFlags: modifierFlags))
        view.mouseDragged(with: mouseDraggedEvent(at: end, in: window))
        view.mouseUp(with: mouseUpEvent(at: end, in: window))
    }

    func testRectangleSelect_noModifier_replace_discardsExistingSelectionEntirely() {
        let zoomScale = 4
        let view = makeViewInWindow(width: 8, height: 8, zoomScale: zoomScale)
        view.activeTool = .rectangleSelect
        view.selection = SelectionMask.rectangle(x0: 0, y0: 0, x1: 1, y1: 1, width: 8, height: 8)

        dragRectangleSelect(on: view, fromCol: 4, fromRow: 4, toCol: 5, toRow: 5, zoomScale: zoomScale)

        XCTAssertFalse(view.selection!.contains(x: 0, y: 0), "the old selection must be completely discarded by a plain (no-modifier) drag")
        XCTAssertTrue(view.selection!.contains(x: 4, y: 4))
    }

    func testRectangleSelect_shiftAdd_withNoExistingSelection_behavesLikeAPlainReplace() {
        let zoomScale = 4
        let view = makeViewInWindow(width: 8, height: 8, zoomScale: zoomScale)
        view.activeTool = .rectangleSelect
        XCTAssertNil(view.selection, "precondition: nothing selected yet")

        dragRectangleSelect(on: view, fromCol: 2, fromRow: 2, toCol: 3, toRow: 3, zoomScale: zoomScale, modifierFlags: [.shift])

        XCTAssertTrue(view.selection!.contains(x: 2, y: 2))
        XCTAssertTrue(view.selection!.contains(x: 3, y: 3))
        XCTAssertFalse(view.selection!.contains(x: 0, y: 0))
    }

    func testRectangleSelect_optionSubtract_withNoExistingSelection_staysNil() {
        let zoomScale = 4
        let view = makeViewInWindow(width: 8, height: 8, zoomScale: zoomScale)
        view.activeTool = .rectangleSelect

        dragRectangleSelect(on: view, fromCol: 2, fromRow: 2, toCol: 3, toRow: 3, zoomScale: zoomScale, modifierFlags: [.option])

        XCTAssertNil(view.selection, "subtracting from nothing has nothing to subtract from — must stay nil, not become an inverted/negative selection")
    }

    func testRectangleSelect_shiftOptionIntersect_withNoExistingSelection_staysNil() {
        let zoomScale = 4
        let view = makeViewInWindow(width: 8, height: 8, zoomScale: zoomScale)
        view.activeTool = .rectangleSelect

        dragRectangleSelect(on: view, fromCol: 2, fromRow: 2, toCol: 3, toRow: 3, zoomScale: zoomScale, modifierFlags: [.shift, .option])

        XCTAssertNil(view.selection, "intersecting with nothing has nothing to intersect with — must stay nil")
    }

    func testRectangleSelect_replace_withExistingSelection_discardsItCompletely() {
        let zoomScale = 4
        let view = makeViewInWindow(width: 8, height: 8, zoomScale: zoomScale)
        view.activeTool = .rectangleSelect
        view.selection = SelectionMask.rectangle(x0: 0, y0: 0, x1: 6, y1: 6, width: 8, height: 8)

        dragRectangleSelect(on: view, fromCol: 7, fromRow: 7, toCol: 7, toRow: 7, zoomScale: zoomScale)

        XCTAssertFalse(view.selection!.contains(x: 0, y: 0), "none of the old, much larger selection should survive a replace")
        XCTAssertTrue(view.selection!.contains(x: 7, y: 7))
    }

    func testRectangleSelect_replace_dragResolvesToAnEmptyMask_clearsExistingSelectionToNil() {
        let zoomScale = 4
        let view = makeViewInWindow(width: 8, height: 8, zoomScale: zoomScale)
        view.activeTool = .rectangleSelect
        view.selection = SelectionMask.rectangle(x0: 0, y0: 0, x1: 3, y1: 3, width: 8, height: 8)

        // Both drag endpoints resolve to pixel coordinates entirely outside
        // the 8x8 canvas, so the resulting rectangle mask clips to empty.
        dragRectangleSelect(on: view, fromCol: -10, fromRow: -10, toCol: -5, toRow: -5, zoomScale: zoomScale)

        XCTAssertNil(view.selection, "a replace whose new mask is empty must clear the existing selection to nil, not leave it, and not leave an all-false mask standing")
    }

    func testRectangleSelect_shiftAdd_exactlyOverlappingRegion_leavesSelectionUnchanged() {
        let zoomScale = 4
        let view = makeViewInWindow(width: 8, height: 8, zoomScale: zoomScale)
        view.activeTool = .rectangleSelect
        view.selection = SelectionMask.rectangle(x0: 2, y0: 2, x1: 4, y1: 4, width: 8, height: 8)

        dragRectangleSelect(on: view, fromCol: 2, fromRow: 2, toCol: 4, toRow: 4, zoomScale: zoomScale, modifierFlags: [.shift])

        let expected = SelectionMask.rectangle(x0: 2, y0: 2, x1: 4, y1: 4, width: 8, height: 8)
        for y in 0..<8 {
            for x in 0..<8 {
                XCTAssertEqual(view.selection!.contains(x: x, y: y), expected.contains(x: x, y: y), "(\(x),\(y)) union of an identical region with itself must be unchanged")
            }
        }
    }

    func testRectangleSelect_shiftAdd_partiallyOverlappingRegion_expandsToTheUnion() {
        let zoomScale = 4
        let view = makeViewInWindow(width: 8, height: 8, zoomScale: zoomScale)
        view.activeTool = .rectangleSelect
        view.selection = SelectionMask.rectangle(x0: 0, y0: 0, x1: 2, y1: 2, width: 8, height: 8)

        dragRectangleSelect(on: view, fromCol: 2, fromRow: 2, toCol: 5, toRow: 5, zoomScale: zoomScale, modifierFlags: [.shift])

        XCTAssertTrue(view.selection!.contains(x: 0, y: 0), "the old selection's exclusive area must survive the union")
        XCTAssertTrue(view.selection!.contains(x: 5, y: 5), "the new drag's exclusive area must be added by the union")
    }

    func testRectangleSelect_optionSubtract_exactlyOverlappingRegion_clearsSelectionToNil() {
        let zoomScale = 4
        let view = makeViewInWindow(width: 8, height: 8, zoomScale: zoomScale)
        view.activeTool = .rectangleSelect
        view.selection = SelectionMask.rectangle(x0: 2, y0: 2, x1: 4, y1: 4, width: 8, height: 8)

        dragRectangleSelect(on: view, fromCol: 2, fromRow: 2, toCol: 4, toRow: 4, zoomScale: zoomScale, modifierFlags: [.option])

        XCTAssertNil(view.selection, "subtracting exactly the whole existing selection must leave nothing, collapsing to nil")
    }

    func testRectangleSelect_optionSubtract_disjointRegion_leavesSelectionUnchanged() {
        let zoomScale = 4
        let view = makeViewInWindow(width: 8, height: 8, zoomScale: zoomScale)
        view.activeTool = .rectangleSelect
        view.selection = SelectionMask.rectangle(x0: 0, y0: 0, x1: 1, y1: 1, width: 8, height: 8)

        dragRectangleSelect(on: view, fromCol: 5, fromRow: 5, toCol: 6, toRow: 6, zoomScale: zoomScale, modifierFlags: [.option])

        XCTAssertTrue(view.selection!.contains(x: 0, y: 0), "subtracting a disjoint region must leave the existing selection untouched")
        XCTAssertTrue(view.selection!.contains(x: 1, y: 1))
    }

    func testRectangleSelect_shiftOptionIntersect_exactlyOverlappingRegion_leavesSelectionUnchanged() {
        let zoomScale = 4
        let view = makeViewInWindow(width: 8, height: 8, zoomScale: zoomScale)
        view.activeTool = .rectangleSelect
        view.selection = SelectionMask.rectangle(x0: 2, y0: 2, x1: 4, y1: 4, width: 8, height: 8)

        dragRectangleSelect(on: view, fromCol: 2, fromRow: 2, toCol: 4, toRow: 4, zoomScale: zoomScale, modifierFlags: [.shift, .option])

        let expected = SelectionMask.rectangle(x0: 2, y0: 2, x1: 4, y1: 4, width: 8, height: 8)
        for y in 0..<8 {
            for x in 0..<8 {
                XCTAssertEqual(view.selection!.contains(x: x, y: y), expected.contains(x: x, y: y))
            }
        }
    }

    func testRectangleSelect_shiftOptionIntersect_disjointRegion_clearsSelectionToNil() {
        let zoomScale = 4
        let view = makeViewInWindow(width: 8, height: 8, zoomScale: zoomScale)
        view.activeTool = .rectangleSelect
        view.selection = SelectionMask.rectangle(x0: 0, y0: 0, x1: 1, y1: 1, width: 8, height: 8)

        dragRectangleSelect(on: view, fromCol: 5, fromRow: 5, toCol: 6, toRow: 6, zoomScale: zoomScale, modifierFlags: [.shift, .option])

        XCTAssertNil(view.selection, "intersecting with a disjoint region has no overlap, so the result must collapse to nil")
    }

    // MARK: - Combine modes across tools (issue #11 test-authoring pass):
    // brief cross-check that lasso and magic wand share the same combine
    // logic as rectangle-select above, rather than each having its own
    // (possibly diverging) copy.

    func testLassoSelect_shiftAdd_partiallyOverlappingRegion_expandsToTheUnion() {
        let zoomScale = 4
        let view = makeViewInWindow(width: 8, height: 8, zoomScale: zoomScale)
        view.activeTool = .lassoSelect
        view.selection = SelectionMask.rectangle(x0: 0, y0: 0, x1: 2, y1: 2, width: 8, height: 8)
        let window = view.window!

        view.mouseDown(with: mouseDownEvent(at: windowPoint(forPixelCol: 5, row: 5, zoomScale: zoomScale, viewHeight: view.frame.height), in: window, modifierFlags: [.shift]))
        view.mouseDragged(with: mouseDraggedEvent(at: windowPoint(forPixelCol: 7, row: 5, zoomScale: zoomScale, viewHeight: view.frame.height), in: window))
        view.mouseDragged(with: mouseDraggedEvent(at: windowPoint(forPixelCol: 7, row: 7, zoomScale: zoomScale, viewHeight: view.frame.height), in: window))
        view.mouseUp(with: mouseUpEvent(at: windowPoint(forPixelCol: 7, row: 7, zoomScale: zoomScale, viewHeight: view.frame.height), in: window))

        XCTAssertTrue(view.selection!.contains(x: 0, y: 0), "the old selection must survive a Shift (add) lasso, same as rectangle-select")
        XCTAssertTrue(view.selection!.contains(x: 6, y: 6), "the new lasso region must be added")
    }

    func testMagicWandSelect_optionSubtract_exactlyOverlappingRegion_clearsSelectionToNil() {
        let zoomScale = 4
        let view = makeViewInWindow(width: 8, height: 8, zoomScale: zoomScale)
        view.activeTool = .magicWandSelect
        view.magicWandTolerance = 0
        // The whole (solid white) canvas is one magic-wand region.
        let fullCanvas = SelectionMask.rectangle(x0: 0, y0: 0, x1: 7, y1: 7, width: 8, height: 8)
        view.selection = fullCanvas
        let window = view.window!

        view.mouseDown(with: mouseDownEvent(at: windowPoint(forPixelCol: 3, row: 3, zoomScale: zoomScale, viewHeight: view.frame.height), in: window, modifierFlags: [.option]))

        XCTAssertNil(view.selection, "subtracting the magic wand's full-canvas region from an identical existing selection must clear it to nil, same combine rule as rectangle-select")
    }

    // MARK: - Selection tool state machines: Escape/Return/tool-switch cleanup (issue #11 test-authoring pass)

    func testPolygonSelect_escapeMidGesture_leavesSelectionUnchanged_andClearsTheVertexList() {
        let zoomScale = 4
        let view = makeViewInWindow(width: 8, height: 8, zoomScale: zoomScale)
        view.activeTool = .polygonSelect
        let window = view.window!

        view.mouseDown(with: mouseDownEvent(at: windowPoint(forPixelCol: 1, row: 1, zoomScale: zoomScale, viewHeight: view.frame.height), in: window))
        view.mouseUp(with: mouseUpEvent(at: windowPoint(forPixelCol: 1, row: 1, zoomScale: zoomScale, viewHeight: view.frame.height), in: window))
        view.mouseDown(with: mouseDownEvent(at: windowPoint(forPixelCol: 6, row: 1, zoomScale: zoomScale, viewHeight: view.frame.height), in: window))
        view.mouseUp(with: mouseUpEvent(at: windowPoint(forPixelCol: 6, row: 1, zoomScale: zoomScale, viewHeight: view.frame.height), in: window))

        view.keyDown(with: keyDownEvent(keyCode: 53, in: window)) // Escape

        XCTAssertNil(view.selection, "Escape must cancel the in-progress polygon without touching the selection")

        // Prove the vertex list was actually emptied (not just left alone
        // because 2 vertices can't close anyway): a fresh 3-click polygon
        // afterward must produce exactly the plain 3-vertex triangle, not a
        // 5-vertex shape tainted by the 2 vertices placed before Escape.
        let v1 = windowPoint(forPixelCol: 1, row: 1, zoomScale: zoomScale, viewHeight: view.frame.height)
        let v2 = windowPoint(forPixelCol: 6, row: 1, zoomScale: zoomScale, viewHeight: view.frame.height)
        let v3 = windowPoint(forPixelCol: 6, row: 6, zoomScale: zoomScale, viewHeight: view.frame.height)
        view.mouseDown(with: mouseDownEvent(at: v1, in: window))
        view.mouseUp(with: mouseUpEvent(at: v1, in: window))
        view.mouseDown(with: mouseDownEvent(at: v2, in: window))
        view.mouseUp(with: mouseUpEvent(at: v2, in: window))
        view.mouseDown(with: mouseDownEvent(at: v3, in: window))
        view.mouseUp(with: mouseUpEvent(at: v3, in: window))
        view.mouseDown(with: mouseDownEvent(at: v1, in: window)) // close

        let expected = SelectionMask.polygon(vertices: [(1, 1), (6, 1), (6, 6)], width: 8, height: 8)
        for y in 0..<8 {
            for x in 0..<8 {
                XCTAssertEqual(view.selection!.contains(x: x, y: y), expected.contains(x: x, y: y), "(\(x),\(y)) the post-Escape polygon must match a plain fresh 3-vertex triangle exactly")
            }
        }
    }

    func testPolygonSelect_threeClicksThenReturn_closesWithThoseThreeVertices() {
        let zoomScale = 4
        let view = makeViewInWindow(width: 8, height: 8, zoomScale: zoomScale)
        view.activeTool = .polygonSelect
        let window = view.window!
        let vertices: [(x: Int, y: Int)] = [(1, 1), (6, 1), (6, 6)]

        for vertex in vertices {
            let point = windowPoint(forPixelCol: vertex.x, row: vertex.y, zoomScale: zoomScale, viewHeight: view.frame.height)
            view.mouseDown(with: mouseDownEvent(at: point, in: window))
            view.mouseUp(with: mouseUpEvent(at: point, in: window))
        }
        view.keyDown(with: keyDownEvent(keyCode: 36, in: window)) // Return

        let expected = SelectionMask.polygon(vertices: vertices, width: 8, height: 8)
        XCTAssertNotNil(view.selection)
        for y in 0..<8 {
            for x in 0..<8 {
                XCTAssertEqual(view.selection!.contains(x: x, y: y), expected.contains(x: x, y: y))
            }
        }
    }

    func testPolygonSelect_onlyTwoVerticesThenReturn_doesNothing() {
        let zoomScale = 4
        let view = makeViewInWindow(width: 8, height: 8, zoomScale: zoomScale)
        view.activeTool = .polygonSelect
        let window = view.window!

        view.mouseDown(with: mouseDownEvent(at: windowPoint(forPixelCol: 1, row: 1, zoomScale: zoomScale, viewHeight: view.frame.height), in: window))
        view.mouseUp(with: mouseUpEvent(at: windowPoint(forPixelCol: 1, row: 1, zoomScale: zoomScale, viewHeight: view.frame.height), in: window))
        view.mouseDown(with: mouseDownEvent(at: windowPoint(forPixelCol: 6, row: 1, zoomScale: zoomScale, viewHeight: view.frame.height), in: window))
        view.mouseUp(with: mouseUpEvent(at: windowPoint(forPixelCol: 6, row: 1, zoomScale: zoomScale, viewHeight: view.frame.height), in: window))

        view.keyDown(with: keyDownEvent(keyCode: 36, in: window)) // Return

        XCTAssertNil(view.selection, "fewer than 3 vertices can't enclose an area; Return must be a no-op on the selection")
    }

    func testLassoSelect_repeatedMouseDraggedAtTheSamePixel_doesNotDistortTheFinalShape() {
        // `lassoVertices` is private, so this can't inspect the accumulated
        // point count directly; instead it checks the one thing that would
        // actually be observably wrong if de-duplication were removed in a
        // way that corrupts (not just fails to shrink) the path: feeding
        // many repeated points at the same pixel, interspersed with the real
        // path, must produce the exact same mask as a plain drag through
        // just the distinct points.
        let zoomScale = 4
        let view = makeViewInWindow(width: 8, height: 8, zoomScale: zoomScale)
        view.activeTool = .lassoSelect
        let window = view.window!
        let p1 = windowPoint(forPixelCol: 1, row: 1, zoomScale: zoomScale, viewHeight: view.frame.height)
        let p2 = windowPoint(forPixelCol: 6, row: 6, zoomScale: zoomScale, viewHeight: view.frame.height)
        let p3 = windowPoint(forPixelCol: 1, row: 6, zoomScale: zoomScale, viewHeight: view.frame.height)

        view.mouseDown(with: mouseDownEvent(at: p1, in: window))
        for _ in 0..<5 {
            view.mouseDragged(with: mouseDraggedEvent(at: p1, in: window)) // repeated, no movement
        }
        view.mouseDragged(with: mouseDraggedEvent(at: p2, in: window))
        for _ in 0..<5 {
            view.mouseDragged(with: mouseDraggedEvent(at: p2, in: window)) // repeated again
        }
        view.mouseDragged(with: mouseDraggedEvent(at: p3, in: window))
        view.mouseUp(with: mouseUpEvent(at: p3, in: window))

        let expected = SelectionMask.polygon(vertices: [(1, 1), (6, 6), (1, 6)], width: 8, height: 8)
        XCTAssertNotNil(view.selection)
        for y in 0..<8 {
            for x in 0..<8 {
                XCTAssertEqual(view.selection!.contains(x: x, y: y), expected.contains(x: x, y: y), "(\(x),\(y)) repeated same-pixel drag events must not distort the path from the plain 3-point equivalent")
            }
        }
    }

    func testActiveTool_switchedAwayMidPolygonGesture_clearsVertexState() {
        let zoomScale = 4
        let view = makeViewInWindow(width: 8, height: 8, zoomScale: zoomScale)
        view.activeTool = .polygonSelect
        let window = view.window!

        view.mouseDown(with: mouseDownEvent(at: windowPoint(forPixelCol: 1, row: 1, zoomScale: zoomScale, viewHeight: view.frame.height), in: window))
        view.mouseUp(with: mouseUpEvent(at: windowPoint(forPixelCol: 1, row: 1, zoomScale: zoomScale, viewHeight: view.frame.height), in: window))
        view.mouseDown(with: mouseDownEvent(at: windowPoint(forPixelCol: 6, row: 1, zoomScale: zoomScale, viewHeight: view.frame.height), in: window))
        view.mouseUp(with: mouseUpEvent(at: windowPoint(forPixelCol: 6, row: 1, zoomScale: zoomScale, viewHeight: view.frame.height), in: window))

        view.activeTool = .pencil
        view.activeTool = .polygonSelect

        let v1 = windowPoint(forPixelCol: 1, row: 1, zoomScale: zoomScale, viewHeight: view.frame.height)
        let v2 = windowPoint(forPixelCol: 6, row: 1, zoomScale: zoomScale, viewHeight: view.frame.height)
        let v3 = windowPoint(forPixelCol: 6, row: 6, zoomScale: zoomScale, viewHeight: view.frame.height)
        view.mouseDown(with: mouseDownEvent(at: v1, in: window))
        view.mouseUp(with: mouseUpEvent(at: v1, in: window))
        view.mouseDown(with: mouseDownEvent(at: v2, in: window))
        view.mouseUp(with: mouseUpEvent(at: v2, in: window))
        view.mouseDown(with: mouseDownEvent(at: v3, in: window))
        view.mouseUp(with: mouseUpEvent(at: v3, in: window))
        view.mouseDown(with: mouseDownEvent(at: v1, in: window)) // close

        let expected = SelectionMask.polygon(vertices: [(1, 1), (6, 1), (6, 6)], width: 8, height: 8)
        XCTAssertNotNil(view.selection)
        for y in 0..<8 {
            for x in 0..<8 {
                XCTAssertEqual(view.selection!.contains(x: x, y: y), expected.contains(x: x, y: y), "switching tools mid-gesture and back must have cleared the stale 2-vertex list, not tainted the next polygon with it")
            }
        }
    }

    func testActiveTool_switchedAwayMidLassoGesture_clearsPathState() {
        let zoomScale = 4
        let view = makeViewInWindow(width: 8, height: 8, zoomScale: zoomScale)
        view.activeTool = .lassoSelect
        let window = view.window!

        // Mid-drag: mouseDown + mouseDragged, but the gesture is never
        // finished with mouseUp — interrupted by a tool switch instead.
        view.mouseDown(with: mouseDownEvent(at: windowPoint(forPixelCol: 0, row: 0, zoomScale: zoomScale, viewHeight: view.frame.height), in: window))
        view.mouseDragged(with: mouseDraggedEvent(at: windowPoint(forPixelCol: 7, row: 0, zoomScale: zoomScale, viewHeight: view.frame.height), in: window))

        view.activeTool = .pencil
        view.activeTool = .lassoSelect

        let p1 = windowPoint(forPixelCol: 1, row: 1, zoomScale: zoomScale, viewHeight: view.frame.height)
        let p2 = windowPoint(forPixelCol: 6, row: 6, zoomScale: zoomScale, viewHeight: view.frame.height)
        let p3 = windowPoint(forPixelCol: 1, row: 6, zoomScale: zoomScale, viewHeight: view.frame.height)
        view.mouseDown(with: mouseDownEvent(at: p1, in: window))
        view.mouseDragged(with: mouseDraggedEvent(at: p2, in: window))
        view.mouseDragged(with: mouseDraggedEvent(at: p3, in: window))
        view.mouseUp(with: mouseUpEvent(at: p3, in: window))

        let expected = SelectionMask.polygon(vertices: [(1, 1), (6, 6), (1, 6)], width: 8, height: 8)
        XCTAssertNotNil(view.selection)
        for y in 0..<8 {
            for x in 0..<8 {
                XCTAssertEqual(view.selection!.contains(x: x, y: y), expected.contains(x: x, y: y), "switching tools mid-lasso-drag and back must have cleared the stale interrupted path")
            }
        }
    }

    func testActiveTool_switchingToPencilFromASelectionTool_preservesTheConfirmedSelection() {
        let view = makeView()
        view.activeTool = .rectangleSelect
        view.selection = SelectionMask.rectangle(x0: 1, y0: 1, x1: 3, y1: 3, width: 8, height: 8)

        view.activeTool = .pencil

        XCTAssertNotNil(view.selection, "switching away from a selection tool must not clear an already-confirmed selection")
        XCTAssertTrue(view.selection!.contains(x: 2, y: 2))
    }
}
