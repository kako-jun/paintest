import AppKit

/// Photoshop's left-hand toolbox: a 2-column grid of tool icons (issue #58;
/// was a single column under issue #7, which itself had replaced the
/// original 2-column grid from issue #2 — #7's "Photoshop is single-column"
/// premise didn't account for Photoshop's own chevron toggle between 1- and
/// 2-column toolbars, so #58 reverts to the 2-column layout as an equally
/// valid Photoshop look while keeping every tool/wiring change added since
/// #7). Pencil, eraser, pen, the eyedropper, the magnifier, the
/// rectangle/ellipse/lasso/polygon/magic-wand select tools, crop, bucket
/// fill, gradient, and text are wired to real behavior (issues #5, #10,
/// #14, #13, #11, #21, #38, #41, #42) — clicking any of them fires
/// `onToolSelected` and exclusively toggles that button's pressed state
/// against the others' — so every other button here stays a purely visual
/// placeholder with no target/action, same as before. Text was previously
/// its own disabled-but-unwired placeholder (issue #43, `isEnabled = false`
/// with no target/action) until issue #42 gave it a real implementation;
/// it now gets the same target/action wiring as every other wired tool
/// below, with no special-cased disabling left over.
/// The pencil cell renders pressed (`state == .on`) by default so the
/// grid still communicates "this is the active tool" the way the
/// reference screenshots do.
///
/// 21 icons in a 2-column grid (11 rows, the last row holding a single
/// leftover button) still runs taller than the window at typical sizes, so
/// (like `DocumentTabBarView`) the grid is wrapped in a vertically-
/// scrolling `NSScrollView` — but with roughly half the row count of the
/// single-column layout, the scroll distance shrinks accordingly.
final class ToolboxView: NSView {
    private struct ToolDescriptor {
        let symbol: String
        let label: String
        // Non-nil only for the buttons wired up so far — pencil/eraser
        // (issue #5), pen (issue #10), the eyedropper (issue #14), the
        // magnifier (issue #13), the rectangle/ellipse/lasso/polygon/
        // magic-wand select tools (issue #11), crop (issue #21), bucket
        // fill (issue #38), gradient (issue #41), and text (issue #42); every other descriptor
        // stays `nil` and its button gets no target/action, matching the
        // previous all-placeholder behavior.
        let tool: Tool?
    }

    // Row-major, 2 per row, matching Photoshop's 2-column toolbar layout.
    // Crop sits right after the five selection tools and before eraser
    // (issue #21), mirroring where Photoshop's own toolbox places its crop
    // tool relative to its selection tool group.
    private static let tools: [ToolDescriptor] = [
        ToolDescriptor(symbol: "lasso", label: "投げ縄選択", tool: .lassoSelect),
        ToolDescriptor(symbol: "hexagon.dashed", label: "多角形選択", tool: .polygonSelect),
        ToolDescriptor(symbol: "rectangle.dashed", label: "矩形選択", tool: .rectangleSelect),
        ToolDescriptor(symbol: "circle.dashed", label: "楕円選択", tool: .ellipseSelect),
        ToolDescriptor(symbol: "wand.and.rays", label: "マジックワンド", tool: .magicWandSelect),
        ToolDescriptor(symbol: "crop", label: "切り抜き", tool: .crop),
        ToolDescriptor(symbol: "eraser", label: "消しゴム", tool: .eraser),
        ToolDescriptor(symbol: "drop.fill", label: "塗りつぶし", tool: .bucketFill),
        ToolDescriptor(symbol: "rectangle.lefthalf.filled", label: "グラデーション", tool: .gradient),
        ToolDescriptor(symbol: "eyedropper", label: "スポイト", tool: .eyedropper),
        ToolDescriptor(symbol: "magnifyingglass", label: "拡大鏡", tool: .magnifier),
        ToolDescriptor(symbol: "pencil", label: "鉛筆", tool: .pencil),
        ToolDescriptor(symbol: "paintbrush.fill", label: "ペン", tool: .pen),
        ToolDescriptor(symbol: "aqi.medium", label: "エアブラシ", tool: nil),
        ToolDescriptor(symbol: "textformat", label: "テキスト", tool: .text),
        ToolDescriptor(symbol: "line.diagonal", label: "直線", tool: nil),
        ToolDescriptor(symbol: "scribble", label: "曲線", tool: nil),
        ToolDescriptor(symbol: "rectangle", label: "四角形", tool: nil),
        ToolDescriptor(symbol: "rhombus", label: "多角形", tool: nil),
        ToolDescriptor(symbol: "circle", label: "楕円", tool: nil),
        ToolDescriptor(symbol: "capsule", label: "角丸四角形", tool: nil)
    ]

