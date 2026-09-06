import AppKit

/// Photoshop's top-of-window options bar (issue #7): a fixed-height strip
/// spanning the full window width, sitting above the document tab strip /
/// toolbox / canvas / right panel group. Photoshop fills this with controls
/// for whichever tool is currently selected; each tool's own issue is
/// responsible for populating it once that tool is selectable — the
/// magnifier's zoom-level dropdown (issue #13, `showZoomPresets`) is the
/// first. Every other tool still leaves this an empty chrome-colored frame,
/// via `clear()`.
///
/// Unlike `PlaceholderPanelView` (プロパティ/ヒストリー), this carries no
/// title label of its own (issue #7 self-review question-5): the real
/// Photoshop options bar has no fixed heading either — it's just a bare
/// strip of whatever settings the active tool contributes, so a permanent
/// "オプション"-style label here would misrepresent what this chrome
/// actually becomes once populated.
final class OptionBarView: NSView {
    static let height: CGFloat = 30
    private static let horizontalPadding: CGFloat = 8
    private static let popUpWidth: CGFloat = 90

    /// Fired when the zoom presets popup's selection changes (issue #13).
    /// `AppDelegate` forwards the picked level straight into
    /// `CanvasView.setZoomScale(_:)`, the same entry point used for
    /// click/drag zoom and the View menu's zoom-in/out.
    private var onZoomPresetSelected: ((Int) -> Void)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Populates the bar with a single zoom-level dropdown (issue #13),
    /// the first control this previously-empty strip ever gets (issue #7).
    /// Rebuilt from scratch on every call — including from `AppDelegate`
    /// each time the zoom level changes while the magnifier is active — so
    /// there's no incremental "just update the selection" path to keep in
    /// sync separately. No title label, matching issue #7's "no permanent
    /// heading" rule for this bar (see the type-level doc comment).
    func showZoomPresets(currentZoomScale: Int, levels: [Int], onSelect: @escaping (Int) -> Void) {
        clear()
        onZoomPresetSelected = onSelect

        let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
        popUp.translatesAutoresizingMaskIntoConstraints = false
        popUp.target = self
        popUp.action = #selector(zoomPresetChanged(_:))

        for level in levels {
            popUp.addItem(withTitle: "\(level * 100)%")
        }
        if let matchIndex = levels.firstIndex(of: currentZoomScale) {
            popUp.selectItem(at: matchIndex)
        }

        addSubview(popUp)
        NSLayoutConstraint.activate([
            popUp.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalPadding),
            popUp.centerYAnchor.constraint(equalTo: centerYAnchor),
            popUp.widthAnchor.constraint(equalToConstant: Self.popUpWidth)
        ])
    }

    /// Removes every control from the bar, returning it to the empty frame
    /// it starts as (issue #13) — used when switching to a tool that has no
    /// options of its own.
    func clear() {
        subviews.forEach { $0.removeFromSuperview() }
        onZoomPresetSelected = nil
    }

    @objc private func zoomPresetChanged(_ sender: NSPopUpButton) {
        // Bug fix (found while writing tests for issue #13): the item's
        // title is "\(level * 100)%" (e.g. "3200%" for level 32), so
        // `dropLast()` alone only strips the "%" and leaves the *percentage*
        // (3200), not the level (32). Passing that straight to `onSelect`
        // meant every dropdown selection silently did nothing in
        // production, since `CanvasView.setZoomScale(_:)` rejects any value
        // not in `zoomLevels` ([1, 2, 4, 8, 16, 32]) — 3200 never matches.
        guard let title = sender.titleOfSelectedItem, let percent = Int(title.dropLast()) else { return }
        onZoomPresetSelected?(percent / 100)
    }
}
