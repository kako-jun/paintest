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
    private var layerPanelView: LayerPanelView!
    private var documentTabBarView: DocumentTabBarView!
    private var documentManager: DocumentManager!
    // The document currently shown by `canvasView`, tracked separately from
    // `documentManager.activeDocument` because by the time
    // `activateActiveDocument()` runs, `documentManager` has already moved
    // on to the new active document (`DocumentTabBarView`/`closeDocument(at:)`
    // update it before invoking the `onSelect`/`onClose` callback). Without
    // this, there would be no way to know which document's zoom to write
    // `canvasView.zoomScale` back into before swapping to the new one.
    private var displayedDocument: Document!
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
    private static let layerPanelWidth: CGFloat = 180
    private static let documentTabBarWidth: CGFloat = 140

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Classic Paint's chrome (Windows Classic silver/gray) is always a
        // light theme. Without this, macOS Dark Mode recolors the window
        // frame/controls dark and clashes with the reference screenshots'
        // fixed light impression (issue #2 follow-up).
        NSApp.appearance = NSAppearance(named: .aqua)

        buildMainMenu()

        let initialLayerStack = LayerStack(width: Self.defaultCanvasSize, height: Self.defaultCanvasSize, background: .white)
        let initialDocument = Document(layerStack: initialLayerStack, displayName: "untitled")
        documentManager = DocumentManager(initialDocument: initialDocument)
        displayedDocument = initialDocument

        canvasView = CanvasView(layerStack: documentManager.activeDocument.layerStack)
        canvasView.onZoomChanged = { [weak self] scale in
            self?.zoomLabelField?.stringValue = "\(scale)x"
        }
        canvasView.onLayerContentChanged = { [weak self] in
            self?.layerPanelView.reload()
            // Keeps the tab strip's thumbnail in sync with in-progress
            // edits, not just with tab switches/new documents (review S1 on
            // #18): without this, a document's thumbnail only updated the
            // next time some other action happened to call
            // `documentTabBarView.reload()`.
            self?.documentTabBarView.reload()
        }

        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        // No horizontal scroller (issue #22): with it enabled, AppKit
        // permanently reserves a scroller-track strip along the *bottom*
        // edge of the scroll view — confirmed via Accessibility as a
        // dedicated `AXScrollBar` frame sitting flush above `colorBar` — even
        // when the canvas is smaller than the viewport and nothing is
        // scrollable in that direction (the common case: a 64x64 canvas at
        // the default zoom). That reserved strip reads as an extra, uneven
        // margin between the canvas and the color bar below it, one that has
        // no counterpart on the toolbox/layer-panel sides (which butt
        // directly against the canvas with no reserved chrome). Horizontal
        // panning for wider canvases is still available via trackpad/scroll
        // wheel; only the always-visible drag handle is gone. The vertical
        // scroller stays on, since tall canvases needing it are common.
        scrollView.hasHorizontalScroller = false
        scrollView.allowsMagnification = false
        scrollView.documentView = canvasView
        scrollView.backgroundColor = .windowBackgroundColor

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(documentManager.activeDocument.displayName) - paintest"
        window.appearance = NSAppearance(named: .aqua)
        window.center()
        window.contentView = makeRootView()
        // Width increment matches the default window width's own increment
        // for the document tab strip (720 -> 860, i.e. +140pt for
        // `documentTabBarWidth`): 420 + 140 = 560. The previous 500 only
        // accounted for part of the tab strip's width, so shrinking to the
        // minimum squeezed the rest of the layout (review S3 on #18).
        window.minSize = NSSize(width: 560, height: 320)
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

        // Provisional placement (issue #15): the document tab strip is the
        // leftmost element, further left than the toolbox — Edge's vertical
        // tabs, not Photoshop's horizontal tabs along the top. Reconciling
        // this with the full Photoshop layout is issue #7's scope, not this
        // one.
        documentTabBarView = DocumentTabBarView(documentManager: documentManager)
        documentTabBarView.onSelect = { [weak self] in
            self?.activateActiveDocument()
        }
        documentTabBarView.onClose = { [weak self] in
            self?.activateActiveDocument()
        }
        documentTabBarView.onNewDocumentRequested = { [weak self] in
            self?.newCanvas()
        }
        documentTabBarView.translatesAutoresizingMaskIntoConstraints = false
        documentTabBarView.wantsLayer = true
        documentTabBarView.layer?.backgroundColor = Self.chromeColor.cgColor

        toolboxView = ToolboxView()
        toolboxView.translatesAutoresizingMaskIntoConstraints = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // Provisional placement (issue #8): a fixed-width panel docked to
        // the right of the canvas. Reproducing the full Photoshop layout is
        // issue #7's scope, not this one.
        layerPanelView = LayerPanelView(layerStack: canvasView.layerStack)
        layerPanelView.onChange = { [weak self] in
            self?.canvasView.needsDisplay = true
        }
        layerPanelView.translatesAutoresizingMaskIntoConstraints = false
        layerPanelView.wantsLayer = true
        layerPanelView.layer?.backgroundColor = Self.chromeColor.cgColor

        let colorBar = makeColorBar()
        colorBar.translatesAutoresizingMaskIntoConstraints = false

        let statusBar = makeStatusBar()
        statusBar.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(documentTabBarView)
        root.addSubview(toolboxView)
        root.addSubview(scrollView)
        root.addSubview(layerPanelView)
        root.addSubview(colorBar)
        root.addSubview(statusBar)

        NSLayoutConstraint.activate([
            documentTabBarView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            documentTabBarView.topAnchor.constraint(equalTo: root.topAnchor),
            documentTabBarView.bottomAnchor.constraint(equalTo: colorBar.topAnchor),
            documentTabBarView.widthAnchor.constraint(equalToConstant: Self.documentTabBarWidth),

            toolboxView.leadingAnchor.constraint(equalTo: documentTabBarView.trailingAnchor),
            toolboxView.topAnchor.constraint(equalTo: root.topAnchor),
            toolboxView.bottomAnchor.constraint(equalTo: colorBar.topAnchor),
            toolboxView.widthAnchor.constraint(equalToConstant: Self.toolboxWidth),

            scrollView.leadingAnchor.constraint(equalTo: toolboxView.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: layerPanelView.leadingAnchor),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: colorBar.topAnchor),

            layerPanelView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            layerPanelView.topAnchor.constraint(equalTo: root.topAnchor),
            layerPanelView.bottomAnchor.constraint(equalTo: colorBar.topAnchor),
            layerPanelView.widthAnchor.constraint(equalToConstant: Self.layerPanelWidth),

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
            ("保存…", #selector(saveCanvas), "s"),
            ("名前を付けて保存（レイヤー保持）…", #selector(saveLayeredCanvas), ""),
            ("タブを閉じる", #selector(closeActiveTab), "w")
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

    /// Rewires the canvas/layer panel/tab strip to the now-active document.
    /// Called whenever `documentManager.activeDocumentIndex` changes for any
    /// reason (tab clicked, tab closed, new document created, file opened).
    ///
    /// Zoom is per-document state (issue #15 follow-up): before swapping the
    /// canvas over, the previously displayed document's zoom is written back
    /// from `canvasView`, then the newly active document's own remembered
    /// zoom is applied. Without this, zoom would leak across tabs as shared
    /// state on the single `CanvasView` instance instead of following each
    /// document independently.
    private func activateActiveDocument() {
        displayedDocument?.zoomScale = canvasView.zoomScale

        let document = documentManager.activeDocument
        canvasView.replaceLayerStack(document.layerStack)
        canvasView.setZoomScale(document.zoomScale)
        layerPanelView.replaceLayerStack(document.layerStack)
        documentTabBarView.reload()
        updateWindowTitle(for: document)

        displayedDocument = document
    }

    /// Takes the `Document` to title for explicitly, rather than re-reading
    /// `documentManager.activeDocument` itself (review S4 on #18):
    /// `saveCanvas`/`saveLayeredCanvas` capture `document` before showing a
    /// modal save panel and write results back onto that same reference
    /// afterward, so titling from that captured reference keeps this in
    /// lock-step with whichever document was actually just saved instead of
    /// relying on it still being the active one by the time the panel closes.
    private func updateWindowTitle(for document: Document) {
        window.title = "\(document.displayName) - paintest"
    }

    /// Creates a new blank document and opens it in a new tab (issue #15:
    /// "新規作成…で新しいタブが追加される" — this does not replace the
    /// currently active tab).
    @objc private func newCanvas() {
        guard let size = NewCanvasDialog.promptForSize() else { return }
        let layerStack = LayerStack(width: size.width, height: size.height, background: .white)
        documentManager.addDocument(Document(layerStack: layerStack, displayName: "untitled"))
        activateActiveDocument()
    }

    /// Opens a file into a new tab (issue #15: "開く…で新しいタブが追加
    /// される" — this does not replace the currently active tab).
    @objc private func openCanvas() {
        let panel = NSOpenPanel()
        // `.paintestdoc` is written out as a plain directory (a package),
        // and this project has no `.app` bundle/Info.plist to declare it as
        // a proper package UTI (SwiftPM executable target only — see issue
        // #8 review). Without that declaration, a dynamic
        // `UTType(filenameExtension:)` doesn't reliably let the panel treat
        // a `.paintestdoc` as a selectable "file": `allowedContentTypes`
        // filtering and directory selection don't mix well. So instead of
        // fighting that, leave `allowedContentTypes` unset (allow any file)
        // and just allow choosing directories too, so both a `.png` file and
        // a `.paintestdoc` directory can be picked here. The existing
        // extension-based branch below still decides how to read whatever
        // was chosen.
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        if url.pathExtension.lowercased() == "paintestdoc" {
            guard let layerStack = PaintestDocument.read(from: url) else {
                presentError("ドキュメントの読み込みに失敗しました。")
                return
            }
            documentManager.addDocument(Document(layerStack: layerStack, displayName: url.deletingPathExtension().lastPathComponent, fileURL: url))
            activateActiveDocument()
            return
        }

        do {
            let data = try Data(contentsOf: url)
            guard let canvas = PixelCanvas.load(from: data) else {
                presentError("PNGの読み込みに失敗しました。")
                return
            }
            let layerStack = LayerStack(width: canvas.width, height: canvas.height, layers: [Layer(canvas: canvas, name: "レイヤー1")])
            documentManager.addDocument(Document(layerStack: layerStack, displayName: url.deletingPathExtension().lastPathComponent, fileURL: url))
            activateActiveDocument()
        } catch {
            presentError("ファイルの読み込みに失敗しました: \(error.localizedDescription)")
        }
    }

    /// Closes the currently active tab (issue #18 review S5: "タブを閉じる"
    /// / Cmd+W). `DocumentManager.closeDocument(at:)` never leaves zero open
    /// documents — closing the last tab replaces it with a fresh blank one
    /// — so this is always safe to invoke, the same as clicking a tab's own
    /// close button.
    @objc private func closeActiveTab() {
        documentManager.closeDocument(at: documentManager.activeDocumentIndex)
        activateActiveDocument()
    }

    /// PNG export: flattens all layers into a single image, since PNG can't
    /// hold layer structure. "名前を付けて保存（レイヤー保持）…" is the
    /// counterpart that keeps layers intact.
    @objc private func saveCanvas() {
        let document = documentManager.activeDocument
        guard let data = document.layerStack.flattenedPNGData() else {
            presentError("PNGへの変換に失敗しました。")
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(document.displayName).png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
            document.displayName = url.deletingPathExtension().lastPathComponent
            document.fileURL = url
            documentTabBarView.reload()
            updateWindowTitle(for: document)
        } catch {
            presentError("ファイルの保存に失敗しました: \(error.localizedDescription)")
        }
    }

    @objc private func saveLayeredCanvas() {
        let document = documentManager.activeDocument
        let panel = NSSavePanel()
        let paintestDocType = UTType(filenameExtension: "paintestdoc") ?? .data
        panel.allowedContentTypes = [paintestDocType]
        panel.nameFieldStringValue = "\(document.displayName).paintestdoc"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try PaintestDocument.write(document.layerStack, to: url)
            document.displayName = url.deletingPathExtension().lastPathComponent
            document.fileURL = url
            documentTabBarView.reload()
            updateWindowTitle(for: document)
        } catch {
            presentError("ドキュメントの保存に失敗しました: \(error.localizedDescription)")
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
