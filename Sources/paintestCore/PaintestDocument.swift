import AppKit

/// One layer's entry in a `.paintestdoc` package's `manifest.json`.
/// `order` is the layer's index in `LayerStack.layers` (bottom-to-top), and
/// `fileName` is the PNG file inside the package holding that layer's pixels.
struct LayerManifestEntry: Codable {
    var name: String
    var isVisible: Bool
    var opacity: Double
    var order: Int
    var fileName: String
}

/// The full contents of a `.paintestdoc` package's `manifest.json`.
struct DocumentManifest: Codable {
    var width: Int
    var height: Int
    var layers: [LayerManifestEntry]
    var activeLayerIndex: Int
}

/// Reads and writes `.paintestdoc` packages: a plain directory containing
/// `manifest.json` (layer order/name/visibility/opacity + canvas size) and
/// one PNG per layer. Unlike the "保存…" PNG export, this format preserves
/// the full layer structure so a document can be reopened and kept editing.
enum PaintestDocument {
    private static let manifestFileName = "manifest.json"

    /// Writes `layerStack` to `url` as a `.paintestdoc` package, creating
    /// the package directory (and any of its ancestors) if needed.
    ///
    /// This is atomic with respect to `url`: the whole package (every layer
    /// PNG plus `manifest.json`) is assembled first in a temporary sibling
    /// directory, and `url` itself is only touched once that temporary
    /// package is complete (issue #8 review). If anything fails partway
    /// through — disk full, permission error, a layer that fails to encode
    /// — only the temporary directory ends up incomplete; whatever was
    /// already saved at `url` is left untouched right up until the final
    /// swap at the bottom. Writing new layer PNGs directly into `url` and
    /// relying on a fresh `removeItem`/`createDirectory` there (this
    /// function's previous approach — see the orphaned-PNG fix below) would
    /// instead destroy the existing save before the replacement is known to
    /// be good.
    static func write(_ layerStack: LayerStack, to url: URL) throws {
        let tempURL = url.appendingPathExtension("tmp")
        // Clear out any stale leftover from a previous write that crashed
        // mid-way, so the temporary package always starts from empty.
        try? FileManager.default.removeItem(at: tempURL)

        do {
            try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)

            var entries: [LayerManifestEntry] = []
            for (index, layer) in layerStack.layers.enumerated() {
                let fileName = "layer_\(index).png"
                guard let pngData = layer.canvas.pngData() else {
                    throw PaintestDocumentError.pngEncodingFailed(layerName: layer.name)
                }
                try pngData.write(to: tempURL.appendingPathComponent(fileName))
                entries.append(LayerManifestEntry(
                    name: layer.name,
                    isVisible: layer.isVisible,
                    opacity: layer.opacity,
                    order: index,
                    fileName: fileName
                ))
            }

            let manifest = DocumentManifest(
                width: layerStack.width,
                height: layerStack.height,
                layers: entries,
                activeLayerIndex: layerStack.activeLayerIndex
            )
            let manifestData = try JSONEncoder().encode(manifest)
            try manifestData.write(to: tempURL.appendingPathComponent(manifestFileName))
        } catch {
            // Don't leave a half-written temporary package lying around.
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }

        // The temporary package is now complete and self-consistent. Only
        // now do we touch the real destination: remove whatever was there
        // before — this is also what fixes the orphaned-layer-PNG bug
        // (issue #8 review S2), since re-saving with fewer layers than
        // before no longer leaves the old save's higher-numbered
        // `layer_N.png` files behind, as nothing of the old package
        // survives this swap — and move the new package into place.
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: tempURL, to: url)
    }

    /// Reads a `.paintestdoc` package at `url` back into a `LayerStack`.
    /// Returns `nil` if the manifest or any layer PNG can't be read/decoded,
    /// or if any layer's actual PNG dimensions don't match `manifest.width`/
    /// `manifest.height` — a mismatch means the manifest and pixel data have
    /// drifted apart (tampering/corruption), and opening it anyway would
    /// silently stretch a wrong-sized layer to fit, breaking dot-exact
    /// editing. Better to refuse the whole document, matching the existing
    /// "manifest missing/undecodable" policy.
    static func read(from url: URL) -> LayerStack? {
        guard let manifestData = try? Data(contentsOf: url.appendingPathComponent(manifestFileName)),
              let manifest = try? JSONDecoder().decode(DocumentManifest.self, from: manifestData) else {
            return nil
        }

        // A manifest that explicitly declares zero layers is just as
        // invalid as a missing manifest or an undecodable layer PNG — there
        // is no legitimate document with no layers at all, so refuse it
        // rather than fabricating a blank placeholder layer (see issue #8
        // review S1: this used to silently synthesize a single white layer
        // here, inconsistent with every other malformed-input case above).
        guard !manifest.layers.isEmpty else {
            return nil
        }

        let sortedEntries = manifest.layers.sorted { $0.order < $1.order }
        var layers: [Layer] = []
        for entry in sortedEntries {
            guard let pngData = try? Data(contentsOf: url.appendingPathComponent(entry.fileName)),
                  let canvas = PixelCanvas.load(from: pngData) else {
                return nil
            }
            guard canvas.width == manifest.width, canvas.height == manifest.height else {
                return nil
            }
            layers.append(Layer(canvas: canvas, name: entry.name, isVisible: entry.isVisible, opacity: entry.opacity))
        }

        return LayerStack(
            width: manifest.width,
            height: manifest.height,
            layers: layers,
            activeLayerIndex: manifest.activeLayerIndex
        )
    }
}

enum PaintestDocumentError: Error {
    case pngEncodingFailed(layerName: String)
}
