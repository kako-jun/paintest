import AppKit
import XCTest
@testable import paintestCore

final class OptionBarViewTests: XCTestCase {
    private func makeView() -> OptionBarView {
        OptionBarView()
    }

    func testInit_doesNotCrash() {
        _ = makeView()
    }

    func testHeight_matchesStaticHeightConstant() {
        XCTAssertEqual(OptionBarView.height, 30)
    }

    func testWantsLayer_isTrue() {
        let view = makeView()
        XCTAssertTrue(view.wantsLayer, "the option bar must have a backing layer so it can be chrome-colored")
    }

    // MARK: - showZoomPresets(currentZoomScale:levels:onSelect:) / clear() (issue #13)
    //
    // Previously zero coverage: this bar stayed permanently empty until the
    // magnifier tool's zoom-level dropdown became its first real control.

    private func popUpButton(in view: OptionBarView) -> NSPopUpButton? {
        view.subviews.compactMap { $0 as? NSPopUpButton }.first
    }

    func testShowZoomPresets_createsOneItemPerLevel_titledAsPercent() {
        let view = makeView()

        view.showZoomPresets(currentZoomScale: 4, levels: CanvasView.zoomLevels) { _ in }

        guard let popUp = popUpButton(in: view) else {
            XCTFail("showZoomPresets should add an NSPopUpButton")
            return
        }
        XCTAssertEqual(popUp.numberOfItems, CanvasView.zoomLevels.count)
        let titles = popUp.itemTitles
        let expectedTitles = CanvasView.zoomLevels.map { "\($0 * 100)%" }
        XCTAssertEqual(titles, expectedTitles)
    }

    func testShowZoomPresets_currentZoomScaleInLevels_selectsMatchingItem() {
        let view = makeView()

        view.showZoomPresets(currentZoomScale: 8, levels: CanvasView.zoomLevels) { _ in }

        guard let popUp = popUpButton(in: view) else {
            XCTFail("showZoomPresets should add an NSPopUpButton")
            return
        }
        let expectedIndex = CanvasView.zoomLevels.firstIndex(of: 8)
        XCTAssertEqual(popUp.indexOfSelectedItem, expectedIndex)
        XCTAssertEqual(popUp.titleOfSelectedItem, "800%")
    }

    func testShowZoomPresets_currentZoomScaleNotInLevels_leavesPopUpsOwnDefaultSelectionAsIs() {
        // `showZoomPresets` only calls `selectItem(at:)` on a match; when
        // `currentZoomScale` isn't one of `levels` at all, it makes no
        // selection call, so whatever `NSPopUpButton` selects by default
        // after items are added (empirically: the first item) is left
        // standing untouched, rather than the method forcing some fallback
        // selection of its own.
        let view = makeView()

        view.showZoomPresets(currentZoomScale: 999, levels: CanvasView.zoomLevels) { _ in }

        guard let popUp = popUpButton(in: view) else {
            XCTFail("showZoomPresets should add an NSPopUpButton")
            return
        }
        XCTAssertEqual(popUp.indexOfSelectedItem, 0, "with no match, the popup's own default (first item) selection must be left untouched")
    }

    func testShowZoomPresets_changingPopUpSelection_firesOnSelectWithTheChosenLevel() {
        let view = makeView()
        var selectedLevels: [Int] = []
        view.showZoomPresets(currentZoomScale: 4, levels: CanvasView.zoomLevels) { selectedLevels.append($0) }

        guard let popUp = popUpButton(in: view) else {
            XCTFail("showZoomPresets should add an NSPopUpButton")
            return
        }
        let targetIndex = CanvasView.zoomLevels.firstIndex(of: 32)!
        popUp.selectItem(at: targetIndex)
        _ = popUp.sendAction(popUp.action, to: popUp.target)

        XCTAssertEqual(selectedLevels, [32], "onSelect must receive the Int zoom level the user picked, not the popup's title string or index")
    }

    func testShowZoomPresets_calledTwiceInARow_leavesOnlyOnePopUpButton() {
        let view = makeView()

        view.showZoomPresets(currentZoomScale: 4, levels: CanvasView.zoomLevels) { _ in }
        view.showZoomPresets(currentZoomScale: 8, levels: CanvasView.zoomLevels) { _ in }

        let popUps = view.subviews.compactMap { $0 as? NSPopUpButton }
        XCTAssertEqual(popUps.count, 1, "a second call must not leave the first call's popup behind")
        XCTAssertEqual(view.subviews.count, 1, "no other stray subviews should accumulate either")
    }

