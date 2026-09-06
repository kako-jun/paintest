import AppKit
import XCTest
@testable import paintestCore

/// `draggingEntered`/`performDragOperation` take `NSDraggingInfo`, an
/// Objective-C protocol whose every member is `@required` — there's no
/// system-provided concrete type this test file can construct on its own
/// (unlike, say, `NSEvent.mouseEvent(...)`). `FakeDraggingInfo` below is a
/// minimal conformance that hard-codes everything `DropTargetView` doesn't
/// actually read (window, location, drag formation, ...) and forwards only
/// `draggingPasteboard` to a real `NSPasteboard` this file controls — a
/// private, uniquely-named pasteboard (`NSPasteboard(name:)`) so tests don't
/// collide with each other or with the system general pasteboard.
final class DropTargetViewTests: XCTestCase {
    // MARK: - Fakes

    private final class FakeDraggingInfo: NSObject, NSDraggingInfo {
        let draggingPasteboard: NSPasteboard

        init(pasteboard: NSPasteboard) {
            self.draggingPasteboard = pasteboard
        }

        var draggingDestinationWindow: NSWindow? { nil }
        var draggingSourceOperationMask: NSDragOperation { .copy }
        var draggingLocation: NSPoint { .zero }
        var draggedImageLocation: NSPoint { .zero }
        var draggedImage: NSImage? { nil }
        var draggingSource: Any? { nil }
        var draggingSequenceNumber: Int { 0 }
        func slideDraggedImage(to screenPoint: NSPoint) {}
        override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
        var draggingFormation: NSDraggingFormation = .default
        var animatesToDestination: Bool = false
        var numberOfValidItemsForDrop: Int = 0
        func enumerateDraggingItems(
            options enumOpts: NSDraggingItemEnumerationOptions = [],
            for view: NSView?,
            classes classArray: [AnyClass],
            searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
            using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
        ) {}
        var springLoadingHighlight: NSSpringLoadingHighlight { .none }
        func resetSpringLoading() {}
    }

    // MARK: - Helpers

    /// A fresh, uniquely-named pasteboard per test (not `.general`), so
    /// tests can't see each other's leftovers or interfere with the real
    /// system pasteboard.
    private func makePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.paintest.tests.DropTargetViewTests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        return pasteboard
    }

    private func draggingInfo(withFileURLs urls: [URL]) -> FakeDraggingInfo {
        let pasteboard = makePasteboard()
        pasteboard.writeObjects(urls.map { $0 as NSURL })
        return FakeDraggingInfo(pasteboard: pasteboard)
    }

    private func draggingInfo(withString string: String) -> FakeDraggingInfo {
        let pasteboard = makePasteboard()
        pasteboard.setString(string, forType: .string)
        return FakeDraggingInfo(pasteboard: pasteboard)
    }

    private func draggingInfoWithEmptyPasteboard() -> FakeDraggingInfo {
        FakeDraggingInfo(pasteboard: makePasteboard())
    }

    // MARK: - draggingEntered

    func testDraggingEntered_pasteboardWithFileURL_returnsCopy() {
        let view = DropTargetView(frame: .zero)
        let info = draggingInfo(withFileURLs: [URL(fileURLWithPath: "/tmp/example.png")])

        XCTAssertEqual(view.draggingEntered(info), .copy, "a pasteboard carrying a file URL must be accepted with .copy")
    }

    func testDraggingEntered_pasteboardWithNonURLContent_returnsEmptyOperation() {
        let view = DropTargetView(frame: .zero)
        let info = draggingInfo(withString: "just some plain text, not a file")

        XCTAssertEqual(view.draggingEntered(info), [], "a pasteboard with only a plain string must not be accepted as a file drop")
    }

    func testDraggingEntered_emptyPasteboard_returnsEmptyOperation() {
        let view = DropTargetView(frame: .zero)
        let info = draggingInfoWithEmptyPasteboard()

        XCTAssertEqual(view.draggingEntered(info), [], "an empty pasteboard has nothing to accept")
    }

    // MARK: - performDragOperation

    func testPerformDragOperation_singleFileURL_invokesOnFilesDroppedWithThatURLAndReturnsTrue() {
        let view = DropTargetView(frame: .zero)
        let url = URL(fileURLWithPath: "/tmp/example.png")
        var droppedURLs: [URL]?
        view.onFilesDropped = { droppedURLs = $0 }

        let result = view.performDragOperation(draggingInfo(withFileURLs: [url]))

        XCTAssertTrue(result, "a single valid file URL must be accepted")
        XCTAssertEqual(droppedURLs, [url])
    }

    func testPerformDragOperation_multipleFileURLs_invokesOnFilesDroppedOnceWithAllURLsInOrder() {
        let view = DropTargetView(frame: .zero)
        let urls = [
            URL(fileURLWithPath: "/tmp/a.png"),
            URL(fileURLWithPath: "/tmp/b.png"),
            URL(fileURLWithPath: "/tmp/c.png"),
        ]
        var invocationCount = 0
        var droppedURLs: [URL]?
        view.onFilesDropped = { invocationCount += 1; droppedURLs = $0 }

        let result = view.performDragOperation(draggingInfo(withFileURLs: urls))

        XCTAssertTrue(result)
        XCTAssertEqual(invocationCount, 1, "onFilesDropped should fire exactly once for a multi-file drop, not once per file")
        XCTAssertEqual(droppedURLs, urls, "the dropped URLs must arrive in the same order they were on the pasteboard")
    }

    /// Real-world macOS behavior: a pasteboard with nothing `NSURL`-readable
    /// on it (an empty pasteboard, exercised here) makes
    /// `readObjects(forClasses:options:)` return `nil` rather than a
    /// literal empty array — but `performDragOperation`'s guard treats
    /// "nil" and "empty array" identically (both fail the `guard let ...,
    /// !urls.isEmpty` and hit the same `return false`), so this still
    /// covers the "nothing usable was on the pasteboard" branch the test
    /// name describes.
    func testPerformDragOperation_readObjectsReturnsEmptyArray_doesNotInvokeCallbackAndReturnsFalse() {
        let view = DropTargetView(frame: .zero)
        var invoked = false
        view.onFilesDropped = { _ in invoked = true }

        let result = view.performDragOperation(draggingInfoWithEmptyPasteboard())

        XCTAssertFalse(result, "nothing usable on the pasteboard must not be reported as a successful drop")
        XCTAssertFalse(invoked, "onFilesDropped must not fire when there's nothing to hand it")
    }

    func testPerformDragOperation_onFilesDroppedNotWired_doesNotCrashAndStillReturnsTrue() {
        let view = DropTargetView(frame: .zero)
        // onFilesDropped deliberately left nil.

        let result = view.performDragOperation(draggingInfo(withFileURLs: [URL(fileURLWithPath: "/tmp/example.png")]))

        XCTAssertTrue(result, "a valid drop is still reported as accepted even if no one is listening for it")
    }

    // MARK: - init

    func testInit_registersForFileURLDraggedType() {
        let view = DropTargetView(frame: .zero)

        XCTAssertTrue(view.registeredDraggedTypes.contains(.fileURL), "DropTargetView must register for .fileURL to receive file drops at all")
    }
}
