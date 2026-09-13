import AppKit
import XCTest
@testable import paintestCore

final class LayerStackTests: XCTestCase {
    func testCompositeImage_topLayerPixelOverridesBottomLayerBackground() {
        let stack = LayerStack(width: 4, height: 4, background: .white)
        stack.addLayer()
        XCTAssertEqual(stack.activeLayerIndex, 1)
        stack.activeLayer.canvas.setPixel(x: 1, y: 1, color: .black)

        guard let composite = stack.compositeImage() else {
            XCTFail("compositeImage() returned nil")
            return
        }
        let rep = NSBitmapImageRep(cgImage: composite)
        let blackPixel = rep.colorAt(x: 1, y: 1)
        let whitePixel = rep.colorAt(x: 0, y: 0)

        XCTAssertEqual(blackPixel?.usingColorSpace(.deviceRGB)?.redComponent ?? 1, 0, accuracy: 0.01)
        XCTAssertEqual(whitePixel?.usingColorSpace(.deviceRGB)?.redComponent ?? 0, 1, accuracy: 0.01)
    }

    // MARK: - addLayer (test list 1-3)

    func testAddLayer_insertsDirectlyAboveActiveLayer_notAlwaysAtTop() {
        // 3 layers, active is the middle one. addLayer() must land right
        // above the active layer (index 2), not appended at the very top.
        let stack = LayerStack(width: 2, height: 2, background: .white)
        stack.addLayer(name: "B") // index 1, active
        stack.addLayer(name: "C") // index 2, active
        stack.activeLayerIndex = 1 // make "B" active again
        stack.addLayer(name: "new")

        XCTAssertEqual(stack.layers.map { $0.name }, ["レイヤー1", "B", "new", "C"])
    }

    func testAddLayer_becomesTheNewActiveLayer() {
        let stack = LayerStack(width: 2, height: 2, background: .white)
        let added = stack.addLayer()
        XCTAssertTrue(stack.activeLayer === added)
    }

    func testAddLayer_defaultNamesAreSequential() {
        // Naming collisions after remove/re-add are explicitly not
        // guaranteed by this scheme (it only counts current layers at the
        // moment of insertion) — this test only pins the simple growing
        // case where no removal has happened yet.
        let stack = LayerStack(width: 2, height: 2, background: .white)
        let second = stack.addLayer()
        let third = stack.addLayer()
        XCTAssertEqual(second.name, "レイヤー2")
        XCTAssertEqual(third.name, "レイヤー3")
    }

    // MARK: - removeLayer (test list 4-7)

    func testRemoveLayer_lastRemainingLayer_isNoOp() {
        let stack = LayerStack(width: 2, height: 2, background: .white)
        stack.removeLayer(at: 0)
        XCTAssertEqual(stack.layers.count, 1, "a LayerStack always keeps at least one layer")
    }

    func testRemoveLayer_indexBelowZero_isNoOp() {
        let stack = LayerStack(width: 2, height: 2, background: .white)
        stack.addLayer()
        stack.removeLayer(at: -1)
        XCTAssertEqual(stack.layers.count, 2)
    }

    func testRemoveLayer_indexEqualsCount_isNoOp() {
        let stack = LayerStack(width: 2, height: 2, background: .white)
        stack.addLayer()
        stack.removeLayer(at: stack.layers.count)
        XCTAssertEqual(stack.layers.count, 2)
    }

    func testRemoveLayer_removingActiveLayerItself_shiftsActiveToValidRange() {
        // 3 layers, active is the middle one (index 1). Removing it leaves
        // no "previously active" object to re-find, so activeLayerIndex
        // falls back to the removal index clamped to the new bounds.
        let stack = LayerStack(width: 2, height: 2, background: .white)
        stack.addLayer(name: "B") // index 1, active
        stack.addLayer(name: "C") // index 2, active
        stack.activeLayerIndex = 1 // "B" active
        stack.removeLayer(at: 1)

        XCTAssertEqual(stack.layers.map { $0.name }, ["レイヤー1", "C"])
        XCTAssertEqual(stack.activeLayerIndex, 1)
        XCTAssertEqual(stack.activeLayer.name, "C")
    }

    func testRemoveLayer_removingNonActiveLayerBelowActive_activeStaysTrackedByObjectIdentity() {
        // Fixed behavior (was the bug this test locks in): removing a
        // non-active layer *below* the active one must not just re-clamp
        // the old numeric index — that would silently point
        // activeLayerIndex at the wrong layer once the array shifts down.
        // The active layer must keep being the same object.
        let stack = LayerStack(width: 2, height: 2, background: .white)
        stack.addLayer(name: "B") // index 1
        stack.addLayer(name: "C") // index 2, active
        let activeBeforeRemoval = stack.activeLayer
        XCTAssertEqual(activeBeforeRemoval.name, "C")

        stack.removeLayer(at: 0) // remove "レイヤー1", below the active layer

        XCTAssertTrue(stack.activeLayer === activeBeforeRemoval, "active layer must still be the same object, not re-derived from a stale index")
        XCTAssertEqual(stack.activeLayer.name, "C")
        XCTAssertEqual(stack.activeLayerIndex, 1, "\"C\" shifted down one slot when \"レイヤー1\" was removed")
    }

    // MARK: - duplicateLayer (test list 8-12)

    func testDuplicateLayer_preservesPixelContent() {
        let stack = LayerStack(width: 2, height: 2, background: .white)
        stack.activeLayer.canvas.setPixel(x: 0, y: 0, color: .black)
        stack.activeLayer.canvas.setPixel(x: 1, y: 1, color: NSColor(deviceRed: 0.2, green: 0.4, blue: 0.6, alpha: 1))

        guard let duplicate = stack.duplicateLayer(at: 0) else {
            XCTFail("duplicateLayer returned nil")
            return
        }

        XCTAssertEqual(duplicate.canvas.rawPixel(x: 0, y: 0)?.r, 0)
        let blended = duplicate.canvas.rawPixel(x: 1, y: 1)
        XCTAssertEqual(blended?.r, 51) // 0.2 * 255, rounded
        XCTAssertEqual(blended?.g, 102) // 0.4 * 255, rounded
        XCTAssertEqual(blended?.b, 153) // 0.6 * 255, rounded
    }

    func testDuplicateLayer_appendsCopySuffixToName() {
        let stack = LayerStack(width: 2, height: 2, background: .white)
        guard let duplicate = stack.duplicateLayer(at: 0) else {
            XCTFail("duplicateLayer returned nil")
            return
        }
        XCTAssertEqual(duplicate.name, "レイヤー1 のコピー")
    }

    func testDuplicateLayer_insertsDirectlyAboveSourceAndBecomesActive() {
        let stack = LayerStack(width: 2, height: 2, background: .white)
        stack.addLayer(name: "B") // index 1
        stack.addLayer(name: "C") // index 2, active

        guard let duplicate = stack.duplicateLayer(at: 0) else {
            XCTFail("duplicateLayer returned nil")
            return
        }

        XCTAssertEqual(stack.layers.map { $0.name }, ["レイヤー1", "レイヤー1 のコピー", "B", "C"])
        XCTAssertTrue(stack.activeLayer === duplicate)
        XCTAssertEqual(stack.activeLayerIndex, 1)
    }

    func testDuplicateLayer_outOfRangeIndex_returnsNil() {
        let stack = LayerStack(width: 2, height: 2, background: .white)
        XCTAssertNil(stack.duplicateLayer(at: -1))
        XCTAssertNil(stack.duplicateLayer(at: stack.layers.count))
    }

    func testDuplicateLayer_editingDuplicateDoesNotAffectSource() {
        let stack = LayerStack(width: 2, height: 2, background: .white)
        guard let duplicate = stack.duplicateLayer(at: 0) else {
            XCTFail("duplicateLayer returned nil")
            return
        }
        duplicate.canvas.setPixel(x: 0, y: 0, color: .black)

        XCTAssertEqual(duplicate.canvas.rawPixel(x: 0, y: 0)?.r, 0)
        XCTAssertEqual(stack.layers[0].canvas.rawPixel(x: 0, y: 0)?.r, 255, "editing the duplicate's canvas must not mutate the source layer's canvas")
    }

    func testDuplicateLayer_preservesBlendMode() {
        // Regression test (independent review of issue #40's PR, must-1):
        // `duplicateLayer` used to build its `Layer(...)` without a
        // `blendMode:` argument at all, silently defaulting the copy to
        // `.normal` regardless of the source layer's own blend mode.
        let stack = LayerStack(width: 2, height: 2, background: .white)
        stack.setBlendMode(.multiply, at: 0)

        guard let duplicate = stack.duplicateLayer(at: 0) else {
            XCTFail("duplicateLayer returned nil")
            return
        }

        XCTAssertEqual(duplicate.blendMode, .multiply, "duplicating a layer must carry over its blend mode, not silently reset it to .normal")
    }

    // MARK: - moveLayer (test list 13-15)

    func testMoveLayer_tracksActiveLayerByObjectIdentityWhenAnotherLayerMoves() {
        // 3 layers, "C" is active (index 2). Moving an *unrelated* layer
        // ("レイヤー1", index 0) to the end shifts everything else down by
        // one — activeLayerIndex must follow the object, not stay frozen
        // at the old numeric index.
        let stack = LayerStack(width: 2, height: 2, background: .white)
        stack.addLayer(name: "B") // index 1
        stack.addLayer(name: "C") // index 2, active
        let activeBeforeMove = stack.activeLayer

        stack.moveLayer(from: 0, to: 2)

        XCTAssertEqual(stack.layers.map { $0.name }, ["B", "C", "レイヤー1"])
        XCTAssertTrue(stack.activeLayer === activeBeforeMove)
        XCTAssertEqual(stack.activeLayerIndex, 1)
    }

    func testMoveLayer_sameSourceAndDestination_isNoOp() {
        let stack = LayerStack(width: 2, height: 2, background: .white)
        stack.addLayer(name: "B")
        let namesBefore = stack.layers.map { $0.name }
        let activeBefore = stack.activeLayerIndex

        stack.moveLayer(from: 1, to: 1)

        XCTAssertEqual(stack.layers.map { $0.name }, namesBefore)
        XCTAssertEqual(stack.activeLayerIndex, activeBefore)
    }

