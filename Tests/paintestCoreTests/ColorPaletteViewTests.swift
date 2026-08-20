import AppKit
import XCTest
@testable import paintestCore

final class ColorPaletteViewTests: XCTestCase {
    private func makeView() -> ColorPaletteView {
        ColorPaletteView()
    }

    /// Swatches are plain `NSView`s that opt into a backed layer with a
    /// solid fill color — that combination is how `ColorPaletteView`
    /// constructs them (`makeSwatch`), so it identifies them independently
    /// of their position in the `NSGridView` hierarchy.
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

    func testSwatchCount_equals28() {
        let view = makeView()
        XCTAssertEqual(colorSwatches(in: view).count, 28, "2 rows x 14 columns")
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

    func testSwatches_haveNoClickTarget() {
        let view = makeView()
        let swatches = colorSwatches(in: view)
        XCTAssertFalse(swatches.isEmpty)
        for swatch in swatches {
            XCTAssertFalse(swatch is NSControl, "swatches are plain NSViews, not clickable controls")
        }
    }
}
