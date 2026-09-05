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
    static func write(_ layerStack: LayerStack, to url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        var entries: [LayerManifestEntry] = []
        for (index, layer) in layerStack.layers.enumerated() {
            let fileName = "layer_\(index).png"
            guard let pngData = layer.canvas.pngData() else {
                throw PaintestDocumentError.pngEncodingFailed(layerName: layer.name)
            }
            try pngData.write(to: url.appendingPathComponent(fileName))
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
        try manifestData.write(to: url.appendingPathComponent(manifestFileName))
    }

    /// Reads a `.paintestdoc` package at `url` back into a `LayerStack`.
    /// Returns `nil` if the manifest or any layer PNG can't be read/decoded.
    static func read(from url: URL) -> LayerStack? {
        guard let manifestData = try? Data(contentsOf: url.appendingPathComponent(manifestFileName)),
              let manifest = try? JSONDecoder().decode(DocumentManifest.self, from: manifestData) else {
            return nil
        }

        let sortedEntries = manifest.layers.sorted { $0.order < $1.order }
        var layers: [Layer] = []
        for entry in sortedEntries {
            guard let pngData = try? Data(contentsOf: url.appendingPathComponent(entry.fileName)),
                  let canvas = PixelCanvas.load(from: pngData) else {
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
