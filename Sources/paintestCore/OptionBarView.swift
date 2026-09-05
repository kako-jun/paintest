import AppKit

/// Photoshop's top-of-window options bar (issue #7): a fixed-height strip
/// spanning the full window width, sitting above the document tab strip /
/// toolbox / canvas / right panel group. Photoshop fills this with controls
/// for whichever tool is currently selected; since tool-switching itself
/// isn't implemented yet, this stays an empty chrome-colored frame — each
/// tool's own issue is responsible for populating it once that tool is
/// selectable.
final class OptionBarView: NSView {
    static let height: CGFloat = 30

    init() {
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
