import AppKit

/// Photoshop's left-hand toolbox: a single vertical column of tool icons
/// (issue #7; was a 2-column grid under issue #2). Only the pencil is wired
/// to real behavior — `CanvasView` always paints with the pencil regardless
/// of which button is showing — so every other button here is a purely
/// visual placeholder with no target/action. The pencil cell renders
/// pressed (`state == .on`) by default so the column still communicates
/// "this is the active tool" the way the reference screenshots do, without
/// pretending tool-switching is implemented (that lands in a later issue).
///
/// A single column of 16 icons runs taller than the window at typical
/// sizes, so (like `DocumentTabBarView`) the column is wrapped in a
/// vertically-scrolling `NSScrollView` rather than widened back into extra
/// columns.
final class ToolboxView: NSView {
    private struct Tool {
        let symbol: String
        let label: String
    }

    // Top to bottom, one per row, matching Photoshop's single-column
    // toolbar layout.
    private static let tools: [Tool] = [
        Tool(symbol: "lasso", label: "自由選択"),
        Tool(symbol: "rectangle.dashed", label: "選択"),
        Tool(symbol: "eraser", label: "消しゴム"),
        Tool(symbol: "drop.fill", label: "塗りつぶし"),
        Tool(symbol: "eyedropper", label: "スポイト"),
        Tool(symbol: "magnifyingglass", label: "拡大鏡"),
        Tool(symbol: "pencil", label: "鉛筆"),
        Tool(symbol: "paintbrush.fill", label: "ブラシ"),
        Tool(symbol: "aqi.medium", label: "エアブラシ"),
        Tool(symbol: "textformat", label: "テキスト"),
        Tool(symbol: "line.diagonal", label: "直線"),
        Tool(symbol: "scribble", label: "曲線"),
        Tool(symbol: "rectangle", label: "四角形"),
        Tool(symbol: "rhombus", label: "多角形"),
        Tool(symbol: "circle", label: "楕円"),
        Tool(symbol: "capsule", label: "角丸四角形")
    ]

    // `?? 0` guards against a future label rename/removal for "鉛筆": if the
    // lookup ever fails, fall back to the first button instead of crashing
    // the app at launch.
    private static let pencilIndex = tools.firstIndex { $0.label == "鉛筆" } ?? 0
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
            grid.addRow(with: [makeButton(for: tool, isPencil: index == Self.pencilIndex)])
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

    private func makeButton(for tool: Tool, isPencil: Bool) -> NSButton {
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
