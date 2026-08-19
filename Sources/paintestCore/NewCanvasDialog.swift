import AppKit

/// Presents a simple `NSAlert`-based dialog asking for a new canvas' pixel
/// dimensions. Returns `nil` if the user cancels.
enum NewCanvasDialog {
    /// Parses and clamps the width/height text field contents into valid
    /// canvas dimensions. Pulled out as a pure function (no `NSAlert`/
    /// `NSTextField` dependency) so the parse-or-fallback and clamping rules
    /// can be unit tested directly, independent of `promptForSize`'s modal
    /// UI plumbing.
    ///
    /// Non-numeric or empty input (including full-width digits, which
    /// `Int.init(_:)` does not parse) falls back to the default rather than
    /// being clamped. Numeric input is clamped to `1...4096`.
    static func parseSize(
        widthText: String,
        heightText: String,
        defaultWidth: Int,
        defaultHeight: Int
    ) -> (width: Int, height: Int) {
        let width = max(1, min(4096, Int(widthText) ?? defaultWidth))
        let height = max(1, min(4096, Int(heightText) ?? defaultHeight))
        return (width, height)
    }

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

        return parseSize(
            widthText: widthField.stringValue,
            heightText: heightField.stringValue,
            defaultWidth: defaultWidth,
            defaultHeight: defaultHeight
        )
    }
}
