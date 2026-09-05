import AppKit

/// A row in the document tab strip: click-anywhere-on-the-row selection,
/// same pattern as `LayerPanelView`'s `LayerRowView` (the close button
/// intercepts its own clicks before they reach this).
private final class DocumentTabRowView: NSView {
    var onSelectRow: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onSelectRow?()
    }
}

/// A vertical `NSStackView` that reports itself as flipped, so row 0 sits
/// at the top of the tab strip instead of the bottom. Same trick as
/// `LayerPanelView`'s `FlippedStackView`.
private final class FlippedTabStackView: NSStackView {
    override var isFlipped: Bool { true }
}

/// The left-edge vertical document tab strip (issue #15): one row per open
/// `Document` (thumbnail + display name + close button), in the style of
/// Microsoft Edge's vertical tabs rather than Photoshop's horizontal tabs
/// along the top.
///
/// Follows `ToolboxView`/`ColorPaletteView`/`LayerPanelView`'s "hand-built
/// AppKit view, no data source" style. `DocumentManager` is the single
/// source of truth: every action here calls straight into it, then this
/// view rebuilds its own rows from scratch and calls `onSelect`/`onClose`
/// so the host (`AppDelegate`) can swap the canvas/layer panel over to the
/// newly active document.
final class DocumentTabBarView: NSView {
    private(set) var documentManager: DocumentManager
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var onNewDocumentRequested: (() -> Void)?

    private let rowsStack = FlippedTabStackView()

    private static let thumbnailSide: CGFloat = 28
    private static let selectedRowColor = NSColor.selectedControlColor
    private static let padding: CGFloat = 4

    init(documentManager: DocumentManager) {
        self.documentManager = documentManager
        super.init(frame: .zero)
        buildLayout()
        reload()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Layout

    private func buildLayout() {
        let addButton = NSButton(title: "+", target: self, action: #selector(addTapped))
        addButton.bezelStyle = .rounded
        addButton.font = .boldSystemFont(ofSize: 13)
        addButton.toolTip = "新規ドキュメント"
        addButton.translatesAutoresizingMaskIntoConstraints = false

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

        addSubview(addButton)
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            addButton.topAnchor.constraint(equalTo: topAnchor, constant: Self.padding),
            addButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padding),
            addButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.padding),

            scrollView.topAnchor.constraint(equalTo: addButton.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    // MARK: - Row building

    /// Rebuilds every row from the current `documentManager` state, the
    /// same "simple rebuild over incremental diffing" approach
    /// `LayerPanelView.reload()` uses.
    func reload() {
        for view in rowsStack.arrangedSubviews {
            rowsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for index in documentManager.documents.indices {
            rowsStack.addArrangedSubview(makeRow(for: index))
        }
    }

    private func makeRow(for index: Int) -> NSView {
        let document = documentManager.documents[index]
        let isActive = index == documentManager.activeDocumentIndex

        let row = DocumentTabRowView()
        row.wantsLayer = true
        row.layer?.backgroundColor = isActive ? Self.selectedRowColor.cgColor : NSColor.clear.cgColor
        row.onSelectRow = { [weak self] in
            self?.documentManager.selectDocument(at: index)
            // Not calling `reload()` here: `onSelect` leads back to
            // `AppDelegate.activateActiveDocument()`, which already calls
            // `documentTabBarView.reload()` once the canvas/layer panel have
            // been swapped over. Reloading here too would rebuild every row
            // twice per click (review S2 on #18).
            self?.onSelect?()
        }
        row.translatesAutoresizingMaskIntoConstraints = false

        let thumbnail = NSImageView()
        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        if let cgImage = document.layerStack.compositeImage() {
            thumbnail.image = NSImage(cgImage: cgImage, size: NSSize(width: Self.thumbnailSide, height: Self.thumbnailSide))
        }
        NSLayoutConstraint.activate([
            thumbnail.widthAnchor.constraint(equalToConstant: Self.thumbnailSide),
            thumbnail.heightAnchor.constraint(equalToConstant: Self.thumbnailSide)
        ])

        let nameLabel = NSTextField(labelWithString: document.displayName)
        nameLabel.font = isActive ? .boldSystemFont(ofSize: 10) : .systemFont(ofSize: 10)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let closeButton = NSButton(title: "×", target: self, action: #selector(closeTapped(_:)))
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.font = .systemFont(ofSize: 12)
        closeButton.toolTip = "閉じる"
        closeButton.tag = index
        NSLayoutConstraint.activate([
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16)
        ])

        let content = NSStackView(views: [thumbnail, nameLabel, closeButton])
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

    // MARK: - Actions

    @objc private func addTapped() {
        onNewDocumentRequested?()
    }

    /// Closes a tab unconditionally — no "unsaved changes?" prompt. Issue
    /// #4 (unsaved-changes confirmation) isn't implemented yet, so for now
    /// a tab closes regardless of whether it's been saved. Once #4 lands,
    /// this is the spot to ask before calling `closeDocument(at:)` when the
    /// target document has unsaved edits.
    @objc private func closeTapped(_ sender: NSButton) {
        documentManager.closeDocument(at: sender.tag)
        // Not calling `reload()` here for the same reason as
        // `onSelectRow` above: `onClose` leads back to
        // `AppDelegate.activateActiveDocument()`, which reloads the tab
        // strip itself (review S2 on #18).
        onClose?()
    }
}