    func testMoveLayer_outOfRangeSourceIndex_isNoOp() {
        let stack = LayerStack(width: 2, height: 2, background: .white)
        stack.addLayer(name: "B")
        let namesBefore = stack.layers.map { $0.name }

        stack.moveLayer(from: -1, to: 0)
        stack.moveLayer(from: stack.layers.count, to: 0)

        XCTAssertEqual(stack.layers.map { $0.name }, namesBefore)
    }

    func testMoveLayer_outOfRangeDestinationIndex_isNoOp() {
        let stack = LayerStack(width: 2, height: 2, background: .white)
        stack.addLayer(name: "B")
        let namesBefore = stack.layers.map { $0.name }

        stack.moveLayer(from: 0, to: -1)
        stack.moveLayer(from: 0, to: stack.layers.count)

        XCTAssertEqual(stack.layers.map { $0.name }, namesBefore)
    }

    // MARK: - setOpacity clamping (test list 16-17, boundary values 3)

    func testSetOpacity_belowZeroBoundary_clampsToZero() {
        let stack = LayerStack(width: 2, height: 2, background: .white)
        stack.setOpacity(-0.0001, at: 0)
        XCTAssertEqual(stack.layers[0].opacity, 0)

        stack.setOpacity(0.0, at: 0)
        XCTAssertEqual(stack.layers[0].opacity, 0)

        stack.setOpacity(0.0001, at: 0)
        XCTAssertEqual(stack.layers[0].opacity, 0.0001, accuracy: 0.00001, "just above zero must not be clamped")
    }

    func testSetOpacity_aboveOneBoundary_clampsToOne() {
        let stack = LayerStack(width: 2, height: 2, background: .white)
        stack.setOpacity(0.9999, at: 0)
        XCTAssertEqual(stack.layers[0].opacity, 0.9999, accuracy: 0.00001, "just below one must not be clamped")

        stack.setOpacity(1.0, at: 0)
        XCTAssertEqual(stack.layers[0].opacity, 1.0)

        stack.setOpacity(1.0001, at: 0)
        XCTAssertEqual(stack.layers[0].opacity, 1.0)
    }

    func testSetOpacity_outOfRangeIndex_isNoOp() {
        let stack = LayerStack(width: 2, height: 2, background: .white)
        let opacityBefore = stack.layers[0].opacity
        stack.setOpacity(0.3, at: -1)
        stack.setOpacity(0.3, at: stack.layers.count)
        XCTAssertEqual(stack.layers[0].opacity, opacityBefore)
    }

    // MARK: - setVisibility (test list 19)

    func testSetVisibility_outOfRangeIndex_isNoOp() {
        let stack = LayerStack(width: 2, height: 2, background: .white)
        let visibilityBefore = stack.layers[0].isVisible
        stack.setVisibility(false, at: -1)
        stack.setVisibility(false, at: stack.layers.count)
        XCTAssertEqual(stack.layers[0].isVisible, visibilityBefore)
    }

    // MARK: - setBlendMode / blend-mode compositing (issue #37)

    func testNewLayer_defaultsToNormalBlendMode() {
        let stack = LayerStack(width: 2, height: 2, background: .white)
        XCTAssertEqual(stack.layers[0].blendMode, .normal)
        stack.addLayer()
        XCTAssertEqual(stack.activeLayer.blendMode, .normal)
    }

    func testSetBlendMode_outOfRangeIndex_isNoOp() {
        let stack = LayerStack(width: 2, height: 2, background: .white)
        stack.setBlendMode(.multiply, at: -1)
        stack.setBlendMode(.multiply, at: stack.layers.count)
        XCTAssertEqual(stack.layers[0].blendMode, .normal)
    }

    func testSetBlendMode_changesLayerBlendMode() {
        let stack = LayerStack(width: 2, height: 2, background: .white)
        stack.setBlendMode(.screen, at: 0)
        XCTAssertEqual(stack.layers[0].blendMode, .screen)
    }

    /// Bottom layer gray(200) + top layer gray(100) at full opacity, one
    /// test per blend mode. Values chosen so each mode's textbook per-channel
    /// formula (with an opaque backdrop, `B(Cb, Cs)` alone determines the
    /// result — see `LayerStack.compositeImage`'s bypass-cache comment)
    /// lands on a distinct expected value, well clear of the others and of
    /// plain source-over's (100): multiply ≈ 78, screen ≈ 222, overlay ≈
    /// 188. A ±15 tolerance absorbs any sRGB/deviceRGB color-management
    /// rounding (same reasoning `testCompositeImage_bothVisible_halfOpacity_
    /// blendsIntoAMiddleColor` above already uses a wide tolerance for)
    /// without blurring together which mode actually ran.
    private func makeTwoGrayLayerStack(blendMode: LayerBlendMode) -> LayerStack {
        // `NSColor(deviceRed:green:blue:alpha:)`, not `.white`-family
        // convenience initializers, to avoid any calibrated/generic-space
        // gamma conversion on the way into `PixelCanvas`'s deviceRGB bitmap
        // (see `PixelCanvas.components(of:)`) — the exact byte values this
        // test's expected numbers are computed from.
        let bottom = NSColor(deviceRed: 200.0 / 255.0, green: 200.0 / 255.0, blue: 200.0 / 255.0, alpha: 1)
        let top = NSColor(deviceRed: 100.0 / 255.0, green: 100.0 / 255.0, blue: 100.0 / 255.0, alpha: 1)
        let stack = LayerStack(width: 2, height: 2, background: bottom)
        stack.addLayer()
        stack.activeLayer.canvas.fill(with: top)
        stack.setBlendMode(blendMode, at: 1)
        return stack
    }

    func testCompositeImage_multiplyBlendMode_darkensTowardTheirProduct() {
        let stack = makeTwoGrayLayerStack(blendMode: .multiply)
        guard let composite = stack.compositeImage(), let pixel = rawRGBA(of: composite, x: 0, y: 0) else {
            XCTFail("compositeImage() returned nil")
            return
        }
        XCTAssertEqual(Double(pixel.r), 78, accuracy: 15)
    }

    func testCompositeImage_screenBlendMode_lightensTowardTheirInverseProduct() {
        let stack = makeTwoGrayLayerStack(blendMode: .screen)
        guard let composite = stack.compositeImage(), let pixel = rawRGBA(of: composite, x: 0, y: 0) else {
            XCTFail("compositeImage() returned nil")
            return
        }
        XCTAssertEqual(Double(pixel.r), 222, accuracy: 15)
    }

    func testCompositeImage_overlayBlendMode_combinesMultiplyAndScreen() {
        let stack = makeTwoGrayLayerStack(blendMode: .overlay)
        guard let composite = stack.compositeImage(), let pixel = rawRGBA(of: composite, x: 0, y: 0) else {
            XCTFail("compositeImage() returned nil")
            return
        }
        XCTAssertEqual(Double(pixel.r), 188, accuracy: 15)
    }

    func testCompositeImage_afterSetBlendMode_reflectsChangeImmediately() {
        // Mirrors testCompositeImage_afterSetOpacity_reflectsChangeImmediately
        // above: a blend-mode change must not serve a stale
        // backgroundCompositeCache result (issue #17 integration).
        let stack = makeTwoGrayLayerStack(blendMode: .normal)
        guard let beforePixel = stack.compositeImage().flatMap({ rawRGBA(of: $0, x: 0, y: 0) }) else {
            XCTFail("compositeImage() returned nil")
            return
        }
        XCTAssertEqual(beforePixel.r, 100, "normal blend at full opacity should just show the top layer's own color")

        stack.setBlendMode(.multiply, at: 1)
        guard let afterPixel = stack.compositeImage().flatMap({ rawRGBA(of: $0, x: 0, y: 0) }) else {
            XCTFail("compositeImage() returned nil")
            return
        }
        XCTAssertEqual(Double(afterPixel.r), 78, accuracy: 15)
    }

    func testCopy_preservesBlendMode() {
        let stack = LayerStack(width: 2, height: 2, background: .white)
        stack.setBlendMode(.overlay, at: 0)
        let copied = stack.copy()
        XCTAssertEqual(copied.layers[0].blendMode, .overlay)
    }

    // MARK: - mergeDown / flatten (issue #40)

    func testMergeDown_indexZero_isNoOp() {
        let stack = LayerStack(width: 2, height: 2, background: .white)
        stack.addLayer()
        let countBefore = stack.layers.count
        stack.mergeDown(at: 0)
        XCTAssertEqual(stack.layers.count, countBefore, "there's nothing beneath the bottom-most layer to merge into")
    }

    func testMergeDown_outOfRangeIndex_isNoOp() {
        let stack = LayerStack(width: 2, height: 2, background: .white)
        stack.addLayer()
        let countBefore = stack.layers.count
        stack.mergeDown(at: -1)
        stack.mergeDown(at: stack.layers.count)
        XCTAssertEqual(stack.layers.count, countBefore)
    }

    func testMergeDown_reducesLayerCountByOne_andKeepsTheLowerLayersName() {
        let stack = LayerStack(width: 2, height: 2, background: .white)
        stack.layers[0].name = "背景"
        stack.addLayer(name: "上")

        stack.mergeDown(at: 1)

        XCTAssertEqual(stack.layers.count, 1)
        XCTAssertEqual(stack.layers[0].name, "背景")
    }

    func testMergeDown_makesTheMergedLayerActive() {
        let stack = LayerStack(width: 2, height: 2, background: .white)
        stack.addLayer() // index 1, active
        stack.addLayer() // index 2, active

        stack.mergeDown(at: 2)

        XCTAssertEqual(stack.activeLayerIndex, 1, "the merged layer replaces index 1 (the lower of the merged pair)")
    }

