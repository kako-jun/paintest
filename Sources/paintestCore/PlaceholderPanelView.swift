import AppKit

/// A reusable "frame only" panel for right-column panels whose real content
/// lands in a later issue (issue #7: プロパティ / ヒストリー). Shows just a
/// title label so the panel group visually reads as three distinct panels
/// (レイヤー / プロパティ / ヒストリー) even before those two have any real
/// content — the same "枠だけ先に用意" treatment issue #7 gives the option
/// bar.
final class PlaceholderPanelView: NSView {
    // Both match `LayerPanelView.panelPadding` (issue #7 self-review
    // should-3, extended to the leading edge in re-review): the two panels
    // sit stacked in the same right-hand column, so their title labels need
    // the same top and leading inset to line up instead of drifting a
    // couple points apart.
    private static let titleTopPadding: CGFloat = 6
    private static let titleLeadingPadding: CGFloat = 6

    init(title: String) {
        super.init(frame: .zero)
        wantsLayer = true

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .boldSystemFont(ofSize: 11)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: Self.titleTopPadding),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.titleLeadingPadding)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
