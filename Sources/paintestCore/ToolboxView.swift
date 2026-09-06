import AppKit

/// Photoshop's left-hand toolbox: a single vertical column of tool icons
/// (issue #7; was a 2-column grid under issue #2). Pencil, eraser, pen, the
/// eyedropper, and the magnifier are wired to real behavior (issues #5,
/// #10, #14, #13) — clicking any of them fires `onToolSelected` and
/// exclusively toggles that button's pressed state against the others' — so
/// every other button here stays a purely visual placeholder with no
/// target/action, same as before.
/// The pencil cell renders pressed (`state == .on`) by default so the
/// column still communicates "this is the active tool" the way the
/// reference screenshots do.
///
/// A single column of 16 icons runs taller than the window at typical
/// sizes, so (like `DocumentTabBarView`) the column is wrapped in a
/// vertically-scrolling `NSScrollView` rather than widened back into extra
/// columns.
final class ToolboxView: NSView {
    private struct ToolDescriptor {
        let symbol: String
        let label: String
        // Non-nil only for the buttons wired up so far — pencil/eraser
        // (issue #5), pen (issue #10), the eyedropper (issue #14), and the
        // magnifier (issue #13); every other descriptor stays `nil` and its
        // button gets no target/action, matching the previous
        // all-placeholder behavior.
        let tool: Tool?
    }

    // Top to bottom, one per row, matching Photoshop's single-column
    // toolbar layout.
    private static let tools: [ToolDescriptor] = [
        ToolDescriptor(symbol: "lasso", label: "自由選択", tool: nil),
        ToolDescriptor(symbol: "rectangle.dashed", label: "選択", tool: nil),
        ToolDescriptor(symbol: "eraser", label: "消しゴム", tool: .eraser),
        ToolDescriptor(symbol: "drop.fill", label: "塗りつぶし", tool: nil),
        ToolDescriptor(symbol: "eyedropper", label: "スポイト", tool: .eyedropper),
        ToolDescriptor(symbol: "magnifyingglass", label: "拡大鏡", tool: .magnifier),
        ToolDescriptor(symbol: "pencil", label: "鉛筆", tool: .pencil),
        ToolDescriptor(symbol: "paintbrush.fill", label: "ペン", tool: .pen),
        ToolDescriptor(symbol: "aqi.medium", label: "エアブラシ", tool: nil),
        ToolDescriptor(symbol: "textformat", label: "テキスト", tool: nil),
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
        buildColumn()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildColumn() {
        let grid = NSGridView(numberOfColumns: 1, rows: 0)
        grid.rowSpacing = 1
        grid.translatesAutoresizingMaskIntoConstraints = false

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
            grid.addRow(with: [button])
        }

        grid.column(at: 0).width = Self.buttonSide

        // Wrapped in a scroll view (same pattern as `DocumentTabBarView`):
        // 16 buttons in a single column run taller than the window at
        // typical sizes, so the column scrolls vertically instead of
        // widening back into extra columns.
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
