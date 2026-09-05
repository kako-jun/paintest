import AppKit

/// A row in the document tab strip: click-anywhere-on-the-row selection,
/// same pattern as `LayerPanelView`'s `LayerRowView` (the close button
/// intercepts its own clicks before they reach this).
///
/// Also exposes itself as an `NSAccessibility` button (issue #15 review
/// round 2): a plain `NSView` with only `mouseDown` overridden has no way
/// to be "clicked" from outside real mouse hardware — VoiceOver, UI test
/// automation, and `osascript`'s `click`/`AXPress` all go through the
/// accessibility tree, which this view didn't participate in at all.
/// `accessibilityPerformPress()` runs the exact same selection logic as
/// `mouseDown`, via the shared `selectRow()` method, so neither path can
/// drift from the other.
private final class DocumentTabRowView: NSView {
    var onSelectRow: (() -> Void)?

    /// The document this row represents, surfaced as the row's
    /// accessibility label so VoiceOver/AX clients can tell rows apart.
    var displayName: String = ""

    override func isAccessibilityElement() -> Bool {
        true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .button
    }

    override func accessibilityLabel() -> String? {
        displayName
    }

    override func mouseDown(with event: NSEvent) {
        selectRow()
    }

    @discardableResult
    override func accessibilityPerformPress() -> Bool {
        selectRow()
        return true
    }

    private func selectRow() {
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

    /// The "+" new-document button (kako-jun review on #15: it should be
    /// the same width as a tab row, and sit directly below the last tab
    /// rather than pinned to the panel's top edge). It's built once in
    /// `buildLayout()` and re-appended as `rowsStack`'s last arranged
    /// subview on every `reload()`, so it rides along with the row list
    /// instead of living outside the stack.
    private let addButton = NSButton()

    private static let thumbnailSide: CGFloat = 28
    private static let selectedRowColor = NSColor.selectedControlColor
    private static let padding: CGFloat = 4
    /// Extra vertical gap between the last tab row and the "+" button,
    /// on top of `rowsStack.spacing` (which stays tight between tab rows
    /// themselves) — kako-jun review on #15.
    private static let addButtonTopSpacing: CGFloat = 8

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
        addButton.title = "+"
        addButton.target = self
        addButton.action = #selector(addTapped)
        addButton.bezelStyle = .rounded
        addButton.font = .boldSystemFont(ofSize: 13)
        addButton.toolTip = "新規ドキュメント"
        addButton.translatesAutoresizingMaskIntoConstraints = false

        rowsStack.orientation = .vertical
        rowsStack.spacing = 1
        rowsStack.alignment = .leading
        // Gap between the panel's top edge and the first tab row (kako-jun
        // review on #15). Left/right/bottom stay 0: the horizontal insets
        // are unwanted (rows are pinned to `rowsStack`'s full width via the
        // per-row constraint in `reload()`, so a nonzero left/right inset
        // here would make `alignment = .leading` start each row's leading
        // edge inside that inset while its width constraint still spans
        // the whole stack, pushing it past the trailing edge), and no
        // bottom gap after the "+" button was requested.
        rowsStack.edgeInsets = NSEdgeInsets(top: Self.padding, left: 0, bottom: 0, right: 0)
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

        addSubview(scrollView)

        // `addButton` is no longer a sibling pinned above `scrollView`: it's
        // appended as `rowsStack`'s last arranged subview in `reload()`, so
        // the stack (rows + the "+" button) now fills the whole panel.
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
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
        var lastRow: NSView?
        for index in documentManager.documents.indices {
            let row = makeRow(for: index)
            rowsStack.addArrangedSubview(row)
            // `rowsStack.alignment = .leading` doesn't stretch arranged
            // subviews to the stack's full width — each row would otherwise
            // size itself to its own content (thumbnail + name + close
            // button), so rows with a longer `displayName` end up wider
            // than rows with a shorter one. Since `content` inside the row
            // (see `makeRow(for:)`) is pinned to the row's own
            // leading/trailing edges, that made the close button's
            // x-position drift from row to row instead of staying
            // right-aligned across the whole tab strip. Pinning each row's
            // width to `rowsStack`'s width keeps every row (and therefore
            // every close button) the same width regardless of name
            // length. This has to happen here, after `addArrangedSubview`,
            // rather than inside `makeRow(for:)`: activating a constraint
            // between `row` and `rowsStack` before `row` is actually in
            // `rowsStack`'s view hierarchy throws "no common ancestor".
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
            lastRow = row
        }
        // The "+" button rides along as the stack's last row (kako-jun
        // review on #15): about the same width as a tab, sitting right
        // below the last one instead of pinned to the panel's top edge.
        // It's wrapped in a fresh container each `reload()` (rather than
        // added to `rowsStack` directly) purely to give it a left inset to
        // match the tabs' own left padding — `addButton` itself is a
        // stored property re-used across reloads, so its target/action/
        // tooltip only need to be set up once, in `buildLayout()`.
        let addButtonRow = makeAddButtonRow()
        rowsStack.addArrangedSubview(addButtonRow)
        addButtonRow.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        if let lastRow {
            // Extra breathing room between the last tab and the "+" button,
            // on top of `rowsStack.spacing` (which stays tight between the
            // tab rows themselves).
            rowsStack.setCustomSpacing(Self.addButtonTopSpacing, after: lastRow)
        }
    }

    /// Wraps the persistent `addButton` in a plain container so it can have
    /// a left inset (kako-jun review on #15) without needing that inset to
    /// apply to every tab row too. Called fresh on every `reload()`, since
    /// the container itself (unlike `addButton`) is torn down along with
    /// the rows at the top of that method.
    private func makeAddButtonRow() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(addButton)
        NSLayoutConstraint.activate([
            addButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.padding),
            addButton.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            addButton.topAnchor.constraint(equalTo: container.topAnchor),
            addButton.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    private func makeRow(for index: Int) -> NSView {
        let document = documentManager.documents[index]
        let isActive = index == documentManager.activeDocumentIndex

        let row = DocumentTabRowView()
        row.wantsLayer = true
        row.layer?.backgroundColor = isActive ? Self.selectedRowColor.cgColor : NSColor.clear.cgColor
        row.displayName = document.displayName
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
        // `NSStackView`'s default `distribution` is `.gravityAreas`, which
        // doesn't stretch arranged subviews to fill the stack's width —
        // instead it just centers the (intrinsically-sized) content block
        // within any leftover space. With `content` pinned to `row`'s full
        // width below, that meant a short `displayName` left a lot of
        // slack that got split evenly on both sides of the whole
        // thumbnail+label+button group, shifting `closeButton` left by
        // however much slack there was — the same "×" drifts left" bug
        // this fix targets, just one layer further in than the row-width
        // issue above. `.fill` instead stretches `content`'s flexible
        // member (`nameLabel`, the only one without a fixed-width
        // constraint) to absorb all the slack, so `thumbnail` and
        // `closeButton` stay pinned to their fixed offsets from the
        // leading/trailing edges regardless of name length.
        content.distribution = .fill
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
