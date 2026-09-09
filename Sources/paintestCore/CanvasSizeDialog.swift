import AppKit

/// Presents an `NSAlert`-based dialog asking for a new canvas size and a
/// 9-point anchor (issue #39's "カンバスサイズ", modeled on Photoshop's own
/// Canvas Size dialog). Unlike `ImageResolutionDialog`, existing pixels are
/// never resampled, only repositioned/clipped — `anchor` decides where the
/// current content lands within the new, differently-sized canvas (see
/// `CanvasAnchor`, and `LayerStack.resized(toWidth:toHeight:anchor:)` which
/// actually performs the resize). Returns `nil` if the user cancels.
///
/// Reuses `NewCanvasDialog.parseSize` for the width/height parse-and-clamp
/// rule, same as `ImageResolutionDialog` — see that dialog's own doc
/// comment for why.
enum CanvasSizeDialog {
    private static let anchorGrid: [[CanvasAnchor]] = [
        [.topLeft, .top, .topRight],
        [.left, .center, .right],
        [.bottomLeft, .bottom, .bottomRight]
    ]
    private static let anchorButtonSide: CGFloat = 22
    private static let anchorButtonSpacing: CGFloat = 4

    static func promptForSize(currentWidth: Int, currentHeight: Int) -> (width: Int, height: Int, anchor: CanvasAnchor)? {
        let alert = NSAlert()
        alert.messageText = "カンバスサイズ"
        alert.informativeText = "新しい幅と高さ、および基準位置を選択してください。既存のピクセルは拡大縮小されません。"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "キャンセル")

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 148))

        let widthLabel = NSTextField(labelWithString: "幅:")
        widthLabel.frame = NSRect(x: 0, y: 122, width: 40, height: 20)
        let widthField = NSTextField(frame: NSRect(x: 44, y: 120, width: 80, height: 22))
        widthField.stringValue = String(currentWidth)
        widthField.alignment = .right

        let heightLabel = NSTextField(labelWithString: "高さ:")
        heightLabel.frame = NSRect(x: 0, y: 94, width: 40, height: 20)
        let heightField = NSTextField(frame: NSRect(x: 44, y: 92, width: 80, height: 22))
        heightField.stringValue = String(currentHeight)
        heightField.alignment = .right

        let anchorLabel = NSTextField(labelWithString: "基準位置:")
        anchorLabel.frame = NSRect(x: 0, y: 66, width: 100, height: 18)

        // A native `.radio`-type `NSButton` group: AppKit automatically
        // keeps radio buttons that share the same immediate superview
        // mutually exclusive, so no manual "force every other button off"
        // wiring (unlike `ToolboxView`'s `.pushOnPushOff` tool buttons,
        // which don't get that behavior for free) is needed here.
        var anchorButtons: [CanvasAnchor: NSButton] = [:]
        for (row, anchors) in anchorGrid.enumerated() {
            for (column, anchor) in anchors.enumerated() {
                let button = NSButton(radioButtonWithTitle: "", target: nil, action: nil)
                let x = CGFloat(column) * (anchorButtonSide + anchorButtonSpacing)
                let y = CGFloat(anchorGrid.count - 1 - row) * (anchorButtonSide + anchorButtonSpacing)
                button.frame = NSRect(x: x, y: y, width: anchorButtonSide, height: anchorButtonSide)
                accessory.addSubview(button)
                anchorButtons[anchor] = button
            }
        }
        anchorButtons[.center]?.state = .on

        accessory.addSubview(widthLabel)
        accessory.addSubview(widthField)
        accessory.addSubview(heightLabel)
        accessory.addSubview(heightField)
        accessory.addSubview(anchorLabel)
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = widthField

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }

        let selectedAnchor = anchorButtons.first(where: { $0.value.state == .on })?.key ?? .center
        let size = NewCanvasDialog.parseSize(
            widthText: widthField.stringValue,
            heightText: heightField.stringValue,
            defaultWidth: currentWidth,
            defaultHeight: currentHeight
        )
        return (size.width, size.height, selectedAnchor)
    }
}
