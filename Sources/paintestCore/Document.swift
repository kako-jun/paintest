import AppKit

/// One open image document: its `LayerStack` plus the book-keeping needed
/// to show it in `DocumentTabBarView` (display name, backing file
/// location). `fileURL` is `nil` for a document that has never been saved
/// or opened from disk yet.
final class Document {
    var layerStack: LayerStack
    var displayName: String
    var fileURL: URL?

    init(layerStack: LayerStack, displayName: String = "untitled", fileURL: URL? = nil) {
        self.layerStack = layerStack
        self.displayName = displayName
        self.fileURL = fileURL
    }
}
