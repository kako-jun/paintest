import AppKit

/// The four "イメージ" color-adjustment dialogs (issue #12): トーンカーブ,
/// 明るさ・コントラスト, 色相・彩度, レベル補正. Each `show*` function below
/// runs its own modal `NSPanel` (built the same "explicit-frame `NSView`s,
/// no accessory-view `NSAlert`" way `NewCanvasDialog`/`ColorPickerDialog`
/// build their own simpler modals) and shares the same live-preview contract:
///
/// - `target` is the active layer's *real* `PixelCanvas` (issue #11: writes
///   are restricted to `mask` when one is given). A private `.copy()` is
///   snapshotted the instant the dialog opens (mirroring
///   `CanvasView.beginLayerTransform()`'s own "snapshot on begin" pattern for
///   its transform preview) and every UI change re-derives the live preview
///   from *that* snapshot via `ImageAdjustments.apply(...)`, written straight
///   into `target` — so `CanvasView`'s ordinary compositing draws the preview
///   with no extra plumbing of its own, once `onPreview()` asks it to
///   redraw.
/// - Returns `true` if the user clicked "OK" (the adjustment stays applied —
///   `target` is left holding the last-previewed result) or `false` if they
///   clicked "キャンセル"/closed the panel (the pre-dialog snapshot is copied
///   back into `target` before returning, so cancel is a true no-op).
///   `AppDelegate` uses this to decide whether to record an undo/redo
///   checkpoint at all — a cancelled dialog must leave no trace in history,
///   the same rule `CanvasView.cancelLayerTransform()` follows for a
///   cancelled layer transform.
enum AdjustmentDialog {
    // MARK: - Brightness / Contrast

