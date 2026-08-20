import AppKit
import UniformTypeIdentifiers

/// Boots the app. This is the only symbol `paintestCore` exposes publicly —
/// `AppDelegate` and friends stay internal to this module, so the thin
/// `paintest` executable target (whose `main.swift` calls this) never needs
/// to expose AppKit delegate protocol conformances across a module boundary.
/// Keeping this as a plain function (not top-level code in a `main.swift`)
/// also means the `paintestTests` target can `@testable import paintestCore`
/// without inadvertently launching the app's run loop.
public func runPaintestApp() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var canvasView: CanvasView!
    private var scrollView: NSScrollView!
    private var toolboxView: ToolboxView!
    private var colorPaletteView: ColorPaletteView!
    private var currentColorIndicator: CurrentColorIndicatorView!
    // The status bar's zoom readout, kept as a direct reference from
    // creation time rather than re-derived later by digging through the
    // view hierarchy. `NewCanvasDialog.promptForSize` follows the same
    // "keep the direct reference, don't search for it later" approach for
    // its accessory view's fields.
    private var zoomLabelField: NSTextField!

    private static let defaultCanvasSize = 64

    // Classic Windows chrome gray (192, 192, 192) — the background behind
    // the toolbox / palette / status bar, distinct from the white canvas.
    private static let chromeColor = NSColor(calibratedWhite: 0.753, alpha: 1)

    private static let toolboxWidth: CGFloat = 70
    private static let colorBarHeight: CGFloat = 44
    private static let statusBarHeight: CGFloat = 22
    private static let colorIndicatorWidth: CGFloat = 48

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()

        let initialCanvas = PixelCanvas(width: Self.defaultCanvasSize, height: Self.defaultCanvasSize, background: .white)
        canvasView = CanvasView(canvas: initialCanvas)
        canvasView.onZoomChanged = { [weak self] scale in
            self?.zoomLabelField?.stringValue = "\(scale)x"
        }

        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.allowsMagnification = false
        scrollView.documentView = canvasView
        scrollView.backgroundColor = .windowBackgroundColor

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "untitled - paintest"
        window.center()
        window.contentView = makeRootView()
        window.minSize = NSSize(width: 420, height: 320)
        window.makeKeyAndOrderFront(nil)

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - Root layout (issue #2: classic Paint's toolbox + canvas +
    // color palette + status bar impression, replacing #1's NSToolbar).

    private func makeRootView() -> NSView {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = Self.chromeColor.cgColor

        toolboxView = ToolboxView()
        toolboxView.translatesAutoresizingMaskIntoConstraints = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let colorBar = makeColorBar()
        colorBar.translatesAutoresizingMaskIntoConstraints = false

        let statusBar = makeStatusBar()
        statusBar.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(toolboxView)
        root.addSubview(scrollView)
        root.addSubview(colorBar)
        root.addSubview(statusBar)

        NSLayoutConstraint.activate([
            toolboxView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolboxView.topAnchor.constraint(equalTo: root.topAnchor),
            toolboxView.bottomAnchor.constraint(equalTo: colorBar.topAnchor),
            toolboxView.widthAnchor.constraint(equalToConstant: Self.toolboxWidth),

            scrollView.leadingAnchor.constraint(equalTo: toolboxView.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: colorBar.topAnchor),

            colorBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            colorBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            colorBar.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            colorBar.heightAnchor.constraint(equalToConstant: Self.colorBarHeight),

            statusBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: Self.statusBarHeight)
        ])

        return root
    }

    private func makeColorBar() -> NSView {
        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = Self.chromeColor.cgColor

        currentColorIndicator = CurrentColorIndicatorView()
        currentColorIndicator.translatesAutoresizingMaskIntoConstraints = false

        colorPaletteView = ColorPaletteView()
        colorPaletteView.translatesAutoresizingMaskIntoConstraints = false

        bar.addSubview(currentColorIndicator)
        bar.addSubview(colorPaletteView)

        NSLayoutConstraint.activate([
            currentColorIndicator.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            currentColorIndicator.topAnchor.constraint(equalTo: bar.topAnchor),
            currentColorIndicator.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            currentColorIndicator.widthAnchor.constraint(equalToConstant: Self.colorIndicatorWidth),

            colorPaletteView.leadingAnchor.constraint(equalTo: currentColorIndicator.trailingAnchor),
            colorPaletteView.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            colorPaletteView.topAnchor.constraint(equalTo: bar.topAnchor),
            colorPaletteView.bottomAnchor.constraint(equalTo: bar.bottomAnchor)
        ])

        return bar
    }

    private func makeStatusBar() -> NSView {
        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = Self.chromeColor.cgColor

        let hintLabel = NSTextField(labelWithString: "作業を始めるには、[ヘルプ] メニューをクリックしてください。")
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.translatesAutoresizingMaskIntoConstraints = false

        let zoomField = NSTextField(labelWithString: "\(canvasView.zoomScale)x")
        zoomField.font = .systemFont(ofSize: 11)
        zoomField.alignment = .right
        zoomField.translatesAutoresizingMaskIntoConstraints = false
        zoomLabelField = zoomField

        bar.addSubview(hintLabel)
        bar.addSubview(zoomField)

        NSLayoutConstraint.activate([
            hintLabel.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 6),
            hintLabel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            zoomField.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -6),
            zoomField.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            zoomField.widthAnchor.constraint(equalToConstant: 48)
        ])

        return bar
    }

    // MARK: - Menu

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "paintestを終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        mainMenu.addItem(makeMenuItem(title: "ファイル", items: [
            ("新規", #selector(newCanvas), "n"),
            ("開く…", #selector(openCanvas), "o"),
            ("保存…", #selector(saveCanvas), "s")
        ]))

        // Edit / Image / Colors / Help: labels + a handful of decorative
        // items to match the reference screenshots' impression. None of
        // these are wired to real behavior (out of scope for #2).
        mainMenu.addItem(makeMenuItem(title: "編集", placeholders: ["元に戻す", "切り取り", "コピー", "貼り付け", "選択の解除"]))

        mainMenu.addItem(makeMenuItem(title: "表示", items: [
            ("拡大", #selector(zoomIn), "+"),
            ("縮小", #selector(zoomOut), "-")
        ], placeholders: ["ツール バー", "カラー ボックス", "ステータス バー"]))

        mainMenu.addItem(makeMenuItem(title: "イメージ", placeholders: ["反転と回転", "拡大縮小と傾斜", "色の反転", "属性…"]))
        mainMenu.addItem(makeMenuItem(title: "色", placeholders: ["色の編集…"]))
        mainMenu.addItem(makeMenuItem(title: "ヘルプ", placeholders: ["ヘルプ トピック", "paintestのバージョン情報"]))

        NSApp.mainMenu = mainMenu
    }

    /// Builds a top-level menu item whose submenu mixes real, wired items
    /// (`items`) with purely decorative ones (`placeholders`, `action: nil`)
    /// — the latter exist only to make the menu bar look populated like
    /// classic Paint's, per issue #2's "labels only" scope.
    private func makeMenuItem(
        title: String,
        items: [(String, Selector, String)] = [],
        placeholders: [String] = []
    ) -> NSMenuItem {
        let menuItem = NSMenuItem()
        let menu = NSMenu(title: title)
        for (label, action, keyEquivalent) in items {
            menu.addItem(withTitle: label, action: action, keyEquivalent: keyEquivalent)
        }
        for label in placeholders {
            menu.addItem(withTitle: label, action: nil, keyEquivalent: "")
        }
        menuItem.submenu = menu
        return menuItem
    }

    @objc private func newCanvas() {
        guard let size = NewCanvasDialog.promptForSize() else { return }
        let canvas = PixelCanvas(width: size.width, height: size.height, background: .white)
        canvasView.replaceCanvas(canvas)
    }

    @objc private func openCanvas() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            guard let canvas = PixelCanvas.load(from: data) else {
                presentError("PNGの読み込みに失敗しました。")
                return
            }
            canvasView.replaceCanvas(canvas)
        } catch {
            presentError("ファイルの読み込みに失敗しました: \(error.localizedDescription)")
        }
    }

    @objc private func saveCanvas() {
        guard let data = canvasView.canvas.pngData() else {
            presentError("PNGへの変換に失敗しました。")
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "untitled.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
        } catch {
            presentError("ファイルの保存に失敗しました: \(error.localizedDescription)")
        }
    }

    @objc private func zoomIn() {
        canvasView.zoomIn()
    }

    @objc private func zoomOut() {
        canvasView.zoomOut()
    }

    private func presentError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.runModal()
    }
}
