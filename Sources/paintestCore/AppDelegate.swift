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
    private var zoomLabelItem: NSToolbarItem!

    private static let defaultCanvasSize = 64

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()

        let initialCanvas = PixelCanvas(width: Self.defaultCanvasSize, height: Self.defaultCanvasSize, background: .white)
        canvasView = CanvasView(canvas: initialCanvas)
        canvasView.onZoomChanged = { [weak self] scale in
            self?.zoomLabelItem?.view?.subviews.compactMap { $0 as? NSTextField }.first?.stringValue = "\(scale)x"
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
        window.title = "paintest"
        window.center()
        window.contentView = scrollView
        window.toolbarStyle = .unified
        window.toolbar = makeToolbar()
        window.makeKeyAndOrderFront(nil)

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - Menu

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "paintestを終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "ファイル")
        fileMenu.addItem(withTitle: "新規", action: #selector(newCanvas), keyEquivalent: "n")
        fileMenu.addItem(withTitle: "開く…", action: #selector(openCanvas), keyEquivalent: "o")
        fileMenu.addItem(withTitle: "保存…", action: #selector(saveCanvas), keyEquivalent: "s")
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "表示")
        viewMenu.addItem(withTitle: "拡大", action: #selector(zoomIn), keyEquivalent: "+")
        viewMenu.addItem(withTitle: "縮小", action: #selector(zoomOut), keyEquivalent: "-")
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Toolbar

    private enum ToolbarItem {
        static let newCanvas = NSToolbarItem.Identifier("newCanvas")
        static let open = NSToolbarItem.Identifier("open")
        static let save = NSToolbarItem.Identifier("save")
        static let zoomIn = NSToolbarItem.Identifier("zoomIn")
        static let zoomOut = NSToolbarItem.Identifier("zoomOut")
        static let zoomLabel = NSToolbarItem.Identifier("zoomLabel")
    }

    private func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        return toolbar
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

extension AppDelegate: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ToolbarItem.newCanvas, ToolbarItem.open, ToolbarItem.save, .flexibleSpace, ToolbarItem.zoomOut, ToolbarItem.zoomLabel, ToolbarItem.zoomIn]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case ToolbarItem.newCanvas:
            return makeButtonItem(id: itemIdentifier, label: "新規", symbol: "doc.badge.plus", action: #selector(newCanvas))
        case ToolbarItem.open:
            return makeButtonItem(id: itemIdentifier, label: "開く", symbol: "folder", action: #selector(openCanvas))
        case ToolbarItem.save:
            return makeButtonItem(id: itemIdentifier, label: "保存", symbol: "square.and.arrow.down", action: #selector(saveCanvas))
        case ToolbarItem.zoomIn:
            return makeButtonItem(id: itemIdentifier, label: "拡大", symbol: "plus.magnifyingglass", action: #selector(zoomIn))
        case ToolbarItem.zoomOut:
            return makeButtonItem(id: itemIdentifier, label: "縮小", symbol: "minus.magnifyingglass", action: #selector(zoomOut))
        case ToolbarItem.zoomLabel:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            let field = NSTextField(labelWithString: "\(canvasView.zoomScale)x")
            field.alignment = .center
            field.frame = NSRect(x: 0, y: 0, width: 40, height: 20)
            item.view = field
            item.label = "ズーム"
            zoomLabelItem = item
            return item
        default:
            return nil
        }
    }

    private func makeButtonItem(id: NSToolbarItem.Identifier, label: String, symbol: String, action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = label
        item.paletteLabel = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.target = self
        item.action = action
        return item
    }
}
