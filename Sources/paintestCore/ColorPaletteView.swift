import AppKit

/// The current foreground/background color indicator that classic Paint
/// shows at the bottom-left, as two overlapping squares. Purely decorative
/// for issue #2 — actual color selection is out of scope (#5).
final class CurrentColorIndicatorView: NSView {
    var foregroundColor: NSColor = .black
    var backgroundColor: NSColor = .white

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let side: CGFloat = 20
        let backRect = CGRect(x: bounds.midX - 4, y: bounds.midY - 4, width: side, height: side)
        let frontRect = CGRect(x: bounds.midX - side + 4, y: bounds.midY - side + 4, width: side, height: side)

        context.setFillColor(backgroundColor.cgColor)
        context.fill(backRect)
        context.setStrokeColor(NSColor.black.cgColor)
        context.stroke(backRect)

        context.setFillColor(foregroundColor.cgColor)
        context.fill(frontRect)
        context.setStrokeColor(NSColor.black.cgColor)
        context.stroke(frontRect)
    }
}

/// The two-row color swatch strip along the bottom of the window (issue
/// #2). Each swatch is a plain colored `NSView` with no click handling —
/// clicking to change the active color is #5's scope, not this one.
final class ColorPaletteView: NSView {
    private static let swatchSide: CGFloat = 18

    // 14 columns x 2 rows, muted shades on top and vivid tones below —
    // an approximation of the classic 28-color Paint palette. Exact hues
    // don't matter here, only the "two rows of small color chips" impression.
    private static let rows: [[NSColor]] = [
        [
            .black, .darkGray,
            NSColor(calibratedRed: 0.5, green: 0, blue: 0, alpha: 1),
            NSColor(calibratedRed: 0.5, green: 0.5, blue: 0, alpha: 1),
            NSColor(calibratedRed: 0, green: 0.5, blue: 0, alpha: 1),
            NSColor(calibratedRed: 0, green: 0.5, blue: 0.5, alpha: 1),
            NSColor(calibratedRed: 0, green: 0, blue: 0.5, alpha: 1),
            NSColor(calibratedRed: 0.5, green: 0, blue: 0.5, alpha: 1),
            NSColor(calibratedRed: 0.5, green: 0.25, blue: 0, alpha: 1),
            NSColor(calibratedRed: 0.75, green: 0.75, blue: 0.5, alpha: 1),
            NSColor(calibratedRed: 0, green: 0.25, blue: 0.25, alpha: 1),
            NSColor(calibratedRed: 0, green: 0, blue: 0.25, alpha: 1),
            NSColor(calibratedRed: 0.25, green: 0, blue: 0.25, alpha: 1),
            NSColor(calibratedRed: 0.4, green: 0.2, blue: 0, alpha: 1)
        ],
        [
            .white, .lightGray, .red, .yellow, .green, .cyan, .blue, .magenta,
            NSColor(calibratedRed: 1, green: 0.65, blue: 0, alpha: 1),
            NSColor(calibratedRed: 1, green: 1, blue: 0.6, alpha: 1),
            NSColor(calibratedRed: 0.5, green: 1, blue: 0.5, alpha: 1),
            NSColor(calibratedRed: 0.6, green: 1, blue: 1, alpha: 1),
            NSColor(calibratedRed: 0.6, green: 0.6, blue: 1, alpha: 1),
            NSColor(calibratedRed: 1, green: 0.6, blue: 1, alpha: 1)
        ]
    ]

    init() {
        super.init(frame: .zero)
        buildSwatches()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildSwatches() {
        let grid = NSGridView(numberOfColumns: Self.rows[0].count, rows: 0)
        grid.rowSpacing = 1
        grid.columnSpacing = 1
        grid.translatesAutoresizingMaskIntoConstraints = false

        for row in Self.rows {
            grid.addRow(with: row.map(makeSwatch))
        }
        for column in 0..<Self.rows[0].count {
            grid.column(at: column).width = Self.swatchSide
        }

        addSubview(grid)
        NSLayoutConstraint.activate([
            // constant: 0, not some extra padding (issue #22 follow-up): the
            // gap this panel visually needs on its left is already supplied
            // by `CurrentColorIndicatorView`'s own drawing, not by padding
            // here. That view is `colorBarHeight`-independent-width 48pt,
            // and draws its two 20pt swatches centered, so their bounding
            // box (32pt) sits with an 8pt margin on *both* of the
            // indicator's own edges. Adding padding here on top of that
            // trailing 8pt would make the indicator-to-palette gap wider
            // than the color-bar's leading edge to the indicator's drawn
            // square — an asymmetry kako-jun flagged. Zero here keeps both
            // gaps equal at 8pt.
            grid.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0),
            grid.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    private func makeSwatch(color: NSColor) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = color.cgColor
        view.layer?.borderColor = NSColor.gray.cgColor
        view.layer?.borderWidth = 0.5
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: Self.swatchSide),
            view.heightAnchor.constraint(equalToConstant: Self.swatchSide)
        ])
        return view
    }
}
