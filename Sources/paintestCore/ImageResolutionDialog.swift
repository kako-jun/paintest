import AppKit

/// Presents an `NSAlert`-based dialog asking for a new pixel resolution to
/// resample the whole document to (issue #39's "画像解像度"). Returns `nil`
/// if the user cancels.
///
/// Reuses `NewCanvasDialog.parseSize` for the actual parse-and-clamp rule
/// (same `1...4096` policy, same "non-numeric input falls back to the
/// default" behavior) rather than duplicating it — the two dialogs collect
/// the same shape of input (a width/height pair), just for different
/// purposes, so this is the same "pure parse function + NSAlert-driven
/// promptFor" split, sharing the one function that has nothing dialog-
/// specific about it.
enum ImageResolutionDialog {
    static func promptForSize(currentWidth: Int, currentHeight: Int) -> (width: Int, height: Int)? {
        let alert = NSAlert()
        alert.messageText = "画像解像度"
        alert.informativeText = "新しい幅と高さをピクセル単位で入力してください。既存の内容は拡大縮小されます。"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "キャンセル")

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 56))

        let widthLabel = NSTextField(labelWithString: "幅:")
        widthLabel.frame = NSRect(x: 0, y: 30, width: 40, height: 20)
        let widthField = NSTextField(frame: NSRect(x: 44, y: 28, width: 80, height: 22))
        widthField.stringValue = String(currentWidth)
        widthField.alignment = .right

        let heightLabel = NSTextField(labelWithString: "高さ:")
        heightLabel.frame = NSRect(x: 0, y: 2, width: 40, height: 20)
        let heightField = NSTextField(frame: NSRect(x: 44, y: 0, width: 80, height: 22))
        heightField.stringValue = String(currentHeight)
        heightField.alignment = .right

        accessory.addSubview(widthLabel)
        accessory.addSubview(widthField)
        accessory.addSubview(heightLabel)
        accessory.addSubview(heightField)
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = widthField

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }

        return NewCanvasDialog.parseSize(
            widthText: widthField.stringValue,
            heightText: heightField.stringValue,
            defaultWidth: currentWidth,
            defaultHeight: currentHeight
        )
    }
}
