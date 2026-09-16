import AppKit

/// The current foreground/background color indicator that classic Paint
/// shows at the bottom-left, as two overlapping squares (issue #2): the
/// foreground swatch top-left (front, on top), the background swatch
/// bottom-right (back), matching the diagonal Photoshop uses (issue #60).
/// Clicking either square picks that color via `ColorPickerDialog` (issue
/// #5); a small "reset to default" button in the free corner below the
/// squares resets both to black/white.
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

    // Small, borderless, tucked into the free corner below the overlapping
    // squares (issue #60: front top-left, back bottom-right leaves the
    // bottom-left corner empty): with `swatchSide` 20, the squares'
    // combined bounding box is vertically centered and 32pt tall (see
    // `swatchRects()`), leaving a margin of (H - 32) / 2 above and below
    // it. The button occupies that margin's bottom 14pt (12pt tall, 2pt
    // inset from the edge), so it only clears the swatches once that
    // margin is at least 14pt, i.e. any view H >= 60pt (every real
    // `colorBarHeight` is) leaves an empty strip along the bottom edge for
    // this button to sit in without overlapping the swatches.
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
            resetButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
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
    ///
    /// Diagonal matches Photoshop (issue #60): foreground (front) top-left,
    /// background (back) bottom-right. AppKit views are bottom-left-origin
    /// (not flipped) here, so "top" is the larger `y`.
    private func swatchRects() -> (front: CGRect, back: CGRect) {
        let side = Self.swatchSide
        let front = CGRect(x: bounds.midX - side + 4, y: bounds.midY - 4, width: side, height: side)
        let back = CGRect(x: bounds.midX - 4, y: bounds.midY - side + 4, width: side, height: side)
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

    /// The gap between adjacent swatches, in both directions — shared by
    /// `columnCount(forWidth:)`'s fit math and `rebuildGrid(columnCount:)`'s
    /// actual `grid.rowSpacing`/`grid.columnSpacing` (issue #59 PR #63
    /// review should-3): before this constant existed the two had to be kept
    /// in sync by a comment alone, which is exactly the kind of
    /// silently-drifts-apart duplication this codebase avoids elsewhere
    /// (see `AppDelegate.colorBarHeight`'s "derived, not guessed" comment).
    private static let swatchSpacing: CGFloat = 1

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

    // How many columns the grid is currently built with (issue #59): starts
    // at the classic 14 and grows as the view widens so the swatches reach
    // the window's right edge instead of leaving it blank. Never shrinks
    // below `rows[0].count` — that stays the floor both for the classic
    // "28-color Paint palette" look and for `recentColorsCapacity`, which is
    // a *data* concept (how many recent colors are remembered) independent
    // of how many columns are currently on screen.
    private var currentColumnCount = rows[0].count

    // The most recent `updateRecentColors(_:)` argument, kept around so a
    // resize-triggered `rebuildGrid(columnCount:)` can redraw the
    // recent-colors row at the new column count without losing its content.
    private var lastRecentColors: [NSColor] = []

    // True between `NSWindow.willStartLiveResizeNotification` and
    // `didEndLiveResizeNotification` for this view's window (issue #59 PR
    // #63 review should-5): while the user is actively dragging a window
    // edge, `frameDidChange()` fires on every intermediate frame, and
    // rebuilding the whole grid (tear down + recreate 3 rows of
    // `NSGridView` cells) on each of those would be wasted work and a
    // visible flicker risk. Rebuilds are suppressed while this is `true`
    // and caught up once with the final size when live resizing ends.
    private var isLiveResizing = false

    init() {
        super.init(frame: .zero)
        // Rebuild the grid whenever this view's own width changes (e.g. the
        // window is resized) so the swatch columns keep filling it (issue
        // #59). `postsFrameChangedNotifications` must be turned on for a
        // plain `NSView` to actually emit this notification.
        postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(frameDidChange),
            name: NSView.frameDidChangeNotification,
            object: self
        )
        rebuildGrid(columnCount: currentColumnCount)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // Tracks the live-resize window notifications against whichever window
    // this view is currently in (issue #59 should-5) — `object: nil` on the
    // `removeObserver` calls clears out a stale registration against a
    // *previous* window before (re-)registering against the current one, so
    // this stays correct even if the view is ever moved between windows.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.willStartLiveResizeNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didEndLiveResizeNotification, object: nil)
        guard let window else { return }
        NotificationCenter.default.addObserver(
            self, selector: #selector(liveResizeWillStart),
            name: NSWindow.willStartLiveResizeNotification, object: window
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(liveResizeDidEnd),
            name: NSWindow.didEndLiveResizeNotification, object: window
        )
    }

    @objc private func liveResizeWillStart() {
        isLiveResizing = true
    }

    @objc private func liveResizeDidEnd() {
        isLiveResizing = false
        frameDidChange() // catch up to whatever size the drag settled on
    }

    @objc private func frameDidChange() {
        // Suppressed mid-drag (issue #59 should-5, see `isLiveResizing`'s
        // doc comment) — `liveResizeDidEnd()` calls this again once the
        // drag settles, so the grid still ends up at the right column count,
        // just without a rebuild per intermediate frame.
        guard !isLiveResizing else { return }
        let desired = Self.columnCount(forWidth: bounds.width)
        guard desired != currentColumnCount else { return }
        rebuildGrid(columnCount: desired)
    }

    /// How many swatch columns fit across `width` without going narrower
    /// than the classic 14-column palette (issue #59). `width` is this
    /// view's own bounds width, which already excludes
    /// `CurrentColorIndicatorView`'s space (see `AppDelegate.makeColorBar()`
    /// constraints) — so filling it edge-to-edge here is what puts the
    /// swatches flush against the window's right edge.
    ///
    /// `internal`, not `private`, so `ColorPaletteViewTests` can pin its
    /// boundary behavior directly (PR #63 review must-1: this is the core
    /// width-to-column-count conversion the whole issue is about, and it
    /// had no test coverage at all) — same testability reasoning as
    /// `baseRowColors(_:rowIndex:columnCount:)` and
    /// `updatedRecentColors(adding:to:capacity:)`.
    static func columnCount(forWidth width: CGFloat) -> Int {
        let minimumColumns = rows[0].count
        guard width > 0 else { return minimumColumns }
        let cellStride = swatchSide + swatchSpacing
        // n columns span n*swatchSide + (n-1)*swatchSpacing <= width, i.e.
        // n <= (width + swatchSpacing) / cellStride.
        let fitted = Int((width + swatchSpacing) / cellStride)
        return max(minimumColumns, fitted)
    }

    /// Adapts a fixed classic-palette row to `columnCount` columns (issue
    /// #59). At the classic column count (`row.count`, 14) this returns
    /// `row` untouched, so the default/narrow look stays exactly what it
    /// was before this issue. Once the grid is wider than that, simply
    /// repeating the same 14 colors would put visibly duplicate swatches
    /// side by side for no reason (kako-jun flagged this after the first
    /// pass) — so instead the whole row is regenerated at `columnCount`
    /// colors via `proceduralRowColors(rowIndex:columnCount:)`, which
    /// actually uses the extra width to show more distinct hues.
    ///
    /// `internal`, not `private`, so `ColorPaletteViewTests` can exercise it
    /// directly (the same testability reasoning as
    /// `updatedRecentColors(adding:to:capacity:)` below).
    static func baseRowColors(_ row: [NSColor], rowIndex: Int, columnCount: Int) -> [NSColor] {
        if columnCount == row.count {
            return row
        }
        if columnCount < row.count {
            // Not reachable via `columnCount(forWidth:)` today (it never
            // returns below `rows[0].count`), but truncating rather than
            // procedurally generating keeps this safe if that ever changes.
            return Array(row.prefix(columnCount))
        }
        return proceduralRowColors(rowIndex: rowIndex, columnCount: columnCount)
    }

    /// Generates `columnCount` colors spread evenly around the hue wheel
    /// (`hue = column / columnCount`), so widening the window actually
    /// reveals new, distinct colors instead of a repeated pattern (issue
    /// #59). `rowIndex` selects a saturation/brightness profile that keeps
    /// each row's original character: row 0 was "muted shades" (lower
    /// saturation, on the darker side), row 1 was "vivid tones" (high
    /// saturation, bright) — see the `rows` doc comment above.
    private static func proceduralRowColors(rowIndex: Int, columnCount: Int) -> [NSColor] {
        let isMutedRow = rowIndex == 0
        let saturation: CGFloat = isMutedRow ? 0.55 : 0.9
        let brightness: CGFloat = isMutedRow ? 0.55 : 0.95
        return (0..<columnCount).map { column in
            let hue = CGFloat(column) / CGFloat(columnCount)
            return NSColor(calibratedHue: hue, saturation: saturation, brightness: brightness, alpha: 1)
        }
    }

    /// `colors`, padded with transparent placeholders up to `columnCount` if
    /// shorter, or truncated if longer — shared by the initial empty build
    /// and by `updateRecentColors(_:)`.
    private static func paddedRecentColors(_ colors: [NSColor], columnCount: Int) -> [NSColor] {
        var display = Array(colors.prefix(columnCount))
        if display.count < columnCount {
            display += Array(repeating: NSColor.clear, count: columnCount - display.count)
        }
        return display
    }

    /// Tears down the current grid (if any) and builds a fresh one at
    /// `columnCount` columns, reusing `lastRecentColors` so a resize doesn't
    /// forget the recent-colors row's content (issue #59).
    private func rebuildGrid(columnCount: Int) {
        currentColumnCount = columnCount
        grid?.removeFromSuperview()

        let grid = NSGridView(numberOfColumns: columnCount, rows: 0)
        grid.rowSpacing = Self.swatchSpacing
        grid.columnSpacing = Self.swatchSpacing
        grid.translatesAutoresizingMaskIntoConstraints = false

        for (rowIndex, row) in Self.rows.enumerated() {
            grid.addRow(with: Self.baseRowColors(row, rowIndex: rowIndex, columnCount: columnCount).map(makeSwatch))
        }
        // Third row: recently used colors (issue #5), empty at launch —
        // `updateRecentColors(_:)` fills it in as the user picks colors.
        // Transparent placeholders keep the row's column count (and hence
        // the grid's overall geometry) stable from the very first frame.
        let recentDisplay = Self.paddedRecentColors(lastRecentColors, columnCount: columnCount)
        grid.addRow(with: recentDisplay.map(makeSwatch))

        for column in 0..<columnCount {
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
    /// `colors` is padded with transparent placeholders up to the current
    /// column count if shorter, or truncated if somehow longer (callers are
    /// expected to already respect `recentColorsCapacity`, but this stays
    /// safe either way). The column count itself can be wider than
    /// `recentColorsCapacity` (issue #59) — capacity is a data-retention
    /// concept, display width is not — so any extra columns are simply left
    /// as transparent placeholders.
    func updateRecentColors(_ colors: [NSColor]) {
        // Remembered so a resize-triggered `rebuildGrid(columnCount:)` can
        // redraw this row at the new column count (issue #59).
        lastRecentColors = colors
        let display = Self.paddedRecentColors(colors, columnCount: currentColumnCount)

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
