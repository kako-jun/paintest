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

    // MARK: - ColorSwatchView click behavior (issue #5)
    //
    // `ColorSwatchView` is `private` to ColorPaletteView.swift, so it can
    // only be reached here as a plain `NSView` via `colorSwatches(in:)` —
    // but `mouseDown(with:)`/`rightMouseDown(with:)` are dynamically
    // dispatched AppKit overrides, so calling them through that `NSView`
    // reference still invokes the real subclass behavior. Neither override
    // reads the event's location, so a minimal synthetic event (not tied to
    // any real window) is enough to drive them.

    private func dummyMouseEvent(type: NSEvent.EventType) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }

    func testSwatchLeftClick_firesOnSwatchSelectedWithForegroundFlag() {
        let view = makeView()
        guard let swatch = colorSwatches(in: view).first else {
            XCTFail("expected at least one swatch")
            return
        }
        var receivedIsSecondary: Bool?
        view.onSwatchSelected = { _, isSecondary in receivedIsSecondary = isSecondary }

        swatch.mouseDown(with: dummyMouseEvent(type: .leftMouseDown))

        XCTAssertEqual(receivedIsSecondary, false, "a left click must pick the foreground (isSecondary == false)")
    }

    func testSwatchRightClick_firesOnSwatchSelectedWithBackgroundFlag() {
        let view = makeView()
        guard let swatch = colorSwatches(in: view).first else {
            XCTFail("expected at least one swatch")
            return
        }
        var receivedIsSecondary: Bool?
        view.onSwatchSelected = { _, isSecondary in receivedIsSecondary = isSecondary }

        swatch.rightMouseDown(with: dummyMouseEvent(type: .rightMouseDown))

        XCTAssertEqual(receivedIsSecondary, true, "a right click must pick the background (isSecondary == true)")
    }

    func testOnSwatchSelected_deliversTheClickedSwatchsOwnColor() {
        let view = makeView()
        guard let swatch = colorSwatches(in: view).first else {
            XCTFail("expected at least one swatch")
            return
        }
        var receivedColor: NSColor?
        view.onSwatchSelected = { color, _ in receivedColor = color }

        swatch.mouseDown(with: dummyMouseEvent(type: .leftMouseDown))

        XCTAssertEqual(receivedColor?.cgColor, swatch.layer?.backgroundColor, "the callback must carry the color actually drawn by the clicked swatch")
    }

    // MARK: - updateRecentColors(_:) — AppKit-facing entry point (issue #5)

    private func recentColorsRowSwatches(in view: ColorPaletteView) -> [NSView] {
        guard let grid = view.subviews.first as? NSGridView else { return [] }
        let rowIndex = grid.numberOfRows - 1 // recent-colors row is always the last of the 3 rows
        let row = grid.row(at: rowIndex)
        var result: [NSView] = []
        for column in 0..<row.numberOfCells {
            if let contentView = row.cell(at: column).contentView {
                result.append(contentView)
            }
        }
        return result
    }

    func testUpdateRecentColors_emptyArray_doesNotCrashAndFillsWithTransparentPlaceholders() {
        let view = makeView()

        view.updateRecentColors([])

        let swatches = recentColorsRowSwatches(in: view)
        XCTAssertEqual(swatches.count, 14)
        for swatch in swatches {
            XCTAssertEqual(swatch.layer?.backgroundColor?.alpha, 0, "an empty recent-colors list must render as fully transparent placeholders")
        }
    }

    func testUpdateRecentColors_moreColorsThanCapacity_doesNotCrash() {
        let view = makeView()
        let manyColors = (0..<50).map { NSColor(calibratedWhite: CGFloat($0) / 50, alpha: 1) }

        view.updateRecentColors(manyColors)

        XCTAssertEqual(recentColorsRowSwatches(in: view).count, 14, "the recent-colors row always keeps exactly 14 cells regardless of the input length")
    }

    func testUpdateRecentColors_afterUpdate_totalSwatchCountStays42() {
        let view = makeView()

        view.updateRecentColors([.red, .green, .blue])

        XCTAssertEqual(colorSwatches(in: view).count, 42, "updating the recent-colors row must not change the overall 3x14 grid shape")
    }

    // MARK: - updatedRecentColors(adding:to:capacity:) — pure recency-list logic (issue #5)

    func testUpdatedRecentColors_addingToEmptyList_resultsInOneColor() {
        let result = ColorPaletteView.updatedRecentColors(adding: .red, to: [], capacity: 14)
        XCTAssertEqual(result, [.red])
    }

    func testUpdatedRecentColors_addingNewColor_isInsertedAtTheFront() {
        let result = ColorPaletteView.updatedRecentColors(adding: .blue, to: [.red, .green], capacity: 14)
        XCTAssertEqual(result.first, .blue)
    }

    func testUpdatedRecentColors_addingUnusedColorToExistingList_keepsExistingColorsAtTheEnd() {
        let result = ColorPaletteView.updatedRecentColors(adding: .blue, to: [.red, .green], capacity: 14)
        XCTAssertEqual(result, [.blue, .red, .green])
    }

    func testUpdatedRecentColors_addingAlreadyPresentColor_movesToFrontWithoutDuplicating() {
        let result = ColorPaletteView.updatedRecentColors(adding: .green, to: [.red, .green, .blue], capacity: 14)
        XCTAssertEqual(result, [.green, .red, .blue])
    }

    // `.calibratedRed`/`.calibratedWhite` colors are not guaranteed to
    // convert to the exact same `.deviceRGB` component values as their
    // `.deviceRed`/`.deviceWhite` counterparts (confirmed empirically: pure
    // `calibratedRed(1, 0, 0)` converts to `deviceRGB(1, 0.149, 0)`, not
    // `(1, 0, 0)`) — so this test instead pairs two constructors that both
    // land in `.deviceRGB` terms already: `deviceRed:green:blue:` and the
    // equivalent `deviceWhite:` shorthand for a neutral gray, at 0.5 (an
    // exact power-of-two fraction, so there's no float-rounding drift
    // between the two constructors' internal representations either).
    func testUpdatedRecentColors_matchesByRGBAValueAcrossDifferentConstructionPaths() {
        let existing = [NSColor(deviceRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)]
        let sameValueDifferentConstructor = NSColor(deviceWhite: 0.5, alpha: 1)

        let result = ColorPaletteView.updatedRecentColors(adding: sameValueDifferentConstructor, to: existing, capacity: 14)

        XCTAssertEqual(result.count, 1, "the same RGBA value produced via a different NSColor initializer must still be recognized as a duplicate")
    }

    func testUpdatedRecentColors_belowCapacity_addingOneMoreReachesCapacityWithoutTruncation() {
        let capacity = 5
        let existing = (0..<(capacity - 1)).map { NSColor(calibratedWhite: CGFloat($0) / 10, alpha: 1) }

        let result = ColorPaletteView.updatedRecentColors(adding: .red, to: existing, capacity: capacity)

        XCTAssertEqual(result.count, capacity)
        XCTAssertEqual(result.last, existing.last, "no existing entry should be dropped when landing exactly at capacity")
    }

    func testUpdatedRecentColors_atCapacity_addingOneMoreDropsTheOldestEntry() {
        let capacity = 5
        let existing = (0..<capacity).map { NSColor(calibratedWhite: CGFloat($0) / 10, alpha: 1) }
        let oldest = existing.last!

        let result = ColorPaletteView.updatedRecentColors(adding: .red, to: existing, capacity: capacity)

        XCTAssertEqual(result.count, capacity)
        XCTAssertFalse(result.contains(oldest), "the oldest (tail) entry must be dropped once the list is already at capacity")
    }

    func testUpdatedRecentColors_existingListAlreadyOverCapacity_truncatesToCapacity() {
        let capacity = 5
        let existing = (0..<(capacity + 3)).map { NSColor(calibratedWhite: CGFloat($0) / 20, alpha: 1) }

        let result = ColorPaletteView.updatedRecentColors(adding: .red, to: existing, capacity: capacity)

        XCTAssertEqual(result.count, capacity, "the result must never exceed capacity, even if the input list already did")
    }

    func testUpdatedRecentColors_zeroCapacity_alwaysResultsInEmptyArray() {
        let result = ColorPaletteView.updatedRecentColors(adding: .red, to: [.blue, .green], capacity: 0)
        XCTAssertTrue(result.isEmpty)
    }

    func testUpdatedRecentColors_multipleExistingDuplicates_areAllCollapsedToOne() {
        let duplicate = NSColor(calibratedRed: 0, green: 1, blue: 0, alpha: 1)
        let existing = [duplicate, .red, duplicate, .blue, duplicate]

        let result = ColorPaletteView.updatedRecentColors(adding: duplicate, to: existing, capacity: 14)

        XCTAssertEqual(result.filter { $0 == duplicate }.count, 1, "every existing occurrence of the added color must collapse into the single front entry")
        XCTAssertEqual(result.first, duplicate)
    }
}
