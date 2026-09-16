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
    /// The Feather numeric field's width (issue #56) — narrow, matching a
    /// short "0"–"999"-ish pixel-radius entry, not a whole sentence the way
    /// `textFontPopUpWidth` needs to accommodate.
    private static let featherFieldWidth: CGFloat = 44

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

    /// Fired when the magic wand's "隣接ピクセルのみ" (Contiguous) checkbox
    /// toggles (issue #52). `AppDelegate` forwards the new value straight
    /// into `CanvasView.magicWandContiguous`. `nil` when the bar is showing
    /// the tolerance-only layout (bucket fill reuses `showMagicWandOptions`
    /// but has no contiguous option of its own — see that method's doc
    /// comment).
    private var onContiguousChanged: ((Bool) -> Void)?

    /// Fired when the pen tool's size/hardness/opacity/flow sliders move
    /// (issue #20). `AppDelegate` forwards each new value straight into the
    /// matching field of `CanvasView.penBrushSettings`.
    private var onPenSizeChanged: ((CGFloat) -> Void)?
    private var onPenHardnessChanged: ((Double) -> Void)?
    private var onPenOpacityChanged: ((Double) -> Void)?
    private var onPenFlowChanged: ((Double) -> Void)?

    /// The Feather numeric field's stored reference (issue #56) — same
    /// "stored reference, re-normalized after every edit" pattern as
    /// `toleranceValueLabel`, needed so `featherFieldChanged(_:)` can write
    /// the clamped/reformatted value straight back into the field it read
    /// from.
    private var featherField: NSTextField?

    /// Fired when the Feather field commits a new value (issue #56, one of
    /// the five selection tools' shared option-bar controls — see
    /// `showSelectionOptions`). `AppDelegate` forwards the new value straight
    /// into `CanvasView.selectionFeather`.
    private var onFeatherChanged: ((Double) -> Void)?
    /// Fired when the Anti-alias checkbox toggles (issue #56). `AppDelegate`
    /// forwards the new value straight into `CanvasView.selectionAntiAlias`.
    /// `nil` when the bar is showing the Feather-only layout (the rectangle
    /// marquee has no diagonal edges to anti-alias — see
    /// `showSelectionOptions`'s own doc comment).
    private var onAntiAliasChanged: ((Bool) -> Void)?

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
    ///
    /// `currentContiguous`/`onContiguousChanged` (issue #52) add a
    /// "隣接ピクセルのみ" checkbox after the tolerance controls — Photoshop's
    /// own magic-wand-only "Contiguous" option. Both default to `nil`,
    /// which omits the checkbox entirely: `AppDelegate` also reuses this
    /// same method for the bucket fill tool's own tolerance slider (see its
    /// call site's doc comment), and bucket fill has no contiguous option
    /// of its own (non-contiguous *fill* is a different, out-of-scope
    /// feature — see `CanvasView.magicWandContiguous`'s doc comment), so
    /// passing `nil` there keeps that layout exactly as it was before this
    /// issue.
    ///
    /// `currentFeather`/`onFeatherChanged` and `currentAntiAlias`/
    /// `onAntiAliasChanged` (issue #56) append the same Feather field +
    /// Anti-alias checkbox `showSelectionOptions` shows the other four
    /// selection tools, after the Contiguous checkbox — the magic wand is
    /// itself one of the five selection tools issue #56 covers, so it needs
    /// both sets of controls in one bar rather than choosing between this
    /// method and `showSelectionOptions`. `currentFeather` defaults to `nil`,
    /// which omits both Feather and Anti-alias entirely: bucket fill (this
    /// method's other caller) reuses the tolerance-only layout unmodified,
    /// since bucket fill paints dot-exact pixels and has no selection
    /// boundary of its own for Feather/Anti-alias to soften.
    func showMagicWandOptions(
        currentTolerance: Int,
        currentContiguous: Bool? = nil,
        currentFeather: Double? = nil,
        currentAntiAlias: Bool? = nil,
        onToleranceChanged: @escaping (Int) -> Void,
        onContiguousChanged: ((Bool) -> Void)? = nil,
        onFeatherChanged: ((Double) -> Void)? = nil,
        onAntiAliasChanged: ((Bool) -> Void)? = nil
    ) {
        clear()
        self.onToleranceChanged = onToleranceChanged
        self.onContiguousChanged = onContiguousChanged
        // `onFeatherChanged`/`onAntiAliasChanged` (issue #56) are wired by
        // `addFeatherAntiAliasControls` further down, only once both it and
        // `currentFeather` are confirmed non-`nil` — not here — so a caller
        // that omits Feather (bucket fill) leaves both `nil`, matching
        // `clear()`'s own reset.

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

        // Tracks whichever control ended up rightmost so far, so the
        // Contiguous checkbox and/or the Feather/Anti-alias controls below
        // each chain off the *actual* previous control instead of always
        // assuming `valueLabel` — needed because `currentContiguous == nil`
        // (bucket fill) skips the checkbox entirely, and issue #56's
        // Feather/Anti-alias controls need to land after whichever of
        // `valueLabel`/`contiguousCheckbox` is actually on screen.
        var trailingAnchor = valueLabel.trailingAnchor

        if let currentContiguous {
            let contiguousCheckbox = NSButton(
                checkboxWithTitle: "隣接ピクセルのみ",
                target: self,
                action: #selector(contiguousCheckboxChanged(_:))
            )
            contiguousCheckbox.translatesAutoresizingMaskIntoConstraints = false
            contiguousCheckbox.state = currentContiguous ? .on : .off
            addSubview(contiguousCheckbox)
            NSLayoutConstraint.activate([
                contiguousCheckbox.leadingAnchor.constraint(equalTo: trailingAnchor, constant: Self.penGroupSpacing),
                contiguousCheckbox.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
            trailingAnchor = contiguousCheckbox.trailingAnchor
        }

        guard let currentFeather, let onFeatherChanged else { return }
        addFeatherAntiAliasControls(
            currentFeather: currentFeather,
            currentAntiAlias: currentAntiAlias,
            leadingAnchor: trailingAnchor,
            leadingSpacing: Self.penGroupSpacing,
            onFeatherChanged: onFeatherChanged,
            onAntiAliasChanged: onAntiAliasChanged
        )
    }

    /// Populates the bar with the selection tools' shared Feather/Anti-alias
    /// controls (issue #56): a "ぼかし (Feather)" label + numeric text field
    /// over `CanvasView.selectionFeather`'s pixel-radius range, and — when
    /// `currentAntiAlias` is non-`nil` — an "アンチエイリアス" checkbox after
    /// it. Same "rebuilt from scratch on every call" pattern as
    /// `showZoomPresets`/`showMagicWandOptions` above.
    ///
    /// `currentAntiAlias`/`onAntiAliasChanged` default to `nil`, which omits
    /// the checkbox entirely — same "`nil` omits this part of the layout"
    /// convention `showMagicWandOptions`'s own `currentContiguous` already
    /// uses. `AppDelegate` calls this with `nil` only for the rectangle
    /// marquee: its selection boundary is always axis-aligned, so
    /// `SelectionMask.rectangle(...)` has no `antiAlias` parameter for a
    /// checkbox here to drive (see that method's own doc comment — issue
    /// #56's anti-aliasing only applies to the ellipse/lasso/polygon/magic-
    /// wand tools' non-axis-aligned boundaries). Every other selection tool
    /// passes a real value, showing both controls.
    func showSelectionOptions(
        currentFeather: Double,
        currentAntiAlias: Bool? = nil,
        onFeatherChanged: @escaping (Double) -> Void,
        onAntiAliasChanged: ((Bool) -> Void)? = nil
    ) {
        clear()
        addFeatherAntiAliasControls(
            currentFeather: currentFeather,
            currentAntiAlias: currentAntiAlias,
            leadingAnchor: leadingAnchor,
            leadingSpacing: Self.horizontalPadding,
            onFeatherChanged: onFeatherChanged,
            onAntiAliasChanged: onAntiAliasChanged
        )
    }

    /// Appends the Feather field (and, when `currentAntiAlias` is non-`nil`,
    /// the Anti-alias checkbox right after it) starting at `leadingAnchor`
    /// (issue #56) — factored out because these two controls are shared by
    /// two different call sites: `showSelectionOptions` above (the
    /// rectangle/ellipse/lasso/polygon tools, where Feather/Anti-alias are
    /// the *only* controls in the bar) and `showMagicWandOptions` below
    /// (where they come *after* that method's own tolerance/contiguous
    /// controls, in the same bar — the magic wand is itself one of the five
    /// selection tools issue #56 covers, not a separate layout). Also wires
    /// `onFeatherChanged`/`onAntiAliasChanged` itself, so neither caller
    /// needs to repeat that.
    private func addFeatherAntiAliasControls(
        currentFeather: Double,
        currentAntiAlias: Bool?,
        leadingAnchor: NSLayoutXAxisAnchor,
        leadingSpacing: CGFloat,
        onFeatherChanged: @escaping (Double) -> Void,
        onAntiAliasChanged: ((Bool) -> Void)?
    ) {
        self.onFeatherChanged = onFeatherChanged
        self.onAntiAliasChanged = onAntiAliasChanged

        let label = NSTextField(labelWithString: "ぼかし(Feather)")
        label.translatesAutoresizingMaskIntoConstraints = false

        let field = NSTextField(frame: .zero)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.alignment = .right
        field.stringValue = Self.featherString(currentFeather)
        field.target = self
        field.action = #selector(featherFieldChanged(_:))
        featherField = field

        addSubview(label)
        addSubview(field)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leadingSpacing),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),

            field.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: Self.controlSpacing),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.widthAnchor.constraint(equalToConstant: Self.featherFieldWidth)
        ])

        guard let currentAntiAlias else { return }
        let antiAliasCheckbox = NSButton(
            checkboxWithTitle: "アンチエイリアス",
            target: self,
            action: #selector(antiAliasCheckboxChanged(_:))
        )
        antiAliasCheckbox.translatesAutoresizingMaskIntoConstraints = false
        antiAliasCheckbox.state = currentAntiAlias ? .on : .off
        addSubview(antiAliasCheckbox)
        NSLayoutConstraint.activate([
            antiAliasCheckbox.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: Self.penGroupSpacing),
            antiAliasCheckbox.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    /// Formats a Feather radius for the numeric field (issue #56) — `%g`
    /// prints a whole number plainly ("0", "12") and trims a fractional
    /// one's trailing zeros ("2.5"), unlike a fixed-precision `%.1f` which
    /// would print every whole value as "12.0".
    private static func featherString(_ value: Double) -> String {
        String(format: "%g", value)
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
        onContiguousChanged = nil
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
        onFeatherChanged = nil
        onAntiAliasChanged = nil
        featherField = nil
    }

    @objc private func toleranceSliderChanged(_ sender: NSSlider) {
        let tolerance = Int(sender.doubleValue.rounded())
        toleranceValueLabel?.stringValue = "\(tolerance)"
        onToleranceChanged?(tolerance)
    }

    /// Fired when the magic wand's "隣接ピクセルのみ" checkbox toggles
    /// (issue #52). `sender.state` is an `NSControl.StateValue`, not a
    /// `Bool`, so this compares against `.on` the same way
    /// `textOrientationChanged(_:)` below compares its segmented control's
    /// `selectedSegment` rather than assuming any particular raw value.
    @objc private func contiguousCheckboxChanged(_ sender: NSButton) {
        onContiguousChanged?(sender.state == .on)
    }

    /// Fired when the Feather field commits (Return, or focus loss — an
    /// `NSTextField`'s own default `action`-firing behavior, issue #56).
    /// Unparseable text (empty field, stray characters) falls back to `0`
    /// rather than leaving the previous value silently in place, matching
    /// how a blank/garbled Feather entry reads most naturally as "no
    /// feather". Negative input clamps to `0` — a negative blur radius is
    /// meaningless.
    ///
    /// Clamped to `SelectionMask.maxRadius` at the *upper* end too (issue
    /// #56 independent review must-1): an unbounded Feather value typed
    /// here is the concrete way a user could hit the performance hang the
    /// review measured (5+ minutes, no progress indicator, no cancel) before
    /// `SelectionMask.feathered(radius:)` itself was rewritten to a
    /// radius-independent box blur — this UI-level clamp is the first line
    /// of defense a typed value actually hits, and `feathered(radius:)`'s
    /// own clamp to the same constant is the backstop for any other caller.
    ///
    /// Either way (fallback or clamp), the field is reformatted back through
    /// `featherString(_:)` so what's displayed always matches the value
    /// actually applied — typing "99999" visibly snaps back to
    /// `SelectionMask.maxRadius` rather than silently capping the applied
    /// value while the field still reads "99999".
    @objc private func featherFieldChanged(_ sender: NSTextField) {
        let parsed = Double(sender.stringValue) ?? 0
        let feather = max(0, min(SelectionMask.maxRadius, parsed))
        sender.stringValue = Self.featherString(feather)
        onFeatherChanged?(feather)
    }

    /// Fired when the Anti-alias checkbox toggles (issue #56). Same
    /// `sender.state == .on` comparison as `contiguousCheckboxChanged(_:)`
    /// above.
    @objc private func antiAliasCheckboxChanged(_ sender: NSButton) {
        onAntiAliasChanged?(sender.state == .on)
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
