import AppKit

/// One open image document: its `LayerStack` plus the book-keeping needed
/// to show it in `DocumentTabBarView` (display name, backing file
/// location). `fileURL` is `nil` for a document that has never been saved
/// or opened from disk yet.
final class Document {
    var layerStack: LayerStack
    var displayName: String
    var fileURL: URL?
    /// Kept per-document, not on `CanvasView`, so switching tabs restores
    /// each document's own zoom instead of leaking the last-viewed
    /// document's zoom onto every other tab (issue #15 follow-up).
    var zoomScale: Int

    init(layerStack: LayerStack, displayName: String = "untitled", fileURL: URL? = nil, zoomScale: Int = CanvasView.defaultZoomScale) {
        self.layerStack = layerStack
        self.displayName = displayName
        self.fileURL = fileURL
        self.zoomScale = zoomScale
    }
}