    static func showBrightnessContrast(target: PixelCanvas, mask: SelectionMask?, onPreview: @escaping () -> Void) -> Bool {
        let original = target.copy()
        var settings = ImageAdjustments.BrightnessContrastSettings.identity

        func preview() {
            ImageAdjustments.apply(transform: settings.makeTransform(), from: original, into: target, mask: mask)
            onPreview()
        }

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 76))

        let brightnessLabel = NSTextField(labelWithString: "明るさ")
        brightnessLabel.frame = NSRect(x: 0, y: 50, width: 60, height: 18)
        let brightnessValueLabel = NSTextField(labelWithString: "0")
        brightnessValueLabel.frame = NSRect(x: 240, y: 50, width: 40, height: 18)
        brightnessValueLabel.alignment = .right

        let contrastLabel = NSTextField(labelWithString: "コントラスト")
        contrastLabel.frame = NSRect(x: 0, y: 10, width: 60, height: 18)
        let contrastValueLabel = NSTextField(labelWithString: "0")
        contrastValueLabel.frame = NSRect(x: 240, y: 10, width: 40, height: 18)
        contrastValueLabel.alignment = .right

        let brightnessBridge = SliderActionBridge { value in
            settings.brightness = Int(value.rounded())
            brightnessValueLabel.stringValue = "\(settings.brightness)"
            preview()
        }
        let brightnessSlider = NSSlider(value: 0, minValue: -150, maxValue: 150, target: brightnessBridge, action: #selector(SliderActionBridge.changed(_:)))
        brightnessSlider.frame = NSRect(x: 64, y: 46, width: 172, height: 24)
        brightnessSlider.isContinuous = true

        let contrastBridge = SliderActionBridge { value in
            settings.contrast = Int(value.rounded())
            contrastValueLabel.stringValue = "\(settings.contrast)"
            preview()
        }
        let contrastSlider = NSSlider(value: 0, minValue: -100, maxValue: 100, target: contrastBridge, action: #selector(SliderActionBridge.changed(_:)))
        contrastSlider.frame = NSRect(x: 64, y: 6, width: 172, height: 24)
        contrastSlider.isContinuous = true

        [brightnessLabel, brightnessSlider, brightnessValueLabel, contrastLabel, contrastSlider, contrastValueLabel]
            .forEach { content.addSubview($0) }

        let applied = runModalPanel(title: "明るさ・コントラスト", contentView: content)
        if !applied {
            restore(original: original, into: target)
            onPreview()
        }
        return applied
    }

    // MARK: - Hue / Saturation

    static func showHueSaturation(target: PixelCanvas, mask: SelectionMask?, onPreview: @escaping () -> Void) -> Bool {
        let original = target.copy()
        var settings = ImageAdjustments.HueSaturationSettings.identity

        func preview() {
            ImageAdjustments.apply(transform: settings.makeTransform(), from: original, into: target, mask: mask)
            onPreview()
        }

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 112))

        let hueLabel = NSTextField(labelWithString: "色相")
        hueLabel.frame = NSRect(x: 0, y: 86, width: 60, height: 18)
        let hueValueLabel = NSTextField(labelWithString: "0")
        hueValueLabel.frame = NSRect(x: 240, y: 86, width: 40, height: 18)
        hueValueLabel.alignment = .right

        let saturationLabel = NSTextField(labelWithString: "彩度")
        saturationLabel.frame = NSRect(x: 0, y: 48, width: 60, height: 18)
        let saturationValueLabel = NSTextField(labelWithString: "0")
        saturationValueLabel.frame = NSRect(x: 240, y: 48, width: 40, height: 18)
        saturationValueLabel.alignment = .right

        let lightnessLabel = NSTextField(labelWithString: "明度")
        lightnessLabel.frame = NSRect(x: 0, y: 10, width: 60, height: 18)
        let lightnessValueLabel = NSTextField(labelWithString: "0")
        lightnessValueLabel.frame = NSRect(x: 240, y: 10, width: 40, height: 18)
        lightnessValueLabel.alignment = .right

        let hueBridge = SliderActionBridge { value in
            settings.hue = Int(value.rounded())
            hueValueLabel.stringValue = "\(settings.hue)"
            preview()
        }
        let hueSlider = NSSlider(value: 0, minValue: -180, maxValue: 180, target: hueBridge, action: #selector(SliderActionBridge.changed(_:)))
        hueSlider.frame = NSRect(x: 64, y: 82, width: 172, height: 24)
        hueSlider.isContinuous = true

        let saturationBridge = SliderActionBridge { value in
            settings.saturation = Int(value.rounded())
            saturationValueLabel.stringValue = "\(settings.saturation)"
            preview()
        }
        let saturationSlider = NSSlider(value: 0, minValue: -100, maxValue: 100, target: saturationBridge, action: #selector(SliderActionBridge.changed(_:)))
        saturationSlider.frame = NSRect(x: 64, y: 44, width: 172, height: 24)
        saturationSlider.isContinuous = true

        let lightnessBridge = SliderActionBridge { value in
            settings.lightness = Int(value.rounded())
            lightnessValueLabel.stringValue = "\(settings.lightness)"
            preview()
        }
        let lightnessSlider = NSSlider(value: 0, minValue: -100, maxValue: 100, target: lightnessBridge, action: #selector(SliderActionBridge.changed(_:)))
        lightnessSlider.frame = NSRect(x: 64, y: 6, width: 172, height: 24)
        lightnessSlider.isContinuous = true

        [hueLabel, hueSlider, hueValueLabel,
         saturationLabel, saturationSlider, saturationValueLabel,
         lightnessLabel, lightnessSlider, lightnessValueLabel].forEach { content.addSubview($0) }

        let applied = runModalPanel(title: "色相・彩度", contentView: content)
        if !applied {
            restore(original: original, into: target)
            onPreview()
        }
        return applied
    }

    // MARK: - Levels

    static func showLevels(target: PixelCanvas, mask: SelectionMask?, onPreview: @escaping () -> Void) -> Bool {
        let original = target.copy()
        var settings = ImageAdjustments.LevelsSettings.identity
        var selectedChannel = Channel.master

        func currentChannel() -> ImageAdjustments.LevelsChannel {
            switch selectedChannel {
            case .master: return settings.master
            case .red: return settings.red
            case .green: return settings.green
            case .blue: return settings.blue
            }
        }
        func setCurrentChannel(_ channel: ImageAdjustments.LevelsChannel) {
            switch selectedChannel {
            case .master: settings.master = channel
            case .red: settings.red = channel
            case .green: settings.green = channel
            case .blue: settings.blue = channel
            }
        }
        func preview() {
            ImageAdjustments.apply(transform: settings.makeTransform(), from: original, into: target, mask: mask)
            onPreview()
        }

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 190))

        let channelPopup = NSPopUpButton(frame: NSRect(x: 0, y: 160, width: 150, height: 24), pullsDown: false)
        Channel.allCases.forEach { channelPopup.addItem(withTitle: $0.label) }

        let inputBlackLabel = NSTextField(labelWithString: "入力: 黒点")
        inputBlackLabel.frame = NSRect(x: 0, y: 130, width: 90, height: 18)
        let inputBlackValueLabel = NSTextField(labelWithString: "0")
        inputBlackValueLabel.frame = NSRect(x: 250, y: 130, width: 40, height: 18)
        inputBlackValueLabel.alignment = .right

        let gammaLabel = NSTextField(labelWithString: "ガンマ")
        gammaLabel.frame = NSRect(x: 0, y: 100, width: 90, height: 18)
        let gammaValueLabel = NSTextField(labelWithString: "1.00")
        gammaValueLabel.frame = NSRect(x: 250, y: 100, width: 40, height: 18)
        gammaValueLabel.alignment = .right

        let inputWhiteLabel = NSTextField(labelWithString: "入力: 白点")
        inputWhiteLabel.frame = NSRect(x: 0, y: 70, width: 90, height: 18)
        let inputWhiteValueLabel = NSTextField(labelWithString: "255")
        inputWhiteValueLabel.frame = NSRect(x: 250, y: 70, width: 40, height: 18)
        inputWhiteValueLabel.alignment = .right

        let outputBlackLabel = NSTextField(labelWithString: "出力: 黒点")
        outputBlackLabel.frame = NSRect(x: 0, y: 40, width: 90, height: 18)
        let outputBlackValueLabel = NSTextField(labelWithString: "0")
        outputBlackValueLabel.frame = NSRect(x: 250, y: 40, width: 40, height: 18)
        outputBlackValueLabel.alignment = .right

        let outputWhiteLabel = NSTextField(labelWithString: "出力: 白点")
        outputWhiteLabel.frame = NSRect(x: 0, y: 10, width: 90, height: 18)
        let outputWhiteValueLabel = NSTextField(labelWithString: "255")
        outputWhiteValueLabel.frame = NSRect(x: 250, y: 10, width: 40, height: 18)
        outputWhiteValueLabel.alignment = .right

        let inputBlackBridge = SliderActionBridge { value in
            var channel = currentChannel()
            channel.inputBlack = Int(value.rounded())
            setCurrentChannel(channel)
            inputBlackValueLabel.stringValue = "\(channel.inputBlack)"
            preview()
        }
        let inputBlackSlider = NSSlider(value: 0, minValue: 0, maxValue: 255, target: inputBlackBridge, action: #selector(SliderActionBridge.changed(_:)))
        inputBlackSlider.frame = NSRect(x: 94, y: 126, width: 150, height: 24)
        inputBlackSlider.isContinuous = true

        let gammaBridge = SliderActionBridge { value in
            var channel = currentChannel()
            channel.gamma = value
            setCurrentChannel(channel)
            gammaValueLabel.stringValue = String(format: "%.2f", value)
            preview()
        }
        let gammaSlider = NSSlider(value: 1, minValue: 0.1, maxValue: 9.99, target: gammaBridge, action: #selector(SliderActionBridge.changed(_:)))
        gammaSlider.frame = NSRect(x: 94, y: 96, width: 150, height: 24)
        gammaSlider.isContinuous = true

        let inputWhiteBridge = SliderActionBridge { value in
            var channel = currentChannel()
            channel.inputWhite = Int(value.rounded())
            setCurrentChannel(channel)
            inputWhiteValueLabel.stringValue = "\(channel.inputWhite)"
            preview()
        }
        let inputWhiteSlider = NSSlider(value: 255, minValue: 0, maxValue: 255, target: inputWhiteBridge, action: #selector(SliderActionBridge.changed(_:)))
        inputWhiteSlider.frame = NSRect(x: 94, y: 66, width: 150, height: 24)
        inputWhiteSlider.isContinuous = true

        let outputBlackBridge = SliderActionBridge { value in
            var channel = currentChannel()
            channel.outputBlack = Int(value.rounded())
            setCurrentChannel(channel)
            outputBlackValueLabel.stringValue = "\(channel.outputBlack)"
            preview()
        }
        let outputBlackSlider = NSSlider(value: 0, minValue: 0, maxValue: 255, target: outputBlackBridge, action: #selector(SliderActionBridge.changed(_:)))
        outputBlackSlider.frame = NSRect(x: 94, y: 36, width: 150, height: 24)
        outputBlackSlider.isContinuous = true

        let outputWhiteBridge = SliderActionBridge { value in
            var channel = currentChannel()
            channel.outputWhite = Int(value.rounded())
            setCurrentChannel(channel)
            outputWhiteValueLabel.stringValue = "\(channel.outputWhite)"
            preview()
        }
        let outputWhiteSlider = NSSlider(value: 255, minValue: 0, maxValue: 255, target: outputWhiteBridge, action: #selector(SliderActionBridge.changed(_:)))
        outputWhiteSlider.frame = NSRect(x: 94, y: 6, width: 150, height: 24)
        outputWhiteSlider.isContinuous = true

        // Reflects `selectedChannel`'s own stored settings into every
        // slider/value-label without going through their `SliderActionBridge`
        // callbacks (setting `.doubleValue` programmatically does not fire an
        // `NSSlider`'s action, only user interaction does) — so switching the
        // channel popup never triggers a spurious extra `preview()` call.
        func refreshControls() {
            let channel = currentChannel()
            inputBlackSlider.doubleValue = Double(channel.inputBlack)
            inputBlackValueLabel.stringValue = "\(channel.inputBlack)"
            gammaSlider.doubleValue = channel.gamma
            gammaValueLabel.stringValue = String(format: "%.2f", channel.gamma)
            inputWhiteSlider.doubleValue = Double(channel.inputWhite)
            inputWhiteValueLabel.stringValue = "\(channel.inputWhite)"
            outputBlackSlider.doubleValue = Double(channel.outputBlack)
            outputBlackValueLabel.stringValue = "\(channel.outputBlack)"
            outputWhiteSlider.doubleValue = Double(channel.outputWhite)
            outputWhiteValueLabel.stringValue = "\(channel.outputWhite)"
        }

        let channelBridge = PopUpActionBridge { index in
            selectedChannel = Channel(rawValue: index) ?? .master
            refreshControls()
        }
        channelPopup.target = channelBridge
        channelPopup.action = #selector(PopUpActionBridge.changed(_:))

        [channelPopup,
         inputBlackLabel, inputBlackSlider, inputBlackValueLabel,
         gammaLabel, gammaSlider, gammaValueLabel,
         inputWhiteLabel, inputWhiteSlider, inputWhiteValueLabel,
         outputBlackLabel, outputBlackSlider, outputBlackValueLabel,
         outputWhiteLabel, outputWhiteSlider, outputWhiteValueLabel].forEach { content.addSubview($0) }

        let applied = runModalPanel(title: "レベル補正", contentView: content)
        if !applied {
            restore(original: original, into: target)
            onPreview()
        }
        return applied
    }

    // MARK: - Tone curve

    static func showToneCurve(target: PixelCanvas, mask: SelectionMask?, onPreview: @escaping () -> Void) -> Bool {
        let original = target.copy()
        var settings = ImageAdjustments.ToneCurveSettings.identity
        var selectedChannel = Channel.master

        func currentCurve() -> ImageAdjustments.ToneCurve {
            switch selectedChannel {
            case .master: return settings.master
            case .red: return settings.red
            case .green: return settings.green
            case .blue: return settings.blue
            }
        }
        func setCurrentCurve(_ curve: ImageAdjustments.ToneCurve) {
            switch selectedChannel {
            case .master: settings.master = curve
            case .red: settings.red = curve
            case .green: settings.green = curve
            case .blue: settings.blue = curve
            }
        }
        func preview() {
            ImageAdjustments.apply(transform: settings.makeTransform(), from: original, into: target, mask: mask)
            onPreview()
        }

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 316))

        let channelPopup = NSPopUpButton(frame: NSRect(x: 0, y: 286, width: 150, height: 24), pullsDown: false)
        Channel.allCases.forEach { channelPopup.addItem(withTitle: $0.label) }

        let graphView = ToneCurveGraphView(frame: NSRect(x: 0, y: 0, width: 280, height: 280))
        graphView.curve = currentCurve()
        graphView.onChange = { curve in
            setCurrentCurve(curve)
            preview()
        }

        let channelBridge = PopUpActionBridge { index in
            selectedChannel = Channel(rawValue: index) ?? .master
            // Switching channel only swaps which curve the graph *displays
            // and edits* next — it must not re-run `preview()` itself (no
            // setting actually changed), matching `showLevels`'
            // `refreshControls()` doing the same "reflect state, don't
            // preview" thing for its own channel popup.
            graphView.curve = currentCurve()
        }
        channelPopup.target = channelBridge
        channelPopup.action = #selector(PopUpActionBridge.changed(_:))

        content.addSubview(channelPopup)
        content.addSubview(graphView)

        let applied = runModalPanel(title: "トーンカーブ", contentView: content)
        if !applied {
            restore(original: original, into: target)
            onPreview()
        }
        return applied
    }

    // MARK: - Shared plumbing

    /// The RGB/Red/Green/Blue channel picker shared by トーンカーブ and
    /// レベル補正 (issue #12) — the two adjustments that, unlike
    /// 明るさ・コントラスト/色相・彩度, operate per-channel in Photoshop.
    private enum Channel: Int, CaseIterable {
        case master, red, green, blue

        var label: String {
            switch self {
            case .master: return "RGB (マスター)"
            case .red: return "赤"
            case .green: return "緑"
            case .blue: return "青"
            }
        }
    }

    /// Copies `original`'s pixels back onto `target` byte-for-byte (a
    /// cancelled dialog's restore step) by reusing `ImageAdjustments.apply`
    /// with a no-op transform and no mask, rather than adding a dedicated
    /// raw-byte-copy method to `PixelCanvas` just for this one caller.
    private static func restore(original: PixelCanvas, into target: PixelCanvas) {
        ImageAdjustments.apply(transform: { r, g, b, a in (r, g, b, a) }, from: original, into: target, mask: nil)
    }

    /// Runs a modal `NSPanel` containing `contentView` (already built with an
    /// explicit frame — this reads that frame's size to size the panel, the
    /// same "caller already knows its own layout" convention
    /// `NewCanvasDialog`/`ColorPickerDialog` use for their `NSAlert`
    /// accessory views) above a shared "OK" / "キャンセル" button row.
    ///
    /// Returns whether "OK" was clicked. Closing the panel via its titlebar
    /// button, without clicking either button, relies on documented AppKit
    /// behavior (`NSApplication.runModal(for:)`'s modal session ends
    /// automatically once the window it's running for closes) to fall
    /// through to the same `NSApp.runModal(for:)` return as an explicit
    /// click would — `applied` is only ever flipped to `true` by
    /// `DialogButtonBridge.ok()`, so that path already defaults to "treat
    /// like キャンセル" with no extra handling needed.
    private static func runModalPanel(title: String, contentView: NSView) -> Bool {
        let buttonBarHeight: CGFloat = 44
        let horizontalPadding: CGFloat = 16
        let topPadding: CGFloat = 16
        let buttonWidth: CGFloat = 90
        let buttonHeight: CGFloat = 24
        let buttonSpacing: CGFloat = 8

        let contentFrame = contentView.frame
        let panelWidth = contentFrame.width + horizontalPadding * 2
        let panelHeight = contentFrame.height + buttonBarHeight + topPadding

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.isReleasedWhenClosed = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight))
        contentView.frame.origin = NSPoint(x: horizontalPadding, y: buttonBarHeight)
        container.addSubview(contentView)

        let cancelButton = NSButton(frame: NSRect(
            x: panelWidth - horizontalPadding - buttonWidth,
            y: 10, width: buttonWidth, height: buttonHeight
        ))
        cancelButton.title = "キャンセル"
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"

        let okButton = NSButton(frame: NSRect(
            x: panelWidth - horizontalPadding - buttonWidth * 2 - buttonSpacing,
            y: 10, width: buttonWidth, height: buttonHeight
        ))
        okButton.title = "OK"
        okButton.bezelStyle = .rounded
        okButton.keyEquivalent = "\r"

        container.addSubview(okButton)
        container.addSubview(cancelButton)

        var applied = false
        let buttonBridge = DialogButtonBridge(
            onOK: { applied = true; NSApp.stopModal() },
            onCancel: { applied = false; NSApp.stopModal() }
        )
        okButton.target = buttonBridge
        okButton.action = #selector(DialogButtonBridge.ok)
        cancelButton.target = buttonBridge
        cancelButton.action = #selector(DialogButtonBridge.cancel)

        panel.contentView = container
        panel.center()

        NSApp.runModal(for: panel)
        panel.orderOut(nil)
        return applied
    }
}

