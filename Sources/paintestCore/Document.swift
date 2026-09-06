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
    /// The active selection, if any — `nil` means "no restriction", i.e. the
    /// whole canvas is editable (issue #11). Kept per-document, same as
    /// `zoomScale` above, so switching tabs restores each document's own
    /// selection instead of leaking it onto every other tab.
    ///
    /// Deliberately **not** persisted by `.paintestdoc` save/load: a
    /// selection is transient UI state, not document content, so it doesn't
    /// round-trip through save/open (out of scope for issue #11).
    var selection: SelectionMask?
    /// Whether this document has unsaved changes (issue #4). Set on actual
    /// content edits (pixel drawing, layer add/remove/reorder/opacity —
    /// wired from `AppDelegate`'s `onLayerContentChanged`/`layerPanelView.
    /// onChange`), cleared on a successful save. Defaults to `false`: a
    /// brand-new document or one just loaded from disk hasn't diverged from
    /// what's on disk (or from "nothing", for a new document) yet.
    var isDirty: Bool = false

    // `zoomScale`'s default reaches into `CanvasView` (a view-layer type) for
    // its initial value, so this model type isn't fully independent of the
    // view layer (review N2 on #18). Left as-is rather than reworked here:
    // it keeps "what zoom does a brand-new document start at" defined in
    // exactly one place instead of duplicating the constant.
    init(layerStack: LayerStack, displayName: String = "untitled", fileURL: URL? = nil, zoomScale: Int = CanvasView.defaultZoomScale) {
        self.layerStack = layerStack
        self.displayName = displayName
        self.fileURL = fileURL
        self.zoomScale = zoomScale
    }
}
