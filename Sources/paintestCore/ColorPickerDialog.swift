import AppKit

/// A hex-code color picker (issue #5), built the same way `NewCanvasDialog`
/// is: a thin `NSAlert`-based modal wrapping pure, UI-independent parsing/
/// formatting functions that can be unit tested without any AppKit modal
/// plumbing.
enum ColorPickerDialog {
    /// Parses `#RRGGBB` or `RRGGBB` (leading `#` optional, case-insensitive)
    /// into an opaque `NSColor`. Anything else — wrong length, non-hex
    /// characters, empty input — returns `nil`.
    static func parseHexColor(_ text: String) -> NSColor? {
        var hex = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") {
            hex.removeFirst()
        }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }

        let r = CGFloat((value >> 16) & 0xFF) / 255
        let g = CGFloat((value >> 8) & 0xFF) / 255
        let b = CGFloat(value & 0xFF) / 255
        return NSColor(deviceRed: r, green: g, blue: b, alpha: 1)
    }

    /// Formats `color` as an uppercase `#RRGGBB` string. Converts to
    /// `.deviceRGB` first (falling back to the color itself if that
    /// conversion fails) and rounds each component the same way
    /// `PixelCanvas.components(of:)` does, so the hex text always matches
    /// what would actually be written to the canvas.
    static func hexString(from color: NSColor) -> String {
        let rgba = color.usingColorSpace(.deviceRGB) ?? color
        let r = UInt8(max(0, min(255, (rgba.redComponent * 255).rounded())))
        let g = UInt8(max(0, min(255, (rgba.greenComponent * 255).rounded())))
        let b = UInt8(max(0, min(255, (rgba.blueComponent * 255).rounded())))
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    /// Presents an `NSAlert`-based modal for entering/copying a hex color
    /// code. Returns `initial` both when the user cancels and when "適用"
    /// is clicked with unparsable text — matching
    /// `NewCanvasDialog.parseSize`'s "invalid input falls back to the
    /// default" approach rather than blocking dismissal or nesting another
    /// alert.
    static func promptForColor(initial: NSColor) -> NSColor? {
        let alert = NSAlert()
        alert.messageText = "色の選択"
        alert.informativeText = "16進カラーコードを入力してください（例: #FF0000）。"
        alert.addButton(withTitle: "適用")
        alert.addButton(withTitle: "キャンセル")

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 38))

        let preview = NSView(frame: NSRect(x: 0, y: 4, width: 30, height: 30))
        preview.wantsLayer = true
        preview.layer?.backgroundColor = initial.cgColor
        preview.layer?.borderColor = NSColor.gray.cgColor
        preview.layer?.borderWidth = 0.5

        let hexField = NSTextField(frame: NSRect(x: 40, y: 14, width: 100, height: 22))
        hexField.stringValue = hexString(from: initial)

        let copyButton = NSButton(frame: NSRect(x: 148, y: 12, width: 64, height: 26))
        copyButton.title = "コピー"
        copyButton.bezelStyle = .rounded

        accessory.addSubview(preview)
        accessory.addSubview(hexField)
        accessory.addSubview(copyButton)

        // `NSButton.target` is weak, so this handler object must be kept
        // alive by a local `let` for the duration of `runModal()` below —
        // it doesn't need to close the alert, just push the text field's
        // current contents to the pasteboard.
        let copyHandler = CopyButtonHandler(hexField: hexField)
        copyButton.target = copyHandler
        copyButton.action = #selector(CopyButtonHandler.copyTapped)

        alert.accessoryView = accessory
        alert.window.initialFirstResponder = hexField

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return initial }

        return parseHexColor(hexField.stringValue) ?? initial
    }

    /// Target object for the "コピー" button's action. A plain closure isn't
    /// an option since `NSButton.target` is `AnyObject?`, not a closure
    /// slot; this instance's only job is to outlive the modal loop above.
    private final class CopyButtonHandler: NSObject {
        let hexField: NSTextField

        init(hexField: NSTextField) {
            self.hexField = hexField
        }

        @objc func copyTapped() {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(hexField.stringValue, forType: .string)
        }
    }
}