    func testMergeDown_mergedLayer_resetsOpacityAndVisibilityButCarriesOverLowerLayersBlendMode() {
        // Issue #37 integration + issue #40 self-review must-2: opacity is
        // baked into the merged pixels themselves, so the merged layer's
        // own opacity must reset to the value (`1.0`) that applies nothing
        // further, and the merged layer is always visible regardless of
        // either original layer's own visibility. `blendMode` is NOT baked
        // in the same way — it describes how the merged layer's *slot*
        // relates to whatever still sits further below it in the full
        // stack — so it carries over unchanged from the lower layer
        // (index 0's original `.multiply`) instead of being forced to
        // `.normal`. See `LayerStack.mergeDown`'s own doc comment.
        let stack = LayerStack(width: 2, height: 2, background: .white)
        stack.setOpacity(0.4, at: 0)
        stack.setBlendMode(.multiply, at: 0)
        stack.setVisibility(false, at: 0)
        stack.addLayer()
        stack.setOpacity(0.6, at: 1)
        stack.setBlendMode(.screen, at: 1)

        stack.mergeDown(at: 1)

        XCTAssertEqual(stack.layers[0].opacity, 1)
        XCTAssertEqual(stack.layers[0].blendMode, .multiply, "carries over the lower layer's (index 0) original blend mode, not reset to .normal")
        XCTAssertTrue(stack.layers[0].isVisible)
    }

    func testMergeDown_twoLayerStack_normalBlend_matchesPreMergeCompositeExactly() {
        // With exactly two layers, the lower one truly has nothing beneath
        // it — the same situation `mergeDown`'s isolated two-layer draw
        // assumes — so for `.normal` blend mode this must reproduce
        // `compositeImage()`'s own pre-merge result exactly, not just
        // approximately.
        let stack = LayerStack(width: 2, height: 2, background: .white)
        stack.setOpacity(0.5, at: 0)
        stack.addLayer()
        stack.activeLayer.canvas.fill(with: NSColor(deviceRed: 0, green: 0, blue: 1, alpha: 0.7))
        stack.setOpacity(0.8, at: 1)

        guard let before = stack.compositeImage(), let beforePixel = rawRGBA(of: before, x: 0, y: 0) else {
            XCTFail("compositeImage() returned nil")
            return
        }

        stack.mergeDown(at: 1)

        guard let after = stack.compositeImage(), let afterPixel = rawRGBA(of: after, x: 0, y: 0) else {
            XCTFail("compositeImage() returned nil")
            return
        }
        XCTAssertEqual(Double(afterPixel.r), Double(beforePixel.r), accuracy: 1)
        XCTAssertEqual(Double(afterPixel.g), Double(beforePixel.g), accuracy: 1)
        XCTAssertEqual(Double(afterPixel.b), Double(beforePixel.b), accuracy: 1)
        XCTAssertEqual(Double(afterPixel.a), Double(beforePixel.a), accuracy: 1)
    }

    func testMergeDown_hiddenLowerLayer_discardsItsContentEntirely() {
        let stack = LayerStack(width: 2, height: 2, background: .white)
        stack.setVisibility(false, at: 0) // hidden white background
        stack.addLayer()
        stack.activeLayer.canvas.fill(with: .black)

        stack.mergeDown(at: 1)

        guard let composite = stack.compositeImage(), let pixel = rawRGBA(of: composite, x: 0, y: 0) else {
            XCTFail("compositeImage() returned nil")
            return
        }
        XCTAssertEqual(pixel.r, 0, "the hidden lower layer's white must not show through; only the visible black upper layer should")
    }

    func testMergeDown_hiddenUpperLayer_discardsItsContentEntirely() {
        let stack = LayerStack(width: 2, height: 2, background: .white)
        stack.addLayer()
        stack.activeLayer.canvas.fill(with: .black)
        stack.setVisibility(false, at: 1) // hidden black top layer

        stack.mergeDown(at: 1)

        guard let composite = stack.compositeImage(), let pixel = rawRGBA(of: composite, x: 0, y: 0) else {
            XCTFail("compositeImage() returned nil")
            return
        }
        XCTAssertEqual(pixel.r, 255, "the hidden upper layer's black must not show through; only the visible white lower layer should")
    }

    func testMergeDown_bothLayersHidden_mergedLayerIsStillForcedVisible_producingATransparentCanvas() {
        // nit (independent review of issue #40's PR): NOT a behavior
        // change — `mergeDown` always forces the merged layer's own
        // `isVisible` to `true` (see its own doc comment), regardless of
        // whether either original layer was itself hidden. With BOTH
        // original layers hidden, `mergedCanvas` draws neither of them
        // (each draw is behind its own `isVisible` guard), so the merged
        // layer ends up visible but with a fully transparent canvas. This
        // test just pins that existing, intentionally-unchanged behavior
        // — not a claim that it's the "correct" outcome.
        let stack = LayerStack(width: 2, height: 2, background: .white)
        stack.setVisibility(false, at: 0)
        stack.addLayer()
        stack.activeLayer.canvas.fill(with: .black)
        stack.setVisibility(false, at: 1)

        stack.mergeDown(at: 1)

        XCTAssertTrue(stack.layers[0].isVisible, "current behavior: mergeDown always forces the merged layer visible, even when both merged layers were hidden")
        guard let composite = stack.compositeImage(), let pixel = rawRGBA(of: composite, x: 0, y: 0) else {
            XCTFail("compositeImage() returned nil")
            return
        }
        XCTAssertEqual(pixel.a, 0, "neither original layer was ever drawn (both hidden), so the merged canvas is fully transparent")
    }

    func testMergeDown_threeLayerStack_mergedBlendModeCarriesOverAndCompositeMatchesHandComputedApproximation() {
        // 3-layer stack (issue #40 self-review must-2's own motivating
        // scenario): L0 normal/opaque gray(200), L1 multiply/opaque
        // gray(30) — an arbitrary, distinguishable value chosen
        // specifically to prove it has NO effect on the outcome below —
        // L2 normal/opaque gray(100). Merging L2 into L1
        // (`mergeDown(at: 2)`) must carry the merged layer's `blendMode`
        // over from L1 (`.multiply`), per this fix.
        //
        // Hand trace of `mergedCanvas(lower: L1, upper: L2)`:
        //   - L1 is drawn first (blendMode `.multiply`) onto an initially
        //     empty (alpha 0) context: a blend mode's backdrop term
        //     vanishes against zero backdrop alpha, so this just paints
        //     L1's own color, gray(30), at full opacity — L1's blend mode
        //     has no observable effect here at all.
        //   - L2 is then drawn on top (blendMode `.normal`, i.e.
        //     source-over) at full opacity, fully opaque: source-over
        //     with source alpha 1 completely overwrites whatever was
        //     beneath it, regardless of that color. Result: flat
        //     gray(100) — L2's own color exactly; L1's gray(30) never
        //     survives into the merged canvas at all.
        // So the merged layer (now at index 1)'s canvas is a flat
        // gray(100), same as if L1 had never existed — but its own
        // `blendMode` metadata is still `.multiply` (carried over from
        // L1, per this fix), NOT `.normal`.
        //
        // `compositeImage()` of [L0 gray(200) normal, merged gray(100)
        // multiply] therefore retroactively multiply-blends L2's own
        // color against L0: multiply(200, 100) = 200*100/255 ≈ 78.4 —
        // the same formula `makeTwoGrayLayerStack`'s own multiply test
        // above derives and pins to ~78, same ±15 tolerance kept here for
        // the same sRGB/deviceRGB rounding reasons documented there.
        //
        // KNOWN APPROXIMATION EXAMPLE: the *true* pre-merge composite of
        // all three layers is just gray(100) — L2 sits on top, fully
        // opaque and `.normal`-blended, so it completely covers
        // everything beneath it (L0's gray(200) multiplied by L1's
        // gray(30) included) regardless of any blend mode further down.
        // After merging, that same visible gray(100) gets
        // multiply-blended against L0 all over again, producing ~78
        // instead of the "true" 100 — exactly the kind of case
        // `mergeDown`'s own doc comment calls out as an unavoidable
        // approximation once opacity/blend modes are involved. Pinned
        // here (rather than "fixed") so a future change to this behavior
        // is caught instead of silently drifting further, per kako-jun's
        // decision on issue #40 self-review must-2 to keep current
        // behavior and document it rather than rewrite the merge
        // algorithm.
        let bottom = NSColor(deviceRed: 200.0 / 255.0, green: 200.0 / 255.0, blue: 200.0 / 255.0, alpha: 1)
        let middle = NSColor(deviceRed: 30.0 / 255.0, green: 30.0 / 255.0, blue: 30.0 / 255.0, alpha: 1)
        let top = NSColor(deviceRed: 100.0 / 255.0, green: 100.0 / 255.0, blue: 100.0 / 255.0, alpha: 1)
        let stack = LayerStack(width: 2, height: 2, background: bottom) // L0
        stack.addLayer() // L1
        stack.activeLayer.canvas.fill(with: middle)
        stack.setBlendMode(.multiply, at: 1)
        stack.addLayer() // L2
        stack.activeLayer.canvas.fill(with: top)

        stack.mergeDown(at: 2)

        XCTAssertEqual(stack.layers.count, 2)
        XCTAssertEqual(stack.layers[1].blendMode, .multiply, "the merged layer must carry over L1's original blend mode, not reset to .normal")

        guard let composite = stack.compositeImage(), let pixel = rawRGBA(of: composite, x: 0, y: 0) else {
            XCTFail("compositeImage() returned nil")
            return
        }
        XCTAssertEqual(Double(pixel.r), 78, accuracy: 15, "known approximation: L2's own color (which fully covered L1 during the merge) is now retroactively multiply-blended against L0, instead of showing as L2's true un-blended gray(100)")
    }

    func testFlatten_singleLayer_isNoOp_layerCountStaysOne() {
        let stack = LayerStack(width: 2, height: 2, background: .white)
        stack.flatten()
        XCTAssertEqual(stack.layers.count, 1)
    }

