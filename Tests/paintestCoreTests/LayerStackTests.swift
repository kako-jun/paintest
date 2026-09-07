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
        // exercises compositeActiveLayer's "active layer invisible" path on
        // top of a non-trivial (partially opaque) cached background.
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
        // transparent) stays topmost throughout, so this specifically
        // exercises moveLayer's own explicit `backgroundCompositeCache =
        // nil`, not activeLayerIndex's didSet (which this move never
        // triggers, since the active layer is tracked by object identity
        // and never itself moves here).
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

        stack.activeLayerIndex = stack.activeLayerIndex // reassignment to the SAME value

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
