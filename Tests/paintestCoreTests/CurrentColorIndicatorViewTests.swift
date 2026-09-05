import AppKit
import XCTest
@testable import paintestCore

final class CurrentColorIndicatorViewTests: XCTestCase {
    func testInit_doesNotCrash() {
        _ = CurrentColorIndicatorView()
    }

    func testDefaultColors_areBlackForegroundAndWhiteBackground() {
        let view = CurrentColorIndicatorView()
        XCTAssertEqual(view.foregroundColor, .black)
        XCTAssertEqual(view.backgroundColor, .white)
    }

    // MARK: - Click hit-testing (issue #5)
    //
    // `mouseDown(with:)` converts `event.locationInWindow` via
    // `convert(_:from: nil)`, which needs a real (even if
    // off-screen/borderless) `NSWindow` to resolve coordinates — same
    // requirement and pattern as `CanvasViewTests`' `makeViewInWindow`/
    // `mouseDownEvent` helpers.
    //
    // Geometry mirrors `CurrentColorIndicatorView.swatchRects()` (side
    // 20pt) at a 100x100 view size, so `bounds.midX == bounds.midY == 50`:
    //   - back square:  x in [46, 66), y in [46, 66)
    //   - front square: x in [34, 54), y in [34, 54)
    //   - overlap:      x in [46, 54), y in [46, 54) — front wins there

    private func makeViewInWindow(width: CGFloat = 100, height: CGFloat = 100) -> CurrentColorIndicatorView {
        let view = CurrentColorIndicatorView()
        view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        return view
    }

    private func mouseDownEvent(at point: NSPoint, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }

    private func findButton(in view: NSView) -> NSButton? {
        for subview in view.subviews {
            if let button = subview as? NSButton { return button }
            if let found = findButton(in: subview) { return found }
        }
        return nil
    }

    func testClickInFrontOnlyArea_firesOnForegroundSwatchTappedOnly() {
        let view = makeViewInWindow()
        var foregroundFired = 0
        var backgroundFired = 0
        view.onForegroundSwatchTapped = { foregroundFired += 1 }
        view.onBackgroundSwatchTapped = { backgroundFired += 1 }

        view.mouseDown(with: mouseDownEvent(at: NSPoint(x: 36, y: 36), in: view.window!))

        XCTAssertEqual(foregroundFired, 1)
        XCTAssertEqual(backgroundFired, 0)
    }

    func testClickInBackOnlyArea_firesOnBackgroundSwatchTappedOnly() {
        let view = makeViewInWindow()
        var foregroundFired = 0
        var backgroundFired = 0
        view.onForegroundSwatchTapped = { foregroundFired += 1 }
        view.onBackgroundSwatchTapped = { backgroundFired += 1 }

        view.mouseDown(with: mouseDownEvent(at: NSPoint(x: 60, y: 60), in: view.window!))

        XCTAssertEqual(backgroundFired, 1)
        XCTAssertEqual(foregroundFired, 0)
    }

    func testClickInOverlapArea_foregroundTakesPriorityOverBackground() {
        let view = makeViewInWindow()
        var foregroundFired = 0
        var backgroundFired = 0
        view.onForegroundSwatchTapped = { foregroundFired += 1 }
        view.onBackgroundSwatchTapped = { backgroundFired += 1 }

        view.mouseDown(with: mouseDownEvent(at: NSPoint(x: 50, y: 50), in: view.window!))

        XCTAssertEqual(foregroundFired, 1, "the front square is drawn on top, so it must win the overlap")
        XCTAssertEqual(backgroundFired, 0)
    }

    func testClickOutsideBothSquares_firesNeitherCallback() {
        let view = makeViewInWindow()
        var foregroundFired = 0
        var backgroundFired = 0
        view.onForegroundSwatchTapped = { foregroundFired += 1 }
        view.onBackgroundSwatchTapped = { backgroundFired += 1 }

        view.mouseDown(with: mouseDownEvent(at: NSPoint(x: 5, y: 5), in: view.window!))

        XCTAssertEqual(foregroundFired, 0)
        XCTAssertEqual(backgroundFired, 0)
    }

    // MARK: - Reset button

    func testResetButtonClick_firesOnResetToDefaultTapped() {
        let view = makeViewInWindow()
        var resetFired = 0
        view.onResetToDefaultTapped = { resetFired += 1 }
        guard let button = findButton(in: view) else {
            XCTFail("could not find the reset button")
            return
        }

        button.performClick(nil)

        XCTAssertEqual(resetFired, 1)
    }
}
