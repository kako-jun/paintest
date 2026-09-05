import AppKit
import XCTest
@testable import paintestCore

final class ColorPaletteViewTests: XCTestCase {
    private func makeView() -> ColorPaletteView {
        ColorPaletteView()
    }

    /// Swatches (`ColorSwatchView`, issue #5) are plain `NSView`s — not
    /// `NSControl`s — that opt into a backed layer with a solid fill color;
    /// that combination identifies them independently of their position in
    /// the `NSGridView` hierarchy.
    private func colorSwatches(in view: NSView) -> [NSView] {
        var result: [NSView] = []
        for subview in view.subviews {
            if subview.wantsLayer, subview.layer?.backgroundColor != nil {
                result.append(subview)
            }
            result.append(contentsOf: colorSwatches(in: subview))
        }
        return result
    }

    func testInit_doesNotCrash() {
        _ = makeView()
    }

    // 2 classic-palette rows + 1 recent-colors row (issue #5), 14 columns each.
    func testSwatchCount_equals42() {
        let view = makeView()
        XCTAssertEqual(colorSwatches(in: view).count, 42, "3 rows x 14 columns")
    }

    func testRows_haveEqualColumnCount() {
        let view = makeView()
        guard let grid = view.subviews.first as? NSGridView else {
            XCTFail("expected the palette's root subview to be an NSGridView")
            return
        }
        let columnCounts = (0..<grid.numberOfRows).map { grid.row(at: $0).numberOfCells }
        XCTAssertEqual(
            Set(columnCounts).count, 1,
            "all rows must have the same column count, or NSGridView crashes on construction"
        )
    }

    // Swatches pick their color via overridden mouseDown/rightMouseDown
    // (issue #5), not via NSControl's target/action mechanism.
    func testSwatches_areNotNSControls() {
        let view = makeView()
        let swatches = colorSwatches(in: view)
        XCTAssertFalse(swatches.isEmpty)
        for swatch in swatches {
            XCTAssertFalse(swatch is NSControl, "swatches pick colors via mouseDown/rightMouseDown, not NSControl target/action")
        }
    }
}