    func testFlatten_singleNonDefaultLayer_stillNormalizesOpacityBlendModeAndVisibility() {
        // Issue #37 integration: even though `flatten()`'s own loop never
        // runs for a single-layer stack, the sole remaining layer must
        // still come out fully opaque / `.normal` / visible.
        let stack = LayerStack(width: 2, height: 2, background: .white)
        stack.setOpacity(0.3, at: 0)
        stack.setBlendMode(.multiply, at: 0)
        stack.setVisibility(false, at: 0)

        stack.flatten()

        XCTAssertEqual(stack.layers[0].opacity, 1)
        XCTAssertEqual(stack.layers[0].blendMode, .normal)
        XCTAssertTrue(stack.layers[0].isVisible)
    }

    func testFlatten_multipleLayers_reducesToExactlyOneLayer_keepingBottomLayersName() {
        let stack = LayerStack(width: 2, height: 2, background: .white)
        stack.layers[0].name = "背景"
        stack.addLayer(name: "中")
        stack.addLayer(name: "上")

        stack.flatten()

        XCTAssertEqual(stack.layers.count, 1)
        XCTAssertEqual(stack.layers[0].name, "背景")
        XCTAssertEqual(stack.activeLayerIndex, 0)
    }

    func testFlatten_discardsHiddenLayersContentEntirely() {
        let stack = LayerStack(width: 2, height: 2, background: .white)
        stack.addLayer(name: "中")
        stack.activeLayer.canvas.fill(with: NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1))
        stack.setVisibility(false, at: 1) // hidden red middle layer
        stack.addLayer(name: "上")
        stack.activeLayer.canvas.fill(with: .black)

        stack.flatten()