    func testClear_removesAllSubviews() {
        let view = makeView()
        view.showZoomPresets(currentZoomScale: 4, levels: CanvasView.zoomLevels) { _ in }
        XCTAssertFalse(view.subviews.isEmpty, "precondition: the popup was added")

        view.clear()

        XCTAssertTrue(view.subviews.isEmpty, "clear() must remove every control, returning to the empty chrome frame")
    }

    func testClear_priorOnSelectCallbackIsNoLongerInvoked() {
        // Detach the popup itself from the view via `clear()`, but hold on
        // to the Swift reference so its target/action can still be fired
        // directly — this is what actually proves `clear()` severs
        // `OptionBarView`'s stored `onSelect` closure, as opposed to merely
        // proving the (now-orphaned) button is gone from the view tree.
        let view = makeView()
        var selectedLevels: [Int] = []
        view.showZoomPresets(currentZoomScale: 4, levels: CanvasView.zoomLevels) { selectedLevels.append($0) }
        guard let popUp = popUpButton(in: view) else {
            XCTFail("showZoomPresets should add an NSPopUpButton")
            return
        }

        view.clear()
        popUp.selectItem(at: CanvasView.zoomLevels.firstIndex(of: 16)!)
        _ = popUp.sendAction(popUp.action, to: popUp.target)

        XCTAssertTrue(selectedLevels.isEmpty, "firing the old, now-detached popup's action after clear() must not reach the stale onSelect closure")
    }

    // MARK: - showMagicWandOptions(currentTolerance:onToleranceChanged:) / clear() (issue #11, round 3)
    //
    // Same "previously zero coverage" situation as `showZoomPresets` above:
    // this bar's second-ever control, added once the magic wand tool needed
    // a tolerance slider.

    private func toleranceSlider(in view: OptionBarView) -> NSSlider? {
        view.subviews.compactMap { $0 as? NSSlider }.first
    }

    private func toleranceValueLabel(in view: OptionBarView) -> NSTextField? {
        // Two `NSTextField`s are added ("許容誤差" label, then the numeric
        // readout) — the value readout is added last.
        view.subviews.compactMap { $0 as? NSTextField }.last
    }

    func testShowMagicWandOptions_sliderInitialValueMatchesCurrentTolerance() {
        let view = makeView()

        view.showMagicWandOptions(currentTolerance: 47) { _ in }

        guard let slider = toleranceSlider(in: view) else {
            XCTFail("showMagicWandOptions should add an NSSlider")
            return
        }
        XCTAssertEqual(slider.doubleValue, 47, accuracy: 0.001)
    }

    func testShowMagicWandOptions_changingSlider_firesOnToleranceChangedWithIntValue_andUpdatesTheValueLabel() {
        let view = makeView()
        var receivedValues: [Int] = []
        view.showMagicWandOptions(currentTolerance: 32) { receivedValues.append($0) }

        guard let slider = toleranceSlider(in: view) else {
            XCTFail("showMagicWandOptions should add an NSSlider")
            return
        }
        slider.doubleValue = 128
        _ = slider.sendAction(slider.action, to: slider.target)

        XCTAssertEqual(receivedValues, [128], "onToleranceChanged must receive the Int tolerance the user dragged to, not the slider's own Double")
        XCTAssertEqual(toleranceValueLabel(in: view)?.stringValue, "128", "the numeric readout must stay in sync with the slider")
    }

    func testClear_afterShowMagicWandOptions_removesSliderAndDetachesOldCallback() {
        let view = makeView()
        var receivedValues: [Int] = []
        view.showMagicWandOptions(currentTolerance: 32) { receivedValues.append($0) }
        guard let slider = toleranceSlider(in: view) else {
            XCTFail("showMagicWandOptions should add an NSSlider")
            return
        }

        view.clear()

        XCTAssertTrue(view.subviews.isEmpty, "clear() must remove the slider, label, and value readout, same as it does for the zoom popup")
        slider.doubleValue = 200
        _ = slider.sendAction(slider.action, to: slider.target)
        XCTAssertTrue(receivedValues.isEmpty, "firing the old, now-detached slider's action after clear() must not reach the stale onToleranceChanged closure")
    }
}
