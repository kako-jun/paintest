import AppKit

/// Classic Paint's left-hand toolbox: a fixed 2-column grid of tool icons
/// (issue #2). Only the pencil is wired to real behavior — `CanvasView`
/// always paints with the pencil regardless of which button is showing —
/// so every other button here is a purely visual placeholder with no
/// target/action. The pencil cell renders pressed (`state == .on`) by
/// default so the grid still communicates "this is the active tool" the
/// way the reference screenshots do, without pretending tool-switching is
/// implemented (that lands in a later issue).
final class ToolboxView: NSView {
    private struct Tool {
        let symbol: String
        let label: String
    }

    // Row-major, 2 per row, matching the layout in
    // docs/reference/classic-paint-1.png top to bottom.
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

    private static let pencilIndex = tools.firstIndex { $0.label == "鉛筆" }!
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
            rowButtons.append(makeButton(for: tool, isPencil: index == Self.pencilIndex))
            if rowButtons.count == 2 {
                grid.addRow(with: rowButtons)
                rowButtons = []
            }
        }

        for column in 0..<2 {
            grid.column(at: column).width = Self.buttonSide
        }

        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            grid.centerXAnchor.constraint(equalTo: centerXAnchor)
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
