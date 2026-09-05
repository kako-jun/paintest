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
/// `onChange` so the host (`AppDelegate`) can mark the canvas for redraw.
/// No finer-grained notification machinery than that is needed for a panel
/// this size.
final class LayerPanelView: NSView {
    private(set) var layerStack: LayerStack
    var onChange: (() -> Void)?

    private let rowsStack = FlippedStackView()
    private let opacitySlider = NSSlider(value: 100, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let opacityValueLabel = NSTextField(labelWithString: "100%")

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

        let opacityRow = makeOpacityRow()
        opacityRow.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        addSubview(scrollView)
        addSubview(buttonBar)
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
            buttonBar.bottomAnchor.constraint(equalTo: opacityRow.topAnchor, constant: -4),

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
            rowsStack.addArrangedSubview(makeRow(for: index))
        }

        let active = layerStack.activeLayer
        opacitySlider.doubleValue = active.opacity * 100
        opacityValueLabel.stringValue = "\(Int((active.opacity * 100).rounded()))%"
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
        layerStack.activeLayerIndex = index
        reload()
        onChange?()
    }

    // MARK: - Actions

    @objc private func addLayerTapped() {
        layerStack.addLayer()
        reload()
        onChange?()
    }

    @objc private func removeLayerTapped() {
        layerStack.removeLayer(at: layerStack.activeLayerIndex)
        reload()
        onChange?()
    }

    @objc private func duplicateLayerTapped() {
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
}
