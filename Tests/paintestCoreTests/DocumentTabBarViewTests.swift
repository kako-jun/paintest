import AppKit
import XCTest
@testable import paintestCore

/// `DocumentTabBarView`'s row view (`DocumentTabRowView`) and its stack view
/// (`FlippedTabStackView`) are declared `private` inside
/// `DocumentTabBarView.swift`, so this file can't refer to either type by
/// name. It doesn't need to: every helper below walks the view hierarchy
/// through plain `NSView.subviews` (a public API) and calls overridden
/// `NSResponder` methods (`mouseDown(with:)`) through their statically-typed
/// `NSView` supertype — Swift's `private` restricts *name lookup*, not
/// dynamic dispatch, so the overridden implementation still runs.
///
/// Follows `CanvasViewTests`' "off-screen window + a real `NSEvent`" pattern
/// for the row-click test, and `LayerPanelViewTests`' "find the control by
/// walking `subviews`, then act on it directly" pattern for buttons.
final class DocumentTabBarViewTests: XCTestCase {
    private func makeDocument(_ name: String) -> Document {
        Document(layerStack: LayerStack(width: 4, height: 4), displayName: name)
    }

    // MARK: - View-tree helpers

    private func findScrollView(in view: NSView) -> NSScrollView? {
        for subview in view.subviews {
            if let scrollView = subview as? NSScrollView { return scrollView }
            if let found = findScrollView(in: subview) { return found }
        }
        return nil
    }

    /// The tab strip's rows, top to bottom, in document order.
    ///
    /// `rowsStack` (the `documentView`) now also carries the "+" new-document
    /// button as its last arranged subview, wrapped in a plain `NSView`
    /// container that gives it a left inset (kako-jun review on #15: same
    /// width as a tab row, directly below the last one, with its own left
    /// margin). That container isn't a row, but this file can't name the
    /// private `DocumentTabRowView` type to filter for it directly — instead
    /// it filters by `isAccessibilityElement()`, which `DocumentTabRowView`
    /// overrides to `true` (see issue #15 review round 2) while a plain
    /// `NSView` container defaults to `false`.
    private func rows(in tabBar: DocumentTabBarView) -> [NSView] {
        guard let scrollView = findScrollView(in: tabBar), let documentView = scrollView.documentView else { return [] }
        return documentView.subviews.filter { $0.isAccessibilityElement() }
    }

    private func findButtons(titled title: String, in view: NSView) -> [NSButton] {
        var result: [NSButton] = []
        for subview in view.subviews {
            if let button = subview as? NSButton, button.title == title {
                result.append(button)
            }
            result.append(contentsOf: findButtons(titled: title, in: subview))
        }
        return result
    }

    private func findLabels(in view: NSView) -> [NSTextField] {
        var result: [NSTextField] = []
        for subview in view.subviews {
            if let field = subview as? NSTextField {
                result.append(field)
            }
            result.append(contentsOf: findLabels(in: subview))
        }
        return result
    }

