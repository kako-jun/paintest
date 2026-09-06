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
    private static let toleranceSliderWidth: CGFloat = 150
    private static let toleranceRange: ClosedRange<Double> = 0...255
    private static let controlSpacing: CGFloat = 8

    /// The magic wand's current-value readout (issue #11, round 3) — kept as
    /// a stored reference (unlike the zoom popup, which reads its own
    /// selection back via `sender`) so `toleranceSliderChanged(_:)` can
    /// update its text directly instead of needing to look the label back up
    /// among `subviews`.
    private var toleranceValueLabel: NSTextField?

    /// Fired when the zoom presets popup's selection changes (issue #13).
    /// `AppDelegate` forwards the picked level straight into
    /// `CanvasView.setZoomScale(_:)`, the same entry point used for
    /// click/drag zoom and the View menu's zoom-in/out.
    private var onZoomPresetSelected: ((Int) -> Void)?

    /// Fired when the magic wand's tolerance slider moves (issue #11, round
    /// 3). `AppDelegate` forwards the new value straight into
    /// `CanvasView.magicWandTolerance`.
    private var onToleranceChanged: ((Int) -> Void)?

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
            popUp.lastItem?.tag = level
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

    /// Populates the bar with the magic wand's tolerance control (issue #11,
    /// round 3): a "許容誤差" label, an `NSSlider` over
    /// `SelectionMask.magicWand(...)`'s tolerance range, and a numeric
    /// readout of the current value. Same "rebuilt from scratch on every
    /// call" pattern as `showZoomPresets` above — no incremental
    /// "just update the selection" path to keep in sync separately.
    func showMagicWandOptions(currentTolerance: Int, onToleranceChanged: @escaping (Int) -> Void) {
        clear()
        self.onToleranceChanged = onToleranceChanged

        let label = NSTextField(labelWithString: "許容誤差")
        label.translatesAutoresizingMaskIntoConstraints = false

        let slider = NSSlider(
            value: Double(currentTolerance),
            minValue: Self.toleranceRange.lowerBound,
            maxValue: Self.toleranceRange.upperBound,
            target: self,
            action: #selector(toleranceSliderChanged(_:))
        )
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.isContinuous = true

        let valueLabel = NSTextField(labelWithString: "\(currentTolerance)")
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        toleranceValueLabel = valueLabel

        addSubview(label)
        addSubview(slider)
        addSubview(valueLabel)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalPadding),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),

            slider.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: Self.controlSpacing),
            slider.centerYAnchor.constraint(equalTo: centerYAnchor),
            slider.widthAnchor.constraint(equalToConstant: Self.toleranceSliderWidth),

            valueLabel.leadingAnchor.constraint(equalTo: slider.trailingAnchor, constant: Self.controlSpacing),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    /// Removes every control from the bar, returning it to the empty frame
    /// it starts as (issue #13) — used when switching to a tool that has no
    /// options of its own.
    func clear() {
        subviews.forEach { $0.removeFromSuperview() }
        onZoomPresetSelected = nil
        onToleranceChanged = nil
        toleranceValueLabel = nil
    }

    @objc private func toleranceSliderChanged(_ sender: NSSlider) {
        let tolerance = Int(sender.doubleValue.rounded())
        toleranceValueLabel?.stringValue = "\(tolerance)"
        onToleranceChanged?(tolerance)
    }

    @objc private func zoomPresetChanged(_ sender: NSPopUpButton) {
        // Each item's `tag` carries the raw zoom level (issue #13
        // self-review should-1) rather than deriving it from the displayed
        // title (e.g. "3200%"). Parsing the display string back into a
        // level was fragile — a future label format or localization change
        // would silently break `onSelect` the way an earlier version of
        // this method did (it parsed the *percentage* instead of the
        // level, so every selection was a no-op since
        // `CanvasView.setZoomScale(_:)` rejects values outside
        // `zoomLevels`).
        guard let level = sender.selectedItem?.tag else { return }
        onZoomPresetSelected?(level)
    }
}
