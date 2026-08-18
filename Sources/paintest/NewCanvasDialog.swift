import AppKit

/// Presents a simple `NSAlert`-based dialog asking for a new canvas' pixel
/// dimensions. Returns `nil` if the user cancels.
enum NewCanvasDialog {
    static func promptForSize(defaultWidth: Int = 64, defaultHeight: Int = 64) -> (width: Int, height: Int)? {
        let alert = NSAlert()
        alert.messageText = "新規キャンバス"
        alert.informativeText = "幅と高さをピクセル単位で入力してください。"
        alert.addButton(withTitle: "作成")
        alert.addButton(withTitle: "キャンセル")

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 56))

        let widthLabel = NSTextField(labelWithString: "幅:")
        widthLabel.frame = NSRect(x: 0, y: 30, width: 40, height: 20)
        let widthField = NSTextField(frame: NSRect(x: 44, y: 28, width: 80, height: 22))
        widthField.stringValue = String(defaultWidth)
        widthField.alignment = .right

        let heightLabel = NSTextField(labelWithString: "高さ:")
        heightLabel.frame = NSRect(x: 0, y: 2, width: 40, height: 20)
        let heightField = NSTextField(frame: NSRect(x: 44, y: 0, width: 80, height: 22))
        heightField.stringValue = String(defaultHeight)
        heightField.alignment = .right

        accessory.addSubview(widthLabel)
        accessory.addSubview(widthField)
        accessory.addSubview(heightLabel)
        accessory.addSubview(heightField)
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = widthField

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }

        let width = max(1, min(4096, Int(widthField.stringValue) ?? defaultWidth))
        let height = max(1, min(4096, Int(heightField.stringValue) ?? defaultHeight))
        return (width, height)
    }
}