    /// A `mouseDown` event good enough for `DocumentTabRowView.mouseDown`,
    /// which ignores its argument entirely (`onSelectRow?()`  — no
    /// coordinates or window needed, unlike `CanvasView.mouseDown`).
    private func dummyMouseDownEvent() -> NSEvent {
        NSEvent.mouseEvent(
            with: .leftMouseDown,
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

    // MARK: - reload()

    func testReload_rowCountMatchesDocumentsCount() {
        let manager = DocumentManager(initialDocument: makeDocument("a"))
        manager.addDocument(makeDocument("b"))
        manager.addDocument(makeDocument("c"))
        let tabBar = DocumentTabBarView(documentManager: manager)

        XCTAssertEqual(rows(in: tabBar).count, 3)
    }

    func testReload_highlightsOnlyTheActiveRow() {
        let manager = DocumentManager(initialDocument: makeDocument("a"))
        manager.addDocument(makeDocument("b")) // "b" active, index 1
        let tabBar = DocumentTabBarView(documentManager: manager)

        let allRows = rows(in: tabBar)
        XCTAssertEqual(allRows.count, 2, "precondition: two rows")
        XCTAssertEqual(allRows[0].layer?.backgroundColor, NSColor.clear.cgColor, "row 0 (\"a\") is not active and must not be highlighted")
        XCTAssertEqual(allRows[1].layer?.backgroundColor, NSColor.selectedControlColor.cgColor, "row 1 (\"b\") is active and must be highlighted")
    }

    // MARK: - Row click -> onSelect

    func testRowClick_invokesOnSelectWithClickedRowsDocumentIndex() {
        let manager = DocumentManager(initialDocument: makeDocument("a"))
        manager.addDocument(makeDocument("b"))
        manager.selectDocument(at: 0) // "a" active, so clicking row 1 actually changes something
        let tabBar = DocumentTabBarView(documentManager: manager)
        var selectCount = 0
        tabBar.onSelect = { selectCount += 1 }

        let allRows = rows(in: tabBar)
        XCTAssertEqual(allRows.count, 2, "precondition: two rows")
        allRows[1].mouseDown(with: dummyMouseDownEvent()) // click the row for "b"

        XCTAssertEqual(manager.activeDocumentIndex, 1, "clicking row 1 should select the document at index 1")
        XCTAssertEqual(manager.activeDocument.displayName, "b")
        XCTAssertEqual(selectCount, 1, "onSelect should fire exactly once")
    }

    // MARK: - Row accessibility (AXPress -> onSelect, issue #15 review round 2)

    /// Real mouse hardware isn't the only way to "click" a row: VoiceOver,
    /// UI test automation, and `osascript`'s `click`/`AXPress` action all
    /// go through `NSAccessibility.accessibilityPerformPress()` instead of
    /// `mouseDown`. This asserts that path runs the same selection logic,
    /// independent of `testRowClick_invokesOnSelectWithClickedRowsDocumentIndex`
    /// above, which only exercises `mouseDown`.
    func testRowAccessibilityPerformPress_invokesOnSelectWithClickedRowsDocumentIndex() {
        let manager = DocumentManager(initialDocument: makeDocument("a"))
        manager.addDocument(makeDocument("b"))
        manager.selectDocument(at: 0) // "a" active, so pressing row 1 actually changes something
        let tabBar = DocumentTabBarView(documentManager: manager)
        var selectCount = 0
        tabBar.onSelect = { selectCount += 1 }

        let allRows = rows(in: tabBar)
        XCTAssertEqual(allRows.count, 2, "precondition: two rows")
        XCTAssertTrue(allRows[1].isAccessibilityElement(), "a tab row must expose itself as an accessibility element to be reachable by AXPress")
        XCTAssertEqual(allRows[1].accessibilityRole(), .button, "a tab row should read as a button to accessibility clients")
        XCTAssertEqual(allRows[1].accessibilityLabel(), "b", "a tab row's accessibility label should be its document's display name")

        _ = allRows[1].accessibilityPerformPress() // AXPress the row for "b"

        XCTAssertEqual(manager.activeDocumentIndex, 1, "AXPress on row 1 should select the document at index 1")
        XCTAssertEqual(manager.activeDocument.displayName, "b")
        XCTAssertEqual(selectCount, 1, "onSelect should fire exactly once")
    }

    // MARK: - Close button -> closeDocument + onClose

    func testCloseButtonTap_closesTheCorrectDocumentAndFiresOnClose() {
        let manager = DocumentManager(initialDocument: makeDocument("a"))
        manager.addDocument(makeDocument("b"))
        manager.addDocument(makeDocument("c"))
        let tabBar = DocumentTabBarView(documentManager: manager)
        var closeCount = 0
        tabBar.onClose = { closeCount += 1 }

        let closeButtons = findButtons(titled: "×", in: tabBar)
        XCTAssertEqual(closeButtons.count, 3, "precondition: one close button per row")
        guard let middleCloseButton = closeButtons.first(where: { $0.tag == 1 }) else {
            XCTFail("could not find the close button tagged with index 1 (\"b\"'s row)")
            return
        }

        middleCloseButton.performClick(nil)

        XCTAssertEqual(manager.documents.map(\.displayName), ["a", "c"], "closing index 1 should remove \"b\", not another tab")
        XCTAssertEqual(closeCount, 1, "onClose should fire exactly once")
    }

    // MARK: - Add button -> onNewDocumentRequested

    func testAddButtonTap_firesOnNewDocumentRequested() {
        let manager = DocumentManager(initialDocument: makeDocument("a"))
        let tabBar = DocumentTabBarView(documentManager: manager)
        var requestCount = 0
        tabBar.onNewDocumentRequested = { requestCount += 1 }

        guard let addButton = findButtons(titled: "+", in: tabBar).first else {
            XCTFail("could not find the \"+\" add-document button")
            return
        }

        addButton.performClick(nil)

        XCTAssertEqual(requestCount, 1, "onNewDocumentRequested should fire exactly once")
    }

    // MARK: - displayName rendering (i18n, extreme lengths)

    func testReload_displayNameWithJapaneseAndEmoji_doesNotCrashAndIsRendered() {
        let name = "あいうえお🎨絵文字テスト"
        let manager = DocumentManager(initialDocument: makeDocument(name))
        let tabBar = DocumentTabBarView(documentManager: manager)

        let labels = findLabels(in: tabBar)
        XCTAssertTrue(labels.contains { $0.stringValue == name }, "the Japanese/emoji display name should render without crashing")
    }

    func testReload_veryLongDisplayName_usesTailTruncation() {
        let longName = String(repeating: "a", count: 500)
        let manager = DocumentManager(initialDocument: makeDocument(longName))
        let tabBar = DocumentTabBarView(documentManager: manager)

        guard let label = findLabels(in: tabBar).first(where: { $0.stringValue == longName }) else {
            XCTFail("could not find the name label for the very long display name")
            return
        }
        XCTAssertEqual(label.lineBreakMode, .byTruncatingTail, "a very long display name must be tail-truncated, not wrapped or clipped without an ellipsis")
    }
}
