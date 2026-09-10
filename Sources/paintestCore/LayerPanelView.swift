import AppKit

/// A row in the layer list: a visibility checkbox, a small thumbnail, and
/// the layer's name, with a click-anywhere-on-the-row selection gesture
/// (the checkbox itself intercepts its own clicks, so clicking it toggles
/// visibility without also selecting the row).
private final class LayerRowView: NSView {
    var onSelectRow: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onSelectRow?()
    }
}

/// A vertical `NSStackView` that reports itself as flipped, so its
/// arranged subviews are laid out with the first row pinned to the top of
/// an enclosing scroll view (rather than anchored to the bottom, which is
/// `NSStackView`'s default behavior when there's leftover space).
private final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

/// The layer panel: a scrollable, top-to-bottom list of layer rows
/// (visibility checkbox + thumbnail + name + selection highlight),
/// add/remove/duplicate/reorder buttons, and an opacity slider for the
/// active layer.
///
/// Follows `ToolboxView`/`ColorPaletteView`'s "hand-built AppKit view, no
/// `NSTableView` data source" style. `LayerStack` is the single source of
/// truth: every button here just calls one of its mutating methods, then
/// this view rebuilds its own rows from scratch (`reload()`) and calls
/// `onChange` so the host (`AppDelegate`) can redraw the canvas and mark
/// the document dirty. Selecting a different row (`selectLayer(at:)`) is
/// the one exception: it doesn't touch layer content, so it calls
/// `onSelectionChanged` instead, which the host wires to a redraw only
/// (issue #4 self-review must). No finer-grained notification machinery
/// than that split is needed for a panel this size.
final class LayerPanelView: NSView {
    private(set) var layerStack: LayerStack
    /// Fired when a layer's actual content, structure, or persisted
    /// attributes change (add/remove/duplicate/reorder/opacity/visibility).
    /// These are the operations that should mark the document dirty.
    var onChange: (() -> Void)?
    /// Fired when only the *active layer selection* changes (clicking a
    /// different row). This never alters anything that gets written to the
    /// `.paintestdoc` file, so it must NOT be treated as a content edit —
    /// the host should redraw the canvas (the active-layer highlight/target
    /// changed) but must not mark the document dirty (issue #4 self-review
    /// must: selecting a different layer in a saved document was wrongly
    /// popping the unsaved-changes dialog).
    var onSelectionChanged: (() -> Void)?
    /// Fired right before `layerStack.activeLayerIndex` is about to change
    /// as a result of a user action here — `selectLayer(at:)` (clicking a
    /// different row) and the add/duplicate/remove buttons, all of which
    /// reassign `activeLayerIndex` themselves (see `LayerStack.addLayer()`/
    /// `duplicateLayer(at:)`/`removeLayer(at:)`) — but NOT
    /// `moveLayerUpTapped()`/`moveLayerDownTapped()` (reordering leaves the
    /// active layer *object* unchanged, even though its numeric index
    /// shifts) or `visibilityToggled(_:)`/`opacitySliderChanged()`
    /// (attribute-only edits that never touch which layer is active).
    ///
    /// Exists so `AppDelegate` can auto-confirm an in-progress layer
    /// transform before its target layer is swapped out from under it
    /// (issue #9 review must-1) — `CanvasView.commitLayerTransform()`
    /// writes into whatever `layerStack.activeLayer` is *at confirm time*,
    /// so it has to run while that's still the layer the transform actually
    /// belongs to, not after this panel has already moved on to a
    /// different one. Named "will" (not "did") specifically because the
    /// confirm has to happen before the change, mirroring
    /// `AppDelegate.activateActiveDocument()`'s own placement of its
    /// auto-confirm check ahead of `canvasView.replaceLayerStack(...)`.
    var willChangeActiveLayer: (() -> Void)?