    // `?? 0` guards against a future label rename/removal for "鉛筆": if the
    // lookup ever fails, fall back to the first button instead of crashing
    // the app at launch.
    private static let pencilIndex = tools.firstIndex { $0.label == "鉛筆" } ?? 0

    /// Fired when a wired tool button (pencil, eraser, pen, eyedropper) is
    /// clicked (issues #5, #10, #14). `AppDelegate` forwards this straight
    /// to `CanvasView.activeTool`.
    var onToolSelected: ((Tool) -> Void)?

    /// Every wired tool's button, keyed by its `Tool` case, so exclusive
    /// selection generalizes to N tools instead of hardcoding a pencil/
    /// eraser pair (issue #10).
    private var toolButtons: [Tool: NSButton] = [:]
    /// Reverse lookup from a tapped button back to its `Tool`, since
    /// `@objc` actions only get the sender `NSButton`, not which
    /// `ToolDescriptor` it came from.
    private var buttonToTool: [ObjectIdentifier: Tool] = [:]

    static let buttonSide: CGFloat = 30

    init() {
        super.init(frame: .zero)
        buildGrid()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildGrid() {
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.rowSpacing = 1
        grid.columnSpacing = 1
        grid.translatesAutoresizingMaskIntoConstraints = false

        var rowButtons: [NSButton] = []
        for (index, tool) in Self.tools.enumerated() {
            let button = makeButton(for: tool, isPencil: index == Self.pencilIndex)
            if let wiredTool = tool.tool {
                toolButtons[wiredTool] = button
                buttonToTool[ObjectIdentifier(button)] = wiredTool
                // A plain `.pushOnPushOff` button has no built-in grouping,
                // so exclusive (radio-like) selection across all wired tools
                // is driven by a single shared action (issue #10; was two
                // separate hardcoded actions under issue #5).
                button.target = self
                button.action = #selector(toolButtonTapped(_:))
            }
            rowButtons.append(button)
            if rowButtons.count == 2 {
                grid.addRow(with: rowButtons)
                rowButtons = []
            }
        }
        // `tools` currently has an odd count (21), so this fires once for
        // the trailing pencil-adjacent button. NSGridView accepts fewer
        // views than there are columns and pads the remaining cell as
        // empty, so a leftover single button is rendered safely instead of
        // being silently dropped (mirrors the guard from issue #2's
        // original 2-column grid).
        if !rowButtons.isEmpty {
            grid.addRow(with: rowButtons)
        }

        for column in 0..<2 {
            grid.column(at: column).width = Self.buttonSide
        }

        // Wrapped in a scroll view (same pattern as `DocumentTabBarView`):
        // even at 2 columns, 21 buttons (11 rows) can run taller than the
        // window at typical sizes, so the grid scrolls vertically instead
        // of widening back into extra columns.
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = grid
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor, constant: 4),
            grid.centerXAnchor.constraint(equalTo: scrollView.contentView.centerXAnchor)
        ])

        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @objc private func toolButtonTapped(_ sender: NSButton) {
        guard let tappedTool = buttonToTool[ObjectIdentifier(sender)] else { return }
        // Force the states explicitly rather than trusting `.pushOnPushOff`'s
        // own toggle (issue #5): without this, clicking the already-active
        // button would flip it *off* with neither button pressed, and
        // clicking another wired tool would leave both buttons pressed at
        // once. Generalized to N wired tools under issue #10.
        for (tool, button) in toolButtons {
            button.state = tool == tappedTool ? .on : .off
        }
        onToolSelected?(tappedTool)
    }

    private func makeButton(for tool: ToolDescriptor, isPencil: Bool) -> NSButton {
        let image = NSImage(systemSymbolName: tool.symbol, accessibilityDescription: tool.label) ?? NSImage()
        let button = NSButton(image: image, target: nil, action: nil)
        button.bezelStyle = .smallSquare
        button.setButtonType(.pushOnPushOff)
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = tool.label
        button.state = isPencil ? .on : .off
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: Self.buttonSide),
            button.heightAnchor.constraint(equalToConstant: Self.buttonSide)
        ])
        return button
    }
}
