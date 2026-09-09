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

    // MARK: - showPenOptions(settings:onSizeChanged:onHardnessChanged:onOpacityChanged:onFlowChanged:) / clear() (issue #20)
    //
    // Same "previously zero coverage" situation as `showMagicWandOptions`
    // above: the pen's four sliders (サイズ/硬さ/不透明度/フロー) had no test
    // of their own. `showPenOptions` lays the four groups out in a fixed
    // order (size, hardness, opacity, flow — see its own doc comment), and
    // each group adds its own "label, slider, value readout" in that order
    // (see its loop), so both `subviews.compactMap { $0 as? NSSlider }` and
    // the value-readout half of `subviews.compactMap { $0 as? NSTextField }`
    // come back in that same size/hardness/opacity/flow order.

    private func penSliders(in view: OptionBarView) -> [NSSlider] {
        view.subviews.compactMap { $0 as? NSSlider }
    }

    private func penValueLabels(in view: OptionBarView) -> [NSTextField] {
        // 8 text fields total (4 groups x "title label" + "value readout"),
        // added title-then-value per group — so the value readouts are the
        // odd-indexed half.
        view.subviews.compactMap { $0 as? NSTextField }
            .enumerated()
            .filter { $0.offset % 2 == 1 }
            .map { $0.element }
    }

    func testShowPenOptions_slidersInitialValuesMatchCurrentSettings() {
        let view = makeView()
        var settings = PenBrushSettings()
        settings.size = 10
        settings.hardness = 0.3
        settings.opacity = 0.6
        settings.flow = 0.9

        view.showPenOptions(settings: settings, onSizeChanged: { _ in }, onHardnessChanged: { _ in }, onOpacityChanged: { _ in }, onFlowChanged: { _ in })

        let sliders = penSliders(in: view)
        XCTAssertEqual(sliders.count, 4, "showPenOptions should add exactly 4 sliders: size/hardness/opacity/flow")
        XCTAssertEqual(sliders[0].doubleValue, 10, accuracy: 0.001, "size slider should start at the current settings' size")
        XCTAssertEqual(sliders[1].doubleValue, 0.3, accuracy: 0.001, "hardness slider should start at the current settings' hardness")
        XCTAssertEqual(sliders[2].doubleValue, 0.6, accuracy: 0.001, "opacity slider should start at the current settings' opacity")
        XCTAssertEqual(sliders[3].doubleValue, 0.9, accuracy: 0.001, "flow slider should start at the current settings' flow")
    }

    func testShowPenOptions_changingSizeSlider_firesOnSizeChangedWithCGFloatValue_andUpdatesValueLabel() {
        let view = makeView()
        var receivedValues: [CGFloat] = []
        view.showPenOptions(
            settings: PenBrushSettings(),
            onSizeChanged: { receivedValues.append($0) },
            onHardnessChanged: { _ in },
            onOpacityChanged: { _ in },
            onFlowChanged: { _ in }
        )
        let sizeSlider = penSliders(in: view)[0]
        sizeSlider.doubleValue = 25
        _ = sizeSlider.sendAction(sizeSlider.action, to: sizeSlider.target)

        XCTAssertEqual(receivedValues, [25], "onSizeChanged must receive the CGFloat size the user dragged to")
        XCTAssertEqual(penValueLabels(in: view)[0].stringValue, "25", "the size readout is a plain rounded point value, not a percentage")
    }

    func testShowPenOptions_changingHardnessSlider_firesOnHardnessChangedWithPercentLabel() {
        let view = makeView()
        var receivedValues: [Double] = []
        view.showPenOptions(
            settings: PenBrushSettings(),
            onSizeChanged: { _ in },
            onHardnessChanged: { receivedValues.append($0) },
            onOpacityChanged: { _ in },
            onFlowChanged: { _ in }
        )
        let hardnessSlider = penSliders(in: view)[1]
        hardnessSlider.doubleValue = 0.25
        _ = hardnessSlider.sendAction(hardnessSlider.action, to: hardnessSlider.target)

        XCTAssertEqual(receivedValues, [0.25], "onHardnessChanged must receive the raw 0...1 Double the user dragged to, not a percentage")
        XCTAssertEqual(penValueLabels(in: view)[1].stringValue, "25%", "the hardness readout is a rounded percentage, matching LayerPanelView's opacity-slider convention")
    }

    func testShowPenOptions_changingOpacitySlider_firesOnOpacityChangedWithPercentLabel() {
        let view = makeView()
        var receivedValues: [Double] = []
        view.showPenOptions(
            settings: PenBrushSettings(),
            onSizeChanged: { _ in },
            onHardnessChanged: { _ in },
            onOpacityChanged: { receivedValues.append($0) },
            onFlowChanged: { _ in }
        )
        let opacitySlider = penSliders(in: view)[2]
        opacitySlider.doubleValue = 0.75
        _ = opacitySlider.sendAction(opacitySlider.action, to: opacitySlider.target)

        XCTAssertEqual(receivedValues, [0.75], "onOpacityChanged must receive the raw 0...1 Double the user dragged to, not a percentage")
        XCTAssertEqual(penValueLabels(in: view)[2].stringValue, "75%", "the opacity readout is a rounded percentage")
    }

    func testShowPenOptions_changingFlowSlider_firesOnFlowChangedWithPercentLabel() {
        let view = makeView()
        var receivedValues: [Double] = []
        view.showPenOptions(
            settings: PenBrushSettings(),
            onSizeChanged: { _ in },
            onHardnessChanged: { _ in },
            onOpacityChanged: { _ in },
            onFlowChanged: { receivedValues.append($0) }
        )
        let flowSlider = penSliders(in: view)[3]
        flowSlider.doubleValue = 0.4
        _ = flowSlider.sendAction(flowSlider.action, to: flowSlider.target)

        XCTAssertEqual(receivedValues, [0.4], "onFlowChanged must receive the raw 0...1 Double the user dragged to, not a percentage")
        XCTAssertEqual(penValueLabels(in: view)[3].stringValue, "40%", "the flow readout is a rounded percentage")
    }

    func testClear_afterShowPenOptions_removesAllFourSlidersAndDetachesAllCallbacks() {
        let view = makeView()
        var sizeValues: [CGFloat] = []
        var hardnessValues: [Double] = []
        var opacityValues: [Double] = []
        var flowValues: [Double] = []
        view.showPenOptions(
            settings: PenBrushSettings(),
            onSizeChanged: { sizeValues.append($0) },
            onHardnessChanged: { hardnessValues.append($0) },
            onOpacityChanged: { opacityValues.append($0) },
            onFlowChanged: { flowValues.append($0) }
        )
        let sliders = penSliders(in: view)
        XCTAssertEqual(sliders.count, 4, "precondition: all 4 sliders present")

        view.clear()

        XCTAssertTrue(view.subviews.isEmpty, "clear() must remove every pen control, label, and value readout")
        for slider in sliders {
            slider.doubleValue = 42
            _ = slider.sendAction(slider.action, to: slider.target)
        }
        XCTAssertTrue(sizeValues.isEmpty, "firing the old, now-detached size slider after clear() must not reach the stale onSizeChanged closure")
        XCTAssertTrue(hardnessValues.isEmpty, "...nor the stale onHardnessChanged closure")
        XCTAssertTrue(opacityValues.isEmpty, "...nor the stale onOpacityChanged closure")
        XCTAssertTrue(flowValues.isEmpty, "...nor the stale onFlowChanged closure")
    }

    func testShowPenOptions_calledTwiceInARow_leavesOnlyFourSliders_notEight() {
        let view = makeView()

        view.showPenOptions(settings: PenBrushSettings(), onSizeChanged: { _ in }, onHardnessChanged: { _ in }, onOpacityChanged: { _ in }, onFlowChanged: { _ in })
        view.showPenOptions(settings: PenBrushSettings(), onSizeChanged: { _ in }, onHardnessChanged: { _ in }, onOpacityChanged: { _ in }, onFlowChanged: { _ in })

        XCTAssertEqual(penSliders(in: view).count, 4, "a second call must not leave the first call's 4 sliders behind")
        XCTAssertEqual(view.subviews.count, 12, "no other stray subviews should accumulate either (4 groups x 3 views each)")
    }
}