        guard let composite = stack.compositeImage(), let pixel = rawRGBA(of: composite, x: 0, y: 0) else {
            XCTFail("compositeImage() returned nil")
            return
        }
        XCTAssertEqual(pixel.r, 0, "the hidden red middle layer must not tint the result; only the visible black top layer should show")
    }

    func testFlatten_preservesOverallCompositeForAllNormalBlendVisibleLayers() {
        let stack = LayerStack(width: 2, height: 2, background: .white)
        stack.setOpacity(0.5, at: 0)
        stack.addLayer(name: "中")
        stack.activeLayer.canvas.fill(with: NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1))
        stack.setOpacity(0.5, at: 1)
        stack.addLayer(name: "上")
        stack.activeLayer.canvas.fill(with: NSColor(deviceRed: 0, green: 0, blue: 1, alpha: 1))
        stack.setOpacity(0.5, at: 2)

        guard let before = stack.compositeImage(), let beforePixel = rawRGBA(of: before, x: 0, y: 0) else {
            XCTFail("compositeImage() returned nil")
            return
        }

        stack.flatten()

        guard let after = stack.compositeImage(), let afterPixel = rawRGBA(of: after, x: 0, y: 0) else {
            XCTFail("compositeImage() returned nil")
            return
        }
        XCTAssertEqual(Double(afterPixel.r), Double(beforePixel.r), accuracy: 1)
        XCTAssertEqual(Double(afterPixel.g), Double(beforePixel.g), accuracy: 1)
        XCTAssertEqual(Double(afterPixel.b), Double(beforePixel.b), accuracy: 1)
        XCTAssertEqual(Double(afterPixel.a), Double(beforePixel.a), accuracy: 1)
    }

    // MARK: - resampled(toWidth:toHeight:) (issue #39: 画像解像度)

    func testResampled_upscale_pointSamplesEachSourcePixelIntoABlock() {
        // 2x2 source, each pixel a distinct solid color, upscaled to 4x4:
        // nearest-neighbor must duplicate each source pixel into its own
        // 2x2 block of the destination, not blend/interpolate between them.
        let stack = LayerStack(width: 2, height: 2, background: .white)
        let canvas = stack.layers[0].canvas
        canvas.setPixel(x: 0, y: 0, color: NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1)) // red
        canvas.setPixel(x: 1, y: 0, color: NSColor(deviceRed: 0, green: 1, blue: 0, alpha: 1)) // green
        canvas.setPixel(x: 0, y: 1, color: NSColor(deviceRed: 0, green: 0, blue: 1, alpha: 1)) // blue
        canvas.setPixel(x: 1, y: 1, color: .black)

        let resampled = stack.resampled(toWidth: 4, toHeight: 4)

        XCTAssertEqual(resampled.width, 4)
        XCTAssertEqual(resampled.height, 4)
        let newCanvas = resampled.layers[0].canvas
        XCTAssertEqual(newCanvas.rawPixel(x: 0, y: 0)?.r, 255, "top-left block must sample the source's red pixel")
        XCTAssertEqual(newCanvas.rawPixel(x: 1, y: 1)?.r, 255, "still inside the top-left block")
        XCTAssertEqual(newCanvas.rawPixel(x: 2, y: 0)?.g, 255, "top-right block must sample the source's green pixel")
        XCTAssertEqual(newCanvas.rawPixel(x: 0, y: 2)?.b, 255, "bottom-left block must sample the source's blue pixel")
        XCTAssertEqual(newCanvas.rawPixel(x: 3, y: 3)?.r, 0, "bottom-right block must sample the source's black pixel")
    }

    func testResampled_downscale_pointSamplesWithoutAveraging() {
        // 4x1 source with 4 distinct solid colors, downscaled to 2x1:
        // nearest-neighbor point sampling (not box-filter averaging) must
        // pick exactly one source column per destination column.
        let stack = LayerStack(width: 4, height: 1, background: .white)
        let canvas = stack.layers[0].canvas
        canvas.setPixel(x: 0, y: 0, color: NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1))
        canvas.setPixel(x: 1, y: 0, color: NSColor(deviceRed: 0, green: 1, blue: 0, alpha: 1))
        canvas.setPixel(x: 2, y: 0, color: NSColor(deviceRed: 0, green: 0, blue: 1, alpha: 1))
        canvas.setPixel(x: 3, y: 0, color: .black)

        let resampled = stack.resampled(toWidth: 2, toHeight: 1)

        let newCanvas = resampled.layers[0].canvas
        XCTAssertEqual(newCanvas.rawPixel(x: 0, y: 0)?.r, 255, "destination column 0 must sample source column 0 (red)")
        XCTAssertEqual(newCanvas.rawPixel(x: 1, y: 0)?.b, 255, "destination column 1 must sample source column 2 (blue)")
    }

    func testResampled_preservesLayerAttributesAndActiveLayerIndex() {
        let stack = LayerStack(width: 2, height: 2, background: .white)
        stack.layers[0].name = "背景"
        stack.setOpacity(0.4, at: 0)
        stack.setBlendMode(.multiply, at: 0)
        stack.setVisibility(false, at: 0)
        stack.addLayer(name: "上")

        let resampled = stack.resampled(toWidth: 4, toHeight: 4)

        XCTAssertEqual(resampled.layers.count, 2)
        XCTAssertEqual(resampled.layers[0].name, "背景")
        XCTAssertEqual(resampled.layers[0].opacity, 0.4, accuracy: 0.0001)
        XCTAssertEqual(resampled.layers[0].blendMode, .multiply)
        XCTAssertFalse(resampled.layers[0].isVisible)
        XCTAssertEqual(resampled.layers[1].name, "上")
        XCTAssertEqual(resampled.activeLayerIndex, stack.activeLayerIndex)
    }

    func testResampled_preservesAlpha() {
        let stack = LayerStack(width: 2, height: 2, background: .clear)
        stack.layers[0].canvas.setPixel(x: 0, y: 0, color: NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 0.5))

        let resampled = stack.resampled(toWidth: 4, toHeight: 4)

        let alpha = resampled.layers[0].canvas.rawPixel(x: 0, y: 0)?.a
        XCTAssertEqual(Double(alpha ?? 0), 128, accuracy: 1)
    }

    func testResampled_doesNotMutateTheOriginalStack() {
        let stack = LayerStack(width: 2, height: 2, background: .white)
        _ = stack.resampled(toWidth: 4, toHeight: 4)
        XCTAssertEqual(stack.width, 2)
        XCTAssertEqual(stack.height, 2)
    }

    func testResampled_zeroOrNegativeSize_clampsToOne() {
        let stack = LayerStack(width: 2, height: 2, background: .white)
        let resampled = stack.resampled(toWidth: 0, toHeight: -5)
        XCTAssertEqual(resampled.width, 1)
        XCTAssertEqual(resampled.height, 1)
    }

    // MARK: - resized(toWidth:toHeight:anchor:) (issue #39: カンバスサイズ)

    func testResized_growingCanvas_topLeftAnchor_keepsOldContentAtOriginAndPadsRightAndBottom() {
        let stack = LayerStack(width: 2, height: 2, background: .clear)
        stack.layers[0].canvas.fill(with: .black)

        let resized = stack.resized(toWidth: 4, toHeight: 4, anchor: .topLeft)

        let canvas = resized.layers[0].canvas
        XCTAssertEqual(canvas.rawPixel(x: 0, y: 0)?.a, 255, "old content stays at the origin")
        XCTAssertEqual(canvas.rawPixel(x: 1, y: 1)?.a, 255, "old content stays at the origin")
        XCTAssertEqual(canvas.rawPixel(x: 3, y: 3)?.a, 0, "newly added bottom-right area must be transparent")
        XCTAssertEqual(canvas.rawPixel(x: 2, y: 0)?.a, 0, "newly added right-side area must be transparent")
    }

    func testResized_growingCanvas_centerAnchor_padsEquallyOnAllSides() {
        let stack = LayerStack(width: 2, height: 2, background: .clear)
        stack.layers[0].canvas.fill(with: .black)

        let resized = stack.resized(toWidth: 6, toHeight: 6, anchor: .center)

        let canvas = resized.layers[0].canvas
        // (6-2)/2 == 2, so the old 2x2 content should land at (2,2)-(3,3).
        XCTAssertEqual(canvas.rawPixel(x: 2, y: 2)?.a, 255)
        XCTAssertEqual(canvas.rawPixel(x: 3, y: 3)?.a, 255)
        XCTAssertEqual(canvas.rawPixel(x: 0, y: 0)?.a, 0, "padding on all four sides must be transparent")
        XCTAssertEqual(canvas.rawPixel(x: 5, y: 5)?.a, 0)
        XCTAssertEqual(canvas.rawPixel(x: 1, y: 1)?.a, 0, "just outside the centered content")
        XCTAssertEqual(canvas.rawPixel(x: 4, y: 4)?.a, 0)
    }

    func testResized_growingCanvas_bottomRightAnchor_keepsOldContentFlushToBottomRight() {
        let stack = LayerStack(width: 2, height: 2, background: .clear)
        stack.layers[0].canvas.fill(with: .black)

        let resized = stack.resized(toWidth: 4, toHeight: 4, anchor: .bottomRight)

        let canvas = resized.layers[0].canvas
        XCTAssertEqual(canvas.rawPixel(x: 2, y: 2)?.a, 255, "old content is flush against the bottom-right corner")
        XCTAssertEqual(canvas.rawPixel(x: 3, y: 3)?.a, 255)
        XCTAssertEqual(canvas.rawPixel(x: 0, y: 0)?.a, 0, "newly added top-left area must be transparent")
    }

    func testResized_shrinkingCanvas_topLeftAnchor_clipsAwayTheRightAndBottom() {
        let stack = LayerStack(width: 4, height: 4, background: .clear)
        stack.layers[0].canvas.fill(with: .black)

        let resized = stack.resized(toWidth: 2, toHeight: 2, anchor: .topLeft)

        let canvas = resized.layers[0].canvas
        XCTAssertEqual(canvas.rawPixel(x: 0, y: 0)?.a, 255, "the surviving top-left portion keeps its content")
        XCTAssertEqual(canvas.rawPixel(x: 1, y: 1)?.a, 255)
        XCTAssertNil(canvas.rawPixel(x: 2, y: 2), "outside the new, smaller canvas entirely")
    }

    func testResized_shrinkingCanvas_centerAnchor_keepsACenteredCrop() {
        // 4x4 source, only the very center 2x2 (x=1..2, y=1..2) is black,
        // everything else transparent; shrinking to 2x2 with a center
        // anchor must keep exactly that center crop.
        let stack = LayerStack(width: 4, height: 4, background: .clear)
        let canvas = stack.layers[0].canvas
        canvas.setPixel(x: 1, y: 1, color: .black)
        canvas.setPixel(x: 2, y: 1, color: .black)
        canvas.setPixel(x: 1, y: 2, color: .black)
        canvas.setPixel(x: 2, y: 2, color: .black)

        let resized = stack.resized(toWidth: 2, toHeight: 2, anchor: .center)

        let newCanvas = resized.layers[0].canvas
        XCTAssertEqual(newCanvas.rawPixel(x: 0, y: 0)?.a, 255)
        XCTAssertEqual(newCanvas.rawPixel(x: 1, y: 1)?.a, 255)
    }

    func testResized_preservesExactPixelColor_noResampling() {
        let stack = LayerStack(width: 2, height: 2, background: .clear)
        stack.layers[0].canvas.setPixel(x: 0, y: 0, color: NSColor(deviceRed: 0.4, green: 0.2, blue: 0.6, alpha: 0.8))

        let resized = stack.resized(toWidth: 4, toHeight: 4, anchor: .topLeft)

        let original = stack.layers[0].canvas.rawPixel(x: 0, y: 0)
        let copied = resized.layers[0].canvas.rawPixel(x: 0, y: 0)
        XCTAssertEqual(copied?.r, original?.r, "resizing must never resample a surviving pixel's exact color")
        XCTAssertEqual(copied?.g, original?.g)
        XCTAssertEqual(copied?.b, original?.b)
        XCTAssertEqual(copied?.a, original?.a)
    }

    func testResized_preservesLayerAttributesAndActiveLayerIndex() {
        let stack = LayerStack(width: 2, height: 2, background: .white)
        stack.layers[0].name = "背景"
        stack.setOpacity(0.4, at: 0)
        stack.setBlendMode(.screen, at: 0)
        stack.setVisibility(false, at: 0)
        stack.addLayer(name: "上")

        let resized = stack.resized(toWidth: 4, toHeight: 4, anchor: .center)

        XCTAssertEqual(resized.layers.count, 2)
        XCTAssertEqual(resized.layers[0].name, "背景")
        XCTAssertEqual(resized.layers[0].opacity, 0.4, accuracy: 0.0001)
        XCTAssertEqual(resized.layers[0].blendMode, .screen)
        XCTAssertFalse(resized.layers[0].isVisible)
        XCTAssertEqual(resized.layers[1].name, "上")
        XCTAssertEqual(resized.activeLayerIndex, stack.activeLayerIndex)
    }

    func testResized_multipleLayers_appliesConsistentlyToEveryLayer() {
        let stack = LayerStack(width: 2, height: 2, background: .clear)
        stack.layers[0].canvas.fill(with: NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1))
        stack.addLayer()
        stack.activeLayer.canvas.fill(with: NSColor(deviceRed: 0, green: 0, blue: 1, alpha: 1))

        let resized = stack.resized(toWidth: 4, toHeight: 4, anchor: .topLeft)

        XCTAssertEqual(resized.layers[0].canvas.rawPixel(x: 0, y: 0)?.r, 255)
        XCTAssertEqual(resized.layers[1].canvas.rawPixel(x: 0, y: 0)?.b, 255)
        XCTAssertEqual(resized.layers[0].canvas.rawPixel(x: 3, y: 3)?.a, 0)
        XCTAssertEqual(resized.layers[1].canvas.rawPixel(x: 3, y: 3)?.a, 0)
    }

    func testResized_doesNotMutateTheOriginalStack() {
        let stack = LayerStack(width: 2, height: 2, background: .white)
        _ = stack.resized(toWidth: 4, toHeight: 4, anchor: .center)
        XCTAssertEqual(stack.width, 2)
        XCTAssertEqual(stack.height, 2)
    }

    // MARK: - init(width:height:layers:activeLayerIndex:) (test list 20-21)

    func testInit_emptyLayersArray_fallsBackToSingleBlankLayer() {
        let stack = LayerStack(width: 5, height: 5, layers: [], activeLayerIndex: 0)
        XCTAssertEqual(stack.layers.count, 1, "a LayerStack always keeps at least one layer")
        XCTAssertEqual(stack.layers[0].name, "レイヤー1")
    }

    func testInit_activeLayerIndexBelowZero_clampsToZero() {
        let layers = [Layer(canvas: PixelCanvas(width: 2, height: 2), name: "A"), Layer(canvas: PixelCanvas(width: 2, height: 2), name: "B")]
        let stack = LayerStack(width: 2, height: 2, layers: layers, activeLayerIndex: -1)
        XCTAssertEqual(stack.activeLayerIndex, 0)
    }

    func testInit_activeLayerIndexEqualsCount_clampsToLastIndex() {
        let layers = [Layer(canvas: PixelCanvas(width: 2, height: 2), name: "A"), Layer(canvas: PixelCanvas(width: 2, height: 2), name: "B")]
        let stack = LayerStack(width: 2, height: 2, layers: layers, activeLayerIndex: layers.count)
        XCTAssertEqual(stack.activeLayerIndex, layers.count - 1)
    }

    // MARK: - compositeImage decision table (test list 22, decision table 2-1)

    /// Reads raw RGBA bytes directly out of a composited `CGImage`'s data
    /// provider, bypassing `NSBitmapImageRep.colorAt(x:y:)`. Mirrors
    /// `PixelCanvasTests`' documented reason for avoiding `colorAt` on
    /// alpha=0 pixels: it can be unstable/zeroed by OS-level fast paths for
    /// fully-transparent content, whereas the raw bytes in the CGImage's own
    /// buffer (produced directly by `LayerStack.compositeImage()`, not a
    /// PNG round trip) are exactly what the compositor wrote.
    private func rawRGBA(of image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8)? {
        guard let data = image.dataProvider?.data else { return nil }
        let ptr = CFDataGetBytePtr(data)
        let bytesPerRow = image.bytesPerRow
        let bpp = image.bitsPerPixel / 8
        let offset = y * bytesPerRow + x * bpp
        guard let bytes = ptr else { return nil }
        return (bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3])
    }

    func testCompositeImage_bothVisible_fullOpacity_showsTopLayerColor() {
        let stack = LayerStack(width: 2, height: 2, background: .white) // L1: bottom, white
        stack.addLayer() // L2: top, transparent by default
        stack.activeLayer.canvas.fill(with: .black)
        stack.setOpacity(1.0, at: 1)

        guard let composite = stack.compositeImage(), let pixel = rawRGBA(of: composite, x: 0, y: 0) else {
            XCTFail("compositeImage() returned nil")
            return
        }
        XCTAssertEqual(pixel.r, 0, "fully opaque top layer should completely cover the bottom layer")
        XCTAssertEqual(pixel.a, 255)
    }

    func testCompositeImage_bothVisible_zeroOpacity_showsBottomLayerColor() {
        let stack = LayerStack(width: 2, height: 2, background: .white) // L1: bottom, white
        stack.addLayer() // L2: top
        stack.activeLayer.canvas.fill(with: .black)
        stack.setOpacity(0.0, at: 1)

        guard let composite = stack.compositeImage(), let pixel = rawRGBA(of: composite, x: 0, y: 0) else {
            XCTFail("compositeImage() returned nil")
            return
        }
        XCTAssertEqual(pixel.r, 255, "a fully transparent top layer must not tint the bottom layer at all")
    }

    func testCompositeImage_bothVisible_halfOpacity_blendsIntoAMiddleColor() {
        let stack = LayerStack(width: 2, height: 2, background: .white) // L1: bottom, white
        stack.addLayer() // L2: top
        stack.activeLayer.canvas.fill(with: .black)
        stack.setOpacity(0.5, at: 1)

        guard let composite = stack.compositeImage() else {
            XCTFail("compositeImage() returned nil")
            return
        }
        let rep = NSBitmapImageRep(cgImage: composite)
        let red = rep.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB)?.redComponent
        // Not asserting an exact blend value: sRGB-aware compositing does
        // not necessarily land exactly on the naive linear 0.5 midpoint.
        // What this test locks in is that half opacity produces neither
        // pure white nor pure black — i.e. that setOpacity/setAlpha is
        // actually taking effect on the draw, not being ignored.
        // (Unlike the `rawRGBA`-based tests in this file, this one reads
        // the pixel through `colorAt` + `usingColorSpace(.deviceRGB)`,
        // which applies its own ColorSync conversion on top of the above —
        // another reason a wide tolerance is used here instead of an exact
        // comparison.)
        XCTAssertNotNil(red)
        XCTAssertGreaterThan(red ?? 1, 0.05, "should not be pure black")
        XCTAssertLessThan(red ?? 0, 0.95, "should not be pure white")
    }

    func testCompositeImage_topHidden_showsOnlyBottomLayer() {
        let stack = LayerStack(width: 2, height: 2, background: .white) // L1: bottom, white
        stack.addLayer() // L2: top
        stack.activeLayer.canvas.fill(with: .black)
        stack.setVisibility(false, at: 1)

        guard let composite = stack.compositeImage(), let pixel = rawRGBA(of: composite, x: 0, y: 0) else {
            XCTFail("compositeImage() returned nil")
            return
        }
        XCTAssertEqual(pixel.r, 255, "hidden top layer must be excluded from the composite regardless of its opacity")
    }

    func testCompositeImage_bottomHidden_showsTopLayerAloneOverTransparentBackdrop() {
        let stack = LayerStack(width: 2, height: 2, background: .white) // L1: bottom
        stack.addLayer() // L2: top
        stack.activeLayer.canvas.fill(with: .black)
        stack.setVisibility(false, at: 0)

        guard let composite = stack.compositeImage(), let pixel = rawRGBA(of: composite, x: 0, y: 0) else {
            XCTFail("compositeImage() returned nil")
            return
        }
        XCTAssertEqual(pixel.r, 0)
        XCTAssertEqual(pixel.a, 255, "the visible top layer alone is still fully opaque even with no backdrop")
    }

    func testCompositeImage_allLayersHidden_returnsFullyTransparentImage_notNil() {
        let stack = LayerStack(width: 2, height: 2, background: .white)
        stack.setVisibility(false, at: 0)

        guard let composite = stack.compositeImage() else {
            XCTFail("compositeImage() must still return an image (fully transparent), not nil, when every layer is hidden")
            return
        }
        guard let pixel = rawRGBA(of: composite, x: 0, y: 0) else {
            XCTFail("expected pixel (0,0) to be readable")
            return
        }
        XCTAssertEqual(pixel.r, 0, "every channel including alpha must be zero when nothing is drawn")
        XCTAssertEqual(pixel.g, 0)
        XCTAssertEqual(pixel.b, 0)
        XCTAssertEqual(pixel.a, 0)
    }

    func testCompositeImage_orderReversedViaMoveLayer_changesBlendResult() {
        // Two fully-opaque, distinguishable colors: whichever one is on
        // top after the reorder should be the one the composite shows —
        // proving compositeImage() recomputes from the *current* layer
        // order, not some order cached at construction time.
        let stack = LayerStack(width: 2, height: 2, background: .white)
        stack.layers[0].canvas.fill(with: NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1)) // L1: red
        stack.addLayer()
        stack.activeLayer.canvas.fill(with: NSColor(deviceRed: 0, green: 1, blue: 0, alpha: 1)) // L2: green, currently on top

        guard let beforeComposite = stack.compositeImage(), let beforePixel = rawRGBA(of: beforeComposite, x: 0, y: 0) else {
            XCTFail("compositeImage() returned nil")
            return
        }
        XCTAssertEqual(beforePixel.g, 255, "green (L2) is on top before reordering")

        stack.moveLayer(from: 0, to: 1) // red now on top

        guard let afterComposite = stack.compositeImage(), let afterPixel = rawRGBA(of: afterComposite, x: 0, y: 0) else {
            XCTFail("compositeImage() returned nil")
            return
        }
        XCTAssertEqual(afterPixel.r, 255, "red is on top after moveLayer reversed the order")
        XCTAssertEqual(afterPixel.g, 0)
    }

    /// should-4/5 (PR #36 self-review): every other `compositeImage()` test
    /// above either (a) keeps the active layer topmost while only
    /// reordering two *inactive* layers, or (b) excludes the active layer
    /// entirely — none of them call the plain, non-excluding
    /// `compositeImage()` on a stack where a visible layer sits *below*
    /// the active layer AND a visible layer sits *above* it at the same
    /// time, which is exactly the `below → activeLayer → above` shape
    /// `backgroundCompositeCache` and `composite(below:activeLayer:above:)`
    /// exist to handle (see their doc comments). And the cache-hit-vs-miss
    /// tests below this one can't stand in for that: both paths call the
    /// same `composite(below:activeLayer:above:)`, so a wrong blend
    /// formula there would make cache hit and miss agree with each other
    /// while still being wrong. This test instead checks the result
    /// against a value derived independently, straight from the source-over
    /// alpha formula, not from any other call to this module's own code.
    func testCompositeImage_activeLayerSandwichedBetweenVisibleLayers_producesCorrectBlend() {
        // L0 (below, non-active):  opaque red   (255, 0, 0, 255)
        // L1 (ACTIVE, middle):     opaque green (0, 255, 0, 255) canvas,
        //                          layer opacity 0.75 — translucent via
        //                          the *layer's* opacity.
        // L2 (above, non-active):  opaque-alpha-wise canvas draw, but the
        //                          fill color's own alpha is 0.25, i.e.
        //                          translucent via the *canvas pixel's own
        //                          alpha* instead — a different mechanism
        //                          than L1's, so the sandwich exercises
        //                          both at once. `PixelCanvas.components(of:)`
        //                          rounds 0.25 * 255 = 63.75 to 64
        //                          (`.rounded()` is round-half-away-from-
        //                          zero, and 63.75 isn't even a tie), so
        //                          L2's canvas alpha byte is exactly 64,
        //                          not some other rounding of 0.25 — every
        //                          number below is derived from that 64.
        let stack = LayerStack(width: 2, height: 2, background: .white)
        stack.layers[0].canvas.fill(with: NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1)) // L0
        stack.addLayer() // L1, active for now
        stack.activeLayer.canvas.fill(with: NSColor(deviceRed: 0, green: 1, blue: 0, alpha: 1))
        stack.setOpacity(0.75, at: 1)
        stack.addLayer() // L2, active for now (topmost)
        stack.activeLayer.canvas.fill(with: NSColor(deviceRed: 0, green: 0, blue: 1, alpha: 0.25))
        stack.activeLayerIndex = 1 // re-designate L1 as active: L0 is now below it, L2 above it

        guard let composite = stack.compositeImage(), let pixel = rawRGBA(of: composite, x: 0, y: 0) else {
            XCTFail("compositeImage() returned nil")
            return
        }

        // Hand-derived expected value, plain source-over compositing
        // applied bottom-to-top, destination starting fully transparent:
        //
        // Draw L0 (opaque) onto empty: the destination contributes nothing
        // at alpha 0, so the result is just L0's own color exactly:
        //   (255, 0, 0, 255)
        //
        // Draw L1 over that at its own opacity (0.75), i.e. effective
        // source alpha 0.75 over an opaque (alpha 1) destination:
        //   outA = 0.75 + 1*(1 - 0.75)              = 1
        //   outR = 0*0.75 + 255*1*(1 - 0.75)        = 63.75
        //   outG = 255*0.75 + 0*1*(1 - 0.75)        = 191.25
        //   outB = 0
        // 63.75/191.25 must still be rounded to an 8-bit byte somewhere in
        // this pipeline, and this environment has no Swift toolchain to
        // confirm whether that rounds-to-nearest or truncates — the two
        // conventions agree on 191 (`.25` rounds/floors to the same
        // integer) but disagree on 63.75 (63 vs 64). Call that byte R_mid
        // ∈ {63, 64}; G_mid = 191 either way.
        //
        // Draw L2 over that (canvas alpha 64/255, layer opacity 1.0, so
        // effective source alpha is exactly 64/255) over the now-opaque
        // destination:
        //   outA = 64/255 + 1*(1 - 64/255)          = 1
        //   outR = 0*(64/255) + R_mid*(1 - 64/255)  = R_mid * 191/255
        //        = 64*191/255 ≈ 47.94   or   63*191/255 ≈ 47.18
        //   outG = 0*(64/255) + 191*(191/255)       = 36481/255 ≈ 143.06
        //   outB = 255*(64/255) + 0*(1 - 64/255)    = 64  (exact — no
        //          fractional part to round, so this channel is pinned
        //          regardless of the R_mid ambiguity above)
        //   outA = 255 (exact — both blend steps land on outA = 1 exactly,
        //          with no fractional component to round at all)
        //
        // So R lands at 47 or 48 depending on the unresolved rounding
        // convention above (±0.6 around the 47.5 midpoint covers both,
        // and nothing else); G is pinned to 143 either way. A small ±2
        // margin is kept on R/G/B (but not A, which is never touched by
        // color management) as a hedge against the deviceRGB-vs-sRGB
        // color-space conversion this pipeline also performs (`Layer`'s
        // canvas is `.deviceRGB`, the compositing context is named
        // `sRGB`) that this environment cannot verify either way — a
        // margin still far tighter than the tens-of-units gap a genuinely
        // wrong blend (wrong stacking order, ignored opacity, ignored
        // alpha) would produce.
        XCTAssertEqual(pixel.a, 255, "an opaque bottom layer keeps the whole sandwich opaque")
        XCTAssertEqual(Double(pixel.r), 47.5, accuracy: 2.1, "expected ~47-48 (below*above blend of the L0/L1 midtone)")
        XCTAssertEqual(Double(pixel.g), 143, accuracy: 2, "expected ~143 (L1's green surviving both blends)")
        XCTAssertEqual(Double(pixel.b), 64, accuracy: 2, "expected exactly 64 (L2's own blue is this sandwich's only source of blue)")
    }

    // MARK: - copy() (issue #19: HistoryManager's copy-in/copy-out contract
    // depends entirely on this being a true deep copy)

    func testCopy_editingTheCopyDoesNotAffectTheOriginal() {
        let stack = LayerStack(width: 2, height: 2, background: .white)
        let duplicate = stack.copy()

        duplicate.activeLayer.canvas.setPixel(x: 0, y: 0, color: .black)

        XCTAssertEqual(duplicate.activeLayer.canvas.rawPixel(x: 0, y: 0)?.r, 0)
        XCTAssertEqual(stack.activeLayer.canvas.rawPixel(x: 0, y: 0)?.r, 255, "editing the copy's canvas must not mutate the original's canvas")
    }

    func testCopy_editingTheOriginalAfterCopyingDoesNotAffectTheCopy() {
        let stack = LayerStack(width: 2, height: 2, background: .white)
        let duplicate = stack.copy()

        stack.activeLayer.canvas.setPixel(x: 0, y: 0, color: .black)

        XCTAssertEqual(stack.activeLayer.canvas.rawPixel(x: 0, y: 0)?.r, 0)
        XCTAssertEqual(duplicate.activeLayer.canvas.rawPixel(x: 0, y: 0)?.r, 255, "editing the original's canvas after copying must not reach back into the copy")
    }

    func testCopy_preservesLayerCountNamesAndActiveLayerIndex() {
        let stack = LayerStack(width: 2, height: 2, background: .white)
        stack.addLayer(name: "B")
        stack.addLayer(name: "C")
        stack.activeLayerIndex = 1
        stack.setOpacity(0.5, at: 1)
        stack.setVisibility(false, at: 2)

        let duplicate = stack.copy()

        XCTAssertEqual(duplicate.layers.map { $0.name }, ["レイヤー1", "B", "C"])
        XCTAssertEqual(duplicate.activeLayerIndex, 1)
        XCTAssertEqual(duplicate.layers[1].opacity, 0.5)
        XCTAssertEqual(duplicate.layers[2].isVisible, false)
    }

    // MARK: - copy() with 2+ layers: per-layer independence (issue #19 test list 4)

    func testCopy_twoOrMoreLayers_editingOneLayerOfTheCopyLeavesTheOtherCopyLayerAndTheOriginalUntouched() {
        // Each layer gets its own distinct, opaque fill color (rather than
        // relying on `addLayer()`'s default `.clear` background, which would
        // make an untouched layer indistinguishable from a wrongly-aliased
        // one at this same pixel) so a genuine cross-layer aliasing bug and
        // an merely-still-blank layer can't be confused with each other.
        let stack = LayerStack(width: 2, height: 2, background: .white) // layer 0: white
        stack.addLayer() // layer 1
        stack.layers[1].canvas.fill(with: NSColor(deviceRed: 0, green: 1, blue: 0, alpha: 1)) // green
        stack.addLayer() // layer 2
        stack.layers[2].canvas.fill(with: NSColor(deviceRed: 0, green: 0, blue: 1, alpha: 1)) // blue
        let duplicate = stack.copy()

        duplicate.layers[1].canvas.setPixel(x: 0, y: 0, color: .black)

        XCTAssertEqual(duplicate.layers[1].canvas.rawPixel(x: 0, y: 0)?.r, 0, "the edited layer of the copy reflects the edit")
        XCTAssertEqual(duplicate.layers[0].canvas.rawPixel(x: 0, y: 0)?.r, 255, "an untouched layer (white) of the SAME copy must be unaffected")
        XCTAssertEqual(duplicate.layers[2].canvas.rawPixel(x: 0, y: 0)?.b, 255, "another untouched layer (blue) of the same copy must be unaffected")
        XCTAssertEqual(stack.layers[1].canvas.rawPixel(x: 0, y: 0)?.g, 255, "the original stack's corresponding layer (green) must be unaffected")
    }

    // MARK: - compositeImage backgroundCompositeCache (issue #17)

    /// Compares two composited images pixel-by-pixel (all four RGBA bytes
    /// at every coordinate), not just a couple of sampled points — used by
    /// tests that need to prove two `compositeImage()` results are the
    /// SAME image byte-for-byte (e.g. a cache-hit render vs. a cache-miss
    /// render of the identical state), where checking only one or two
    /// pixels could miss a discrepancy elsewhere in the buffer.
    private func assertCompositesEqual(_ a: CGImage, _ b: CGImage, width: Int, height: Int, file: StaticString = #filePath, line: UInt = #line) {
        guard let dataA = a.dataProvider?.data, let ptrA = CFDataGetBytePtr(dataA),
              let dataB = b.dataProvider?.data, let ptrB = CFDataGetBytePtr(dataB) else {
            XCTFail("could not read raw image data from one of the two composites", file: file, line: line)
            return
        }
        let bppA = a.bitsPerPixel / 8
        let bppB = b.bitsPerPixel / 8
        let rowA = a.bytesPerRow
        let rowB = b.bytesPerRow
        for y in 0..<height {
            for x in 0..<width {
                let offsetA = y * rowA + x * bppA
                let offsetB = y * rowB + x * bppB
                for channel in 0..<4 {
                    XCTAssertEqual(ptrA[offsetA + channel], ptrB[offsetB + channel], "pixel (\(x), \(y)) channel \(channel) differs between the two composites", file: file, line: line)
                }
            }
        }
    }

    func testCompositeImage_excludeNil_cacheHitVsCacheMiss_produceIdenticalResult() {
        // 3 layers, opacity/visibility mixed, active layer itself hidden —
        // exercises the "active layer is invisible" case on top of a
        // non-trivial (partially opaque) cached background.
        let stack = LayerStack(width: 2, height: 2, background: .white) // L0: white
        stack.addLayer() // L1
        stack.activeLayer.canvas.fill(with: NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1))
        stack.setOpacity(0.4, at: 1)
        stack.addLayer() // L2: active
        stack.activeLayer.canvas.fill(with: NSColor(deviceRed: 0, green: 0, blue: 1, alpha: 1))
        stack.setVisibility(false, at: 2)

        guard let firstCall = stack.compositeImage() else {
            XCTFail("compositeImage() returned nil")
            return
        }
        guard let secondCall = stack.compositeImage() else {
            XCTFail("compositeImage() returned nil")
            return
        }
        assertCompositesEqual(firstCall, secondCall, width: 2, height: 2)
    }

    func testCompositeImage_excludeActiveLayerIndex_matchesManualExclusionOfActiveLayer() {
        let stack = LayerStack(width: 2, height: 2, background: .white) // L0
        stack.addLayer() // L1
        stack.activeLayer.canvas.fill(with: NSColor(deviceRed: 0, green: 1, blue: 0, alpha: 1))
        stack.addLayer() // L2: active, topmost
        stack.activeLayer.canvas.fill(with: NSColor(deviceRed: 0, green: 0, blue: 1, alpha: 1))
        stack.activeLayerIndex = 1 // make the middle (green) layer active instead

        guard let excludedResult = stack.compositeImage(excludingLayerAtIndex: stack.activeLayerIndex) else {
            XCTFail("compositeImage(excludingLayerAtIndex:) returned nil")
            return
        }

        stack.setVisibility(false, at: 1) // manually hide what was the active layer
        guard let manualResult = stack.compositeImage() else {
            XCTFail("compositeImage() returned nil")
            return
        }

        assertCompositesEqual(excludedResult, manualResult, width: 2, height: 2)
    }

    func testCompositeImage_excludeOtherIndex_matchesManualExclusionOfThatLayer() {
        let stack = LayerStack(width: 2, height: 2, background: .white) // L0
        stack.addLayer() // L1
        stack.activeLayer.canvas.fill(with: NSColor(deviceRed: 0, green: 1, blue: 0, alpha: 1))
        stack.setOpacity(0.5, at: 1)
        stack.addLayer() // L2: active, topmost
        stack.activeLayer.canvas.fill(with: NSColor(deviceRed: 0, green: 0, blue: 1, alpha: 1))
        // activeLayerIndex == 2; exclude index 0, which is neither the
        // active layer nor nil — the cache must not be touched at all.

        guard let excludedResult = stack.compositeImage(excludingLayerAtIndex: 0) else {
            XCTFail("compositeImage(excludingLayerAtIndex:) returned nil")
            return
        }

        stack.setVisibility(false, at: 0)
        guard let manualResult = stack.compositeImage() else {
            XCTFail("compositeImage() returned nil")
            return
        }

        assertCompositesEqual(excludedResult, manualResult, width: 2, height: 2)
    }

    func testCompositeImage_repeatedCallsWithNoStateChange_areIdempotent() {
        let stack = LayerStack(width: 2, height: 2, background: .white)
        stack.addLayer()
        stack.activeLayer.canvas.fill(with: NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1))
        stack.setOpacity(0.5, at: 1)

        guard let first = stack.compositeImage(),
              let second = stack.compositeImage(),
              let third = stack.compositeImage() else {
            XCTFail("compositeImage() returned nil")
            return
        }

        assertCompositesEqual(first, second, width: 2, height: 2)
        assertCompositesEqual(second, third, width: 2, height: 2)
    }

    func testCompositeImage_afterSetVisibility_reflectsChangeImmediately() {
        let stack = LayerStack(width: 2, height: 2, background: .white) // L0: bottom, non-active
        stack.addLayer() // L1: top, active
        stack.activeLayer.canvas.fill(with: .black)
        stack.setOpacity(0.5, at: 1)
        _ = stack.compositeImage() // primes backgroundCompositeCache with the (still-visible) bottom layer

        stack.setVisibility(false, at: 0) // hide the non-active bottom layer

        guard let composite = stack.compositeImage(), let pixel = rawRGBA(of: composite, x: 0, y: 0) else {
            XCTFail("compositeImage() returned nil")
            return
        }
        XCTAssertLessThan(pixel.a, 250, "the cache must be invalidated: with the bottom layer now hidden, the half-opaque top layer alone can no longer be fully opaque")
    }

    func testCompositeImage_afterSetOpacity_reflectsChangeImmediately() {
        let stack = LayerStack(width: 2, height: 2, background: .white)
        stack.layers[0].canvas.fill(with: NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1)) // L0: opaque red, non-active
        stack.addLayer() // L1: active, transparent by default — lets L0 show through untouched
        _ = stack.compositeImage() // primes backgroundCompositeCache with L0 at full opacity

        stack.setOpacity(0.3, at: 0) // change the (non-active) bottom layer's opacity

        guard let composite = stack.compositeImage(), let pixel = rawRGBA(of: composite, x: 0, y: 0) else {
            XCTFail("compositeImage() returned nil")
            return
        }
        XCTAssertLessThan(pixel.a, 250, "the cache must be invalidated: the bottom layer's own reduced opacity must show up immediately")
    }

    func testCompositeImage_afterAddLayer_reflectsNewLayer() {
        let stack = LayerStack(width: 2, height: 2, background: .white)
        _ = stack.compositeImage() // primes the cache with just the base layer

        let added = stack.addLayer()
        added.canvas.fill(with: .black)

        guard let composite = stack.compositeImage(), let pixel = rawRGBA(of: composite, x: 0, y: 0) else {
            XCTFail("compositeImage() returned nil")
            return
        }
        XCTAssertEqual(pixel.r, 0, "the newly added (and now active) layer's fill must show in the composite")
    }

    func testCompositeImage_afterRemoveLayer_excludesRemovedLayer() {
        let stack = LayerStack(width: 2, height: 2, background: .white) // L0
        let toRemove = stack.addLayer() // L1
        toRemove.canvas.fill(with: .black)
        stack.addLayer() // L2: active, transparent, topmost
        _ = stack.compositeImage() // primes the cache

        stack.removeLayer(at: 1) // remove the (now non-active) black layer

        guard let composite = stack.compositeImage(), let pixel = rawRGBA(of: composite, x: 0, y: 0) else {
            XCTFail("compositeImage() returned nil")
            return
        }
        XCTAssertEqual(pixel.r, 255, "the removed layer's black fill must no longer appear in the composite")
    }

    func testCompositeImage_afterDuplicateLayer_includesDuplicate() {
        let stack = LayerStack(width: 2, height: 2, background: .white) // L0
        _ = stack.compositeImage() // primes the cache

        guard let duplicate = stack.duplicateLayer(at: 0) else {
            XCTFail("duplicateLayer returned nil")
            return
        }
        duplicate.canvas.setPixel(x: 0, y: 0, color: .black)

        guard let composite = stack.compositeImage(), let pixel = rawRGBA(of: composite, x: 0, y: 0) else {
            XCTFail("compositeImage() returned nil")
            return
        }
        XCTAssertEqual(pixel.r, 0, "the duplicated (and now active) layer's edited pixel must show in the composite")
    }

    func testCompositeImage_afterMoveLayer_reflectsNewStackingOrder() {
        // Both reordered layers are non-active — the active layer (L2,
        // transparent) stays topmost throughout, and never itself moves
        // (it's tracked by object identity). moveLayer still reassigns
        // `activeLayerIndex` unconditionally to the identical index it
        // already held, so this specifically exercises that same-value
        // reassignment's `didSet` as the sole cache-invalidation path here
        // — moveLayer has no explicit `backgroundCompositeCache = nil` of
        // its own.
        let stack = LayerStack(width: 2, height: 2, background: .white)
        stack.layers[0].canvas.fill(with: NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1)) // L0: red
        stack.addLayer() // L1
        stack.activeLayer.canvas.fill(with: NSColor(deviceRed: 0, green: 1, blue: 0, alpha: 1)) // L1: green
        stack.addLayer() // L2: active, transparent, topmost — never covers anything below it
        _ = stack.compositeImage() // primes the cache: green (L1) currently on top of red (L0)

        stack.moveLayer(from: 0, to: 1) // reorder the two non-active layers: red now on top of green

        guard let composite = stack.compositeImage(), let pixel = rawRGBA(of: composite, x: 0, y: 0) else {
            XCTFail("compositeImage() returned nil")
            return
        }
        XCTAssertEqual(pixel.r, 255, "red must now be on top after moveLayer reordered the two background layers")
        XCTAssertEqual(pixel.g, 0)
    }

    func testCompositeImage_afterDirectActiveLayerIndexAssignment_reflectsNewActiveLayer() {
        // Mirrors LayerPanelView.selectLayer(at:)'s call pattern: a direct
        // property assignment (`stack.activeLayerIndex = ...`), never a
        // method call — proving activeLayerIndex's didSet (not just the
        // explicit `backgroundCompositeCache = nil` calls sprinkled through
        // the other mutating methods) is what invalidates the cache here.
        let stack = LayerStack(width: 2, height: 2, background: .white) // L0
        stack.addLayer() // L1: active, transparent by default

        stack.activeLayerIndex = 0 // direct assignment, back to L0
        _ = stack.compositeImage(excludingLayerAtIndex: 0) // primes the cache with "everything except L0" == L1, still blank/transparent

        stack.activeLayerIndex = 1 // direct assignment, forward to L1 — must invalidate the cache
        stack.activeLayer.canvas.fill(with: .black) // edits L1's canvas directly, bypassing every LayerStack method

        stack.activeLayerIndex = 0 // direct assignment, back to L0 — same excludedIndex as the priming call above

        guard let composite = stack.compositeImage(excludingLayerAtIndex: 0),
              let pixel = rawRGBA(of: composite, x: 0, y: 0) else {
            XCTFail("compositeImage(excludingLayerAtIndex:) returned nil")
            return
        }
        XCTAssertEqual(pixel.a, 255, "excluding L0 must show L1's black fill fully opaque — a stale cache from before L1 was edited would still be blank/transparent (alpha 0)")
        XCTAssertEqual(pixel.r, 0)
    }

    func testCompositeImage_reassignActiveLayerIndexToSameValue_stillProducesCorrectResult() {
        // activeLayerIndex's didSet fires even when Swift reassigns the
        // exact same value it already held — proving that firing actually
        // invalidates the cache (rather than a hypothetical `oldValue !=
        // newValue` guard skipping it) requires an out-of-band background
        // edit that bypasses every LayerStack method's own explicit
        // invalidation, since only the reassignment itself is left to
        // notice the change.
        let stack = LayerStack(width: 2, height: 2, background: .white) // L0: non-active after addLayer
        stack.addLayer() // L1: active, transparent

        _ = stack.compositeImage() // primes the cache with L0 (white) as the background

        stack.layers[0].canvas.fill(with: .black) // edits the non-active L0 directly, bypassing setVisibility/setOpacity/etc.

        let sameActiveLayerIndex = stack.activeLayerIndex
        stack.activeLayerIndex = sameActiveLayerIndex // reassignment to the SAME value

        guard let composite = stack.compositeImage(), let pixel = rawRGBA(of: composite, x: 0, y: 0) else {
            XCTFail("compositeImage() returned nil")
            return
        }
        XCTAssertEqual(pixel.r, 0, "the same-value reassignment's didSet must still invalidate the cache, so L0's direct edit is picked up")
    }

    func testLayerStack_freshlyConstructed_firstCompositeImageCallSucceedsWithoutPriorInvalidation() {
        // `didSet` on a stored property is not invoked for the initial
        // value assigned inside `init` — so the very first compositeImage()
        // call, for either initializer, must still succeed correctly with
        // no prior invalidation trigger ever having run.
        let simple = LayerStack(width: 2, height: 2, background: .white)
        guard let simpleComposite = simple.compositeImage(), let simplePixel = rawRGBA(of: simpleComposite, x: 0, y: 0) else {
            XCTFail("compositeImage() returned nil for the width:height:background: initializer")
            return
        }
        XCTAssertEqual(simplePixel.r, 255)
        XCTAssertEqual(simplePixel.a, 255)

        let layers = [Layer(canvas: PixelCanvas(width: 2, height: 2, background: .black), name: "A")]
        let loaded = LayerStack(width: 2, height: 2, layers: layers, activeLayerIndex: 0)
        guard let loadedComposite = loaded.compositeImage(), let loadedPixel = rawRGBA(of: loadedComposite, x: 0, y: 0) else {
            XCTFail("compositeImage() returned nil for the width:height:layers:activeLayerIndex: initializer")
            return
        }
        XCTAssertEqual(loadedPixel.r, 0)
        XCTAssertEqual(loadedPixel.a, 255)
    }

    func testCompositeImage_excludedIndexOutOfRange_fallsBackToFullRecompositeWithoutCrash() {
        let stack = LayerStack(width: 2, height: 2, background: .white) // L0
        stack.addLayer() // L1: active
        stack.activeLayer.canvas.fill(with: .black)

        guard let negativeResult = stack.compositeImage(excludingLayerAtIndex: -1),
              let negativePixel = rawRGBA(of: negativeResult, x: 0, y: 0) else {
            XCTFail("compositeImage(excludingLayerAtIndex: -1) returned nil")
            return
        }
        XCTAssertEqual(negativePixel.r, 0, "an out-of-range excludedIndex must exclude nothing — the full composite (black on top) is still shown")

        guard let outOfBoundsResult = stack.compositeImage(excludingLayerAtIndex: stack.layers.count),
              let outOfBoundsPixel = rawRGBA(of: outOfBoundsResult, x: 0, y: 0) else {
            XCTFail("compositeImage(excludingLayerAtIndex: layers.count) returned nil")
            return
        }
        XCTAssertEqual(outOfBoundsPixel.r, 0)
    }

    func testCompositeImage_excludeOtherIndex_doesNotMutateExistingCache() {
        let stack = LayerStack(width: 2, height: 2, background: .white) // L0: non-active
        stack.addLayer() // L1: active
        stack.activeLayer.canvas.fill(with: .black)

        _ = stack.compositeImage() // builds backgroundCompositeCache excluding the active layer (L1)

        guard let beforeInterleave = stack.compositeImage(excludingLayerAtIndex: stack.activeLayerIndex) else {
            XCTFail("compositeImage(excludingLayerAtIndex:) returned nil")
            return
        }

        _ = stack.compositeImage(excludingLayerAtIndex: 0) // excludes the OTHER (non-active) layer — must not touch or rebuild the cache

        guard let afterInterleave = stack.compositeImage(excludingLayerAtIndex: stack.activeLayerIndex) else {
            XCTFail("compositeImage(excludingLayerAtIndex:) returned nil")
            return
        }

        assertCompositesEqual(beforeInterleave, afterInterleave, width: 2, height: 2)
    }
}
