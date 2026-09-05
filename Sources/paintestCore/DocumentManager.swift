import AppKit

/// Owns every open `Document` and tracks which one is active, backing the
/// left-edge vertical tab strip (`DocumentTabBarView`).
///
/// Unlike `LayerStack.removeLayer(at:)` — which refuses to remove the last
/// remaining layer — `closeDocument(at:)` always succeeds: closing the
/// last open document replaces it with a fresh blank one instead of
/// refusing the close. An editor with zero open documents doesn't make
/// sense, but from the user's point of view "close this tab" should never
/// be a no-op just because it's the only tab left.
final class DocumentManager {
    private(set) var documents: [Document]
    var activeDocumentIndex: Int

    init(initialDocument: Document) {
        self.documents = [initialDocument]
        self.activeDocumentIndex = 0
    }

    var activeDocument: Document {
        documents[activeDocumentIndex]
    }

    /// Adds `document` and makes it active (opening a file or creating a
    /// new canvas both add a new tab rather than replacing the current one).
    @discardableResult
    func addDocument(_ document: Document) -> Document {
        documents.append(document)
        activeDocumentIndex = documents.count - 1
        return document
    }

    func closeDocument(at index: Int) {
        guard documents.indices.contains(index) else { return }

        if documents.count == 1 {
            let closed = documents[0]
            documents[0] = Document(layerStack: LayerStack(width: closed.layerStack.width, height: closed.layerStack.height))
            activeDocumentIndex = 0
            return
        }

        let previouslyActive = documents[activeDocumentIndex]
        documents.remove(at: index)
        if let newIndex = documents.firstIndex(where: { $0 === previouslyActive }) {
            activeDocumentIndex = newIndex
        } else {
            // The active document itself was the one just closed; fall
            // back to the tab that slid into its old position (or the new
            // last tab, if it was at the end).
            activeDocumentIndex = min(index, documents.count - 1)
        }
    }

    func selectDocument(at index: Int) {
        guard documents.indices.contains(index) else { return }
        activeDocumentIndex = index
    }
}
