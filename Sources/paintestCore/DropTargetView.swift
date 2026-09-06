import AppKit

/// A plain `NSView` that accepts a file-URL drag-and-drop and forwards the
/// dropped URLs via `onFilesDropped` (issue #4: dragging an image file onto
/// the window opens it, in addition to "開く…"/`NSOpenPanel`).
///
/// Used as `AppDelegate`'s window root view — the whole window accepts a
/// drop, not just the canvas, so a drop lands the same way regardless of
/// which panel it happens to hit.
final class DropTargetView: NSView {
    var onFilesDropped: (([URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: nil) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty else { return false }
        onFilesDropped?(urls)
        return true
    }
}
