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
    /// Between one pen control group ("label + slider + value") and the
    /// next (issue #20) — wider than `controlSpacing` (used *within* a
    /// group, between its own label/slider/value) so four groups packed
    /// into one bar row still read as visually distinct settings rather
    /// than one long run of controls.
    private static let penGroupSpacing: CGFloat = 16
    private static let penSizeSliderWidth: CGFloat = 90
    private static let penUnitSliderWidth: CGFloat = 70
    private static let penValueLabelWidth: CGFloat = 36
    /// The text tool's font-family popup width (issue #42) — wider than
    /// `popUpWidth` (the zoom presets popup's own width) since font family
    /// names run much longer than "3200%".
    private static let textFontPopUpWidth: CGFloat = 160
    private static let textSizeSliderWidth: CGFloat = 90

    /// The magic wand's current-value readout (issue #11, round 3) — kept as
    /// a stored reference (unlike the zoom popup, which reads its own
    /// selection back via `sender`) so `toleranceSliderChanged(_:)` can
    /// update its text directly instead of needing to look the label back up
    /// among `subviews`.
    private var toleranceValueLabel: NSTextField?

    /// The pen tool's four current-value readouts (issue #20) — same
    /// "stored reference, updated directly by the slider's own action
    /// method" pattern as `toleranceValueLabel` above.
    private var penSizeValueLabel: NSTextField?
    private var penHardnessValueLabel: NSTextField?
    private var penOpacityValueLabel: NSTextField?
    private var penFlowValueLabel: NSTextField?

    /// The text tool's size readout (issue #42) — same "stored reference,
    /// updated directly by its own control's action method" pattern as
    /// `penSizeValueLabel` above.
    private var textSizeValueLabel: NSTextField?

    /// Fired when the text tool's font-family popup selection changes
    /// (issue #42). `AppDelegate` forwards the picked family straight into
    /// `CanvasView.textSettings.fontFamily`.
    private var onTextFontChanged: ((String) -> Void)?
    /// Fired when the text tool's size slider moves (issue #42).
    /// `AppDelegate` forwards the new value into
    /// `CanvasView.textSettings.fontSize`.
    private var onTextSizeChanged: ((CGFloat) -> Void)?
    /// Fired when the text tool's 横書き/縦書き segmented control changes
    /// (issue #42): `true` selects 縦書き (vertical). `AppDelegate`
    /// forwards this into `CanvasView.textSettings.isVertical`.
    private var onTextOrientationChanged: ((Bool) -> Void)?

    /// Fired when the zoom presets popup's selection changes (issue #13).
    /// `AppDelegate` forwards the picked level straight into
    /// `CanvasView.setZoomScale(_:)`, the same entry point used for
    /// click/drag zoom and the View menu's zoom-in/out.
    private var onZoomPresetSelected: ((Int) -> Void)?

    /// Fired when the magic wand's tolerance slider moves (issue #11, round
    /// 3). `AppDelegate` forwards the new value straight into
    /// `CanvasView.magicWandTolerance`.
    private var onToleranceChanged: ((Int) -> Void)?

    /// Fired when the pen tool's size/hardness/opacity/flow sliders move
    /// (issue #20). `AppDelegate` forwards each new value straight into the
    /// matching field of `CanvasView.penBrushSettings`.
    private var onPenSizeChanged: ((CGFloat) -> Void)?
    private var onPenHardnessChanged: ((Double) -> Void)?
    private var onPenOpacityChanged: ((Double) -> Void)?
    private var onPenFlowChanged: ((Double) -> Void)?

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

    /// Populates the bar with the pen tool's brush detail controls (issue
    /// #20): four "label + `NSSlider` + numeric readout" groups laid out
    /// side by side — サイズ (`PenBrushSettings.sizeRange`, shown as a plain
    /// point value), then 硬さ/不透明度/フロー (each
    /// `PenBrushSettings.unitRange`, shown as a percentage, matching
    /// `LayerPanelView`'s own opacity-slider readout convention). Same
    /// "rebuilt from scratch on every call" pattern as
    /// `showZoomPresets`/`showMagicWandOptions` above.
    func showPenOptions(
        settings: PenBrushSettings,
        onSizeChanged: @escaping (CGFloat) -> Void,
        onHardnessChanged: @escaping (Double) -> Void,
        onOpacityChanged: @escaping (Double) -> Void,
        onFlowChanged: @escaping (Double) -> Void
    ) {
        clear()
        self.onPenSizeChanged = onSizeChanged
        self.onPenHardnessChanged = onHardnessChanged
        self.onPenOpacityChanged = onOpacityChanged
        self.onPenFlowChanged = onFlowChanged

        let sizeGroup = makePenControlGroup(
            title: "サイズ",
            value: Double(settings.size),
            range: Double(PenBrushSettings.sizeRange.lowerBound)...Double(PenBrushSettings.sizeRange.upperBound),
            sliderWidth: Self.penSizeSliderWidth,
            valueText: "\(Int(settings.size.rounded()))",
            action: #selector(penSizeSliderChanged(_:))
        )
        penSizeValueLabel = sizeGroup.valueLabel

        let hardnessGroup = makePenControlGroup(
            title: "硬さ",
            value: settings.hardness,
            range: PenBrushSettings.unitRange,
            sliderWidth: Self.penUnitSliderWidth,
            valueText: Self.percentString(settings.hardness),
            action: #selector(penHardnessSliderChanged(_:))
        )
        penHardnessValueLabel = hardnessGroup.valueLabel

        let opacityGroup = makePenControlGroup(
            title: "不透明度",
            value: settings.opacity,
            range: PenBrushSettings.unitRange,
            sliderWidth: Self.penUnitSliderWidth,
            valueText: Self.percentString(settings.opacity),
            action: #selector(penOpacitySliderChanged(_:))
        )
        penOpacityValueLabel = opacityGroup.valueLabel

        let flowGroup = makePenControlGroup(
            title: "フロー",
            value: settings.flow,
            range: PenBrushSettings.unitRange,
            sliderWidth: Self.penUnitSliderWidth,
            valueText: Self.percentString(settings.flow),
            action: #selector(penFlowSliderChanged(_:))
        )
        penFlowValueLabel = flowGroup.valueLabel

        var previousTrailingAnchor = leadingAnchor
        var leadingSpacing = Self.horizontalPadding
        for group in [sizeGroup, hardnessGroup, opacityGroup, flowGroup] {
            addSubview(group.label)
            addSubview(group.slider)
            addSubview(group.valueLabel)
            NSLayoutConstraint.activate([
                group.label.leadingAnchor.constraint(equalTo: previousTrailingAnchor, constant: leadingSpacing),
                group.label.centerYAnchor.constraint(equalTo: centerYAnchor),

                group.slider.leadingAnchor.constraint(equalTo: group.label.trailingAnchor, constant: Self.controlSpacing),
                group.slider.centerYAnchor.constraint(equalTo: centerYAnchor),
                group.slider.widthAnchor.constraint(equalToConstant: group.sliderWidth),

                group.valueLabel.leadingAnchor.constraint(equalTo: group.slider.trailingAnchor, constant: Self.controlSpacing),
                group.valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
                group.valueLabel.widthAnchor.constraint(equalToConstant: Self.penValueLabelWidth)
            ])
            previousTrailingAnchor = group.valueLabel.trailingAnchor
            leadingSpacing = Self.penGroupSpacing
        }
    }

    /// Builds one "label + slider + numeric readout" control group for
    /// `showPenOptions` above (issue #20) — pulled out since that method
    /// needs four near-identical groups side by side, unlike
    /// `showMagicWandOptions`'s single inline one.
    private func makePenControlGroup(title: String, value: Double, range: ClosedRange<Double>, sliderWidth: CGFloat, valueText: String, action: Selector) -> (label: NSTextField, slider: NSSlider, valueLabel: NSTextField, sliderWidth: CGFloat) {
        let label = NSTextField(labelWithString: title)
        label.translatesAutoresizingMaskIntoConstraints = false

        let slider = NSSlider(value: value, minValue: range.lowerBound, maxValue: range.upperBound, target: self, action: action)
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.isContinuous = true

        let valueLabel = NSTextField(labelWithString: valueText)
        valueLabel.translatesAutoresizingMaskIntoConstraints = false

        return (label, slider, valueLabel, sliderWidth)
    }

    /// Populates the bar with the text tool's font/size/writing-direction
    /// controls (issue #42): a font-family popup (every installed family,
    /// via `NSFontManager.shared.availableFontFamilies`), a "サイズ" label
    /// + slider + numeric readout over `TextToolSettings.fontSizeRange`
    /// (same shape as `showPenOptions`'s own size group), and a 横書き/
    /// 縦書き `NSSegmentedControl`. Color is deliberately not duplicated
    /// here: the text tool paints with the existing foreground-color state
    /// the same way the pencil/pen do, so it gets no swatch of its own in
    /// this bar, matching how neither of those two tools gets one either.
    /// Same "rebuilt from scratch on every call" pattern as
    /// `showZoomPresets`/`showMagicWandOptions`/`showPenOptions` above.
    func showTextOptions(
        settings: TextToolSettings,
        onFontChanged: @escaping (String) -> Void,
        onSizeChanged: @escaping (CGFloat) -> Void,
        onOrientationChanged: @escaping (Bool) -> Void
    ) {
        clear()
        onTextFontChanged = onFontChanged
        onTextSizeChanged = onSizeChanged
        onTextOrientationChanged = onOrientationChanged

        let fontPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
        fontPopUp.translatesAutoresizingMaskIntoConstraints = false
        fontPopUp.target = self
        fontPopUp.action = #selector(textFontChanged(_:))
        let families = NSFontManager.shared.availableFontFamilies.sorted()
        for family in families {
            fontPopUp.addItem(withTitle: family)
        }
        if let matchIndex = families.firstIndex(of: settings.fontFamily) {
            fontPopUp.selectItem(at: matchIndex)
        }

        let sizeLabel = NSTextField(labelWithString: "サイズ")
        sizeLabel.translatesAutoresizingMaskIntoConstraints = false

        let sizeSlider = NSSlider(
            value: Double(settings.fontSize),
            minValue: Double(TextToolSettings.fontSizeRange.lowerBound),
            maxValue: Double(TextToolSettings.fontSizeRange.upperBound),
            target: self,
            action: #selector(textSizeSliderChanged(_:))
        )
        sizeSlider.translatesAutoresizingMaskIntoConstraints = false
        sizeSlider.isContinuous = true

        let sizeValueLabel = NSTextField(labelWithString: "\(Int(settings.fontSize.rounded()))")
        sizeValueLabel.translatesAutoresizingMaskIntoConstraints = false
        textSizeValueLabel = sizeValueLabel

        let orientationControl = NSSegmentedControl(
            labels: ["横書き", "縦書き"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(textOrientationChanged(_:))
        )
        orientationControl.translatesAutoresizingMaskIntoConstraints = false
        orientationControl.selectedSegment = settings.isVertical ? 1 : 0

        addSubview(fontPopUp)
        addSubview(sizeLabel)
        addSubview(sizeSlider)
        addSubview(sizeValueLabel)
        addSubview(orientationControl)
        NSLayoutConstraint.activate([
            fontPopUp.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalPadding),
            fontPopUp.centerYAnchor.constraint(equalTo: centerYAnchor),
            fontPopUp.widthAnchor.constraint(equalToConstant: Self.textFontPopUpWidth),

            sizeLabel.leadingAnchor.constraint(equalTo: fontPopUp.trailingAnchor, constant: Self.penGroupSpacing),
            sizeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            sizeSlider.leadingAnchor.constraint(equalTo: sizeLabel.trailingAnchor, constant: Self.controlSpacing),
            sizeSlider.centerYAnchor.constraint(equalTo: centerYAnchor),
            sizeSlider.widthAnchor.constraint(equalToConstant: Self.textSizeSliderWidth),

            sizeValueLabel.leadingAnchor.constraint(equalTo: sizeSlider.trailingAnchor, constant: Self.controlSpacing),
            sizeValueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            sizeValueLabel.widthAnchor.constraint(equalToConstant: Self.penValueLabelWidth),

            orientationControl.leadingAnchor.constraint(equalTo: sizeValueLabel.trailingAnchor, constant: Self.penGroupSpacing),
            orientationControl.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    /// Formats a `0...1` setting as a rounded percentage (issue #20) —
    /// matches `LayerPanelView`'s own opacity-slider readout convention
    /// (e.g. "100%").
    private static func percentString(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    /// Removes every control from the bar, returning it to the empty frame
    /// it starts as (issue #13) — used when switching to a tool that has no
    /// options of its own.
    func clear() {
        subviews.forEach { $0.removeFromSuperview() }
        onZoomPresetSelected = nil
        onToleranceChanged = nil
        toleranceValueLabel = nil
        onPenSizeChanged = nil
        onPenHardnessChanged = nil
        onPenOpacityChanged = nil
        onPenFlowChanged = nil
        penSizeValueLabel = nil
        penHardnessValueLabel = nil
        penOpacityValueLabel = nil
        penFlowValueLabel = nil
        onTextFontChanged = nil
        onTextSizeChanged = nil
        onTextOrientationChanged = nil
        textSizeValueLabel = nil
    }

    @objc private func toleranceSliderChanged(_ sender: NSSlider) {
        let tolerance = Int(sender.doubleValue.rounded())
        toleranceValueLabel?.stringValue = "\(tolerance)"
        onToleranceChanged?(tolerance)
    }

    @objc private func penSizeSliderChanged(_ sender: NSSlider) {
        let size = CGFloat(sender.doubleValue)
        penSizeValueLabel?.stringValue = "\(Int(size.rounded()))"
        onPenSizeChanged?(size)
    }

    @objc private func penHardnessSliderChanged(_ sender: NSSlider) {
        let hardness = sender.doubleValue
        penHardnessValueLabel?.stringValue = Self.percentString(hardness)
        onPenHardnessChanged?(hardness)
    }

    @objc private func penOpacitySliderChanged(_ sender: NSSlider) {
        let opacity = sender.doubleValue
        penOpacityValueLabel?.stringValue = Self.percentString(opacity)
        onPenOpacityChanged?(opacity)
    }

    @objc private func penFlowSliderChanged(_ sender: NSSlider) {
        let flow = sender.doubleValue
        penFlowValueLabel?.stringValue = Self.percentString(flow)
        onPenFlowChanged?(flow)
    }

    @objc private func textFontChanged(_ sender: NSPopUpButton) {
        guard let family = sender.selectedItem?.title else { return }
        onTextFontChanged?(family)
    }

    @objc private func textSizeSliderChanged(_ sender: NSSlider) {
        let size = CGFloat(sender.doubleValue)
        textSizeValueLabel?.stringValue = "\(Int(size.rounded()))"
        onTextSizeChanged?(size)
    }

    @objc private func textOrientationChanged(_ sender: NSSegmentedControl) {
        onTextOrientationChanged?(sender.selectedSegment == 1)
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
