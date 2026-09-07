import AppKit

/// A row in the history list: a label showing the entry's recorded action
/// name, with a click-anywhere-on-the-row jump gesture — the same
/// click-to-act pattern as `LayerRowView` in `LayerPanelView.swift`.
private final class HistoryRowView: NSView {
    var onSelectRow: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onSelectRow?()
    }
}

/// A vertical `NSStackView` that reports itself as flipped, so its arranged
/// subviews lay out with the first row pinned to the top of the enclosing
/// scroll view — same trick as `LayerPanelView`'s private `FlippedStackView`
/// (each file keeps its own copy rather than sharing one, matching this
/// app's existing per-panel-file convention for these small AppKit helper
/// views).
private final class FlippedHistoryStackView: NSStackView {
    override var isFlipped: Bool { true }
}

/// The history panel (issue #19 round 2): a scrollable, top-to-bottom list
/// of every recorded `HistoryEntry`, with the current position highlighted
/// and click-to-jump on each row.
///
/// Follows `LayerPanelView`'s "hand-built AppKit view, no `NSTableView` data
/// source" style: `AppDelegate` calls `reload(entries:currentIndex:)` after
/// every operation that can move or extend the history (recording a new
/// checkpoint, undo, redo, a jump from this very panel, or switching to a
/// different document's tab), and this view just rebuilds its rows from
/// scratch each time — simple and correct beats incremental diffing for a
/// list this size, same reasoning as `LayerPanelView.reload()`.
///
/// Display order is oldest-to-newest, top-to-bottom (entry 0, "初期状態", is
/// always the top row) — the opposite convention from `LayerPanelView`,
/// which shows layers in reverse-storage order because layers are stacked
/// bottom-to-top on the canvas. History has no such visual stacking to
/// mirror; oldest-on-top/newest-on-bottom instead matches Photoshop's own
/// History panel, where a linear list simply grows downward as new entries
/// are recorded and undo/redo moves the highlighted "current" row up/down
/// through it.
final class HistoryPanelView: NSView {
    private(set) var entries: [HistoryEntry]
    private(set) var currentIndex: Int
    /// Fired when a row is clicked, with that row's index into `entries`.
    /// The host (`AppDelegate`) is responsible for actually applying the
    /// jump (via `HistoryManager.jump(to:)`) and calling `reload(...)`
    /// afterward — this view never mutates history state itself, same
    /// division of responsibility as `LayerPanelView.onChange`/
    /// `onSelectionChanged`.
    var onJumpToIndex: ((Int) -> Void)?

    private let rowsStack = FlippedHistoryStackView()

    private static let selectedRowColor = NSColor.selectedControlColor
    private static let panelPadding: CGFloat = 6

    init(entries: [HistoryEntry], currentIndex: Int) {
        self.entries = entries
        self.currentIndex = currentIndex
        super.init(frame: .zero)
        buildLayout()
        reload(entries: entries, currentIndex: currentIndex)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Layout

    private func buildLayout() {
        let titleLabel = NSTextField(labelWithString: "ヒストリー")
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

        addSubview(titleLabel)
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: Self.panelPadding),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.panelPadding),

            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.panelPadding),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.panelPadding),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.panelPadding)
        ])
    }

    // MARK: - Row building

    /// Rebuilds every row from `entries`/`currentIndex` — called by
    /// `AppDelegate` after every operation that can change either (see this
    /// type's own doc comment for the full list of call sites).
    func reload(entries: [HistoryEntry], currentIndex: Int) {
        self.entries = entries
        self.currentIndex = currentIndex

        for view in rowsStack.arrangedSubviews {
            rowsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        for index in entries.indices {
            let row = makeRow(for: index)
            rowsStack.addArrangedSubview(row)
            // Activated only after `row` joins `rowsStack`'s view hierarchy —
            // same "no common ancestor" constraint-activation-order note as
            // `LayerPanelView.reload()`.
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        }
    }

    private func makeRow(for index: Int) -> NSView {
        let entry = entries[index]
        let isCurrent = index == currentIndex

        let row = HistoryRowView()
        row.wantsLayer = true
        row.layer?.backgroundColor = isCurrent ? Self.selectedRowColor.cgColor : NSColor.clear.cgColor
        row.onSelectRow = { [weak self] in
            self?.onJumpToIndex?(index)
        }
        row.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: entry.label)
        label.font = isCurrent ? .boldSystemFont(ofSize: 11) : .systemFont(ofSize: 11)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        row.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -4),
            label.topAnchor.constraint(equalTo: row.topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -3)
        ])

        return row
    }
}
