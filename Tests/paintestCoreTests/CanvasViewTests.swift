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
        // Auto-confirms an in-progress layer transform before anything else
        // (issue #9 review must-1), mirroring the real
        // `AppDelegate.activateActiveDocument()`'s own ordering: at this
        // point `view.layerStack` still points at the OUTGOING document —
        // the one the transform actually belongs to — so
        // `commitLayerTransform()` here rasterizes onto the correct layer,
        // not whatever ends up active in `incoming` after the swap below.
        if view.isTransforming {
            view.commitLayerTransform()
        }
        previouslyDisplayed?.zoomScale = view.zoomScale
        // Selection write-back/restore, same pattern as zoom above and in
        // the real `AppDelegate.activateActiveDocument()` (issue #11).
        previouslyDisplayed?.selection = view.selection
        view.replaceLayerStack(incoming.layerStack)
        view.setZoomScale(incoming.zoomScale)
        view.selection = incoming.selection
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

    // MARK: - Per-document selection independence across tab switches (issue #11)
    //
    // Mirrors `testZoom_perDocument_staysIndependentAcrossTabSwitches` above:
    // `CanvasView` itself only ever holds one `selection` at a time — the
    // per-document memory lives on `Document.selection`, and it's
    // `AppDelegate.activateActiveDocument()` that writes the outgoing
    // document's selection back before applying the incoming one's, exactly
    // like it does for `zoomScale`. `activateActiveDocument()` is private on
    // `AppDelegate` (not practical to unit test directly), so this reuses
    // the same `activate(_:previouslyDisplayed:on:)` helper, which now
    // reproduces the selection half of that protocol too.

    func testSelection_perDocument_staysIndependentAcrossTabSwitches() {
        let docA = Document(layerStack: LayerStack(width: 8, height: 8), displayName: "a")
        let docB = Document(layerStack: LayerStack(width: 8, height: 8), displayName: "b")
        let view = CanvasView(layerStack: docA.layerStack)
        let selectionA = SelectionMask.rectangle(x0: 0, y0: 0, x1: 3, y1: 3, width: 8, height: 8)

        view.selection = selectionA // "a" has a selection while it's the displayed document

        activate(docB, previouslyDisplayed: docA, on: view) // switch to "b"
        XCTAssertNil(view.selection, "\"b\" has never had a selection and must show none, not \"a\"'s rectangle")

        activate(docA, previouslyDisplayed: docB, on: view) // switch back to "a"
        // `SelectionMask` is a class with no `Equatable` conformance (see
        // `SelectionMaskTests.assertMasks(_:equalTo:...)`, which compares
        // cell-by-cell instead), so identity comparison is what "restored,
        // not reset" actually means here: the exact same mask object should
        // come back, not an equivalent-but-different one.
        XCTAssertTrue(view.selection === selectionA, "\"a\"'s selection must be restored, not reset to none")
    }

    // MARK: - Layer transform auto-confirm on document switch (issue #9
    // review must-1)
    //
    // Before this fix, `commitLayerTransform()` always wrote into whatever
    // `layerStack.activeLayer` happened to be AT CONFIRM TIME — so
    // switching documents (or layers) between `beginLayerTransform()` and
    // pressing Return would silently rasterize the transform onto a
    // completely unrelated layer/document, destroying its real content with
    // no undo. The fix calls `commitLayerTransform()` proactively, from
    // `activate(_:previouslyDisplayed:on:)` above, the instant a document
    // switch is about to happen — while `view.layerStack` still points at
    // the transform's own document. This test drives that exact sequence
    // and checks both halves of the guarantee: the originating document
    // ends up correctly transformed, and the destination document is
    // completely untouched.

    func testLayerTransform_activeWhenSwitchingDocuments_autoCommitsOntoTheOriginatingDocument_leavesTheOtherDocumentUntouched() {
        let zoomScale = 4
        // 8x8 (not e.g. 4x4): the click point below has to be far enough
        // from every corner to avoid the rotate ring
        // (`transformRotateHandleOuterRadius`, 14 *view* points) as well as
        // the plain hit radius, same reasoning as
        // `testMouseDragged_moveHandleWithShiftAndOptionHeld_stillJustTranslates`
        // above — on a small canvas at ordinary zoom, the rectangle's own
        // center can actually fall inside a corner's rotate ring, silently
        // turning an intended "drag the interior" test into a rotate-handle
        // test instead.
        let docA = Document(layerStack: LayerStack(width: 8, height: 8), displayName: "a")
        let docB = Document(layerStack: LayerStack(width: 8, height: 8), displayName: "b")
        let canvasA = docA.layerStack.activeLayer.canvas
        let canvasB = docB.layerStack.activeLayer.canvas
        for y in 0..<8 {
            for x in 0..<8 {
                canvasA.setPixel(x: x, y: y, color: NSColor(deviceRed: Double(x) / 7, green: Double(y) / 7, blue: 0.2, alpha: 1))
                canvasB.setPixel(x: x, y: y, color: NSColor(deviceRed: 0.1, green: 0.2, blue: Double(x + y) / 14, alpha: 1))
            }
        }
        var beforeA: [[(r: UInt8, g: UInt8, b: UInt8, a: UInt8)]] = []
        for y in 0..<8 { beforeA.append((0..<8).map { canvasA.rawPixel(x: $0, y: y)! }) }
        var beforeB: [[(r: UInt8, g: UInt8, b: UInt8, a: UInt8)]] = []
        for y in 0..<8 { beforeB.append((0..<8).map { canvasB.rawPixel(x: $0, y: y)! }) }

        let view = makeViewInWindow(width: 8, height: 8, zoomScale: zoomScale)
        view.replaceLayerStack(docA.layerStack)
        let window = view.window!

        view.beginLayerTransform()
        // Canvas (4, 4) is the rectangle's own center — comfortably past
        // the rotate ring at this zoom (see the comment above) — dragged by
        // (+1, +1), same scenario as
        // `testMouseDragged_moveHandleWithShiftAndOptionHeld_stillJustTranslates`.
        let down = transformWindowPoint(canvasX: 4, canvasY: 4, zoomScale: zoomScale, viewHeight: view.frame.height)
        let drag = transformWindowPoint(canvasX: 5, canvasY: 5, zoomScale: zoomScale, viewHeight: view.frame.height)
        view.mouseDown(with: mouseDownEvent(at: down, in: window))
        view.mouseDragged(with: mouseDraggedEvent(at: drag, in: window))
        view.mouseUp(with: mouseUpEvent(at: drag, in: window))
        XCTAssertTrue(view.isTransforming, "precondition: still mid-transform, not yet confirmed")

        // Switch tabs to "b" WITHOUT ever pressing Return — exactly the
        // sequence that used to silently corrupt whichever layer/document
        // ended up active afterward.
        activate(docB, previouslyDisplayed: docA, on: view)

        XCTAssertFalse(view.isTransforming, "switching documents must auto-confirm the in-progress transform")

        // A pure (+1, +1) translation onto docA: destination (x, y) shows
        // source (x - 1, y - 1), for the interior region only (the
        // shifted-in edge is left transparent — same cropping convention as
        // `testMouseDragged_moveHandleWithShiftAndOptionHeld_stillJustTranslates`).
        for y in 0..<8 {
            for x in 0..<8 {
                let actual = canvasA.rawPixel(x: x, y: y)
                if x >= 1, y >= 1 {
                    let expected = beforeA[y - 1][x - 1]
                    XCTAssertEqual(actual?.r, expected.r, "docA x=\(x) y=\(y) red")
                    XCTAssertEqual(actual?.g, expected.g, "docA x=\(x) y=\(y) green")
                    XCTAssertEqual(actual?.b, expected.b, "docA x=\(x) y=\(y) blue")
                    XCTAssertEqual(actual?.a, expected.a, "docA x=\(x) y=\(y) alpha")
                } else {
                    XCTAssertEqual(actual?.a, 0, "docA x=\(x) y=\(y) should be left transparent (shifted in from outside)")
                }
            }
        }

        // docB — the tab switched TO — must be completely untouched: not
        // one pixel of it should have changed.
        for y in 0..<8 {
            for x in 0..<8 {
                let actual = canvasB.rawPixel(x: x, y: y)
                XCTAssertEqual(actual?.r, beforeB[y][x].r, "docB x=\(x) y=\(y) red")
                XCTAssertEqual(actual?.g, beforeB[y][x].g, "docB x=\(x) y=\(y) green")
                XCTAssertEqual(actual?.b, beforeB[y][x].b, "docB x=\(x) y=\(y) blue")
                XCTAssertEqual(actual?.a, beforeB[y][x].a, "docB x=\(x) y=\(y) alpha")
            }
        }
    }

    // MARK: - History checkpoint recorded onto the correct document during
    // a tab-switch auto-commit (issue #19 self-review must-1)
    //
    // `AppDelegate.activateActiveDocument()`'s transform auto-commit above
    // fires `CanvasView.onEditCompleted` synchronously from inside
    // `commitLayerTransform()`. In the real app, that happens AFTER
    // `documentManager.activeDocumentIndex` has already advanced to the
    // incoming document — `DocumentTabBarView`/`closeDocument(at:)` update
    // the index before invoking `onSelect`/`onClose`, which is what calls
    // `activateActiveDocument()` — but BEFORE `AppDelegate.displayedDocument`
    // is reassigned (that happens only at the very end of
    // `activateActiveDocument()`, once every other hand-off is done). The
    // fixed `recordHistoryCheckpoint(label:)` records onto `displayedDocument`
    // for exactly this reason. `AppDelegate` itself can't be unit tested
    // directly (see `activate(_:previouslyDisplayed:on:)`'s own doc comment
    // above), so this test reproduces that same interleaving directly
    // against `Document` + `CanvasView`, extending the `activate(...)`
    // helper's protocol with the fixed `onEditCompleted` -> history routing.

    func testHistoryCheckpoint_transformAutoCommitDuringTabSwitch_recordsOntoTheOriginatingDocument_leavesTheOtherDocumentsHistoryUntouched() {
        let zoomScale = 4
        let docA = Document(layerStack: LayerStack(width: 8, height: 8), displayName: "a")
        let docB = Document(layerStack: LayerStack(width: 8, height: 8), displayName: "b")
        let canvasA = docA.layerStack.activeLayer.canvas
        for y in 0..<8 {
            for x in 0..<8 {
                canvasA.setPixel(x: x, y: y, color: NSColor(deviceRed: Double(x) / 7, green: Double(y) / 7, blue: 0.2, alpha: 1))
            }
        }
        var beforeA: [[(r: UInt8, g: UInt8, b: UInt8, a: UInt8)]] = []
        for y in 0..<8 { beforeA.append((0..<8).map { canvasA.rawPixel(x: $0, y: y)! }) }
        // Mirrors a real document's usage: the gradient above was already a
        // completed, recorded edit (like a pencil stroke going through
        // `onEditCompleted`) before the transform in question ever began —
        // otherwise `docA.history` would have no pre-transform checkpoint to
        // undo back to.
        docA.history.record(docA.layerStack, label: "描画")

        let view = makeViewInWindow(width: 8, height: 8, zoomScale: zoomScale)
        view.replaceLayerStack(docA.layerStack)
        let window = view.window!

        // Mirrors the FIXED `AppDelegate.recordHistoryCheckpoint(label:)`:
        // always records onto whichever document is still actually
        // *displayed* right now, tracked here the same way `AppDelegate.
        // displayedDocument` is — reassigned only at the very end of a tab
        // switch, after any auto-commit has already fired and recorded.
        var displayedDocument = docA
        view.onEditCompleted = { label in
            displayedDocument.history.record(displayedDocument.layerStack, selection: view.selection, label: label)
        }

        view.beginLayerTransform()
        let down = transformWindowPoint(canvasX: 4, canvasY: 4, zoomScale: zoomScale, viewHeight: view.frame.height)
        let drag = transformWindowPoint(canvasX: 5, canvasY: 5, zoomScale: zoomScale, viewHeight: view.frame.height)
        view.mouseDown(with: mouseDownEvent(at: down, in: window))
        view.mouseDragged(with: mouseDraggedEvent(at: drag, in: window))
        view.mouseUp(with: mouseUpEvent(at: drag, in: window))
        XCTAssertTrue(view.isTransforming, "precondition: still mid-transform, not yet confirmed")

        let docBEntryLabelsBefore = docB.history.entries.map(\.label)
        let docBIndexBefore = docB.history.currentIndex

        // Switch tabs to "b" WITHOUT ever pressing Return — `activate(...)`
        // auto-commits the transform (firing `onEditCompleted` above, which
        // still routes to `docA` via `displayedDocument`) BEFORE
        // `displayedDocument` is reassigned to `docB` immediately after,
        // exactly mirroring `AppDelegate.activateActiveDocument()`'s own
        // ordering.
        activate(docB, previouslyDisplayed: docA, on: view)
        displayedDocument = docB

        XCTAssertEqual(docA.history.entries.map(\.label), ["初期状態", "描画", "変形"], "the auto-committed transform must land in docA's own history, not docB's")
        XCTAssertEqual(docB.history.entries.map(\.label), docBEntryLabelsBefore, "docB's history must be completely untouched by a transform that belongs to docA")
        XCTAssertEqual(docB.history.currentIndex, docBIndexBefore, "docB's currentIndex must be completely untouched too")

        // Switch back to "a" and undo: must revert to the pre-transform
        // (gradient) pixels, proving the checkpoint really is undoable from
        // docA's own tab — the whole point of must-1's fix.
        activate(docA, previouslyDisplayed: docB, on: view)
        displayedDocument = docA

        guard let restored = docA.history.undo() else {
            return XCTFail("docA should have the \"描画\" checkpoint left to undo back to")
        }
        docA.layerStack = restored.layerStack
        view.replaceLayerStack(restored.layerStack)

        let restoredCanvas = restored.layerStack.activeLayer.canvas
        for y in 0..<8 {
            for x in 0..<8 {
                let actual = restoredCanvas.rawPixel(x: x, y: y)
                XCTAssertEqual(actual?.r, beforeA[y][x].r, "docA x=\(x) y=\(y) red after undo")
                XCTAssertEqual(actual?.g, beforeA[y][x].g, "docA x=\(x) y=\(y) green after undo")
                XCTAssertEqual(actual?.b, beforeA[y][x].b, "docA x=\(x) y=\(y) blue after undo")
                XCTAssertEqual(actual?.a, beforeA[y][x].a, "docA x=\(x) y=\(y) alpha after undo")
            }
        }
    }

    // MARK: - Selection restored through canvasView.selection on undo
    // (issue #19 self-review should-3)
    //
    // Mirrors `AppDelegate.applyHistorySnapshot(_:)`'s own selection
    // hand-off (`canvasView.selection = snapshot.selection`) — recording two
    // successive selection checkpoints and undoing back to the first must
    // restore `canvasView.selection`'s actual content, not just the
    // (unchanged, since selecting never paints anything) `layerStack`.

    func testHistorySnapshot_selection_isRecordedAndRestoredThroughCanvasViewSelectionOnUndo() {
        let width = 8, height = 8
        let document = Document(layerStack: LayerStack(width: width, height: height, background: .white))
        let view = CanvasView(layerStack: document.layerStack)

        let selectionA = SelectionMask.rectangle(x0: 0, y0: 0, x1: 2, y1: 2, width: width, height: height)
        view.selection = selectionA
        document.history.record(document.layerStack, selection: view.selection, label: "選択範囲")

        let selectionB = SelectionMask.rectangle(x0: 4, y0: 4, x1: 6, y1: 6, width: width, height: height)
        view.selection = selectionB
        document.history.record(document.layerStack, selection: view.selection, label: "選択範囲")

        guard let restored = document.history.undo() else {
            return XCTFail("expected undo() to return the selectionA checkpoint")
        }
        // Mirrors `AppDelegate.applyHistorySnapshot(_:)`'s hand-off.
        view.selection = restored.selection

        guard let currentSelection = view.selection else {
            return XCTFail("canvasView.selection must be restored to selectionA's content, not nil")
        }
        for y in 0..<height {
            for x in 0..<width {
                XCTAssertEqual(currentSelection.contains(x: x, y: y), selectionA.contains(x: x, y: y), "x=\(x) y=\(y)")
            }
        }
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

    private func mouseDownEvent(at windowPoint: NSPoint, in window: NSWindow, modifierFlags: NSEvent.ModifierFlags = [], clickCount: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: windowPoint,
            modifierFlags: modifierFlags,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 1
        )!
    }

    private func mouseDraggedEvent(at windowPoint: NSPoint, in window: NSWindow, modifierFlags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(
            with: .leftMouseDragged,
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

    // MARK: - Layer transform (issue #9, round 1: move + scale only)
    //
    // Only the two numeric checks the round-1 implementation plan calls out
    // as its core-correctness bar: an untouched (identity) confirm must
    // round-trip the canvas byte-exactly, and a corner-drag scale must
    // nearest-neighbor-stretch the source pixels exactly where the inverse
    // mapping predicts. A fuller decision-table pass (all 8 handles, Shift
    // aspect lock, Escape-cancel, Return/double-click confirm, hit-test
    // boundaries, etc.) is deliberately left to the follow-up test-authoring
    // pass — see this task's own final report.

    /// A window point for a *continuous* canvas-pixel-space coordinate
    /// (unlike `windowPoint(forPixelCol:row:...)`, which targets a specific
    /// pixel cell's interior) — needed here because transform handles sit at
    /// exact rectangle corners/edge-midpoints, not pixel centers.
    private func transformWindowPoint(canvasX: Double, canvasY: Double, zoomScale: Int, viewHeight: CGFloat) -> NSPoint {
        NSPoint(x: canvasX * Double(zoomScale), y: Double(viewHeight) - canvasY * Double(zoomScale))
    }

    func testLayerTransform_commitWithNoDrag_reproducesOriginalCanvasByteExact() {
        let zoomScale = 4
        let view = makeViewInWindow(width: 8, height: 8, zoomScale: zoomScale)
        let canvas = view.layerStack.activeLayer.canvas
        // Every pixel gets its own distinct color so a byte-exact comparison
        // actually exercises every (x, y), not just a couple of samples.
        for y in 0..<8 {
            for x in 0..<8 {
                canvas.setPixel(x: x, y: y, color: NSColor(deviceRed: Double(x) / 7, green: Double(y) / 7, blue: 0.5, alpha: 1))
            }
        }
        var before: [[(r: UInt8, g: UInt8, b: UInt8, a: UInt8)]] = []
        for y in 0..<8 {
            before.append((0..<8).map { canvas.rawPixel(x: $0, y: y)! })
        }

        view.beginLayerTransform()
        view.commitLayerTransform()

        for y in 0..<8 {
            for x in 0..<8 {
                let after = canvas.rawPixel(x: x, y: y)
                XCTAssertEqual(after?.r, before[y][x].r, "x=\(x) y=\(y) red drifted on an identity transform")
                XCTAssertEqual(after?.g, before[y][x].g, "x=\(x) y=\(y) green drifted on an identity transform")
                XCTAssertEqual(after?.b, before[y][x].b, "x=\(x) y=\(y) blue drifted on an identity transform")
                XCTAssertEqual(after?.a, before[y][x].a, "x=\(x) y=\(y) alpha drifted on an identity transform")
            }
        }
    }

    func testLayerTransform_dragBottomRightCornerToDoubleSize_commitsWithNearestNeighborStretch() {
        let zoomScale = 4
        let view = makeViewInWindow(width: 4, height: 4, zoomScale: zoomScale)
        let window = view.window!
        let canvas = view.layerStack.activeLayer.canvas
        // A distinct color per source pixel so the nearest-neighbor mapping
        // below can be checked against a specific, known source pixel
        // rather than just "some color changed".
        for y in 0..<4 {
            for x in 0..<4 {
                canvas.setPixel(x: x, y: y, color: NSColor(deviceRed: Double(x) * 60 / 255, green: Double(y) * 60 / 255, blue: 200.0 / 255, alpha: 1))
            }
        }
        let source00 = canvas.rawPixel(x: 0, y: 0)!
        let source10 = canvas.rawPixel(x: 1, y: 0)!
        let source01 = canvas.rawPixel(x: 0, y: 1)!
        let source11 = canvas.rawPixel(x: 1, y: 1)!

        view.beginLayerTransform()

        // Identity starts as centerX=2, centerY=2, width=4, height=4 — i.e.
        // corners at (0,0)/(4,0)/(4,4)/(0,4). Dragging the bottom-right
        // corner from (4,4) out to (8,8), with the top-left corner (0,0) as
        // the fixed anchor, doubles both axes: the resulting transform rect
        // is centered at (4,4) with width=height=8, which (per
        // `CanvasView.sourcePixel`'s inverse mapping) makes every source
        // pixel cover a 2x2 block of the still-4x4 destination canvas.
        let downPoint = transformWindowPoint(canvasX: 4, canvasY: 4, zoomScale: zoomScale, viewHeight: view.frame.height)
        let dragPoint = transformWindowPoint(canvasX: 8, canvasY: 8, zoomScale: zoomScale, viewHeight: view.frame.height)
        view.mouseDown(with: mouseDownEvent(at: downPoint, in: window))
        view.mouseDragged(with: mouseDraggedEvent(at: dragPoint, in: window))
        view.mouseUp(with: mouseUpEvent(at: dragPoint, in: window))

        view.keyDown(with: keyDownEvent(keyCode: 36, in: window)) // Return: commit

        // Destination columns/rows 0-1 map to source column/row 0, and
        // destination columns/rows 2-3 map to source column/row 1 — the
        // bottom-right 3/4 of the original 4x4 layer falls outside the
        // (still 4x4) canvas once doubled from a top-left anchor, which is
        // the expected, if cropped, result of this particular drag.
        func assertPixel(_ x: Int, _ y: Int, equals expected: (r: UInt8, g: UInt8, b: UInt8, a: UInt8), line: UInt = #line) {
            let actual = canvas.rawPixel(x: x, y: y)
            XCTAssertEqual(actual?.r, expected.r, "x=\(x) y=\(y) red", line: line)
            XCTAssertEqual(actual?.g, expected.g, "x=\(x) y=\(y) green", line: line)
            XCTAssertEqual(actual?.b, expected.b, "x=\(x) y=\(y) blue", line: line)
            XCTAssertEqual(actual?.a, expected.a, "x=\(x) y=\(y) alpha", line: line)
        }
        assertPixel(0, 0, equals: source00)
        assertPixel(1, 0, equals: source00)
        assertPixel(2, 0, equals: source10)
        assertPixel(3, 0, equals: source10)
        assertPixel(0, 1, equals: source00)
        assertPixel(0, 2, equals: source01)
        assertPixel(0, 3, equals: source01)
        assertPixel(3, 3, equals: source11)
    }

    // MARK: - Layer transform: rotation (issue #9, round 2)

    /// `sourcePixel`'s rotation-aware inverse mapping at exactly 90°, hand
    /// -derived independently of the implementation (not just re-running its
    /// own formula): with a 4x4 identity transform (`centerX == centerY ==
    /// 2`), rotating the *displayed* image 90° means destination pixel
    /// `(x, y)` should show whatever source pixel a 90°-clockwise rotation
    /// would carry to that spot — which, worked out by hand, is source
    /// `(y, 4 - x)`.
    ///
    /// Column `x == 0` is a documented exception, not a bug: `sourcePixel`
    /// treats a pixel's own integer coordinate as its top/left corner (see
    /// the `epsilon` comment on `sourcePixel` itself), so an exact
    /// multiple-of-90° rotation of an identity-size rectangle always pushes
    /// that column's `v` to exactly `1.0` — right on the `v < 1` guard's
    /// excluded boundary. This is the same kind of "one edge crops off"
    /// artifact `testLayerTransform_dragBottomRightCornerToDoubleSize_...`
    /// above already accepts for scaling from a corner anchor.
    func testSourcePixel_90DegreeRotation_matchesHandDerivedClockwiseMapping() {
        var transform = LayerTransform.identity(width: 4, height: 4)
        transform.rotation = .pi / 2

        func assertMaps(_ destination: (x: Int, y: Int), to expected: (x: Int, y: Int)?, line: UInt = #line) {
            let actual = CanvasView.sourcePixel(forDestination: destination, transform: transform, sourceWidth: 4, sourceHeight: 4)
            XCTAssertEqual(actual?.x, expected?.x, "destination \(destination) x", line: line)
            XCTAssertEqual(actual?.y, expected?.y, "destination \(destination) y", line: line)
        }

        assertMaps((0, 0), to: nil)
        assertMaps((0, 3), to: nil)
        assertMaps((1, 0), to: (0, 3))
        assertMaps((2, 0), to: (0, 2))
        assertMaps((3, 0), to: (0, 1))
        assertMaps((1, 1), to: (1, 3))
        assertMaps((1, 2), to: (2, 3))
        assertMaps((1, 3), to: (3, 3))
    }

    /// `sourcePixel`'s rotation-aware inverse mapping at exactly 180°, hand
    /// -derived the same independent way as the 90° test above: rotating an
    /// image 180° is a plain point reflection through its center, so
    /// destination `(x, y)` (for `x > 0` and `y > 0` — see below) should show
    /// source `(4 - x, 4 - y)`.
    ///
    /// `x == 0` or `y == 0` is the same documented boundary exception as the
    /// 90° test above (both `u` and `v` individually hit exactly `1.0` for
    /// those rows/columns at 180°, not just one axis as at 90°).
    func testSourcePixel_180DegreeRotation_isPointReflectionThroughCenter() {
        var transform = LayerTransform.identity(width: 4, height: 4)
        transform.rotation = .pi

        func assertMaps(_ destination: (x: Int, y: Int), to expected: (x: Int, y: Int)?, line: UInt = #line) {
            let actual = CanvasView.sourcePixel(forDestination: destination, transform: transform, sourceWidth: 4, sourceHeight: 4)
            XCTAssertEqual(actual?.x, expected?.x, "destination \(destination) x", line: line)
            XCTAssertEqual(actual?.y, expected?.y, "destination \(destination) y", line: line)
        }

        assertMaps((0, 0), to: nil)
        assertMaps((0, 2), to: nil)
        assertMaps((2, 0), to: nil)
        assertMaps((1, 1), to: (3, 3))
        assertMaps((3, 3), to: (1, 1))
        assertMaps((2, 2), to: (2, 2))
        assertMaps((3, 1), to: (1, 3))
        assertMaps((1, 3), to: (3, 1))
    }

    /// Guards against the round-2 rewrite of `sourcePixel` (general rotation
    /// via inverse-rotate-then-round-1-math) accidentally changing behavior
    /// when `rotation` is still `0` — same guarantee `testLayerTransform_
    /// commitWithNoDrag_reproducesOriginalCanvasByteExact` above already
    /// makes at the `CanvasView` gesture level, checked here directly at the
    /// pure-function level across every pixel of a 4x4 canvas.
    func testSourcePixel_zeroRotation_stillMapsEveryPixelToItself() {
        let transform = LayerTransform.identity(width: 4, height: 4)
        for y in 0..<4 {
            for x in 0..<4 {
                let actual = CanvasView.sourcePixel(forDestination: (x, y), transform: transform, sourceWidth: 4, sourceHeight: 4)
                XCTAssertEqual(actual?.x, x, "x=\(x) y=\(y)")
                XCTAssertEqual(actual?.y, y, "x=\(x) y=\(y)")
            }
        }
    }

    /// End-to-end: grabs the rotate ring just outside the top-left corner
    /// (`hitTestTransformHandle`'s new `.rotate` case), drags with Shift
    /// held to a point exactly 180° around the rectangle's center (snapping
    /// confirms the drag lands on a clean angle rather than whatever noise
    /// `atan2` happens to produce), and commits — verifying the *actual
    /// gesture pipeline* (hit-test → drag → rasterize), not just the pure
    /// `sourcePixel` math the tests above already cover in isolation.
    ///
    /// Only checks the interior 3x3 block (`x`/`y` both in `1...3`): the
    /// edge row/column that crops off at exactly 180° (see
    /// `testSourcePixel_180DegreeRotation_isPointReflectionThroughCenter`'s
    /// doc comment) sits exactly on a `u`/`v == 1.0` boundary, which the
    /// degrees-and-back Shift-snap roundtrip could nudge a few ULPs either
    /// side of — asserting the interior avoids that source of flakiness
    /// while still exercising the same rotation end to end.
    func testLayerTransform_rotateHandleDraggedHalfCircleWithShiftSnap_commits180DegreeRotation() {
        let zoomScale = 8
        let view = makeViewInWindow(width: 4, height: 4, zoomScale: zoomScale)
        let window = view.window!
        let canvas = view.layerStack.activeLayer.canvas
        for y in 0..<4 {
            for x in 0..<4 {
                canvas.setPixel(x: x, y: y, color: NSColor(deviceRed: Double(x) / 3, green: Double(y) / 3, blue: 0.4, alpha: 1))
            }
        }
        var before: [[(r: UInt8, g: UInt8, b: UInt8, a: UInt8)]] = []
        for y in 0..<4 {
            before.append((0..<4).map { canvas.rawPixel(x: $0, y: y)! })
        }

        view.beginLayerTransform()

        // Identity starts as centerX=2, centerY=2 (canvas space) — view
        // (16, 16) at this zoom. A click at canvas (-1, -1) — view (-8, -8)
        // — sits ~11.3 view points from the top-left corner (0, 0): outside
        // `transformHandleHitRadius` (6, the scale handle's own hitbox) but
        // inside `transformRotateHandleOuterRadius` (14), so it hits the
        // rotate ring rather than the corner scale handle.
        let downPoint = transformWindowPoint(canvasX: -1, canvasY: -1, zoomScale: zoomScale, viewHeight: view.frame.height)
        // Canvas (3, 3) sits exactly 180° around the center from (-1, -1):
        // both are a diagonal offset of equal magnitude from (2, 2), on
        // opposite sides, so the two points' angles around the center are
        // exactly `π` apart.
        let dragPoint = transformWindowPoint(canvasX: 3, canvasY: 3, zoomScale: zoomScale, viewHeight: view.frame.height)
        view.mouseDown(with: mouseDownEvent(at: downPoint, in: window))
        view.mouseDragged(with: mouseDraggedEvent(at: dragPoint, in: window, modifierFlags: [.shift]))
        view.mouseUp(with: mouseUpEvent(at: dragPoint, in: window))

        view.keyDown(with: keyDownEvent(keyCode: 36, in: window)) // Return: commit

        func assertPixel(_ x: Int, _ y: Int, equalsBefore beforeX: Int, _ beforeY: Int, line: UInt = #line) {
            let actual = canvas.rawPixel(x: x, y: y)
            let expected = before[beforeY][beforeX]
            XCTAssertEqual(actual?.r, expected.r, "x=\(x) y=\(y) red", line: line)
            XCTAssertEqual(actual?.g, expected.g, "x=\(x) y=\(y) green", line: line)
            XCTAssertEqual(actual?.b, expected.b, "x=\(x) y=\(y) blue", line: line)
            XCTAssertEqual(actual?.a, expected.a, "x=\(x) y=\(y) alpha", line: line)
        }
        // A 180° rotation is a point reflection through the center: the
        // interior 3x3 block, post-commit, shows each source pixel's
        // diagonal opposite.
        assertPixel(1, 1, equalsBefore: 3, 3)
        assertPixel(3, 3, equalsBefore: 1, 1)
        assertPixel(2, 2, equalsBefore: 2, 2)
        assertPixel(3, 1, equalsBefore: 1, 3)
        assertPixel(1, 3, equalsBefore: 3, 1)
    }

    // MARK: - Layer transform: resizing after rotation (issue #9, round 2
    // follow-up fix)
    //
    // Round 2's own completion report flagged this as a known bug:
    // `resizeByCorner`/`resizeByEdge` fed the mouse's raw screen-axis drag
    // deltas straight into `width`/`height`/`centerX`/`centerY` math that
    // assumes those axes match the rectangle's own — true only while
    // `rotation == 0`. Once a rectangle is rotated, a screen-axis drag on a
    // corner/edge handle has to be rotated into the rectangle's *local*
    // frame first (and the resulting center shift rotated back out again)
    // or the rectangle shears into a parallelogram instead of staying a
    // rectangle. Both tests below rotate the identity rectangle by exactly
    // 90° first (clean, non-fractional geometry — no `cos`/`sin` rounding to
    // fuzz pixel-boundary assertions), then drag a resize handle, then
    // assert the *actual* committed rasterization against
    // `CanvasView.sourcePixel`'s already-trusted (see the 90°/180°/identity
    // tests above) inverse mapping fed the transform this fix's own algebra
    // predicts — which only matches if the fix is doing its local-frame
    // rotation math rather than round 1's raw screen-axis math.

    /// Corner-handle case. Starting from an 8x8 identity transform
    /// (`centerX == centerY == 4`, `width == height == 8`) rotated 90°, the
    /// `topLeft`-labeled corner physically sits at canvas `(8, 0)` (a 90°
    /// turn swaps which physical corner each label sits at) with the
    /// diagonally opposite `bottomRight` anchor at `(0, 8)`.
    ///
    /// Dragging that corner from `(8, 0)` straight down the screen y-axis to
    /// `(8, 4)` — screen `dx == 0`, `dy == 4` — is, once rotated into the
    /// rectangle's local frame, a pure `localDx == 4, localDy == 0` move:
    /// only the local `width` axis (currently spanning local x
    /// `-4...4`) moves, from `-4` to `0`, halving `width` from 8 to 4 while
    /// `height` and `rotation` stay exactly as the rotate step left them.
    /// Working through `resizeByCorner`'s anchor-relative math by hand (and
    /// confirmed by running it) that lands on `centerX = 4, centerY = 6,
    /// width = 4, height = 8, rotation = π/2` — worked out independently
    /// below via `LayerTransform.corners` as a self-consistency check: the
    /// dragged corner's new physical position falls out to exactly `(8, 4)`,
    /// the same point the mouse was dragged to.
    ///
    /// A pre-fix `resizeByCorner` applying `(dx, dy) == (0, 4)` directly to
    /// the (already-rotated) screen-space corners would instead have left
    /// `width` at 8 and shrunk `height` to 4 — the two fields swapped,
    /// because at exactly 90° the screen axes and the rectangle's local axes
    /// are exactly swapped — so this test only passes with the fix in
    /// place.
    func testLayerTransform_resizeCornerAfterRotation_scalesLocalWidthAxisWithoutShearing() {
        let zoomScale = 8
        let view = makeViewInWindow(width: 8, height: 8, zoomScale: zoomScale)
        // `makeViewInWindow`'s `zoomScale` only sizes the test window/frame
        // — `CanvasView`'s own `zoomScale` (which the rotate/resize math
        // below actually reads) defaults to 4 regardless, so it has to be
        // set explicitly to match or every view-space distance/angle
        // computed from `transformWindowPoint` below would be off by a
        // 4-vs-8 scale factor.
        view.setZoomScale(zoomScale)
        let window = view.window!
        let canvas = view.layerStack.activeLayer.canvas
        for y in 0..<8 {
            for x in 0..<8 {
                canvas.setPixel(x: x, y: y, color: NSColor(deviceRed: Double(x) / 7, green: Double(y) / 7, blue: 0.6, alpha: 1))
            }
        }
        var before: [[(r: UInt8, g: UInt8, b: UInt8, a: UInt8)]] = []
        for y in 0..<8 {
            before.append((0..<8).map { canvas.rawPixel(x: $0, y: y)! })
        }

        view.beginLayerTransform()

        // Step 1: rotate the identity rectangle by exactly 90°, the same
        // rotate-ring gesture as the half-circle test above, but a quarter
        // turn so step 2's corner drag lands on clean integer canvas
        // coordinates. Center (4, 4); grabbing 1 canvas pixel diagonally
        // outside the top-left corner (0, 0) — offset (-5, -5) from center —
        // and dragging to the point at exactly +90° around the center at the
        // same radius — offset (5, -5), i.e. canvas (9, -1) — turns the
        // rectangle exactly 90° (Shift locks it to the nearest 15°, so any
        // small floating-point slop in this hand-picked point still snaps
        // cleanly to π/2).
        let rotateDown = transformWindowPoint(canvasX: -1, canvasY: -1, zoomScale: zoomScale, viewHeight: view.frame.height)
        let rotateDrag = transformWindowPoint(canvasX: 9, canvasY: -1, zoomScale: zoomScale, viewHeight: view.frame.height)
        view.mouseDown(with: mouseDownEvent(at: rotateDown, in: window))
        view.mouseDragged(with: mouseDraggedEvent(at: rotateDrag, in: window, modifierFlags: [.shift]))
        view.mouseUp(with: mouseUpEvent(at: rotateDrag, in: window))

        // Step 2: the rectangle is now rotated 90°, so its `topLeft`-labeled
        // corner sits at physical canvas (8, 0) (see this test's doc
        // comment). Drag it to (8, 4).
        let cornerDown = transformWindowPoint(canvasX: 8, canvasY: 0, zoomScale: zoomScale, viewHeight: view.frame.height)
        let cornerDrag = transformWindowPoint(canvasX: 8, canvasY: 4, zoomScale: zoomScale, viewHeight: view.frame.height)
        view.mouseDown(with: mouseDownEvent(at: cornerDown, in: window))
        view.mouseDragged(with: mouseDraggedEvent(at: cornerDrag, in: window))
        view.mouseUp(with: mouseUpEvent(at: cornerDrag, in: window))

        view.keyDown(with: keyDownEvent(keyCode: 36, in: window)) // Return: commit

        var expected = LayerTransform.identity(width: 8, height: 8)
        expected.centerX = 4
        expected.centerY = 6
        expected.width = 4
        expected.height = 8
        expected.rotation = .pi / 2

        for y in 0..<8 {
            for x in 0..<8 {
                let actual = canvas.rawPixel(x: x, y: y)
                if let source = CanvasView.sourcePixel(forDestination: (x, y), transform: expected, sourceWidth: 8, sourceHeight: 8) {
                    let expectedPixel = before[source.y][source.x]
                    XCTAssertEqual(actual?.r, expectedPixel.r, "x=\(x) y=\(y) red")
                    XCTAssertEqual(actual?.g, expectedPixel.g, "x=\(x) y=\(y) green")
                    XCTAssertEqual(actual?.b, expectedPixel.b, "x=\(x) y=\(y) blue")
                    XCTAssertEqual(actual?.a, expectedPixel.a, "x=\(x) y=\(y) alpha")
                } else {
                    XCTAssertEqual(actual?.a, 0, "x=\(x) y=\(y) should be left transparent (outside the resized rectangle)")
                }
            }
        }
    }

    /// Edge-handle case, same setup and same rotate-90°-first approach as
    /// the corner test above. After the rotate step (identity 8x8, then
    /// rotated 90°), the `top`-labeled edge handle physically sits at canvas
    /// `(8, 4)`.
    ///
    /// Dragging it to `(4, 4)` — screen `dx == -4, dy == 0` — is, rotated
    /// into the local frame, a pure `localDy == 4` move: only the local
    /// `height` axis (spanning local y `-4...4`) moves, from `-4` to `0`,
    /// halving `height` from 8 to 4 while `width` and `rotation` are left
    /// untouched. Worked out by hand (and confirmed by running it) that
    /// lands on `centerX = 2, centerY = 4, width = 8, height = 4,
    /// rotation = π/2`.
    ///
    /// A pre-fix `resizeByEdge` applying `(dx, dy) == (-4, 0)` directly to
    /// the screen axes would have read this as a `left`/`right`-style
    /// horizontal move on the (rotated) rectangle instead of shrinking its
    /// local height, producing different `width`/`height`/`center` values
    /// than the ones asserted here — so, like the corner test, this only
    /// passes with the fix in place.
    func testLayerTransform_resizeTopEdgeAfterRotation_scalesLocalHeightAxisWithoutShearing() {
        let zoomScale = 8
        let view = makeViewInWindow(width: 8, height: 8, zoomScale: zoomScale)
        // See `testLayerTransform_resizeCornerAfterRotation_...` above for
        // why this explicit `setZoomScale` call is required.
        view.setZoomScale(zoomScale)
        let window = view.window!
        let canvas = view.layerStack.activeLayer.canvas
        for y in 0..<8 {
            for x in 0..<8 {
                canvas.setPixel(x: x, y: y, color: NSColor(deviceRed: Double(x) / 7, green: Double(y) / 7, blue: 0.6, alpha: 1))
            }
        }
        var before: [[(r: UInt8, g: UInt8, b: UInt8, a: UInt8)]] = []
        for y in 0..<8 {
            before.append((0..<8).map { canvas.rawPixel(x: $0, y: y)! })
        }

        view.beginLayerTransform()

        let rotateDown = transformWindowPoint(canvasX: -1, canvasY: -1, zoomScale: zoomScale, viewHeight: view.frame.height)
        let rotateDrag = transformWindowPoint(canvasX: 9, canvasY: -1, zoomScale: zoomScale, viewHeight: view.frame.height)
        view.mouseDown(with: mouseDownEvent(at: rotateDown, in: window))
        view.mouseDragged(with: mouseDraggedEvent(at: rotateDrag, in: window, modifierFlags: [.shift]))
        view.mouseUp(with: mouseUpEvent(at: rotateDrag, in: window))

        // The rectangle is now rotated 90°, so its `top`-labeled edge
        // handle's midpoint sits at physical canvas (8, 4).
        let edgeDown = transformWindowPoint(canvasX: 8, canvasY: 4, zoomScale: zoomScale, viewHeight: view.frame.height)
        let edgeDrag = transformWindowPoint(canvasX: 4, canvasY: 4, zoomScale: zoomScale, viewHeight: view.frame.height)
        view.mouseDown(with: mouseDownEvent(at: edgeDown, in: window))
        view.mouseDragged(with: mouseDraggedEvent(at: edgeDrag, in: window))
        view.mouseUp(with: mouseUpEvent(at: edgeDrag, in: window))

        view.keyDown(with: keyDownEvent(keyCode: 36, in: window)) // Return: commit

        var expected = LayerTransform.identity(width: 8, height: 8)
        expected.centerX = 2
        expected.centerY = 4
        expected.width = 8
        expected.height = 4
        expected.rotation = .pi / 2

        for y in 0..<8 {
            for x in 0..<8 {
                let actual = canvas.rawPixel(x: x, y: y)
                if let source = CanvasView.sourcePixel(forDestination: (x, y), transform: expected, sourceWidth: 8, sourceHeight: 8) {
                    let expectedPixel = before[source.y][source.x]
                    XCTAssertEqual(actual?.r, expectedPixel.r, "x=\(x) y=\(y) red")
                    XCTAssertEqual(actual?.g, expectedPixel.g, "x=\(x) y=\(y) green")
                    XCTAssertEqual(actual?.b, expectedPixel.b, "x=\(x) y=\(y) blue")
                    XCTAssertEqual(actual?.a, expectedPixel.a, "x=\(x) y=\(y) alpha")
                } else {
                    XCTAssertEqual(actual?.a, 0, "x=\(x) y=\(y) should be left transparent (outside the resized rectangle)")
                }
            }
        }
    }

    // MARK: - Layer transform: free transform / distort (issue #9, round 3)

    /// Replicates exactly what `CanvasView`'s private `sourcePixelDistorted`
    /// does (build a `ProjectiveTransform` from `transform.corners`, invert
    /// it, epsilon-truncate into a source pixel index) so this test file —
    /// which can't call that `private` method directly — can still exercise
    /// the identical math and compare it against the public
    /// `CanvasView.sourcePixel(forDestination:transform:sourceWidth:
    /// sourceHeight:)` entry point (round 1/2's rectangle-only formula) for
    /// transforms that carry no distortion.
    private func projectiveSourcePixel(forDestination pixel: (x: Int, y: Int), transform: LayerTransform, sourceWidth: Int, sourceHeight: Int) -> (x: Int, y: Int)? {
        let corners = transform.corners
        let projective = ProjectiveTransform(
            topLeft: corners.topLeft,
            topRight: corners.topRight,
            bottomRight: corners.bottomRight,
            bottomLeft: corners.bottomLeft
        )
        guard let (u, v) = projective.inverse(x: Double(pixel.x), y: Double(pixel.y)) else { return nil }
        guard u >= 0, u < 1, v >= 0, v < 1 else { return nil }
        let epsilon = 1e-9
        return (Int(u * Double(sourceWidth) + epsilon), Int(v * Double(sourceHeight) + epsilon))
    }

    /// Numerical verification #1 (issue #9 round 3 plan): for every
    /// distortion-free transform round 1/2 already has tests for (plain
    /// identity, 2x-scaled, and rotated 37° — an arbitrary non-multiple-of-90
    /// angle so no axis lands exactly on a boundary the way 90°/180° do),
    /// the round-3 projective-transform-based inverse mapping must return
    /// the exact same source pixel as round 1/2's existing rectangle-only
    /// `CanvasView.sourcePixel`, at every destination pixel of an 8x8
    /// canvas. This is the regression guarantee the issue calls for: the new
    /// general-quadrilateral math has to reduce to the old math whenever the
    /// quadrilateral is still just a (possibly rotated) rectangle.
    func testProjectiveTransform_noDistortion_matchesPlainRectangleSourcePixel_forIdentityScaledAndRotatedTransforms() {
        let identity = LayerTransform.identity(width: 8, height: 8)
        var scaled = identity
        scaled.width = 16
        scaled.height = 16
        var rotated = identity
        rotated.rotation = 37 * .pi / 180

        for (label, transform) in [("identity", identity), ("scaled2x", scaled), ("rotated37deg", rotated)] {
            for y in 0..<8 {
                for x in 0..<8 {
                    let expected = CanvasView.sourcePixel(forDestination: (x, y), transform: transform, sourceWidth: 8, sourceHeight: 8)
                    let actual = projectiveSourcePixel(forDestination: (x, y), transform: transform, sourceWidth: 8, sourceHeight: 8)
                    XCTAssertEqual(actual?.x, expected?.x, "\(label) x=\(x) y=\(y)")
                    XCTAssertEqual(actual?.y, expected?.y, "\(label) x=\(x) y=\(y)")
                }
            }
        }
    }

    /// Numerical verification #2 (issue #9 round 3 plan): a concrete,
    /// hand-derived distortion case. Starts from the identity transform of
    /// an 8x8 canvas (corners at `(0,0)`/`(8,0)`/`(8,8)`/`(0,8)`) and pulls
    /// only the bottom-right corner inward by `(-3, -2)`, landing it at
    /// `(5, 6)` — a concave quadrilateral, not a parallelogram, so the
    /// perspective terms (`g`/`h` in `ProjectiveTransform`) are genuinely
    /// non-zero (unlike a parallelogram distortion, which a naive
    /// implementation could get "right" by accident with a purely affine
    /// map).
    ///
    /// The expected source pixels below were derived independently of the
    /// implementation: by hand, solving `ProjectiveTransform`'s own 2x2
    /// linear systems for this quadrilateral's `a..h` coefficients
    /// (`a=40/3, b=0, c=0, d=0, e=16, f=0, g=2/3, h=1`), then evaluating
    /// `inverse(x:y:)` at each destination pixel algebraically — not by
    /// running this test's own code and reading back whatever it produced.
    /// Covers a point near an undistorted corner (top-left), one near the
    /// quadrilateral's center, and one near the distorted corner's side,
    /// the last of which is also asserted to differ from what the identity
    /// (no-distortion) mapping would have given at the same destination
    /// pixel — proof the distortion actually changed the sampling, not just
    /// that some source pixel came back.
    func testSourcePixel_singleCornerPulledInward_matchesHandDerivedProjectiveMapping() {
        var transform = LayerTransform.identity(width: 8, height: 8)
        transform.distortBottomRight = CGVector(dx: -3, dy: -2)

        // The distorted quadrilateral's corners land exactly where the hand
        // derivation assumed — checked first so a failure here points
        // straight at `LayerTransform.corners`' offset math rather than
        // `ProjectiveTransform`.
        let corners = transform.corners
        XCTAssertEqual(corners.topLeft, CGPoint(x: 0, y: 0))
        XCTAssertEqual(corners.topRight, CGPoint(x: 8, y: 0))
        XCTAssertEqual(corners.bottomRight, CGPoint(x: 5, y: 6))
        XCTAssertEqual(corners.bottomLeft, CGPoint(x: 0, y: 8))

        func assertMaps(_ destination: (x: Int, y: Int), to expected: (x: Int, y: Int), line: UInt = #line) {
            let actual = CanvasView.sourcePixel(forDestination: destination, transform: transform, sourceWidth: 8, sourceHeight: 8)
            XCTAssertEqual(actual?.x, expected.x, "destination \(destination) x", line: line)
            XCTAssertEqual(actual?.y, expected.y, "destination \(destination) y", line: line)
        }

        // Near the undistorted top-left corner.
        assertMaps((1, 1), to: (0, 0))
        // Near the quadrilateral's center (true perspective center, not the
        // plain average of the 4 corners — see `ProjectiveTransform`'s doc
        // comment on why this test exercises real perspective math).
        assertMaps((4, 4), to: (4, 3))
        // Near the side the distorted corner pulled inward.
        assertMaps((6, 3), to: (7, 2))

        // Proof the distortion changed the mapping: the identity (no
        // distortion) transform would have sampled destination (6, 3) from
        // source (6, 3) exactly (pixel index == destination index, no
        // rotation/scale/distortion at all) — not (7, 2).
        let identity = LayerTransform.identity(width: 8, height: 8)
        let identitySample = CanvasView.sourcePixel(forDestination: (6, 3), transform: identity, sourceWidth: 8, sourceHeight: 8)
        XCTAssertEqual(identitySample?.x, 6)
        XCTAssertEqual(identitySample?.y, 3)
    }

    /// `LayerTransform.hasDistortion` is the switch `CanvasView.sourcePixel`
    /// and the live-preview drawing use to pick between the rectangle-only
    /// and projective-transform code paths — this locks in its truth table
    /// directly, independent of any sampling behavior.
    func testLayerTransform_hasDistortion_trueOnlyWhenSomeCornerOffsetIsNonZero() {
        var transform = LayerTransform.identity(width: 8, height: 8)
        XCTAssertFalse(transform.hasDistortion)

        transform.distortTopLeft = CGVector(dx: 1, dy: 0)
        XCTAssertTrue(transform.hasDistortion)
        transform.distortTopLeft = .zero
        XCTAssertFalse(transform.hasDistortion)

        transform.distortBottomRight = CGVector(dx: 0, dy: -1)
        XCTAssertTrue(transform.hasDistortion)
    }

    // MARK: - Layer transform: mouse/key state machine hardening (issue #9
    // test-authoring pass). `activeTransform`, `transformDragHandle`, etc.
    // are all `private`, so every test below observes behavior indirectly —
    // through committed pixel content (compared against a hand-derived
    // expected `LayerTransform` via `CanvasView.sourcePixel`, the same
    // technique the round 1-3 tests above already established), through
    // `onLayerContentChanged` firing (or not), or through whether a
    // subsequent plain click paints the real canvas (proof transform mode
    // did or didn't release control of `mouseDown`).

    /// Shift only locks aspect ratio on a *corner* drag (`resizeByCorner`'s
    /// `keepAspect` parameter) — `resizeByEdge` (used for the 4 edge
    /// midpoint handles) takes no such parameter and never reads
    /// `event.modifierFlags` at all. Drives the exact same edge drag twice,
    /// with and without Shift held, and requires byte-identical committed
    /// results.
    func testMouseDragged_edgeHandleWithShiftHeld_producesTheSameResultAsWithoutShift() {
        let zoomScale = 4
        func commitEdgeDrag(withShift: Bool) -> [[(r: UInt8, g: UInt8, b: UInt8, a: UInt8)]] {
            let view = makeViewInWindow(width: 4, height: 4, zoomScale: zoomScale)
            let window = view.window!
            let canvas = view.layerStack.activeLayer.canvas
            for y in 0..<4 { for x in 0..<4 { canvas.setPixel(x: x, y: y, color: NSColor(deviceRed: Double(x) / 3, green: Double(y) / 3, blue: 0.5, alpha: 1)) } }
            view.beginLayerTransform()
            // Right edge midpoint of the 4x4 identity rectangle sits at
            // canvas (4, 2); drag it out to (6, 2).
            let down = transformWindowPoint(canvasX: 4, canvasY: 2, zoomScale: zoomScale, viewHeight: view.frame.height)
            let drag = transformWindowPoint(canvasX: 6, canvasY: 2, zoomScale: zoomScale, viewHeight: view.frame.height)
            view.mouseDown(with: mouseDownEvent(at: down, in: window))
            view.mouseDragged(with: mouseDraggedEvent(at: drag, in: window, modifierFlags: withShift ? [.shift] : []))
            view.mouseUp(with: mouseUpEvent(at: drag, in: window))
            view.keyDown(with: keyDownEvent(keyCode: 36, in: window)) // Return: commit
            var result: [[(r: UInt8, g: UInt8, b: UInt8, a: UInt8)]] = []
            for y in 0..<4 { result.append((0..<4).map { canvas.rawPixel(x: $0, y: y)! }) }
            return result
        }

        let withoutShift = commitEdgeDrag(withShift: false)
        let withShift = commitEdgeDrag(withShift: true)
        for y in 0..<4 {
            for x in 0..<4 {
                XCTAssertEqual(withShift[y][x].r, withoutShift[y][x].r, "x=\(x) y=\(y) red")
                XCTAssertEqual(withShift[y][x].g, withoutShift[y][x].g, "x=\(x) y=\(y) green")
                XCTAssertEqual(withShift[y][x].b, withoutShift[y][x].b, "x=\(x) y=\(y) blue")
                XCTAssertEqual(withShift[y][x].a, withoutShift[y][x].a, "x=\(x) y=\(y) alpha")
            }
        }
    }

    /// `mouseDragged`'s `.move` case reads only `dx`/`dy` (the raw drag
    /// delta) — never `event.modifierFlags` — so Shift/Option held during a
    /// move drag must have zero effect, unlike a corner drag (Shift) or a
    /// corner drag with Option (distort).
    func testMouseDragged_moveHandleWithShiftAndOptionHeld_stillJustTranslates() {
        let zoomScale = 4
        // 8x8 (not 4x4): the click point below has to be far enough from
        // every corner to avoid the rotate ring (`transformRotateHandleOuterRadius`,
        // 14 *view* points) as well as the plain hit radius — on a small
        // canvas at ordinary zoom, the rectangle's own center can actually
        // fall inside a corner's rotate ring, silently turning an intended
        // "click the interior" test into a rotate-handle test instead.
        let view = makeViewInWindow(width: 8, height: 8, zoomScale: zoomScale)
        let window = view.window!
        let canvas = view.layerStack.activeLayer.canvas
        for y in 0..<8 { for x in 0..<8 { canvas.setPixel(x: x, y: y, color: NSColor(deviceRed: Double(x) / 7, green: Double(y) / 7, blue: 0.5, alpha: 1)) } }
        var before: [[(r: UInt8, g: UInt8, b: UInt8, a: UInt8)]] = []
        for y in 0..<8 { before.append((0..<8).map { canvas.rawPixel(x: $0, y: y)! }) }

        view.beginLayerTransform()
        // Canvas (4, 4) is the rectangle's own center — in view points
        // (scale 4) that's 22.6 points from every corner, comfortably past
        // even the 14-point rotate ring, so this is unambiguously a `.move`
        // hit. Dragged by (+1, +1).
        let down = transformWindowPoint(canvasX: 4, canvasY: 4, zoomScale: zoomScale, viewHeight: view.frame.height)
        let drag = transformWindowPoint(canvasX: 5, canvasY: 5, zoomScale: zoomScale, viewHeight: view.frame.height)
        view.mouseDown(with: mouseDownEvent(at: down, in: window))
        view.mouseDragged(with: mouseDraggedEvent(at: drag, in: window, modifierFlags: [.shift, .option]))
        view.mouseUp(with: mouseUpEvent(at: drag, in: window))
        view.keyDown(with: keyDownEvent(keyCode: 36, in: window)) // Return: commit

        // A pure (+1, +1) translation: destination (x, y) shows source
        // (x - 1, y - 1), for the interior region only (the shifted-in edge
        // is left transparent, same cropping convention as every other
        // move/resize test above).
        for y in 0..<8 {
            for x in 0..<8 {
                let actual = canvas.rawPixel(x: x, y: y)
                if x >= 1, y >= 1 {
                    let expected = before[y - 1][x - 1]
                    XCTAssertEqual(actual?.r, expected.r, "x=\(x) y=\(y) red")
                    XCTAssertEqual(actual?.g, expected.g, "x=\(x) y=\(y) green")
                    XCTAssertEqual(actual?.b, expected.b, "x=\(x) y=\(y) blue")
                    XCTAssertEqual(actual?.a, expected.a, "x=\(x) y=\(y) alpha")
                } else {
                    XCTAssertEqual(actual?.a, 0, "x=\(x) y=\(y) should be left transparent (shifted in from outside)")
                }
            }
        }
    }

    /// The handle a drag grabs is decided once, at `mouseDown`, from
    /// `event.modifierFlags` at that instant (`hitTestTransformHandle`'s
    /// `.corner` result is only ever converted to `.distort` right there in
    /// `mouseDown`) — `mouseDragged` never re-reads Option to re-decide the
    /// handle type mid-drag, it just keeps using whatever `TransformHandle`
    /// `mouseDown` already captured. Grabbing a corner *without* Option, then
    /// pressing Option only once the drag is already under way, must
    /// therefore still produce a plain resize — byte-identical to the same
    /// drag with no Option involved at all (reusing
    /// `testLayerTransform_dragBottomRightCornerToDoubleSize_...`'s own
    /// scenario above as the known-correct plain-resize baseline).
    func testMouseDragged_cornerGrabbedWithoutOption_thenOptionPressedMidDrag_staysAPlainResize() {
        let zoomScale = 4
        let view = makeViewInWindow(width: 4, height: 4, zoomScale: zoomScale)
        let window = view.window!
        let canvas = view.layerStack.activeLayer.canvas
        for y in 0..<4 { for x in 0..<4 { canvas.setPixel(x: x, y: y, color: NSColor(deviceRed: Double(x) * 60 / 255, green: Double(y) * 60 / 255, blue: 200.0 / 255, alpha: 1)) } }
        let source00 = canvas.rawPixel(x: 0, y: 0)!
        let source10 = canvas.rawPixel(x: 1, y: 0)!
        let source01 = canvas.rawPixel(x: 0, y: 1)!
        let source11 = canvas.rawPixel(x: 1, y: 1)!

        view.beginLayerTransform()
        let downPoint = transformWindowPoint(canvasX: 4, canvasY: 4, zoomScale: zoomScale, viewHeight: view.frame.height)
        let dragPoint = transformWindowPoint(canvasX: 8, canvasY: 8, zoomScale: zoomScale, viewHeight: view.frame.height)
        view.mouseDown(with: mouseDownEvent(at: downPoint, in: window)) // no Option at mouseDown
        view.mouseDragged(with: mouseDraggedEvent(at: dragPoint, in: window, modifierFlags: [.option])) // Option pressed mid-drag
        view.mouseUp(with: mouseUpEvent(at: dragPoint, in: window))
        view.keyDown(with: keyDownEvent(keyCode: 36, in: window)) // Return: commit

        func assertPixel(_ x: Int, _ y: Int, equals expected: (r: UInt8, g: UInt8, b: UInt8, a: UInt8), line: UInt = #line) {
            let actual = canvas.rawPixel(x: x, y: y)
            XCTAssertEqual(actual?.r, expected.r, "x=\(x) y=\(y) red", line: line)
            XCTAssertEqual(actual?.g, expected.g, "x=\(x) y=\(y) green", line: line)
            XCTAssertEqual(actual?.b, expected.b, "x=\(x) y=\(y) blue", line: line)
            XCTAssertEqual(actual?.a, expected.a, "x=\(x) y=\(y) alpha", line: line)
        }
        assertPixel(0, 0, equals: source00)
        assertPixel(1, 0, equals: source00)
        assertPixel(2, 0, equals: source10)
        assertPixel(3, 0, equals: source10)
        assertPixel(0, 1, equals: source00)
        assertPixel(0, 2, equals: source01)
        assertPixel(0, 3, equals: source01)
        assertPixel(3, 3, equals: source11)
    }

    /// `mouseDown`'s double-click shortcut only fires `commitLayerTransform()`
    /// when the hit-tested handle is exactly `.move` (`if event.clickCount ==
    /// 2, handle == .move`) — every other handle, including a plain corner
    /// hit, falls straight through into the ordinary "record the drag start"
    /// path regardless of click count. Double-clicking a corner handle must
    /// not commit at all.
    func testMouseDown_doubleClickOnCornerHandle_doesNotCommit_onlyMoveRespondsToDoubleClick() {
        let zoomScale = 4
        let view = makeViewInWindow(width: 4, height: 4, zoomScale: zoomScale)
        let window = view.window!
        view.beginLayerTransform()
        var contentChangedCount = 0
        view.onLayerContentChanged = { contentChangedCount += 1 }

        // Top-left corner of the 4x4 identity transform sits at canvas (0, 0).
        let point = transformWindowPoint(canvasX: 0, canvasY: 0, zoomScale: zoomScale, viewHeight: view.frame.height)
        view.mouseDown(with: mouseDownEvent(at: point, in: window, clickCount: 2))

        XCTAssertEqual(contentChangedCount, 0, "double-clicking a resize handle (not .move) must not commit the transform")
    }

    /// `resizedAxis`'s `sign`/`abs` math (the core of `resizeByCorner`/
    /// `resizeByEdge`) is built to survive a drag that crosses all the way
    /// past the anchor (the diagonally opposite, pinned corner) without ever
    /// producing a negative or zero size — verified here via a real 2-step
    /// gesture (both hand-derived independently and cross-checked by
    /// directly re-running the same anchor-relative formula in Python):
    /// first shrink a 16x16 identity's `bottomRight` corner from (16, 16) to
    /// (8, 8) (pinning `topLeft` at canvas (0, 0), landing a `center=(4, 4),
    /// width=height=8` rectangle spanning (0, 0)-(8, 8)); then drag that
    /// rectangle's now-physically-relocated `topLeft` corner (at (0, 0)) all
    /// the way past its own diagonally-opposite anchor (`bottomRight`, now
    /// fixed at (8, 8)) out to (14, 14) — a genuine "drag through the pin"
    /// flip, not just an ordinary shrink/grow. The result lands on
    /// `center=(11, 11), width=height=6` (`>= transformMinimumSize`, and the
    /// sign flip correctly relabels which physical corner is "topLeft" vs
    /// "bottomRight" — see this test's own `corners` self-check below).
    func testMouseDragged_cornerDraggedPastItsOwnOppositeAnchor_flipsCorrectly_withoutCollapsingOrGoingNegative() {
        let zoomScale = 2
        let view = makeViewInWindow(width: 16, height: 16, zoomScale: zoomScale)
        view.setZoomScale(zoomScale)
        let window = view.window!
        let before = makeDistinctlyColoredCanvas(view: view, size: 16)

        view.beginLayerTransform()

        // Step 1: shrink bottomRight from (16, 16) to (8, 8), anchored on
        // topLeft (0, 0).
        let shrinkDown = transformWindowPoint(canvasX: 16, canvasY: 16, zoomScale: zoomScale, viewHeight: view.frame.height)
        let shrinkDrag = transformWindowPoint(canvasX: 8, canvasY: 8, zoomScale: zoomScale, viewHeight: view.frame.height)
        view.mouseDown(with: mouseDownEvent(at: shrinkDown, in: window))
        view.mouseDragged(with: mouseDraggedEvent(at: shrinkDrag, in: window))
        view.mouseUp(with: mouseUpEvent(at: shrinkDrag, in: window))

        // Step 2: drag topLeft (now physically at (0, 0)) past the fixed
        // bottomRight anchor (now at (8, 8)) out to (14, 14).
        let flipDown = transformWindowPoint(canvasX: 0, canvasY: 0, zoomScale: zoomScale, viewHeight: view.frame.height)
        let flipDrag = transformWindowPoint(canvasX: 14, canvasY: 14, zoomScale: zoomScale, viewHeight: view.frame.height)
        view.mouseDown(with: mouseDownEvent(at: flipDown, in: window))
        view.mouseDragged(with: mouseDraggedEvent(at: flipDrag, in: window))
        view.mouseUp(with: mouseUpEvent(at: flipDrag, in: window))
        view.keyDown(with: keyDownEvent(keyCode: 36, in: window)) // Return: commit

        var expected = LayerTransform.identity(width: 16, height: 16)
        expected.centerX = 11
        expected.centerY = 11
        expected.width = 6
        expected.height = 6

        // Self-check: the flip correctly relabels which physical corner is
        // which — the OLD anchor's physical position (8, 8) is now this
        // rectangle's `topLeft`-labeled corner, and the mouse's actual drag
        // target (14, 14) is now `bottomRight`.
        XCTAssertEqual(expected.corners.topLeft.x, 8, accuracy: 1e-9)
        XCTAssertEqual(expected.corners.topLeft.y, 8, accuracy: 1e-9)
        XCTAssertEqual(expected.corners.bottomRight.x, 14, accuracy: 1e-9)
        XCTAssertEqual(expected.corners.bottomRight.y, 14, accuracy: 1e-9)

        let canvas = view.layerStack.activeLayer.canvas
        for y in 0..<16 {
            for x in 0..<16 {
                let actual = canvas.rawPixel(x: x, y: y)
                if let source = CanvasView.sourcePixel(forDestination: (x, y), transform: expected, sourceWidth: 16, sourceHeight: 16) {
                    let expectedPixel = before[source.y][source.x]
                    XCTAssertEqual(actual?.r, expectedPixel.r, "x=\(x) y=\(y) red")
                    XCTAssertEqual(actual?.g, expectedPixel.g, "x=\(x) y=\(y) green")
                    XCTAssertEqual(actual?.b, expectedPixel.b, "x=\(x) y=\(y) blue")
                    XCTAssertEqual(actual?.a, expectedPixel.a, "x=\(x) y=\(y) alpha")
                } else {
                    XCTAssertEqual(actual?.a, 0, "x=\(x) y=\(y) should be left transparent")
                }
            }
        }
    }

    /// `resizedAxis`'s `max(transformMinimumSize, abs(raw - anchor))` floor
    /// means any drag that WOULD produce a size below the minimum (4) all
    /// clamp to exactly the same minimum-size rectangle — not merely "some
    /// small size", but the identical one regardless of how much further
    /// past the floor the drag goes. Drags `bottomRight` from (8, 8) to two
    /// different targets close to the (0, 0) anchor — (2, 2) and (0, 0) —
    /// both landing at local size `2` and `0` respectively (both `< 4`), and
    /// requires byte-identical committed results.
    func testMouseDragged_cornerDraggedBelowMinimumSize_alwaysClampsToTheSameFloor() {
        let zoomScale = 4
        func commitCornerDrag(dragToCanvas target: Double) -> [[(r: UInt8, g: UInt8, b: UInt8, a: UInt8)]] {
            let view = makeViewInWindow(width: 8, height: 8, zoomScale: zoomScale)
            let window = view.window!
            let canvas = view.layerStack.activeLayer.canvas
            for y in 0..<8 { for x in 0..<8 { canvas.setPixel(x: x, y: y, color: NSColor(deviceRed: Double(x) / 7, green: Double(y) / 7, blue: 0.5, alpha: 1)) } }
            view.beginLayerTransform()
            let down = transformWindowPoint(canvasX: 8, canvasY: 8, zoomScale: zoomScale, viewHeight: view.frame.height)
            let drag = transformWindowPoint(canvasX: target, canvasY: target, zoomScale: zoomScale, viewHeight: view.frame.height)
            view.mouseDown(with: mouseDownEvent(at: down, in: window))
            view.mouseDragged(with: mouseDraggedEvent(at: drag, in: window))
            view.mouseUp(with: mouseUpEvent(at: drag, in: window))
            view.keyDown(with: keyDownEvent(keyCode: 36, in: window)) // Return: commit
            var result: [[(r: UInt8, g: UInt8, b: UInt8, a: UInt8)]] = []
            for y in 0..<8 { result.append((0..<8).map { canvas.rawPixel(x: $0, y: y)! }) }
            return result
        }

        let draggedTo2 = commitCornerDrag(dragToCanvas: 2) // raw local size 2, < 4
        let draggedTo0 = commitCornerDrag(dragToCanvas: 0) // raw local size 0, < 4
        for y in 0..<8 {
            for x in 0..<8 {
                XCTAssertEqual(draggedTo2[y][x].r, draggedTo0[y][x].r, "x=\(x) y=\(y) red")
                XCTAssertEqual(draggedTo2[y][x].g, draggedTo0[y][x].g, "x=\(x) y=\(y) green")
                XCTAssertEqual(draggedTo2[y][x].b, draggedTo0[y][x].b, "x=\(x) y=\(y) blue")
                XCTAssertEqual(draggedTo2[y][x].a, draggedTo0[y][x].a, "x=\(x) y=\(y) alpha")
            }
        }

        // And it's genuinely the *minimum* size that was applied, not
        // something bigger: the committed rectangle (center local (-2, -2)
        // relative to the original center (4, 4), i.e. canvas (2, 2), size
        // 4x4) only covers destination pixels (0, 0)-(3, 3); canvas (7, 7)
        // must be outside it and therefore transparent.
        XCTAssertEqual(draggedTo2[7][7].a, 0, "the clamped rectangle must not have grown past the minimum size")
    }

    // MARK: - Handle hit-test radius boundaries (issue #9 test-authoring
    // pass). `hitTestTransformHandle` checks corner hits within
    // `transformHandleHitRadius` (6 view points) first, then the rotate ring
    // out to `transformRotateHandleOuterRadius` (14), then falls through to
    // the interior/`.move`/`nil` check. These constants are `private`, so
    // the boundary values (6, 14) are hardcoded here directly — same
    // approach the existing `magnifierClickThreshold` tests above already
    // take for that constant.
    //
    // Both tests click along a pure horizontal ray from the identity
    // rectangle's top-left corner (0, 0), with `zoomScale` set to 1 so
    // view-space distance equals canvas-space distance exactly
    // (`hypot(-R, 0) == R`, no floating-point surprises). At that geometry
    // there are only ever 2 possible outcomes to distinguish between (the
    // clicked point is always outside the rectangle itself, so `.move` is
    // never a candidate), so proving the actual result matches ONE
    // hand-derived prediction is sufficient to also rule out the other.

    private func commitCornerRayDrag(atRadius radius: Double, dragDelta: Double, zoomScale: Int) -> (before: [[(r: UInt8, g: UInt8, b: UInt8, a: UInt8)]], after: [[(r: UInt8, g: UInt8, b: UInt8, a: UInt8)]]) {
        let view = makeViewInWindow(width: 8, height: 8, zoomScale: zoomScale)
        view.setZoomScale(zoomScale)
        let window = view.window!
        let canvas = view.layerStack.activeLayer.canvas
        for y in 0..<8 { for x in 0..<8 { canvas.setPixel(x: x, y: y, color: NSColor(deviceRed: Double(x) / 7, green: Double(y) / 7, blue: 0.5, alpha: 1)) } }
        var before: [[(r: UInt8, g: UInt8, b: UInt8, a: UInt8)]] = []
        for y in 0..<8 { before.append((0..<8).map { canvas.rawPixel(x: $0, y: y)! }) }

        view.beginLayerTransform()
        let down = transformWindowPoint(canvasX: -radius, canvasY: 0, zoomScale: zoomScale, viewHeight: view.frame.height)
        let drag = transformWindowPoint(canvasX: -radius + dragDelta, canvasY: 0, zoomScale: zoomScale, viewHeight: view.frame.height)
        view.mouseDown(with: mouseDownEvent(at: down, in: window))
        view.mouseDragged(with: mouseDraggedEvent(at: drag, in: window))
        view.mouseUp(with: mouseUpEvent(at: drag, in: window))
        view.keyDown(with: keyDownEvent(keyCode: 36, in: window)) // Return: commit

        var after: [[(r: UInt8, g: UInt8, b: UInt8, a: UInt8)]] = []
        for y in 0..<8 { after.append((0..<8).map { canvas.rawPixel(x: $0, y: y)! }) }
        return (before, after)
    }

    /// At exactly `transformHandleHitRadius` (6) from the corner: a corner
    /// hit. Hand-derived expected result, same anchor-relative reasoning as
    /// `testLayerTransform_dragBottomRightCornerToDoubleSize_...` above: the
    /// `bottomRight` anchor (8, 8) stays fixed while dragging `topLeft`
    /// rightward by 4 shrinks `width` from 8 to 4 (new center local x = 2,
    /// canvas x = 6); a horizontal-only drag leaves `height`/`centerY`
    /// untouched at 8/4.
    func testHitTestTransformHandle_atExactlyHandleHitRadius_isACornerResize() {
        let zoomScale = 1
        let (before, after) = commitCornerRayDrag(atRadius: 6, dragDelta: 4, zoomScale: zoomScale)

        var expected = LayerTransform.identity(width: 8, height: 8)
        expected.centerX = 6
        expected.centerY = 4
        expected.width = 4
        expected.height = 8

        for y in 0..<8 {
            for x in 0..<8 {
                let actual = after[y][x]
                if let source = CanvasView.sourcePixel(forDestination: (x, y), transform: expected, sourceWidth: 8, sourceHeight: 8) {
                    let expectedPixel = before[source.y][source.x]
                    XCTAssertEqual(actual.r, expectedPixel.r, "x=\(x) y=\(y) red")
                    XCTAssertEqual(actual.g, expectedPixel.g, "x=\(x) y=\(y) green")
                    XCTAssertEqual(actual.b, expectedPixel.b, "x=\(x) y=\(y) blue")
                    XCTAssertEqual(actual.a, expectedPixel.a, "x=\(x) y=\(y) alpha")
                } else {
                    XCTAssertEqual(actual.a, 0, "x=\(x) y=\(y) should be left transparent")
                }
            }
        }
    }

    /// Just past `transformHandleHitRadius` (radius 7, not a round-number
    /// boundary but comfortably outside 6 and inside the 14 rotate ring): a
    /// rotate, not a corner resize. Rather than hand-deriving the exact
    /// (non-round) rotation angle, this distinguishes the two remaining
    /// candidates (corner-resize vs. rotate — `.move` can't apply, the click
    /// point is outside the rectangle) via a marker pixel whose fate
    /// differs between them: canvas (1, 4) sits at local offset (-3, 0) from
    /// the identity rectangle's center. A corner-resize (as in the radius-6
    /// test above) shrinks `width` to 4 centered at canvas x=6, which pushes
    /// (1, 4) (local x -5 relative to the new center) outside the resized
    /// rectangle — transparent. A small rotation (this drag's angle is
    /// ~9.8°, confirmed by an independent calculation) leaves (1, 4) well
    /// inside the still-full-size, merely-tilted rectangle — opaque.
    func testHitTestTransformHandle_justPastHandleHitRadius_isARotate_notACornerResize() {
        let zoomScale = 1
        let (_, after) = commitCornerRayDrag(atRadius: 7, dragDelta: 4, zoomScale: zoomScale)

        XCTAssertNotEqual(after[4][1].a, 0, "canvas (1,4) must stay opaque: a rotate keeps the full rectangle, unlike the radius-6 corner-resize case which crops this pixel away")
    }

    /// At exactly `transformRotateHandleOuterRadius` (14): still a rotate
    /// (the ring is inclusive on both ends, `> hitRadius && <= outerRadius`).
    /// The only 2 candidates at this distance are "rotate" and "nothing at
    /// all" (`.move` still can't apply — this radius is even farther outside
    /// the rectangle than the radius-7 case above), so proving *some* change
    /// occurred (the committed canvas isn't a byte-exact reproduction of the
    /// original) is enough to rule out "nothing happened".
    func testHitTestTransformHandle_atExactlyRotateHandleOuterRadius_isStillARotate() {
        let zoomScale = 1
        let (before, after) = commitCornerRayDrag(atRadius: 14, dragDelta: 4, zoomScale: zoomScale)

        var changedSomePixel = false
        for y in 0..<8 {
            for x in 0..<8 where after[y][x] != before[y][x] {
                changedSomePixel = true
            }
        }
        XCTAssertTrue(changedSomePixel, "radius 14 is still within the inclusive rotate ring, so the identity transform must not be reproduced unchanged")
    }

    /// Just past `transformRotateHandleOuterRadius` (radius 15): no handle
    /// at all. The click point is far enough from every corner/edge that
    /// none of the corner/edge/rotate checks match, and it's also outside
    /// the rectangle's own interior, so `hitTestTransformHandle` returns
    /// `nil` — the drag is entirely inert, and committing reproduces the
    /// untouched identity canvas byte-exactly (same guarantee
    /// `testLayerTransform_commitWithNoDrag_reproducesOriginalCanvasByteExact`
    /// makes for "no drag at all"; here the drag exists but never grabs a
    /// handle).
    func testHitTestTransformHandle_justPastRotateHandleOuterRadius_isNil_dragIsInert() {
        let zoomScale = 1
        let (before, after) = commitCornerRayDrag(atRadius: 15, dragDelta: 4, zoomScale: zoomScale)

        for y in 0..<8 {
            for x in 0..<8 {
                XCTAssertEqual(after[y][x].r, before[y][x].r, "x=\(x) y=\(y) red")
                XCTAssertEqual(after[y][x].g, before[y][x].g, "x=\(x) y=\(y) green")
                XCTAssertEqual(after[y][x].b, before[y][x].b, "x=\(x) y=\(y) blue")
                XCTAssertEqual(after[y][x].a, before[y][x].a, "x=\(x) y=\(y) alpha")
            }
        }
    }

    /// A `mouseDown` that lands completely outside the transform rectangle
    /// (and outside every handle's hitbox) records `transformDragHandle =
    /// nil` (see `hitTestTransformHandle`'s own doc comment: "a point outside
    /// the rectangle entirely is `nil`"); the following `mouseDragged` then
    /// takes the "drag started outside the rectangle entirely... deliberately
    /// inert" early-return branch. A subsequent commit must reproduce the
    /// untouched canvas byte-exactly.
    func testMouseDown_completelyOutsideTheRectangle_makesTheFollowingMouseDraggedANoOp() {
        let zoomScale = 4
        let view = makeViewInWindow(width: 8, height: 8, zoomScale: zoomScale)
        let window = view.window!
        let canvas = view.layerStack.activeLayer.canvas
        for y in 0..<8 { for x in 0..<8 { canvas.setPixel(x: x, y: y, color: NSColor(deviceRed: Double(x) / 7, green: Double(y) / 7, blue: 0.5, alpha: 1)) } }
        var before: [[(r: UInt8, g: UInt8, b: UInt8, a: UInt8)]] = []
        for y in 0..<8 { before.append((0..<8).map { canvas.rawPixel(x: $0, y: y)! }) }

        view.beginLayerTransform()
        // Canvas (20, 20) is far outside the 8x8 rectangle and far from
        // every corner/edge handle (nearest corner, bottomRight (8, 8), is
        // ~17 view points away — past even the rotate ring).
        let down = transformWindowPoint(canvasX: 20, canvasY: 20, zoomScale: zoomScale, viewHeight: view.frame.height)
        let drag = transformWindowPoint(canvasX: 2, canvasY: 2, zoomScale: zoomScale, viewHeight: view.frame.height)
        view.mouseDown(with: mouseDownEvent(at: down, in: window))
        view.mouseDragged(with: mouseDraggedEvent(at: drag, in: window))
        view.mouseUp(with: mouseUpEvent(at: drag, in: window))
        view.keyDown(with: keyDownEvent(keyCode: 36, in: window)) // Return: commit

        for y in 0..<8 {
            for x in 0..<8 {
                let actual = canvas.rawPixel(x: x, y: y)
                XCTAssertEqual(actual?.r, before[y][x].r, "x=\(x) y=\(y) red")
                XCTAssertEqual(actual?.g, before[y][x].g, "x=\(x) y=\(y) green")
                XCTAssertEqual(actual?.b, before[y][x].b, "x=\(x) y=\(y) blue")
                XCTAssertEqual(actual?.a, before[y][x].a, "x=\(x) y=\(y) alpha")
            }
        }
    }

    // MARK: - Distortion interacting with hit-testing / resizing (issue #9
    // review must-2/should-3). Both tests below used to be CHARACTERIZATION
    // TESTS pinning down actual bugs (see git history for the original
    // "misses every handle" / "anchors on the undistorted base corner"
    // versions); both are now correctness assertions of the fixed behavior.

    /// `hitTestTransformHandle`'s final fallback (the interior/`.move` test)
    /// now switches to a `ProjectiveTransform`-based point-in-quadrilateral
    /// test whenever `transform.hasDistortion` is true, rather than always
    /// testing against the plain, UNDISTORTED rectangle (issue #9 review
    /// must-2). This test distorts `topLeft` far outward on a large (30x30)
    /// canvas, then drags from a point independently verified (by
    /// point-in-polygon and per-handle distance checks) to sit inside the
    /// visually-drawn distorted quadrilateral, outside the plain base
    /// rectangle, and beyond every corner/edge hitbox and rotate ring — a
    /// point that lands squarely in the interior fallback, on the *visual*
    /// shape but not the *base* one. That fallback must now correctly treat
    /// it as `.move`, so the drag actually shifts the whole transform (by
    /// its own canvas-pixel delta) in addition to the standing
    /// `distortTopLeft` offset from the first gesture.
    func testDistortedTransform_clickInsideVisualQuadButOutsideBaseRectangle_hitsMoveHandle() {
        let zoomScale = 1
        let view = makeViewInWindow(width: 30, height: 30, zoomScale: zoomScale)
        view.setZoomScale(zoomScale)
        let window = view.window!
        let canvas = view.layerStack.activeLayer.canvas
        for y in 0..<30 { for x in 0..<30 { canvas.setPixel(x: x, y: y, color: NSColor(deviceRed: Double(x) / 29, green: Double(y) / 29, blue: 0.5, alpha: 1)) } }
        var before: [[(r: UInt8, g: UInt8, b: UInt8, a: UInt8)]] = []
        for y in 0..<30 { before.append((0..<30).map { canvas.rawPixel(x: $0, y: y)! }) }

        view.beginLayerTransform()
        // Distort topLeft (Option+corner drag) from (0, 0) out to (-15, 0).
        let distortDown = transformWindowPoint(canvasX: 0, canvasY: 0, zoomScale: zoomScale, viewHeight: view.frame.height)
        let distortDrag = transformWindowPoint(canvasX: -15, canvasY: 0, zoomScale: zoomScale, viewHeight: view.frame.height)
        view.mouseDown(with: mouseDownEvent(at: distortDown, in: window, modifierFlags: [.option]))
        view.mouseDragged(with: mouseDraggedEvent(at: distortDrag, in: window, modifierFlags: [.option]))
        view.mouseUp(with: mouseUpEvent(at: distortDrag, in: window))

        // (-1, 5): verified independently (point-in-polygon against corners
        // (-15,0)/(30,0)/(30,30)/(0,30), plus distance checks against every
        // corner/edge handle position) to be inside the drawn quad, outside
        // the base [0,30]x[0,30] rectangle, and >14 view points from every
        // corner/edge — a clean miss on every handle check, landing in the
        // interior fallback, which (post-fix) hits `.move`. Dragged to
        // (3, 9): a (+4, +4) canvas-pixel move.
        let movePoint = transformWindowPoint(canvasX: -1, canvasY: 5, zoomScale: zoomScale, viewHeight: view.frame.height)
        let moveDrag = transformWindowPoint(canvasX: 3, canvasY: 9, zoomScale: zoomScale, viewHeight: view.frame.height)
        view.mouseDown(with: mouseDownEvent(at: movePoint, in: window))
        view.mouseDragged(with: mouseDraggedEvent(at: moveDrag, in: window))
        view.mouseUp(with: mouseUpEvent(at: moveDrag, in: window))
        view.keyDown(with: keyDownEvent(keyCode: 36, in: window)) // Return: commit

        var expected = LayerTransform.identity(width: 30, height: 30)
        expected.distortTopLeft = CGVector(dx: -15, dy: 0)
        expected.centerX += 4
        expected.centerY += 4
        for y in 0..<30 {
            for x in 0..<30 {
                let actual = canvas.rawPixel(x: x, y: y)
                if let source = CanvasView.sourcePixel(forDestination: (x, y), transform: expected, sourceWidth: 30, sourceHeight: 30) {
                    let expectedPixel = before[source.y][source.x]
                    XCTAssertEqual(actual?.r, expectedPixel.r, "x=\(x) y=\(y) red")
                    XCTAssertEqual(actual?.g, expectedPixel.g, "x=\(x) y=\(y) green")
                    XCTAssertEqual(actual?.b, expectedPixel.b, "x=\(x) y=\(y) blue")
                    XCTAssertEqual(actual?.a, expectedPixel.a, "x=\(x) y=\(y) alpha")
                } else {
                    XCTAssertEqual(actual?.a, 0, "x=\(x) y=\(y) should be left transparent")
                }
            }
        }
    }

    /// `resizeByCorner`'s anchor is always computed from the plain
    /// UNDISTORTED rectangle's own local-frame corner position (`(±halfWidth,
    /// ±halfHeight)`) — it never reads the anchor corner's own `distort*`
    /// offset — and the result (`var result = start; result.width = ...`)
    /// carries every `distort*` field forward completely untouched. This
    /// `resizeByCorner`'s anchor is always computed from the plain
    /// UNDISTORTED rectangle's own local-frame corner position (`(±halfWidth,
    /// ±halfHeight)`) — it never reads the anchor corner's own `distort*`
    /// offset — so a plain (non-Option) corner/edge resize is not guaranteed
    /// to preserve an existing distortion correctly in general (issue #9
    /// review should-3). Rather than risk a silently-wrong shape, `mouseDragged`
    /// now disables plain corner/edge resize entirely while
    /// `activeTransform.hasDistortion` is true — it's a no-op, not a
    /// (possibly incorrect) resize. This test distorts `bottomLeft`, then
    /// drags the diagonally opposite `topRight` corner with no Shift/Option
    /// held; the resize must have no effect at all, leaving `activeTransform`
    /// exactly as the distort step left it.
    func testDistortedTransform_resizeViaOppositeCorner_isANoOp_leavesDistortionAndSizeUnchanged() {
        let zoomScale = 4
        let view = makeViewInWindow(width: 8, height: 8, zoomScale: zoomScale)
        let window = view.window!
        let canvas = view.layerStack.activeLayer.canvas
        for y in 0..<8 { for x in 0..<8 { canvas.setPixel(x: x, y: y, color: NSColor(deviceRed: Double(x) / 7, green: Double(y) / 7, blue: 0.5, alpha: 1)) } }
        var before: [[(r: UInt8, g: UInt8, b: UInt8, a: UInt8)]] = []
        for y in 0..<8 { before.append((0..<8).map { canvas.rawPixel(x: $0, y: y)! }) }

        view.beginLayerTransform()
        // Distort bottomLeft (Option+corner) from (0, 8) out to (-4, 12).
        let distortDown = transformWindowPoint(canvasX: 0, canvasY: 8, zoomScale: zoomScale, viewHeight: view.frame.height)
        let distortDrag = transformWindowPoint(canvasX: -4, canvasY: 12, zoomScale: zoomScale, viewHeight: view.frame.height)
        view.mouseDown(with: mouseDownEvent(at: distortDown, in: window, modifierFlags: [.option]))
        view.mouseDragged(with: mouseDraggedEvent(at: distortDrag, in: window, modifierFlags: [.option]))
        view.mouseUp(with: mouseUpEvent(at: distortDrag, in: window))

        // Attempt to resize via topRight (currently at (8, 0)), dragging it
        // out to (12, -4) — no Shift/Option. Must be a no-op now that
        // `activeTransform.hasDistortion` is true.
        let resizeDown = transformWindowPoint(canvasX: 8, canvasY: 0, zoomScale: zoomScale, viewHeight: view.frame.height)
        let resizeDrag = transformWindowPoint(canvasX: 12, canvasY: -4, zoomScale: zoomScale, viewHeight: view.frame.height)
        view.mouseDown(with: mouseDownEvent(at: resizeDown, in: window))
        view.mouseDragged(with: mouseDraggedEvent(at: resizeDrag, in: window))
        view.mouseUp(with: mouseUpEvent(at: resizeDrag, in: window))
        view.keyDown(with: keyDownEvent(keyCode: 36, in: window)) // Return: commit

        // Expected: exactly the state left by the distort step alone — the
        // "resize" attempt changed nothing.
        var expected = LayerTransform.identity(width: 8, height: 8)
        expected.distortBottomLeft = CGVector(dx: -4, dy: 4)

        for y in 0..<8 {
            for x in 0..<8 {
                let actual = canvas.rawPixel(x: x, y: y)
                if let source = CanvasView.sourcePixel(forDestination: (x, y), transform: expected, sourceWidth: 8, sourceHeight: 8) {
                    let expectedPixel = before[source.y][source.x]
                    XCTAssertEqual(actual?.r, expectedPixel.r, "x=\(x) y=\(y) red")
                    XCTAssertEqual(actual?.g, expectedPixel.g, "x=\(x) y=\(y) green")
                    XCTAssertEqual(actual?.b, expectedPixel.b, "x=\(x) y=\(y) blue")
                    XCTAssertEqual(actual?.a, expectedPixel.a, "x=\(x) y=\(y) alpha")
                } else {
                    XCTAssertEqual(actual?.a, 0, "x=\(x) y=\(y) should be left transparent")
                }
            }
        }
    }

    /// Same should-3 no-op guarantee as the test above, but for an EDGE
    /// handle (not a corner) and a different distorted corner — since
    /// `activeTransform`/`transformDragHandle` etc. are all `private` (see
    /// this section's own header comment further up), this is verified the
    /// same indirect way every other test in this section is: if the resize
    /// drag had changed `activeTransform` at all, the committed pixels
    /// would no longer match the plain post-distort transform below.
    func testDistortedTransform_resizeViaEdgeHandle_isANoOp_leavesDistortionAndSizeUnchanged() {
        let zoomScale = 4
        let view = makeViewInWindow(width: 8, height: 8, zoomScale: zoomScale)
        let window = view.window!
        let canvas = view.layerStack.activeLayer.canvas
        for y in 0..<8 { for x in 0..<8 { canvas.setPixel(x: x, y: y, color: NSColor(deviceRed: Double(x) / 7, green: Double(y) / 7, blue: 0.5, alpha: 1)) } }
        var before: [[(r: UInt8, g: UInt8, b: UInt8, a: UInt8)]] = []
        for y in 0..<8 { before.append((0..<8).map { canvas.rawPixel(x: $0, y: y)! }) }

        view.beginLayerTransform()
        // Distort topLeft (Option+corner) from (0, 0) out to (-2, -2).
        let distortDown = transformWindowPoint(canvasX: 0, canvasY: 0, zoomScale: zoomScale, viewHeight: view.frame.height)
        let distortDrag = transformWindowPoint(canvasX: -2, canvasY: -2, zoomScale: zoomScale, viewHeight: view.frame.height)
        view.mouseDown(with: mouseDownEvent(at: distortDown, in: window, modifierFlags: [.option]))
        view.mouseDragged(with: mouseDraggedEvent(at: distortDrag, in: window, modifierFlags: [.option]))
        view.mouseUp(with: mouseUpEvent(at: distortDrag, in: window))

        // Attempt to resize via the right edge midpoint (currently at
        // (8, 4)), dragging it out to (12, 4) — no Shift/Option. Must be a
        // no-op now that `activeTransform.hasDistortion` is true.
        let resizeDown = transformWindowPoint(canvasX: 8, canvasY: 4, zoomScale: zoomScale, viewHeight: view.frame.height)
        let resizeDrag = transformWindowPoint(canvasX: 12, canvasY: 4, zoomScale: zoomScale, viewHeight: view.frame.height)
        view.mouseDown(with: mouseDownEvent(at: resizeDown, in: window))
        view.mouseDragged(with: mouseDraggedEvent(at: resizeDrag, in: window))
        view.mouseUp(with: mouseUpEvent(at: resizeDrag, in: window))
        view.keyDown(with: keyDownEvent(keyCode: 36, in: window)) // Return: commit

        // Expected: exactly the state left by the distort step alone.
        var expected = LayerTransform.identity(width: 8, height: 8)
        expected.distortTopLeft = CGVector(dx: -2, dy: -2)

        for y in 0..<8 {
            for x in 0..<8 {
                let actual = canvas.rawPixel(x: x, y: y)
                if let source = CanvasView.sourcePixel(forDestination: (x, y), transform: expected, sourceWidth: 8, sourceHeight: 8) {
                    let expectedPixel = before[source.y][source.x]
                    XCTAssertEqual(actual?.r, expectedPixel.r, "x=\(x) y=\(y) red")
                    XCTAssertEqual(actual?.g, expectedPixel.g, "x=\(x) y=\(y) green")
                    XCTAssertEqual(actual?.b, expectedPixel.b, "x=\(x) y=\(y) blue")
                    XCTAssertEqual(actual?.a, expectedPixel.a, "x=\(x) y=\(y) alpha")
                } else {
                    XCTAssertEqual(actual?.a, 0, "x=\(x) y=\(y) should be left transparent")
                }
            }
        }
    }

    /// `keyDown`'s transform-mode branch only recognizes Return/keypad Enter
    /// (36/76, commit) and Escape (53, cancel) — every other key falls to
    /// `default: super.keyDown(with: event)`, leaving `activeTransform`
    /// completely untouched. Verified indirectly: if a stray key had
    /// exited transform mode (committed or cancelled), the very next plain
    /// click would fall through to the default `.pencil` tool and paint the
    /// real canvas immediately (no separate commit step needed for an
    /// ordinary paint stroke) — since transform mode instead intercepts
    /// every mouse event unconditionally, the real canvas must stay
    /// untouched, and a real Return afterward must still be able to commit.
    func testKeyDown_nonReturnEscapeKey_leavesTransformModeActive_subsequentClickStillDoesNotPaint() {
        let zoomScale = 4
        let view = makeViewInWindow(width: 4, height: 4, zoomScale: zoomScale)
        let window = view.window!
        view.foregroundColor = .black
        let canvas = view.layerStack.activeLayer.canvas
        let before = canvas.rawPixel(x: 2, y: 2)!

        view.beginLayerTransform()
        view.keyDown(with: keyDownEvent(keyCode: 0, in: window)) // 'a' — neither Return (36/76) nor Escape (53)

        let clickPoint = windowPoint(forPixelCol: 2, row: 2, zoomScale: zoomScale, viewHeight: view.frame.height)
        view.mouseDown(with: mouseDownEvent(at: clickPoint, in: window))
        view.mouseUp(with: mouseUpEvent(at: clickPoint, in: window))

        let afterStrayKeyAndClick = canvas.rawPixel(x: 2, y: 2)
        XCTAssertEqual(afterStrayKeyAndClick?.r, before.r, "a non-Return/Escape key must not exit transform mode")
        XCTAssertEqual(afterStrayKeyAndClick?.g, before.g)
        XCTAssertEqual(afterStrayKeyAndClick?.b, before.b)
        XCTAssertEqual(afterStrayKeyAndClick?.a, before.a)

        var contentChangedCount = 0
        view.onLayerContentChanged = { contentChangedCount += 1 }
        view.keyDown(with: keyDownEvent(keyCode: 36, in: window)) // Return: commit
        XCTAssertEqual(contentChangedCount, 1, "the transform must still be alive and committable after the stray key")
    }

    // MARK: - Layer transform: integration-level real gesture tests (issue
    // #9 test-authoring pass). Every test in this section drives the actual
    // `mouseDown`/`mouseDragged`/`mouseUp`/`keyDown` pipeline end to end —
    // no reaching into `private` state — the same way the round 1-3 tests
    // earlier in this file already do.

    /// THE core safety guarantee of a cancellable transform tool: whichever
    /// kind of drag is in progress (resize, rotate, or distort) when Escape
    /// is pressed, the real layer canvas must come back byte-for-byte
    /// identical to what it was before `beginLayerTransform()` — not merely
    /// "visually close" or "transparent where it should be opaque".
    /// `cancelLayerTransform()`'s own doc comment already states this is
    /// true by construction (the real canvas was never written to during the
    /// drag, only `activeTransform`/the live-preview draw were), but this is
    /// the guarantee actually being sold to the user, so it gets its own
    /// direct, per-gesture-kind verification rather than resting solely on
    /// that doc comment.

    private func makeDistinctlyColoredCanvas(view: CanvasView, size: Int) -> [[(r: UInt8, g: UInt8, b: UInt8, a: UInt8)]] {
        let canvas = view.layerStack.activeLayer.canvas
        for y in 0..<size {
            for x in 0..<size {
                canvas.setPixel(x: x, y: y, color: NSColor(deviceRed: Double(x) / Double(size - 1), green: Double(y) / Double(size - 1), blue: 0.5, alpha: 1))
            }
        }
        var snapshot: [[(r: UInt8, g: UInt8, b: UInt8, a: UInt8)]] = []
        for y in 0..<size { snapshot.append((0..<size).map { canvas.rawPixel(x: $0, y: y)! }) }
        return snapshot
    }

    private func assertCanvas(_ view: CanvasView, size: Int, matches expected: [[(r: UInt8, g: UInt8, b: UInt8, a: UInt8)]], line: UInt = #line) {
        let canvas = view.layerStack.activeLayer.canvas
        for y in 0..<size {
            for x in 0..<size {
                let actual = canvas.rawPixel(x: x, y: y)
                XCTAssertEqual(actual?.r, expected[y][x].r, "x=\(x) y=\(y) red", line: line)
                XCTAssertEqual(actual?.g, expected[y][x].g, "x=\(x) y=\(y) green", line: line)
                XCTAssertEqual(actual?.b, expected[y][x].b, "x=\(x) y=\(y) blue", line: line)
                XCTAssertEqual(actual?.a, expected[y][x].a, "x=\(x) y=\(y) alpha", line: line)
            }
        }
    }

    func testEscape_duringAResizeDrag_cancelsAndReproducesTheOriginalCanvasByteExact() {
        let zoomScale = 4
        let view = makeViewInWindow(width: 8, height: 8, zoomScale: zoomScale)
        let window = view.window!
        let before = makeDistinctlyColoredCanvas(view: view, size: 8)

        view.beginLayerTransform()
        let down = transformWindowPoint(canvasX: 8, canvasY: 8, zoomScale: zoomScale, viewHeight: view.frame.height)
        let drag = transformWindowPoint(canvasX: 16, canvasY: 16, zoomScale: zoomScale, viewHeight: view.frame.height)
        view.mouseDown(with: mouseDownEvent(at: down, in: window))
        view.mouseDragged(with: mouseDraggedEvent(at: drag, in: window))
        view.keyDown(with: keyDownEvent(keyCode: 53, in: window)) // Escape: cancel mid-drag

        assertCanvas(view, size: 8, matches: before)
    }

    func testEscape_duringARotateDrag_cancelsAndReproducesTheOriginalCanvasByteExact() {
        let zoomScale = 4
        let view = makeViewInWindow(width: 4, height: 4, zoomScale: zoomScale)
        let window = view.window!
        let before = makeDistinctlyColoredCanvas(view: view, size: 4)

        view.beginLayerTransform()
        let down = transformWindowPoint(canvasX: -1, canvasY: -1, zoomScale: zoomScale, viewHeight: view.frame.height)
        let drag = transformWindowPoint(canvasX: 3, canvasY: 3, zoomScale: zoomScale, viewHeight: view.frame.height)
        view.mouseDown(with: mouseDownEvent(at: down, in: window))
        view.mouseDragged(with: mouseDraggedEvent(at: drag, in: window, modifierFlags: [.shift]))
        view.keyDown(with: keyDownEvent(keyCode: 53, in: window)) // Escape: cancel mid-drag

        assertCanvas(view, size: 4, matches: before)
    }

    func testEscape_duringADistortDrag_cancelsAndReproducesTheOriginalCanvasByteExact() {
        let zoomScale = 4
        let view = makeViewInWindow(width: 8, height: 8, zoomScale: zoomScale)
        let window = view.window!
        let before = makeDistinctlyColoredCanvas(view: view, size: 8)

        view.beginLayerTransform()
        let down = transformWindowPoint(canvasX: 0, canvasY: 0, zoomScale: zoomScale, viewHeight: view.frame.height)
        let drag = transformWindowPoint(canvasX: -3, canvasY: -2, zoomScale: zoomScale, viewHeight: view.frame.height)
        view.mouseDown(with: mouseDownEvent(at: down, in: window, modifierFlags: [.option]))
        view.mouseDragged(with: mouseDraggedEvent(at: drag, in: window, modifierFlags: [.option]))
        view.keyDown(with: keyDownEvent(keyCode: 53, in: window)) // Escape: cancel mid-drag

        assertCanvas(view, size: 8, matches: before)
    }

    /// After a cancel, `beginLayerTransform()`'s only guard is
    /// `activeTransform == nil` — `cancelLayerTransform()` sets exactly that
    /// back to `nil` — so a fresh transform must start (and complete)
    /// normally afterward, with no leftover state from the cancelled attempt.
    func testBeginLayerTransform_afterACancel_startsACleanNewTransformThatCommitsNormally() {
        let zoomScale = 4
        // 8x8: see the comment on `testMouseDragged_moveHandleWithShiftAndOptionHeld_...`
        // above for why the plain move drag below needs a canvas this size
        // to land unambiguously on `.move` rather than a corner's rotate ring.
        let view = makeViewInWindow(width: 8, height: 8, zoomScale: zoomScale)
        let window = view.window!
        let before = makeDistinctlyColoredCanvas(view: view, size: 8)

        view.beginLayerTransform()
        let firstDown = transformWindowPoint(canvasX: 8, canvasY: 8, zoomScale: zoomScale, viewHeight: view.frame.height)
        let firstDrag = transformWindowPoint(canvasX: 16, canvasY: 16, zoomScale: zoomScale, viewHeight: view.frame.height)
        view.mouseDown(with: mouseDownEvent(at: firstDown, in: window))
        view.mouseDragged(with: mouseDraggedEvent(at: firstDrag, in: window))
        view.keyDown(with: keyDownEvent(keyCode: 53, in: window)) // Escape: cancel

        // A fresh transform: a plain (+1, +1) move (from the rectangle's own
        // center, safely away from every corner's rotate ring), committed
        // normally.
        view.beginLayerTransform()
        let moveDown = transformWindowPoint(canvasX: 4, canvasY: 4, zoomScale: zoomScale, viewHeight: view.frame.height)
        let moveDrag = transformWindowPoint(canvasX: 5, canvasY: 5, zoomScale: zoomScale, viewHeight: view.frame.height)
        view.mouseDown(with: mouseDownEvent(at: moveDown, in: window))
        view.mouseDragged(with: mouseDraggedEvent(at: moveDrag, in: window))
        view.mouseUp(with: mouseUpEvent(at: moveDrag, in: window))
        view.keyDown(with: keyDownEvent(keyCode: 36, in: window)) // Return: commit

        let canvas = view.layerStack.activeLayer.canvas
        for y in 0..<8 {
            for x in 0..<8 {
                let actual = canvas.rawPixel(x: x, y: y)
                if x >= 1, y >= 1 {
                    let expected = before[y - 1][x - 1]
                    XCTAssertEqual(actual?.r, expected.r, "x=\(x) y=\(y) red")
                    XCTAssertEqual(actual?.g, expected.g, "x=\(x) y=\(y) green")
                    XCTAssertEqual(actual?.b, expected.b, "x=\(x) y=\(y) blue")
                    XCTAssertEqual(actual?.a, expected.a, "x=\(x) y=\(y) alpha")
                } else {
                    XCTAssertEqual(actual?.a, 0, "x=\(x) y=\(y) should be left transparent (shifted in from outside), proving the second transform ran cleanly")
                }
            }
        }
    }

    /// Regression test for the `.distort` case's own "no rotation
    /// correction" design decision (see its doc comment in
    /// `mouseDragged(with:)`): rotates the identity rectangle 90° first
    /// (clean, hand-verifiable geometry — no `cos`/`sin` rounding), then
    /// grabs the now-physically-relocated `topLeft` corner with Option and
    /// drags it by a plain screen-axis `(2, 3)` delta. If distort *had*
    /// (incorrectly) applied the same local-frame rotation correction
    /// `resizeByCorner`/`resizeByEdge` use, the stored offset would come out
    /// rotated (something like `(-3, 2)` or `(3, -2)`, not `(2, 3)`); this
    /// commits and checks the actual result against the transform predicted
    /// by the *documented* (absolute, uncorrected) behavior.
    func testRotateThenDistort_distortOffsetIsAbsoluteScreenSpace_notRotationCorrected() {
        let zoomScale = 8
        let view = makeViewInWindow(width: 8, height: 8, zoomScale: zoomScale)
        view.setZoomScale(zoomScale)
        let window = view.window!
        let before = makeDistinctlyColoredCanvas(view: view, size: 8)

        view.beginLayerTransform()

        // Step 1: rotate the identity rectangle exactly 90° (same
        // hand-verified rotate-ring gesture as
        // `testLayerTransform_resizeCornerAfterRotation_...` above): after
        // this, the `topLeft`-labeled corner physically sits at canvas
        // (8, 0).
        let rotateDown = transformWindowPoint(canvasX: -1, canvasY: -1, zoomScale: zoomScale, viewHeight: view.frame.height)
        let rotateDrag = transformWindowPoint(canvasX: 9, canvasY: -1, zoomScale: zoomScale, viewHeight: view.frame.height)
        view.mouseDown(with: mouseDownEvent(at: rotateDown, in: window))
        view.mouseDragged(with: mouseDraggedEvent(at: rotateDrag, in: window, modifierFlags: [.shift]))
        view.mouseUp(with: mouseUpEvent(at: rotateDrag, in: window))

        // Step 2: Option+drag that (now relocated) topLeft corner from
        // (8, 0) by a plain screen delta of (+2, +3), to canvas (10, 3).
        let distortDown = transformWindowPoint(canvasX: 8, canvasY: 0, zoomScale: zoomScale, viewHeight: view.frame.height)
        let distortDrag = transformWindowPoint(canvasX: 10, canvasY: 3, zoomScale: zoomScale, viewHeight: view.frame.height)
        view.mouseDown(with: mouseDownEvent(at: distortDown, in: window, modifierFlags: [.option]))
        view.mouseDragged(with: mouseDraggedEvent(at: distortDrag, in: window, modifierFlags: [.option]))
        view.mouseUp(with: mouseUpEvent(at: distortDrag, in: window))

        view.keyDown(with: keyDownEvent(keyCode: 36, in: window)) // Return: commit

        var expected = LayerTransform.identity(width: 8, height: 8)
        expected.rotation = .pi / 2
        expected.distortTopLeft = CGVector(dx: 2, dy: 3)

        // Self-consistency check of this test's own doc comment: the final
        // topLeft corner lands at (10, 3) — the rotated base corner (8, 0)
        // plus the raw, uncorrected (2, 3) drag delta, not some rotated
        // variant of it.
        XCTAssertEqual(expected.corners.topLeft.x, 10, accuracy: 1e-9)
        XCTAssertEqual(expected.corners.topLeft.y, 3, accuracy: 1e-9)

        let canvas = view.layerStack.activeLayer.canvas
        for y in 0..<8 {
            for x in 0..<8 {
                let actual = canvas.rawPixel(x: x, y: y)
                if let source = CanvasView.sourcePixel(forDestination: (x, y), transform: expected, sourceWidth: 8, sourceHeight: 8) {
                    let expectedPixel = before[source.y][source.x]
                    XCTAssertEqual(actual?.r, expectedPixel.r, "x=\(x) y=\(y) red")
                    XCTAssertEqual(actual?.g, expectedPixel.g, "x=\(x) y=\(y) green")
                    XCTAssertEqual(actual?.b, expectedPixel.b, "x=\(x) y=\(y) blue")
                    XCTAssertEqual(actual?.a, expectedPixel.a, "x=\(x) y=\(y) alpha")
                } else {
                    XCTAssertEqual(actual?.a, 0, "x=\(x) y=\(y) should be left transparent")
                }
            }
        }
    }

    func testCommitLayerTransform_firesOnLayerContentChanged() {
        let view = makeViewInWindow(width: 4, height: 4, zoomScale: 4)
        var contentChangedCount = 0
        view.onLayerContentChanged = { contentChangedCount += 1 }

        view.beginLayerTransform()
        view.commitLayerTransform()

        XCTAssertEqual(contentChangedCount, 1)
    }

    /// `activeTool`'s `didSet` only resets selection/lasso/polygon gesture
    /// state (issue #11's own hardening) — it never touches
    /// `activeTransform`, and every one of `mouseDown`/`mouseDragged`/
    /// `mouseUp` checks `activeTransform` before ever looking at
    /// `activeTool`. Switching tools mid-transform must therefore leave the
    /// pending transform completely intact, draggable exactly as before.
    func testActiveTool_switchedMidTransform_activeTransformSurvives_draggingStillWorks() {
        let zoomScale = 4
        // 8x8: see the comment on `testMouseDragged_moveHandleWithShiftAndOptionHeld_...`
        // above for why the plain move drag below needs a canvas this size
        // to land unambiguously on `.move` rather than a corner's rotate ring.
        let view = makeViewInWindow(width: 8, height: 8, zoomScale: zoomScale)
        let window = view.window!
        let before = makeDistinctlyColoredCanvas(view: view, size: 8)

        view.beginLayerTransform()
        view.activeTool = .rectangleSelect // switch tools mid-transform

        // A plain (+1, +1) move (from the rectangle's own center), driven
        // exactly as `testMouseDragged_moveHandleWithShiftAndOptionHeld_...`
        // above.
        let down = transformWindowPoint(canvasX: 4, canvasY: 4, zoomScale: zoomScale, viewHeight: view.frame.height)
        let drag = transformWindowPoint(canvasX: 5, canvasY: 5, zoomScale: zoomScale, viewHeight: view.frame.height)
        view.mouseDown(with: mouseDownEvent(at: down, in: window))
        view.mouseDragged(with: mouseDraggedEvent(at: drag, in: window))
        view.mouseUp(with: mouseUpEvent(at: drag, in: window))
        view.keyDown(with: keyDownEvent(keyCode: 36, in: window)) // Return: commit

        let canvas = view.layerStack.activeLayer.canvas
        for y in 0..<8 {
            for x in 0..<8 {
                let actual = canvas.rawPixel(x: x, y: y)
                if x >= 1, y >= 1 {
                    let expected = before[y - 1][x - 1]
                    XCTAssertEqual(actual?.r, expected.r, "x=\(x) y=\(y) red")
                    XCTAssertEqual(actual?.g, expected.g, "x=\(x) y=\(y) green")
                    XCTAssertEqual(actual?.b, expected.b, "x=\(x) y=\(y) blue")
                    XCTAssertEqual(actual?.a, expected.a, "x=\(x) y=\(y) alpha")
                } else {
                    XCTAssertEqual(actual?.a, 0, "x=\(x) y=\(y) should be left transparent (shifted in from outside)")
                }
            }
        }
        // Also proves the switch away from `.rectangleSelect` never left a
        // stray selection behind: a rectangle-select drag never actually
        // happened (transform mode intercepted every mouse event), so there
        // must be no selection.
        XCTAssertNil(view.selection)
    }

    /// Complements `testKeyDown_nonReturnEscapeKey_leavesTransformModeActive_...`
    /// above (which checks a single click) with a full paint *stroke*
    /// (mouseDown + mouseDragged + mouseUp, the pencil's line-drawing path)
    /// attempted at two different spots while in transform mode: one inside
    /// the transform rectangle's interior (would hit `.move` if transform
    /// mode is intercepting, as it must) and one entirely outside it (would
    /// hit `nil`). Neither may reach the pencil's `paint`/`paintLine` calls.
    func testMouseGestures_duringTransformMode_neverReachThePencilTool_regardlessOfWhereTheyLand() {
        let zoomScale = 4
        let view = makeViewInWindow(width: 8, height: 8, zoomScale: zoomScale)
        let window = view.window!
        view.activeTool = .pencil
        view.foregroundColor = .black
        let before = makeDistinctlyColoredCanvas(view: view, size: 8)

        view.beginLayerTransform()

        // Interior stroke (hits `.move`).
        let interiorStart = windowPoint(forPixelCol: 2, row: 2, zoomScale: zoomScale, viewHeight: view.frame.height)
        let interiorEnd = windowPoint(forPixelCol: 5, row: 5, zoomScale: zoomScale, viewHeight: view.frame.height)
        view.mouseDown(with: mouseDownEvent(at: interiorStart, in: window))
        view.mouseDragged(with: mouseDraggedEvent(at: interiorEnd, in: window))
        view.mouseUp(with: mouseUpEvent(at: interiorEnd, in: window))

        // Exterior stroke (hits `nil` — completely outside the rectangle
        // and every handle, same distances as
        // `testMouseDown_completelyOutsideTheRectangle_...` above).
        let exteriorStart = transformWindowPoint(canvasX: 20, canvasY: 20, zoomScale: zoomScale, viewHeight: view.frame.height)
        let exteriorEnd = transformWindowPoint(canvasX: 22, canvasY: 22, zoomScale: zoomScale, viewHeight: view.frame.height)
        view.mouseDown(with: mouseDownEvent(at: exteriorStart, in: window))
        view.mouseDragged(with: mouseDraggedEvent(at: exteriorEnd, in: window))
        view.mouseUp(with: mouseUpEvent(at: exteriorEnd, in: window))

        // The real layer canvas — not the live preview — must still be
        // completely untouched: transform mode never committed, and neither
        // stroke should have painted anything.
        assertCanvas(view, size: 8, matches: before)
    }

    // MARK: - Live transform preview respects layer opacity (issue #9 review
    // should-5)
    //
    // `draw(_:)`'s live-preview block used to draw the moving/rotated/
    // distorted layer at full opacity regardless of the active layer's own
    // `opacity`, unlike `LayerStack.compositeImage()` (which every OTHER
    // pixel on screen goes through, and which the transform preview itself
    // reverts to the instant the transform is confirmed) — a layer under
    // 100% would visibly "pop" opaque for the whole duration of a drag and
    // only regain its transparency at commit time. Rendered here into an
    // off-screen `CGContext` (mirroring `LayerStackTests`'
    // `testCompositeImage_bothVisible_halfOpacity_blendsIntoAMiddleColor`'s
    // own "not exactly 0.5, just neither pure color" approach — sRGB
    // compositing doesn't land on the naive linear midpoint) since
    // `draw(_:)` has no return value or other observable side effect to
    // assert on directly.

    /// Renders `view`'s current `draw(_:)` output into an off-screen
    /// same-size bitmap and returns it, so a test can sample specific
    /// pixels — `draw(_:)` itself only ever writes to
    /// `NSGraphicsContext.current`, so this pushes a throwaway one backed by
    /// a real `CGContext` rather than the window's own (which isn't
    /// guaranteed to be current, or even backed by readable pixels, in a
    /// headless test run).
    private func renderOffscreen(_ view: CanvasView) -> NSBitmapImageRep? {
        let width = Int(view.bounds.width)
        let height = Int(view.bounds.height)
        guard width > 0, height > 0, let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        // `draw(_:)` assumes `NSGraphicsContext.current`'s flippedness
        // matches `CanvasView.isFlipped` (`true`) — see its own top-of-file
        // doc comment — so this pushed context has to declare the same, or
        // every y-coordinate it draws would land upside down relative to
        // what `rawPixel`/`colorAt` below read back.
        let nsContext = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext
        view.draw(view.bounds)
        NSGraphicsContext.restoreGraphicsState()
        guard let cgImage = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: cgImage)
    }

    /// Two layers — bottom white, top black at 50% opacity — with the top
    /// (active) layer mid-transform (round 1, plain move — no rotation or
    /// distortion, so this exercises should-5's non-distorted preview
    /// branch). A point inside both the moved rectangle and the canvas must
    /// read back as neither pure black nor pure white: proof the preview
    /// applied the layer's opacity instead of drawing it fully opaque.
    func testDraw_liveMovePreview_appliesActiveLayerOpacity_blendsWithLayerBelow() {
        let zoomScale = 4
        let stack = LayerStack(width: 8, height: 8, background: .white) // L1: bottom, white
        stack.addLayer() // L2: top, active
        stack.activeLayer.canvas.fill(with: .black)
        stack.setOpacity(0.5, at: 1)

        let view = makeViewInWindow(width: 8, height: 8, zoomScale: zoomScale)
        view.replaceLayerStack(stack)
        let window = view.window!

        view.beginLayerTransform()
        // A small move, comfortably clear of every edge — every destination
        // pixel sampled below (2,2)..(5,5) in canvas space stays covered by
        // the moved top layer.
        let down = transformWindowPoint(canvasX: 4, canvasY: 4, zoomScale: zoomScale, viewHeight: view.frame.height)
        let drag = transformWindowPoint(canvasX: 5, canvasY: 5, zoomScale: zoomScale, viewHeight: view.frame.height)
        view.mouseDown(with: mouseDownEvent(at: down, in: window))
        view.mouseDragged(with: mouseDraggedEvent(at: drag, in: window))

        guard let rendered = renderOffscreen(view) else {
            XCTFail("renderOffscreen failed")
            return
        }
        // Canvas pixel (3, 3) at zoomScale 4 sits at view/bitmap pixel
        // (14, 14) — comfortably inside both the moved top layer's
        // rectangle and the bottom layer beneath it.
        let sampleX = 3 * zoomScale + zoomScale / 2
        let sampleY = 3 * zoomScale + zoomScale / 2
        let red = rendered.colorAt(x: sampleX, y: sampleY)?.usingColorSpace(.deviceRGB)?.redComponent
        XCTAssertNotNil(red)
        XCTAssertGreaterThan(red ?? 1, 0.05, "should not be pure black — full opacity would show the top layer solid black here")
        XCTAssertLessThan(red ?? 0, 0.95, "should not be pure white")

        view.mouseUp(with: mouseUpEvent(at: drag, in: window))
        view.cancelLayerTransform()
    }

    /// Same as the test above, but for the `hasDistortion` preview branch
    /// (`rasterizeTransform`'s scratch-canvas/`warpedImage` path) instead of
    /// the plain rotate/scale one.
    func testDraw_liveDistortPreview_appliesActiveLayerOpacity_blendsWithLayerBelow() {
        let zoomScale = 4
        let stack = LayerStack(width: 8, height: 8, background: .white) // L1: bottom, white
        stack.addLayer() // L2: top, active
        stack.activeLayer.canvas.fill(with: .black)
        stack.setOpacity(0.5, at: 1)

        let view = makeViewInWindow(width: 8, height: 8, zoomScale: zoomScale)
        view.replaceLayerStack(stack)
        let window = view.window!

        view.beginLayerTransform()
        // Distort topLeft (Option+corner) from (0, 0) out to (-1, -1) — a
        // tiny nudge, just enough to make `hasDistortion` true without
        // pulling the quad away from the (3, 3) sample point below.
        let distortDown = transformWindowPoint(canvasX: 0, canvasY: 0, zoomScale: zoomScale, viewHeight: view.frame.height)
        let distortDrag = transformWindowPoint(canvasX: -1, canvasY: -1, zoomScale: zoomScale, viewHeight: view.frame.height)
        view.mouseDown(with: mouseDownEvent(at: distortDown, in: window, modifierFlags: [.option]))
        view.mouseDragged(with: mouseDraggedEvent(at: distortDrag, in: window, modifierFlags: [.option]))

        guard let rendered = renderOffscreen(view) else {
            XCTFail("renderOffscreen failed")
            return
        }
        let sampleX = 3 * zoomScale + zoomScale / 2
        let sampleY = 3 * zoomScale + zoomScale / 2
        let red = rendered.colorAt(x: sampleX, y: sampleY)?.usingColorSpace(.deviceRGB)?.redComponent
        XCTAssertNotNil(red)
        XCTAssertGreaterThan(red ?? 1, 0.05, "should not be pure black — full opacity would show the top layer solid black here")
        XCTAssertLessThan(red ?? 0, 0.95, "should not be pure white")

        view.mouseUp(with: mouseUpEvent(at: distortDrag, in: window, modifierFlags: [.option]))
        view.cancelLayerTransform()
    }

    // MARK: - onEditCompleted (issue #19): fires exactly once per completed edit gesture

    // MARK: 1 gesture -> 1 fire (test list 31-35)

    func testOnEditCompleted_pencilStroke_mouseDownMultipleDraggedMouseUp_firesExactlyOnce() {
        let zoomScale = 4
        let view = makeViewInWindow(width: 8, height: 8, zoomScale: zoomScale)
        view.activeTool = .pencil
        let window = view.window!
        var labels: [String] = []
        view.onEditCompleted = { labels.append($0) }

        view.mouseDown(with: mouseDownEvent(at: windowPoint(forPixelCol: 1, row: 1, zoomScale: zoomScale, viewHeight: view.frame.height), in: window))
        view.mouseDragged(with: mouseDraggedEvent(at: windowPoint(forPixelCol: 2, row: 1, zoomScale: zoomScale, viewHeight: view.frame.height), in: window))
        view.mouseDragged(with: mouseDraggedEvent(at: windowPoint(forPixelCol: 3, row: 1, zoomScale: zoomScale, viewHeight: view.frame.height), in: window))
        view.mouseUp(with: mouseUpEvent(at: windowPoint(forPixelCol: 3, row: 1, zoomScale: zoomScale, viewHeight: view.frame.height), in: window))

        XCTAssertEqual(labels, ["鉛筆"])
    }

    func testOnEditCompleted_rectangleSelect_mouseDownMultipleDraggedMouseUp_firesExactlyOnce() {
        let zoomScale = 4
        let view = makeViewInWindow(width: 8, height: 8, zoomScale: zoomScale)
        view.activeTool = .rectangleSelect
        let window = view.window!
        var labels: [String] = []
        view.onEditCompleted = { labels.append($0) }

        view.mouseDown(with: mouseDownEvent(at: windowPoint(forPixelCol: 1, row: 1, zoomScale: zoomScale, viewHeight: view.frame.height), in: window))
        view.mouseDragged(with: mouseDraggedEvent(at: windowPoint(forPixelCol: 3, row: 1, zoomScale: zoomScale, viewHeight: view.frame.height), in: window))
        view.mouseDragged(with: mouseDraggedEvent(at: windowPoint(forPixelCol: 5, row: 5, zoomScale: zoomScale, viewHeight: view.frame.height), in: window))
        view.mouseUp(with: mouseUpEvent(at: windowPoint(forPixelCol: 5, row: 5, zoomScale: zoomScale, viewHeight: view.frame.height), in: window))

        XCTAssertEqual(labels, ["選択範囲"])
    }

    func testOnEditCompleted_lassoSelect_mouseDownMultipleDraggedMouseUp_firesExactlyOnce() {
        let zoomScale = 4
        let view = makeViewInWindow(width: 8, height: 8, zoomScale: zoomScale)
        view.activeTool = .lassoSelect
        let window = view.window!
        var labels: [String] = []
        view.onEditCompleted = { labels.append($0) }

        view.mouseDown(with: mouseDownEvent(at: windowPoint(forPixelCol: 1, row: 1, zoomScale: zoomScale, viewHeight: view.frame.height), in: window))
        view.mouseDragged(with: mouseDraggedEvent(at: windowPoint(forPixelCol: 6, row: 1, zoomScale: zoomScale, viewHeight: view.frame.height), in: window))
        view.mouseDragged(with: mouseDraggedEvent(at: windowPoint(forPixelCol: 6, row: 6, zoomScale: zoomScale, viewHeight: view.frame.height), in: window))
        view.mouseDragged(with: mouseDraggedEvent(at: windowPoint(forPixelCol: 1, row: 6, zoomScale: zoomScale, viewHeight: view.frame.height), in: window))
        view.mouseUp(with: mouseUpEvent(at: windowPoint(forPixelCol: 1, row: 6, zoomScale: zoomScale, viewHeight: view.frame.height), in: window))

        XCTAssertEqual(labels, ["選択範囲"])
    }

    func testOnEditCompleted_polygonSelect_multipleClicksThenReturn_firesExactlyOnceAtClose_notOnInterimClicks() {
        let zoomScale = 4
        let view = makeViewInWindow(width: 8, height: 8, zoomScale: zoomScale)
        view.activeTool = .polygonSelect
        let window = view.window!
        var labels: [String] = []
        view.onEditCompleted = { labels.append($0) }
        let v1 = windowPoint(forPixelCol: 1, row: 1, zoomScale: zoomScale, viewHeight: view.frame.height)
        let v2 = windowPoint(forPixelCol: 6, row: 1, zoomScale: zoomScale, viewHeight: view.frame.height)
        let v3 = windowPoint(forPixelCol: 6, row: 6, zoomScale: zoomScale, viewHeight: view.frame.height)

        view.mouseDown(with: mouseDownEvent(at: v1, in: window))
        view.mouseUp(with: mouseUpEvent(at: v1, in: window))
        view.mouseDown(with: mouseDownEvent(at: v2, in: window))
        view.mouseUp(with: mouseUpEvent(at: v2, in: window))
        view.mouseDown(with: mouseDownEvent(at: v3, in: window))
        view.mouseUp(with: mouseUpEvent(at: v3, in: window))
        XCTAssertTrue(labels.isEmpty, "the 3 vertex-placing clicks must not fire onEditCompleted on their own")

        view.keyDown(with: keyDownEvent(keyCode: 36, in: window)) // Return: close

        XCTAssertEqual(labels, ["選択範囲"])
    }

    func testOnEditCompleted_layerTransform_beginMultipleDragsThenCommit_firesExactlyOnce() {
        let zoomScale = 4
        let view = makeViewInWindow(width: 4, height: 4, zoomScale: zoomScale)
        let window = view.window!
        var labels: [String] = []
        view.onEditCompleted = { labels.append($0) }

        view.beginLayerTransform()
        let downPoint = transformWindowPoint(canvasX: 4, canvasY: 4, zoomScale: zoomScale, viewHeight: view.frame.height)
        let midPoint = transformWindowPoint(canvasX: 6, canvasY: 6, zoomScale: zoomScale, viewHeight: view.frame.height)
        let dragPoint = transformWindowPoint(canvasX: 8, canvasY: 8, zoomScale: zoomScale, viewHeight: view.frame.height)
        view.mouseDown(with: mouseDownEvent(at: downPoint, in: window))
        view.mouseDragged(with: mouseDraggedEvent(at: midPoint, in: window))
        view.mouseDragged(with: mouseDraggedEvent(at: dragPoint, in: window))
        view.mouseUp(with: mouseUpEvent(at: dragPoint, in: window))
        view.commitLayerTransform()

        XCTAssertEqual(labels, ["変形"])
    }

    // MARK: Doesn't fire when nothing changed / for non-editing tools (test list 36-38, 40, 42)

    func testOnEditCompleted_pencil_mouseUpWithNothingPaintedDuringTheGesture_doesNotFire() {
        // No preceding mouseDown/mouseDragged at all — `paintedDuringGesture`
        // stays at its default `false`, the same "nothing was actually
        // painted" state a mouseDown that never reached the paint fallback
        // would leave behind. Mirrors this file's existing
        // `testMouseUp_magnifierWithoutAPriorMouseDown_...` precedent for
        // exercising a bare `mouseUp` call.
        let zoomScale = 4
        let view = makeViewInWindow(width: 8, height: 8, zoomScale: zoomScale)
        view.activeTool = .pencil
        var labels: [String] = []
        view.onEditCompleted = { labels.append($0) }

        view.mouseUp(with: mouseUpEvent(at: windowPoint(forPixelCol: 1, row: 1, zoomScale: zoomScale, viewHeight: view.frame.height), in: view.window!))

        XCTAssertTrue(labels.isEmpty, "mouseUp with nothing painted during the gesture must not fire onEditCompleted")
    }

    func testOnEditCompleted_eyedropperMouseDown_doesNotFire() {
        let zoomScale = 4
        let view = makeViewInWindow(width: 8, height: 8, zoomScale: zoomScale)
        view.activeTool = .eyedropper
        var labels: [String] = []
        view.onEditCompleted = { labels.append($0) }

        view.mouseDown(with: mouseDownEvent(at: windowPoint(forPixelCol: 1, row: 1, zoomScale: zoomScale, viewHeight: view.frame.height), in: view.window!))

        XCTAssertTrue(labels.isEmpty)
    }

    func testOnEditCompleted_magnifierClickAndDrag_neverFires() {
        let view = makeMagnifierViewInWindow()
        let window = view.window!
        var labels: [String] = []
        view.onEditCompleted = { labels.append($0) }

        // A plain click.
        view.mouseDown(with: mouseDownEvent(at: NSPoint(x: 10, y: 16), in: window))
        view.mouseDragged(with: mouseDraggedEvent(at: NSPoint(x: 13, y: 16), in: window)) // distance == 3, still a click
        view.mouseUp(with: mouseUpEvent(at: NSPoint(x: 13, y: 16), in: window))
        // A drag.
        view.mouseDown(with: mouseDownEvent(at: NSPoint(x: 2, y: 16), in: window))
        view.mouseDragged(with: mouseDraggedEvent(at: NSPoint(x: 11, y: 16), in: window)) // distance == 9, a drag
        view.mouseUp(with: mouseUpEvent(at: NSPoint(x: 11, y: 16), in: window))

        XCTAssertTrue(labels.isEmpty, "the magnifier tool never edits content, so it must never fire onEditCompleted")
    }

    func testOnEditCompleted_lassoSelect_fewerThanThreeVertices_doesNotFire() {
        let zoomScale = 4
        let view = makeViewInWindow(width: 8, height: 8, zoomScale: zoomScale)
        view.activeTool = .lassoSelect
        let window = view.window!
        var labels: [String] = []
        view.onEditCompleted = { labels.append($0) }
        let point = windowPoint(forPixelCol: 2, row: 2, zoomScale: zoomScale, viewHeight: view.frame.height)

        view.mouseDown(with: mouseDownEvent(at: point, in: window)) // 1 vertex only
        view.mouseUp(with: mouseUpEvent(at: point, in: window))

        XCTAssertTrue(labels.isEmpty, "fewer than 3 vertices can't enclose an area and must not fire onEditCompleted")
    }

    func testOnEditCompleted_commitLayerTransformWithoutBeginningOne_doesNotFire() {
        let view = makeView()
        var labels: [String] = []
        view.onEditCompleted = { labels.append($0) }

        view.commitLayerTransform() // activeTransform is nil: guarded no-op

        XCTAssertTrue(labels.isEmpty)
    }

    // MARK: Fires when expected (test list 41), and a documented current-behavior lock-in (test list 39)

    func testOnEditCompleted_magicWandSelect_singleClick_firesExactlyOnce() {
        let zoomScale = 4
        let view = makeViewInWindow(width: 8, height: 8, zoomScale: zoomScale)
        view.activeTool = .magicWandSelect
        view.magicWandTolerance = 0
        var labels: [String] = []
        view.onEditCompleted = { labels.append($0) }

        view.mouseDown(with: mouseDownEvent(at: windowPoint(forPixelCol: 3, row: 3, zoomScale: zoomScale, viewHeight: view.frame.height), in: view.window!))

        XCTAssertEqual(labels, ["選択範囲"])
    }

    /// Locks in the CURRENT implementation as a deliberate spec, not an
    /// oversight: `mouseUp`'s rectangle/ellipse-select branch calls
    /// `onEditCompleted?("選択範囲")` unconditionally after
    /// `applyCombinedSelection`, with no guard on the dragged rectangle's
    /// size — even a zero-size drag (mouseDown/mouseUp at the exact same
    /// point, which resolves to an empty mask that collapses `selection`
    /// back to `nil`) still fires it. If a future change makes this guard
    /// against no-op drags, this test will catch that change so it's made
    /// on purpose rather than as a silent side effect.
    func testOnEditCompleted_rectangleSelect_zeroSizeDrag_stillFires_currentBehaviorLockedIn() {
        let zoomScale = 4
        let view = makeViewInWindow(width: 8, height: 8, zoomScale: zoomScale)
        view.activeTool = .rectangleSelect
        let window = view.window!
        var labels: [String] = []
        view.onEditCompleted = { labels.append($0) }
        let point = windowPoint(forPixelCol: 2, row: 2, zoomScale: zoomScale, viewHeight: view.frame.height)

        view.mouseDown(with: mouseDownEvent(at: point, in: window))
        view.mouseUp(with: mouseUpEvent(at: point, in: window)) // no mouseDragged at all: zero-size drag

        XCTAssertEqual(labels, ["選択範囲"], "current implementation fires onEditCompleted even for a zero-size drag — see this test's doc comment")
    }
}
