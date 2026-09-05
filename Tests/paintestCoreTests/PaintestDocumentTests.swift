import AppKit
import XCTest
@testable import paintestCore

final class PaintestDocumentTests: XCTestCase {
    /// Every test gets its own throwaway `.paintestdoc` directory under
    /// `NSTemporaryDirectory()`, removed in `tearDown()` so tests don't
    /// accumulate junk on disk or interfere with each other.
    private var tempURLs: [URL] = []

    private func makeTempDocumentURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("paintest-doc-test-\(UUID().uuidString)", isDirectory: true)
            .appendingPathExtension("paintestdoc")
        tempURLs.append(url)
        return url
    }

    override func tearDown() {
        for url in tempURLs {
            try? FileManager.default.removeItem(at: url)
        }
        tempURLs = []
        super.tearDown()
    }

    // MARK: - Round trip (test list 23-27)

    func testRoundTrip_singleLayer_preservesNameVisibilityAndOpacity() {
        let stack = LayerStack(width: 3, height: 3, background: .white)
        stack.layers[0].name = "背景"
        stack.layers[0].isVisible = false
        stack.layers[0].opacity = 0.75
        let url = makeTempDocumentURL()

        XCTAssertNoThrow(try PaintestDocument.write(stack, to: url))
        guard let loaded = PaintestDocument.read(from: url) else {
            XCTFail("read(from:) returned nil")
            return
        }

        XCTAssertEqual(loaded.layers[0].name, "背景")
        XCTAssertEqual(loaded.layers[0].isVisible, false)
        XCTAssertEqual(loaded.layers[0].opacity, 0.75, accuracy: 0.0001)
    }

    func testRoundTrip_multipleLayers_preservesOrder() {
        let stack = LayerStack(width: 2, height: 2, background: .white)
        stack.addLayer(name: "中")
        stack.addLayer(name: "上")
        let url = makeTempDocumentURL()

        XCTAssertNoThrow(try PaintestDocument.write(stack, to: url))
        guard let loaded = PaintestDocument.read(from: url) else {
            XCTFail("read(from:) returned nil")
            return
        }

        XCTAssertEqual(loaded.layers.map { $0.name }, ["レイヤー1", "中", "上"])
    }

    func testRoundTrip_multipleLayers_visibilityIsIndependentPerLayer() {
        let stack = LayerStack(width: 2, height: 2, background: .white)
        stack.addLayer(name: "中")
        stack.addLayer(name: "上")
        stack.setVisibility(false, at: 1) // only the middle layer is hidden
        let url = makeTempDocumentURL()

        XCTAssertNoThrow(try PaintestDocument.write(stack, to: url))
        guard let loaded = PaintestDocument.read(from: url) else {
            XCTFail("read(from:) returned nil")
            return
        }

        XCTAssertEqual(loaded.layers[0].isVisible, true)
        XCTAssertEqual(loaded.layers[1].isVisible, false)
        XCTAssertEqual(loaded.layers[2].isVisible, true)
    }

    func testRoundTrip_multipleLayers_opacityIsIndependentPerLayer() {
        let stack = LayerStack(width: 2, height: 2, background: .white)
        stack.addLayer(name: "中")
        stack.addLayer(name: "上")
        stack.setOpacity(0.2, at: 0)
        stack.setOpacity(0.5, at: 1)
        stack.setOpacity(0.9, at: 2)
        let url = makeTempDocumentURL()

        XCTAssertNoThrow(try PaintestDocument.write(stack, to: url))
        guard let loaded = PaintestDocument.read(from: url) else {
            XCTFail("read(from:) returned nil")
            return
        }

        XCTAssertEqual(loaded.layers[0].opacity, 0.2, accuracy: 0.0001)
        XCTAssertEqual(loaded.layers[1].opacity, 0.5, accuracy: 0.0001)
        XCTAssertEqual(loaded.layers[2].opacity, 0.9, accuracy: 0.0001)
    }

    /// Fixed behavior (was the bug this test locks in): `activeLayerIndex`
    /// used to be dropped on save and always come back as 0. `write`
    /// now includes it in the manifest and `read` restores it.
    func testRoundTrip_activeLayerIndexIsPreserved() {
        let stack = LayerStack(width: 2, height: 2, background: .white)
        stack.addLayer(name: "中")
        stack.addLayer(name: "上")
        stack.activeLayerIndex = 1
        let url = makeTempDocumentURL()

        XCTAssertNoThrow(try PaintestDocument.write(stack, to: url))
        guard let loaded = PaintestDocument.read(from: url) else {
            XCTFail("read(from:) returned nil")
            return
        }

        XCTAssertEqual(loaded.activeLayerIndex, 1)
        XCTAssertEqual(loaded.activeLayer.name, "中")
    }

    // MARK: - Missing/corrupted manifest (test list 28-29, decision table 2-2 rows 2-3)

    func testRead_missingManifest_returnsNil() {
        let url = makeTempDocumentURL()
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // No manifest.json written at all.
        XCTAssertNil(PaintestDocument.read(from: url))
    }

    func testRead_corruptedManifestJSON_returnsNil() {
        let url = makeTempDocumentURL()
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try? Data("{ this is not valid json".utf8).write(to: url.appendingPathComponent("manifest.json"))
        XCTAssertNil(PaintestDocument.read(from: url))
    }

    // MARK: - Missing/corrupted layer PNG (test list 30-31, decision table 2-2 row 4)

    func testRead_missingLayerPNG_returnsNil() {
        let stack = LayerStack(width: 2, height: 2, background: .white)
        let url = makeTempDocumentURL()
        XCTAssertNoThrow(try PaintestDocument.write(stack, to: url))

        try? FileManager.default.removeItem(at: url.appendingPathComponent("layer_0.png"))

        XCTAssertNil(PaintestDocument.read(from: url))
    }

    func testRead_corruptedLayerPNG_returnsNil() {
        let stack = LayerStack(width: 2, height: 2, background: .white)
        let url = makeTempDocumentURL()
        XCTAssertNoThrow(try PaintestDocument.write(stack, to: url))

        try? Data([0x00, 0x01, 0x02, 0xFF]).write(to: url.appendingPathComponent("layer_0.png"))

        XCTAssertNil(PaintestDocument.read(from: url))
    }

    // MARK: - Empty layers array (test list 32, decision table 2-2 row 5)
    // Explicitly out of scope for the 3-bug-fix pass this test suite is
    // pinned to (see task instructions) — this locks in the CURRENT,
    // unmodified behavior as a regression test. It does not assert that
    // this is the *right* behavior.

    /// Observed current behavior (verified experimentally before writing
    /// this test): `manifest.layers == []` does NOT make `read(from:)`
    /// return `nil`. The `for entry in sortedEntries` loop simply never
    /// runs, so `layers` stays `[]`, and that empty array is handed to
    /// `LayerStack.init(width:height:layers:activeLayerIndex:)` — which
    /// silently falls back to a single blank white "レイヤー1" layer sized
    /// to the manifest's width/height, and clamps `activeLayerIndex` to 0
    /// (ignoring whatever value the manifest actually had).
    ///
    /// NOTE (test author's observation, not a code change): this seems like
    /// a questionable design — a document manifest that explicitly says
    /// "zero layers" reads back as a *fabricated* single-layer document
    /// instead of being treated as invalid input, and the manifest's own
    /// `activeLayerIndex` is silently discarded rather than validated. This
    /// is flagged here only as a comment, per this test's instructions: it
    /// is out of scope for this round of fixes and the code is not changed.
    func testRead_emptyLayersArrayInManifest_fabricatesASingleBlankLayer_currentBehaviorLocked() {
        let url = makeTempDocumentURL()
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let manifestJSON = """
        {"width": 5, "height": 6, "layers": [], "activeLayerIndex": 3}
        """
        try? Data(manifestJSON.utf8).write(to: url.appendingPathComponent("manifest.json"))

        guard let loaded = PaintestDocument.read(from: url) else {
            XCTFail("current behavior is to return a fabricated LayerStack, not nil — if this now fails, the empty-layers behavior changed and this test (and its comment) need revisiting")
            return
        }

        XCTAssertEqual(loaded.width, 5)
        XCTAssertEqual(loaded.height, 6)
        XCTAssertEqual(loaded.layers.count, 1)
        XCTAssertEqual(loaded.layers[0].name, "レイヤー1")
        XCTAssertEqual(loaded.activeLayerIndex, 0, "manifest's activeLayerIndex (3) is out of range for a 1-layer fallback and is silently clamped, not validated")
    }

    // MARK: - order stable-sort with gaps/duplicates (test list 33)

    func testRead_manifestOrderWithDuplicatesAndGaps_sortsStably() {
        // order values [5, 3, 3, 1] for layers named D, B1, B2, A (in JSON
        // array order). Swift's sort is stable, so the two order=3 entries
        // must come back in their original relative order (B1 before B2).
        let stack = LayerStack(width: 2, height: 2, background: .white)
        let url = makeTempDocumentURL()

        let manifest = DocumentManifest(
            width: 2,
            height: 2,
            layers: [
                LayerManifestEntry(name: "D", isVisible: true, opacity: 1, order: 5, fileName: "layer_0.png"),
                LayerManifestEntry(name: "B1", isVisible: true, opacity: 1, order: 3, fileName: "layer_0.png"),
                LayerManifestEntry(name: "B2", isVisible: true, opacity: 1, order: 3, fileName: "layer_0.png"),
                LayerManifestEntry(name: "A", isVisible: true, opacity: 1, order: 1, fileName: "layer_0.png")
            ],
            activeLayerIndex: 0
        )
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        guard let pngData = stack.layers[0].canvas.pngData() else {
            XCTFail("failed to build fixture PNG")
            return
        }
        try? pngData.write(to: url.appendingPathComponent("layer_0.png"))
        try? JSONEncoder().encode(manifest).write(to: url.appendingPathComponent("manifest.json"))

        guard let loaded = PaintestDocument.read(from: url) else {
            XCTFail("read(from:) returned nil")
            return
        }

        XCTAssertEqual(loaded.layers.map { $0.name }, ["A", "B1", "B2", "D"])
    }

    // MARK: - width/height mismatch (test list 34, fixed behavior)

    /// Fixed behavior (was the bug this test locks in): a layer PNG whose
    /// actual pixel dimensions don't match the manifest's declared
    /// width/height must make the whole document refuse to load, rather
    /// than silently stretching a wrong-sized layer to fit.
    func testRead_layerPNGDimensionMismatchWithManifest_returnsNil() {
        let stack = LayerStack(width: 4, height: 4, background: .white)
        let url = makeTempDocumentURL()
        XCTAssertNoThrow(try PaintestDocument.write(stack, to: url))

        // Overwrite the layer PNG with one that's a different size than
        // what manifest.json still declares (4x4).
        guard let mismatchedPNG = PixelCanvas(width: 2, height: 2, background: .black).pngData() else {
            XCTFail("failed to build mismatched-size fixture PNG")
            return
        }
        try? mismatchedPNG.write(to: url.appendingPathComponent("layer_0.png"))

        XCTAssertNil(PaintestDocument.read(from: url))
    }

    // MARK: - PNG-only open path (decision table 2-2 rows 6-7)
    // These are exercised through `PixelCanvas.load(from:)` directly
    // (already covered exhaustively by `PixelCanvasTests`' PNG round-trip
    // and invalid-input sections) plus `AppDelegate.openCanvas()`'s
    // `Layer(canvas:name:)` wrapping, which is a one-line, UI-triggered
    // call with no independent logic of its own to unit test — per this
    // project's CLAUDE.md, that thin a UI-driven wire-up is left to manual
    // verification rather than force-tested here.

    // MARK: - Name edge cases (test list 35-37, i18n)

    func testRoundTrip_emptyLayerName_isPreserved() {
        let stack = LayerStack(width: 2, height: 2, background: .white)
        stack.layers[0].name = ""
        let url = makeTempDocumentURL()

        XCTAssertNoThrow(try PaintestDocument.write(stack, to: url))
        guard let loaded = PaintestDocument.read(from: url) else {
            XCTFail("read(from:) returned nil")
            return
        }
        XCTAssertEqual(loaded.layers[0].name, "")
    }

    func testRoundTrip_emojiAndMultibyteLayerName_isPreserved() {
        let stack = LayerStack(width: 2, height: 2, background: .white)
        stack.layers[0].name = "🎨レイヤー・ünïcödé"
        let url = makeTempDocumentURL()

        XCTAssertNoThrow(try PaintestDocument.write(stack, to: url))
        guard let loaded = PaintestDocument.read(from: url) else {
            XCTFail("read(from:) returned nil")
            return
        }
        XCTAssertEqual(loaded.layers[0].name, "🎨レイヤー・ünïcödé")
    }

    func testRoundTrip_veryLongLayerName_isPreserved() {
        let stack = LayerStack(width: 2, height: 2, background: .white)
        let longName = String(repeating: "レイヤー名", count: 500) // 2500 chars
        stack.layers[0].name = longName
        let url = makeTempDocumentURL()

        XCTAssertNoThrow(try PaintestDocument.write(stack, to: url))
        guard let loaded = PaintestDocument.read(from: url) else {
            XCTFail("read(from:) returned nil")
            return
        }
        XCTAssertEqual(loaded.layers[0].name, longName)
    }

    // MARK: - Intermediate directory creation (test list 38)

    func testWrite_createsIntermediateDirectoriesWhenNeeded() {
        let stack = LayerStack(width: 2, height: 2, background: .white)
        let ancestor = FileManager.default.temporaryDirectory
            .appendingPathComponent("paintest-doc-test-\(UUID().uuidString)", isDirectory: true)
        tempURLs.append(ancestor) // clean up the whole throwaway tree in tearDown
        let nestedURL = ancestor
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("deeper", isDirectory: true)
            .appendingPathComponent("doc.paintestdoc", isDirectory: true)

        XCTAssertNoThrow(try PaintestDocument.write(stack, to: nestedURL))
        XCTAssertNotNil(PaintestDocument.read(from: nestedURL), "the package should be readable back from the freshly-created nested path")
    }

    // MARK: - pngData() failure path (test list 39)

    /// `pngData()` (`PixelCanvas.pngData()` -> `NSBitmapImageRep.representation(using:.png,properties:)`)
    /// has no reachable failure path through this app's public API: every
    /// `PixelCanvas` is backed by a valid, freshly-allocated
    /// `NSBitmapImageRep` (see `PixelCanvas.makeBitmap`), and there is no
    /// constructor or mutator that can put it into a state the PNG encoder
    /// rejects. Forcing that failure would require reaching into AppKit
    /// internals or subclassing `NSBitmapImageRep`/`PixelCanvas` just to
    /// inject a failure — not something this app's public surface allows.
    /// Per the test design's own fallback instruction, this is skipped
    /// with this comment instead of writing an artificial (and untrue to
    /// the real code path) failure test.
    func testWrite_pngEncodingFailure_notReachableThroughPublicAPI_skippedByDesign() throws {
        throw XCTSkip("pngData() has no reachable failure path through PixelCanvas's public API; see doc comment above.")
    }
}
