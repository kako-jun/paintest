import AppKit

/// The current foreground/background color indicator that classic Paint
/// shows at the bottom-left, as two overlapping squares (issue #2). Clicking
/// either square picks that color via `ColorPickerDialog` (issue #5); a
/// small "reset to default" button in the free corner above the squares
/// resets both to black/white.
final class CurrentColorIndicatorView: NSView {
    var foregroundColor: NSColor = .black
    var backgroundColor: NSColor = .white

    /// Fired by `mouseDown(with:)` when the click lands inside the
    /// foreground (front) or background (back) square, respectively.
    var onForegroundSwatchTapped: (() -> Void)?
    var onBackgroundSwatchTapped: (() -> Void)?
    /// Fired by the small reset button.
    var onResetToDefaultTapped: (() -> Void)?

    private static let swatchSide: CGFloat = 20

    // Small, borderless, tucked into the corner above the overlapping
    // squares: with `swatchSide` 20, the squares' combined bounding box is
    // vertically centered and 32pt tall (see `swatchRects()`), so any view
    // taller than ~40pt (every real `colorBarHeight` is) leaves an empty
    // strip along the top edge for this button to sit in without
    // overlapping the swatches.
    private let resetButton: NSButton = {
        let image = NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: "既定の色に戻す") ?? NSImage()
        let button = NSButton(image: image, target: nil, action: nil)
        button.isBordered = false
        button.imageScaling = .scaleProportionallyUpOrDown
        button.toolTip = "既定の色に戻す（黒/白）"
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    init() {
        super.init(frame: .zero)
        addSubview(resetButton)
        resetButton.target = self
        resetButton.action = #selector(resetTapped)
        NSLayoutConstraint.activate([
            resetButton.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            resetButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            resetButton.widthAnchor.constraint(equalToConstant: 12),
            resetButton.heightAnchor.constraint(equalToConstant: 12)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func resetTapped() {
        onResetToDefaultTapped?()
    }

    /// The two overlapping squares' rects, in this view's own coordinate
    /// space. Shared between `draw(_:)` and `mouseDown(with:)` (issue #5)
    /// so the click hit-test always matches what's actually drawn.
    private func swatchRects() -> (front: CGRect, back: CGRect) {
        let side = Self.swatchSide
        let back = CGRect(x: bounds.midX - 4, y: bounds.midY - 4, width: side, height: side)
        let front = CGRect(x: bounds.midX - side + 4, y: bounds.midY - side + 4, width: side, height: side)
        return (front, back)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let rects = swatchRects()
        // Front is drawn on top of back, so it's checked first.
        if rects.front.contains(point) {
            onForegroundSwatchTapped?()
        } else if rects.back.contains(point) {
            onBackgroundSwatchTapped?()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let rects = swatchRects()

        context.setFillColor(backgroundColor.cgColor)
        context.fill(rects.back)
        context.setStrokeColor(NSColor.black.cgColor)
        context.stroke(rects.back)

        context.setFillColor(foregroundColor.cgColor)
        context.fill(rects.front)
        context.setStrokeColor(NSColor.black.cgColor)
        context.stroke(rects.front)
    }
}

/// The color swatch strip along the bottom of the window (issue #2): the
/// classic 28-color palette (2 static rows) plus a third row of recently
/// used colors that grows/reshuffles as the user picks colors (issue #5).
/// Left-clicking a swatch picks it as the foreground color; right-clicking
/// picks it as the background color.
final class ColorPaletteView: NSView {
    // `fileprivate` (not `private`) so `ColorSwatchView`, a separate type
    // declared below in this same file, can size itself identically.
    fileprivate static let swatchSide: CGFloat = 18

    /// How many colors `updatedRecentColors(adding:to:capacity:)` keeps —
    /// shared with `AppDelegate`, which owns the actual `recentColors`
    /// array (issue #5).
    static let recentColorsCapacity = 14

    /// Fired when a swatch (classic palette or recent-colors row) is
    /// clicked: `false` for a left-click (foreground), `true` for a
    /// right-click (background).
    var onSwatchSelected: ((NSColor, Bool) -> Void)?

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

    // The recent-colors row is always the row right after the two static
    // classic-palette rows.
    private static let recentRowIndex = rows.count

    private var grid: NSGridView!

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
        // Third row: recently used colors (issue #5), empty at launch —
        // `updateRecentColors(_:)` fills it in as the user picks colors.
        // Transparent placeholders keep the row's column count (and hence
        // the grid's overall geometry) stable from the very first frame.
        grid.addRow(with: Array(repeating: NSColor.clear, count: Self.rows[0].count).map(makeSwatch))

        for column in 0..<Self.rows[0].count {
            grid.column(at: column).width = Self.swatchSide
        }

        self.grid = grid
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

    /// Rebuilds the recent-colors row from scratch (issue #5) — the same
    /// "throwaway rebuild" pattern the rest of this codebase uses for
    /// list-like views (e.g. `LayerPanelView.reload()`), rather than
    /// diffing the old row's swatches against the new list.
    ///
    /// `colors` is padded with transparent placeholders up to the column
    /// count if shorter, or truncated if somehow longer (callers are
    /// expected to already respect `recentColorsCapacity`, but this stays
    /// safe either way).
    func updateRecentColors(_ colors: [NSColor]) {
        let columnCount = Self.rows[0].count
        var display = Array(colors.prefix(columnCount))
        if display.count < columnCount {
            display += Array(repeating: NSColor.clear, count: columnCount - display.count)
        }

        // `NSGridView.removeRow(at:)` detaches the row/cells from the grid's
        // *layout*, but does not remove the cells' `contentView`s from the
        // grid's `subviews` — those orphaned `ColorSwatchView`s would
        // otherwise silently accumulate, 14 at a time, on every color pick
        // (issue #5 self-review), since this method is called once per
        // `AppDelegate.setColor(_:secondary:)`.
        let oldRow = grid.row(at: Self.recentRowIndex)
        for index in 0..<oldRow.numberOfCells {
            oldRow.cell(at: index).contentView?.removeFromSuperview()
        }
        grid.removeRow(at: Self.recentRowIndex)
        grid.insertRow(at: Self.recentRowIndex, with: display.map(makeSwatch))
    }

    private func makeSwatch(color: NSColor) -> ColorSwatchView {
        let swatch = ColorSwatchView(color: color)
        swatch.onSelected = { [weak self] color, isSecondary in
            self?.onSwatchSelected?(color, isSecondary)
        }
        return swatch
    }

    /// True if two colors have identical RGBA components once both are
    /// converted to `.deviceRGB` — the same conversion `PixelCanvas
    /// .components(of:)` uses, so two colors that would write identical
    /// bytes to the canvas are also treated as "the same color" for recency
    /// de-duplication purposes.
    private static func colorsMatch(_ a: NSColor, _ b: NSColor) -> Bool {
        guard let rgbaA = a.usingColorSpace(.deviceRGB), let rgbaB = b.usingColorSpace(.deviceRGB) else {
            return a == b
        }
        return rgbaA.redComponent == rgbaB.redComponent
            && rgbaA.greenComponent == rgbaB.greenComponent
            && rgbaA.blueComponent == rgbaB.blueComponent
            && rgbaA.alphaComponent == rgbaB.alphaComponent
    }

    /// Pure recency-list update (issue #5), pulled out of `updateRecentColors(_:)`
    /// so the "move to front, dedupe, cap at capacity" rule can be unit
    /// tested without any `NSGridView`/AppKit plumbing — the same
    /// UI-independent-pure-function pattern as `NewCanvasDialog.parseSize`
    /// and `CanvasView.pixelCoordinate(forPoint:zoomScale:)`.
    ///
    /// `color` is moved to the front if it already exists in `existing`
    /// (matched via `colorsMatch`, i.e. by RGBA value, not identity) rather
    /// than appearing twice, then the result is truncated to `capacity`
    /// entries — dropping the oldest (tail) ones first.
    static func updatedRecentColors(adding color: NSColor, to existing: [NSColor], capacity: Int) -> [NSColor] {
        var result = existing.filter { !colorsMatch($0, color) }
        result.insert(color, at: 0)
        if result.count > capacity {
            result.removeLast(result.count - capacity)
        }
        return result
    }
}

/// A single clickable palette swatch (issue #5): left-click picks the
/// foreground color, right-click picks the background color, both by
/// calling `onSelected`. Replaces the old plain, non-interactive `NSView`
/// swatches (`ColorPaletteView.makeSwatch` used to build those directly).
private final class ColorSwatchView: NSView {
    let color: NSColor
    var onSelected: ((NSColor, Bool) -> Void)?

    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
        layer?.borderColor = NSColor.gray.cgColor
        layer?.borderWidth = 0.5
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: ColorPaletteView.swatchSide),
            heightAnchor.constraint(equalToConstant: ColorPaletteView.swatchSide)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        onSelected?(color, false)
    }

    override func rightMouseDown(with event: NSEvent) {
        onSelected?(color, true)
    }
}
