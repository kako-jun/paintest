import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var canvasView: CanvasView!
    private var scrollView: NSScrollView!

    private static let defaultCanvasSize = 64

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()

        let initialCanvas = PixelCanvas(width: Self.defaultCanvasSize, height: Self.defaultCanvasSize, background: .white)
        canvasView = CanvasView(canvas: initialCanvas)

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
        window.makeKeyAndOrderFront(nil)

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "paintestを終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "表示")
        viewMenu.addItem(withTitle: "拡大", action: #selector(zoomIn), keyEquivalent: "+")
        viewMenu.addItem(withTitle: "縮小", action: #selector(zoomOut), keyEquivalent: "-")
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func zoomIn() {
        canvasView.zoomIn()
    }

    @objc private func zoomOut() {
        canvasView.zoomOut()
    }
}
