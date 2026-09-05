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
}
