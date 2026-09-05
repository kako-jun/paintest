import AppKit

/// A reusable "frame only" panel for right-column panels whose real content
/// lands in a later issue (issue #7: プロパティ / ヒストリー). Shows just a
/// title label so the panel group visually reads as three distinct panels
/// (レイヤー / プロパティ / ヒストリー) even before those two have any real
/// content — the same "枠だけ先に用意" treatment issue #7 gives the option
/// bar.
final class PlaceholderPanelView: NSView {
    init(title: String) {
        super.init(frame: .zero)
        wantsLayer = true

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .boldSystemFont(ofSize: 11)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