/// Bridges an `NSSlider`'s target/action to a closure — `NSControl.target`
/// is `weak`, so every call site keeps its bridge instance alive via a local
/// `let`/`var` for the duration of its own dialog's modal loop (mirroring
/// `ColorPickerDialog.CopyButtonHandler`'s identical need for its single
/// "コピー" button, generalized here to a `Double` payload so one bridge type
/// covers every slider across all four dialogs above instead of one bespoke
/// `NSObject` subclass per control).
private final class SliderActionBridge: NSObject {
    private let onChange: (Double) -> Void

    init(_ onChange: @escaping (Double) -> Void) {
        self.onChange = onChange
    }

    @objc func changed(_ sender: NSSlider) {
        onChange(sender.doubleValue)
    }
}

/// Same bridging need as `SliderActionBridge`, for an `NSPopUpButton`'s
/// selected item index instead of an `NSSlider`'s value.
private final class PopUpActionBridge: NSObject {
    private let onSelect: (Int) -> Void

    init(_ onSelect: @escaping (Int) -> Void) {
        self.onSelect = onSelect
    }

    @objc func changed(_ sender: NSPopUpButton) {
        onSelect(sender.indexOfSelectedItem)
    }
}

/// Same bridging need as `SliderActionBridge`/`PopUpActionBridge`, for
/// `runModalPanel`'s own "OK" / "キャンセル" button row.
private final class DialogButtonBridge: NSObject {
    private let onOK: () -> Void
    private let onCancel: () -> Void