    private let rowsStack = FlippedStackView()
    private let opacitySlider = NSSlider(value: 100, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let opacityValueLabel = NSTextField(labelWithString: "100%")
    /// Blend-mode selector for the active layer (issue #37). Populated once
    /// from `LayerBlendMode.allCases` in `buildLayout()` and never rebuilt —
    /// only its selection needs to track the active layer, which `reload()`
    /// updates like it does `opacitySlider`.
    private let blendModePopup = NSPopUpButton(frame: .zero, pullsDown: false)

    private static let thumbnailSide: CGFloat = 28
    private static let selectedRowColor = NSColor.selectedControlColor
    private static let panelPadding: CGFloat = 6

    init(layerStack: LayerStack) {
        self.layerStack = layerStack
        super.init(frame: .zero)
        buildLayout()
        reload()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Points this panel at a different document (new canvas / opened
    /// file) and rebuilds the row list for it.
    func replaceLayerStack(_ newLayerStack: LayerStack) {
        layerStack = newLayerStack
        reload()
    }

    /// Repoints `layerStack` at a new instance *without* rebuilding the row
    /// list (issue #21 review should-2) — for the one caller
    /// (`AppDelegate.onLayerStackReplaced`, wired for `CanvasView`'s crop
    /// tool) that's always immediately followed by its own `reload()` call
    /// moments later (`onLayerContentChanged`'s handler, which
    /// `CanvasView.commitCrop()` fires right after `onLayerStackReplaced`,
    /// within the same method). Calling `replaceLayerStack(_:)` there
    /// instead would rebuild the identical row list twice for one crop
    /// commit. Every other caller that swaps in a different `LayerStack`
    /// (document/tab switches, undo/redo, history jumps) has no such
    /// guaranteed follow-up reload and must keep using
    /// `replaceLayerStack(_:)`.
    func setLayerStackReferenceWithoutReload(_ newLayerStack: LayerStack) {
        layerStack = newLayerStack
    }

    // MARK: - Layout

    private func buildLayout() {
        let titleLabel = NSTextField(labelWithString: "レイヤー")
        titleLabel.font = .boldSystemFont(ofSize: 11)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        rowsStack.orientation = .vertical
        rowsStack.spacing = 1
        rowsStack.alignment = .leading
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = rowsStack
        NSLayoutConstraint.activate([
            rowsStack.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            rowsStack.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor)
        ])

        let buttonBar = makeButtonBar()
        buttonBar.translatesAutoresizingMaskIntoConstraints = false

        let blendModeRow = makeBlendModeRow()
        blendModeRow.translatesAutoresizingMaskIntoConstraints = false

        let opacityRow = makeOpacityRow()
        opacityRow.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        addSubview(scrollView)
        addSubview(buttonBar)
        addSubview(blendModeRow)
        addSubview(opacityRow)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: Self.panelPadding),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.panelPadding),

            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.panelPadding),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.panelPadding),
            scrollView.bottomAnchor.constraint(equalTo: buttonBar.topAnchor, constant: -4),

            buttonBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.panelPadding),
            buttonBar.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Self.panelPadding),
            buttonBar.bottomAnchor.constraint(equalTo: blendModeRow.topAnchor, constant: -4),

            blendModeRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.panelPadding),
            blendModeRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.panelPadding),
            blendModeRow.bottomAnchor.constraint(equalTo: opacityRow.topAnchor, constant: -4),

            opacityRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.panelPadding),
            opacityRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.panelPadding),
            opacityRow.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.panelPadding)
        ])
    }

    // A single row of small SF Symbols icon buttons (issue #22), matching
    // `ToolboxView`'s established icon-button look (`.smallSquare` bezel,
    // `NSImage(systemSymbolName:)`) instead of the previous two-row text
    // button layout. `accessibilityDescription` on each symbol image keeps
    // the original Japanese label available to VoiceOver even though the
    // button itself now shows only an icon; `toolTip` mirrors it for sighted
    // hover discovery, same as `ToolboxView`.
    private static let buttonBarSide: CGFloat = 28

    private func makeButtonBar() -> NSView {
        let addButton = makeIconButton(symbol: "plus", label: "追加", action: #selector(addLayerTapped))
        let removeButton = makeIconButton(symbol: "minus", label: "削除", action: #selector(removeLayerTapped))
        let duplicateButton = makeIconButton(symbol: "plus.square.on.square", label: "複製", action: #selector(duplicateLayerTapped))
        let moveUpButton = makeIconButton(symbol: "chevron.up", label: "上へ", action: #selector(moveLayerUpTapped))
        let moveDownButton = makeIconButton(symbol: "chevron.down", label: "下へ", action: #selector(moveLayerDownTapped))

        let stack = NSStackView(views: [addButton, removeButton, duplicateButton, moveUpButton, moveDownButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        return stack
    }

    private func makeIconButton(symbol: String, label: String, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage()
        let button = NSButton(image: image, target: self, action: action)
        button.bezelStyle = .smallSquare
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = label
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: Self.buttonBarSide),
            button.heightAnchor.constraint(equalToConstant: Self.buttonBarSide)
        ])
        return button
    }

    // Issue #37: a popup listing every `LayerBlendMode`, showing/changing
    // the active layer's blend mode. Built once here with a fixed item
    // list (`LayerBlendMode.allCases` never changes at runtime), same
    // "build once, only update selection in reload()" split as
    // `opacitySlider`/`opacityValueLabel` below.
    private func makeBlendModeRow() -> NSView {
        let label = NSTextField(labelWithString: "ブレンドモード")
        label.font = .systemFont(ofSize: 10)

        blendModePopup.removeAllItems()
        blendModePopup.addItems(withTitles: LayerBlendMode.allCases.map(\.displayName))
        blendModePopup.target = self
        blendModePopup.action = #selector(blendModePopupChanged)
        blendModePopup.translatesAutoresizingMaskIntoConstraints = false
        blendModePopup.controlSize = .small
        blendModePopup.font = .systemFont(ofSize: 10)

        let stack = NSStackView(views: [label, blendModePopup])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        return stack
    }

    private func makeOpacityRow() -> NSView {
        let label = NSTextField(labelWithString: "不透明度")
        label.font = .systemFont(ofSize: 10)

        opacitySlider.target = self
        opacitySlider.action = #selector(opacitySliderChanged)
        opacitySlider.translatesAutoresizingMaskIntoConstraints = false

        opacityValueLabel.font = .systemFont(ofSize: 10)
        opacityValueLabel.alignment = .right

        let sliderRow = NSStackView(views: [opacitySlider, opacityValueLabel])
        sliderRow.orientation = .horizontal
        sliderRow.spacing = 4
        NSLayoutConstraint.activate([
            opacityValueLabel.widthAnchor.constraint(equalToConstant: 32)
        ])

        let stack = NSStackView(views: [label, sliderRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        return stack
    }

    // MARK: - Row building

    /// Rebuilds every row from the current `layerStack` state. Called after
    /// every mutation instead of trying to patch individual rows in place —
    /// simple and correct beats incremental diffing for a list this size.
    /// Also called externally by `AppDelegate` (via `CanvasView`'s
    /// `onLayerContentChanged`) to refresh thumbnails after pixel edits made
    /// directly on the canvas, which don't go through any of this panel's
    /// own mutating actions below.
    func reload() {
        for view in rowsStack.arrangedSubviews {
            rowsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        // Display order is top-to-bottom in the panel, i.e. the reverse of
        // `layers`' bottom-to-top storage order.
        for index in layerStack.layers.indices.reversed() {
            let row = makeRow(for: index)
            rowsStack.addArrangedSubview(row)
            // Activated only after `row` joins `rowsStack`'s view hierarchy:
            // AppKit can't resolve a common ancestor for this constraint
            // while `row` is still unparented, and activating it any
            // earlier (e.g. inside `makeRow`) throws "no common ancestor".
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        }

        let active = layerStack.activeLayer
        opacitySlider.doubleValue = active.opacity * 100
        opacityValueLabel.stringValue = "\(Int((active.opacity * 100).rounded()))%"
        if let index = LayerBlendMode.allCases.firstIndex(of: active.blendMode) {
            blendModePopup.selectItem(at: index)
        }
    }

    private func makeRow(for index: Int) -> NSView {
        let layer = layerStack.layers[index]
        let isActive = index == layerStack.activeLayerIndex

        let row = LayerRowView()
        row.wantsLayer = true
        row.layer?.backgroundColor = isActive ? Self.selectedRowColor.cgColor : NSColor.clear.cgColor
        row.onSelectRow = { [weak self] in
            self?.selectLayer(at: index)
        }
        row.translatesAutoresizingMaskIntoConstraints = false

        let visibilityCheckbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(visibilityToggled(_:)))
        visibilityCheckbox.state = layer.isVisible ? .on : .off
        visibilityCheckbox.tag = index

        let thumbnail = NSImageView()
        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        if let cgImage = layer.canvas.cgImage {
            thumbnail.image = NSImage(cgImage: cgImage, size: NSSize(width: Self.thumbnailSide, height: Self.thumbnailSide))
        }
        NSLayoutConstraint.activate([
            thumbnail.widthAnchor.constraint(equalToConstant: Self.thumbnailSide),
            thumbnail.heightAnchor.constraint(equalToConstant: Self.thumbnailSide)
        ])

        let nameLabel = NSTextField(labelWithString: layer.name)
        nameLabel.font = isActive ? .boldSystemFont(ofSize: 11) : .systemFont(ofSize: 11)
        nameLabel.lineBreakMode = .byTruncatingTail

        let content = NSStackView(views: [visibilityCheckbox, thumbnail, nameLabel])
        content.orientation = .horizontal
        content.spacing = 4
        content.edgeInsets = NSEdgeInsets(top: 3, left: 4, bottom: 3, right: 4)
        content.translatesAutoresizingMaskIntoConstraints = false

        row.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            content.topAnchor.constraint(equalTo: row.topAnchor),
            content.bottomAnchor.constraint(equalTo: row.bottomAnchor)
        ])

        return row
    }

    private func selectLayer(at index: Int) {
        guard layerStack.layers.indices.contains(index) else { return }
        willChangeActiveLayer?()
        layerStack.activeLayerIndex = index
        reload()
        // Selection only, not a content change (issue #4 self-review must):
        // must not fire `onChange`, or the host will mark the document
        // dirty just because a different row was clicked.
        onSelectionChanged?()
    }

    // MARK: - Actions

    @objc private func addLayerTapped() {
        willChangeActiveLayer?()
        layerStack.addLayer()
        reload()
        onChange?()
    }

    @objc private func removeLayerTapped() {
        willChangeActiveLayer?()
        layerStack.removeLayer(at: layerStack.activeLayerIndex)
        reload()
        onChange?()
    }

    @objc private func duplicateLayerTapped() {
        willChangeActiveLayer?()
        layerStack.duplicateLayer(at: layerStack.activeLayerIndex)
        reload()
        onChange?()
    }

    @objc private func moveLayerUpTapped() {
        let index = layerStack.activeLayerIndex
        guard index + 1 < layerStack.layers.count else { return }
        layerStack.moveLayer(from: index, to: index + 1)
        reload()
        onChange?()
    }

    @objc private func moveLayerDownTapped() {
        let index = layerStack.activeLayerIndex
        guard index - 1 >= 0 else { return }
        layerStack.moveLayer(from: index, to: index - 1)
        reload()
        onChange?()
    }

    @objc private func visibilityToggled(_ sender: NSButton) {
        layerStack.setVisibility(sender.state == .on, at: sender.tag)
        onChange?()
    }

    // Unlike every other action above, this one intentionally does NOT call
    // `reload()` — opacity isn't shown anywhere in a row today, so rebuilding
    // the rows would be pure wasted work on every slider tick, and skipping
    // it doesn't leave any visible state stale. `onChange?()` alone is
    // enough to get the canvas repainted at the new opacity. If a per-row
    // opacity indicator is ever added to `makeRow(for:)`, this will need a
    // `reload()` call too, or that indicator will silently go stale while
    // dragging the slider.
    @objc private func opacitySliderChanged() {
        layerStack.setOpacity(opacitySlider.doubleValue / 100, at: layerStack.activeLayerIndex)
        opacityValueLabel.stringValue = "\(Int(opacitySlider.doubleValue.rounded()))%"
        onChange?()
    }

    // Same "no reload() needed" reasoning as `opacitySliderChanged` above —
    // blend mode isn't shown anywhere in a row, so only the canvas redraw
    // `onChange?()` triggers needs to happen.
    @objc private func blendModePopupChanged() {
        guard blendModePopup.indexOfSelectedItem >= 0,
              LayerBlendMode.allCases.indices.contains(blendModePopup.indexOfSelectedItem) else { return }
        let mode = LayerBlendMode.allCases[blendModePopup.indexOfSelectedItem]
        layerStack.setBlendMode(mode, at: layerStack.activeLayerIndex)
        onChange?()
    }
}