    init(onOK: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.onOK = onOK
        self.onCancel = onCancel
    }

    @objc func ok() { onOK() }
    @objc func cancel() { onCancel() }
}

/// The トーンカーブ dialog's graph (issue #12): draws the diagonal reference
/// line, grid, and the curve itself — sampled from `ToneCurve.lut()`, the
/// exact same lookup table `ImageAdjustments.apply` uses, so the drawn curve
/// is never an approximation of what the live preview is actually doing to
/// the pixels — plus each draggable control point. Works in a fixed 256x256
/// point coordinate space matching `ToneCurve`'s own `0...255` input/output
/// range 1:1 (no separate scale factor to thread through hit-testing).
final class ToneCurveGraphView: NSView {
    private static let graphSize: CGFloat = 256
    private static let margin: CGFloat = 12
    private static let pointHitRadius: CGFloat = 8

    var curve: ImageAdjustments.ToneCurve = .identity {
        didSet { needsDisplay = true }
    }
    /// Fired on every point add/move (issue #12's live preview) — not just
    /// once at mouse-up — same "fire on every intermediate change, not only
    /// at the gesture's end" contract every slider bridge above already
    /// follows for its own control.
    var onChange: ((ImageAdjustments.ToneCurve) -> Void)?

    private var draggedPointIndex: Int?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.graphSize + Self.margin * 2, height: Self.graphSize + Self.margin * 2)
    }

    override var acceptsFirstResponder: Bool { true }

    // Deliberately left at AppKit's own default (bottom-left origin, y grows
    // upward) rather than flipped like `CanvasView` — this graph reads
    // "higher on screen = higher output value", the same orientation
    // Photoshop's own curve editor uses, which is the opposite of
    // `PixelCanvas`'s top-left-origin pixel-space convention that the rest
    // of this app is built around. That convention doesn't apply here: this
    // view never touches `PixelCanvas` coordinates directly, only
    // `ToneCurve`'s own `0...255` input/output space.
    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let origin = CGPoint(x: Self.margin, y: Self.margin)
        let graphRect = CGRect(x: origin.x, y: origin.y, width: Self.graphSize, height: Self.graphSize)

        context.setFillColor(NSColor.white.cgColor)
        context.fill(graphRect)
        context.setStrokeColor(NSColor.gray.cgColor)
        context.setLineWidth(1)
        context.stroke(graphRect)

        context.setStrokeColor(NSColor.lightGray.cgColor)
        context.setLineWidth(0.5)
        context.beginPath()
        for i in 1..<4 {
            let offset = Self.graphSize * CGFloat(i) / 4
            context.move(to: CGPoint(x: origin.x + offset, y: origin.y))
            context.addLine(to: CGPoint(x: origin.x + offset, y: origin.y + Self.graphSize))
            context.move(to: CGPoint(x: origin.x, y: origin.y + offset))
            context.addLine(to: CGPoint(x: origin.x + Self.graphSize, y: origin.y + offset))
        }
        context.strokePath()

        context.setStrokeColor(NSColor.lightGray.cgColor)
        context.setLineDash(phase: 0, lengths: [4, 3])
        context.beginPath()
        context.move(to: CGPoint(x: origin.x, y: origin.y))
        context.addLine(to: CGPoint(x: origin.x + Self.graphSize, y: origin.y + Self.graphSize))
        context.strokePath()
        context.setLineDash(phase: 0, lengths: [])

        let lut = curve.lut()
        context.setStrokeColor(NSColor.systemBlue.cgColor)
        context.setLineWidth(1.5)
        context.beginPath()
        for x in 0...255 {
            let point = CGPoint(x: origin.x + CGFloat(x), y: origin.y + CGFloat(lut[x]))
            if x == 0 {
                context.move(to: point)
            } else {
                context.addLine(to: point)
            }
        }
        context.strokePath()

        context.setFillColor(NSColor.systemBlue.cgColor)
        for point in curve.points {
            let center = CGPoint(x: origin.x + CGFloat(point.input), y: origin.y + CGFloat(point.output))
            context.fillEllipse(in: CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6))
        }
    }

    private func graphCoordinate(from viewPoint: NSPoint) -> ImageAdjustments.ToneCurvePoint {
        let x = Int(max(0, min(255, (viewPoint.x - Self.margin).rounded())))
        let y = Int(max(0, min(255, (viewPoint.y - Self.margin).rounded())))
        return ImageAdjustments.ToneCurvePoint(x, y)
    }

    private func indexOfPoint(near viewPoint: NSPoint) -> Int? {
        for (index, point) in curve.points.enumerated() {
            let center = NSPoint(x: Self.margin + CGFloat(point.input), y: Self.margin + CGFloat(point.output))
            if hypot(viewPoint.x - center.x, viewPoint.y - center.y) <= Self.pointHitRadius {
                return index
            }
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if let index = indexOfPoint(near: location) {
            draggedPointIndex = index
            return
        }

        // Clicking empty graph space adds a new control point there (issue
        // #12) — Photoshop's own curve editor behavior: no separate "add
        // point" gesture is needed.
        let newPoint = graphCoordinate(from: location)
        var points = curve.points
        points.append(newPoint)
        points.sort { $0.input < $1.input }
        curve.points = points
        draggedPointIndex = points.firstIndex { $0.input == newPoint.input && $0.output == newPoint.output }
        onChange?(curve)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let index = draggedPointIndex else { return }
        let location = convert(event.locationInWindow, from: nil)
        let proposed = graphCoordinate(from: location)
        var points = curve.points
        let clampedInput = ImageAdjustments.ToneCurve.clampedInput(forPointAt: index, proposedInput: proposed.input, in: points)
        points[index] = ImageAdjustments.ToneCurvePoint(clampedInput, proposed.output)
        curve.points = points
        onChange?(curve)
    }

    override func mouseUp(with event: NSEvent) {
        draggedPointIndex = nil
    }
}
