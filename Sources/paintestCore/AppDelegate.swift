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
    private var optionBarView: OptionBarView!
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

    // Foreground/background color and recent-colors history: app-wide
    // state (issue #5), not per-document like `Document.zoomScale` — shared
    // across `canvasView`, `currentColorIndicator` and `colorPaletteView`,
    // the same as classic Paint/Photoshop's single current-color model.
    private var foregroundColor: NSColor = .black
    private var backgroundColor: NSColor = .white
    private var recentColors: [NSColor] = []

    private static let defaultCanvasSize = 64

    // Classic Windows chrome gray (192, 192, 192) — the background behind
    // the toolbox / palette / status bar, distinct from the white canvas.
    private static let chromeColor = NSColor(calibratedWhite: 0.753, alpha: 1)

    // A shade darker than `chromeColor`, used only for the thin divider
    // lines between レイヤー/プロパティ/ヒストリー (issue #7 self-review
    // must-2) so the three stacked panels read as visually distinct
    // sections instead of one undifferentiated gray block.
    private static let panelDividerColor = NSColor(calibratedWhite: 0.6, alpha: 1)

    // Single column of buttons (issue #7; was 2 columns' worth under #2):
    // button width + a little breathing room on each side, plus the
    // vertical scroller's own track width.
    private static let toolboxWidth: CGFloat = ToolboxView.buttonSide + 20
    // Derived, not guessed (issue #5 — the exact bug class from #7's
    // self-review: a fixed-height constant that silently stops matching the
    // content it wraps). `ColorPaletteView`'s swatch grid grew from 2 rows
    // to 3 (issue #5's "recent colors" row): swatchSide (18) * 3 rows +
    // rowSpacing (1) * 2 gaps = 56pt tall, up from the old 2-row grid's
    // 18*2+1 = 37pt. At the old colorBarHeight (44), the grid was centered
    // with an implicit (44-37)/2 = 3.5pt margin above and below (see
    // `ColorPaletteView.buildSwatches()`'s `grid.centerYAnchor` constraint).
    // Keeping that same ~3.5pt margin on the new 56pt-tall grid gives
    // 56 + 3.5*2 = 63.
    private static let colorBarHeight: CGFloat = 63
    private static let statusBarHeight: CGFloat = 22
    private static let colorIndicatorWidth: CGFloat = 48
    // Width of the whole right column — レイヤー/プロパティ/ヒストリー stacked
    // together, not just `layerPanelView` on its own (issue #7 self-review
    // should-4: this used to be named `layerPanelWidth` back when the layer
    // panel was the column's only occupant).
    private static let rightPanelWidth: CGFloat = 180
    private static let documentTabBarWidth: CGFloat = 140
    // Fixed heights for the right column's two frame-only panels (issue
    // #7): レイヤー stays the flexible one, growing/shrinking with the
    // window; プロパティ/ヒストリー are pinned to these heights as a plain
    // frame until their own issues give them real content.
    private static let propertyPanelHeight: CGFloat = 140
    private static let historyPanelHeight: CGFloat = 140
    // Floor on レイヤー's own height (issue #7 self-review must-1): without
    // this, `layerPanelView`'s height is whatever's left after subtracting
    // `propertyPanelHeight` + `historyPanelHeight` from the group's total
    // height, which goes negative once the window shrinks enough — Auto
    // Layout has no lower bound on it otherwise.
    //
    // 110pt is derived from `LayerPanelView.buildLayout()`'s own internal
    // required-priority constraint chain (issue #7 re-review): panelPadding
    // (6, top) + titleLabel (bold 11pt, intrinsic height ≈14) + gap (4) +
    // scrollView (flexible — can compress all the way to 0) + gap (4) +
    // buttonBar (28, fixed) + gap (4) + opacityRow (a label + slider row,
    // intrinsic height ≈12 + 2 + 20 = 34) + panelPadding (6, bottom) = 100pt
    // minimum with the scroll view fully collapsed. 110pt keeps a small
    // margin above that hard floor for font-rendering differences across
    // environments. Below the true 100pt floor, `LayerPanelView`'s own
    // internal required constraints would conflict with each other — a
    // silent breakage that doesn't show up in build/test logs, only as a
    // constraint-conflict warning and visible mis-layout at runtime. The
    // previous 60pt was well under that floor.
    private static let layerPanelMinHeight: CGFloat = 110
    // Thickness of the 1pt divider lines between レイヤー/プロパティ/ヒスト
    // リー (issue #7 self-review must-2).
    private static let panelDividerThickness: CGFloat = 1

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
            // Keeps the magnifier's options-bar dropdown in sync with
            // click/drag zoom, the View menu's zoom-in/out, and the
            // dropdown's own selection — not just changes made through the
            // dropdown itself (issue #13). Low-frequency operation, so
            // rebuilding the whole dropdown here is fine.
            if self?.canvasView.activeTool == .magnifier {
                self?.updateOptionBar(for: .magnifier)
            }
        }
        canvasView.onLayerContentChanged = { [weak self] in
            self?.layerPanelView.reload()
            // Keeps the tab strip's thumbnail in sync with in-progress
            // edits, not just with tab switches/new documents (review S1 on
            // #18): without this, a document's thumbnail only updated the
            // next time some other action happened to call
            // `documentTabBarView.reload()`.
            self?.documentTabBarView.reload()
            // Only fires on an actual pixel edit (pencil/pen/bucket/etc.),
            // never merely from switching tools or tabs — the correct
            // "dirty" signal for issue #4's unsaved-changes tracking.
            self?.documentManager.activeDocument.isDirty = true
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

        wireColorAndToolCallbacks()

        // Width increment matches the default window width's own increment
        // for the document tab strip (720 -> 860, i.e. +140pt for
        // `documentTabBarWidth`): 420 + 140 = 560. The previous 500 only
        // accounted for part of the tab strip's width, so shrinking to the
        // minimum squeezed the rest of the layout (review S3 on #18).
        //
        // Height is the sum of every fixed-height band stacked in the
        // center row, each of which is a `required`-priority constraint
        // that Auto Layout cannot shrink below (issue #7 self-review
        // must-1, recomputed for issue #5's `colorBarHeight` change):
        // `optionBarView` (30) + `colorBar` (63) + `statusBar` (22) +
        // `propertyPanelHeight` (140) + `historyPanelHeight` (140) +
        // `panelDividerThickness` × 2 (2, the two 1pt divider lines between
        // レイヤー/プロパティ/ヒストリー) + `layerPanelMinHeight` (110) = 507.
        // Below that, `layerPanelView`'s height (`rightPanelGroup`'s total
        // minus the two fixed panels and the two dividers) would have to go
        // negative to satisfy every constraint at once, which Auto Layout
        // cannot do — it would instead break one of the "required"
        // constraints and log a constraint-conflict warning while visibly
        // mis-laying-out the right column. The previous 488 used the old
        // 44pt `colorBarHeight`, from before issue #5 grew the color
        // palette's swatch grid from 2 rows to 3 — the exact same "fixed
        // constant drifts out of sync with what it wraps" bug #7's
        // self-review already caught once (must-1 above).
        window.minSize = NSSize(width: 560, height: 507)
        window.makeKeyAndOrderFront(nil)
        // Without this, the window's first responder stays whatever AppKit
        // defaults to for a plain, non-`NSResponder`-opinionated content
        // view (effectively nothing) — `canvasView` would never see a
        // `keyDown(with:)` at all, breaking the polygon select tool's
        // Escape-to-cancel/Return-to-close shortcuts (issue #11 round 2)
        // right from launch.
        window.makeFirstResponder(canvasView)

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Confirms unsaved changes across every open tab before quitting
    /// (issue #4) — this app is single-window, so "close the window" and
    /// "quit the app" are the same event. Each dirty document's tab is
    /// activated before its own confirmation dialog, so the user can see
    /// which document is being asked about; the first "キャンセル" answer
    /// aborts the whole quit and leaves the rest unasked.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        for index in documentManager.documents.indices {
            let document = documentManager.documents[index]
            guard document.isDirty else { continue }

            documentManager.selectDocument(at: index)
            activateActiveDocument()

            guard resolveUnsavedChanges(for: document) else {
                return .terminateCancel
            }
        }
        return .terminateNow
    }

    // MARK: - Root layout (issue #2: classic Paint's toolbox + canvas +
    // color palette + status bar impression, replacing #1's NSToolbar).

    private func makeRootView() -> NSView {
        let root = DropTargetView()
        root.wantsLayer = true
        root.layer?.backgroundColor = Self.chromeColor.cgColor
        // Dropping an image file anywhere on the window opens it in a new
        // tab (issue #4), the same as "開く…" — each dropped URL goes
        // through the same `openDocument(from:)` used by the panel, so
        // multiple files dropped at once each get their own tab.
        root.onFilesDropped = { [weak self] urls in
            urls.forEach { self?.openDocument(from: $0) }
        }

        // Photoshop's options bar (issue #7): spans the full window width,
        // above everything else — the document tab strip, toolbox, canvas,
        // and right panel group all sit below it. Empty frame for now; each
        // tool's own issue populates it once tool-switching exists.
        optionBarView = OptionBarView()
        optionBarView.translatesAutoresizingMaskIntoConstraints = false
        optionBarView.layer?.backgroundColor = Self.chromeColor.cgColor

        // The document tab strip is the leftmost element of the main
        // content row, further left than the toolbox — Edge's vertical
        // tabs, not Photoshop's horizontal tabs along the top (issue #15,
        // kept as-is per issue #7's explicit constraint not to change it).
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
        // Confirms unsaved changes before a tab actually closes (issue #4):
        // `DocumentTabBarView` itself doesn't know about dirty state, so it
        // asks back here before calling into `documentManager.closeDocument`.
        // An out-of-range index (shouldn't happen, but `sender.tag` is a
        // plain `Int` with no compile-time guarantee) is treated as "go
        // ahead and close" rather than silently blocking the close.
        documentTabBarView.onRequestClose = { [weak self] index in
            guard let self, self.documentManager.documents.indices.contains(index) else { return true }
            return self.resolveUnsavedChanges(for: self.documentManager.documents[index])
        }
        documentTabBarView.translatesAutoresizingMaskIntoConstraints = false
        documentTabBarView.wantsLayer = true
        documentTabBarView.layer?.backgroundColor = Self.chromeColor.cgColor

        toolboxView = ToolboxView()
        toolboxView.translatesAutoresizingMaskIntoConstraints = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // Right panel group (issue #7): レイヤー (existing, real
        // functionality, flexible height) stacked above プロパティ /
        // ヒストリー (frame-only placeholders, fixed height each), replacing
        // #8's single-panel-fills-the-column layout.
        let rightPanelGroup = makeRightPanelGroup()
        rightPanelGroup.translatesAutoresizingMaskIntoConstraints = false

        let colorBar = makeColorBar()
        colorBar.translatesAutoresizingMaskIntoConstraints = false

        let statusBar = makeStatusBar()
        statusBar.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(optionBarView)
        root.addSubview(documentTabBarView)
        root.addSubview(toolboxView)
        root.addSubview(scrollView)
        root.addSubview(rightPanelGroup)
        root.addSubview(colorBar)
        root.addSubview(statusBar)

        NSLayoutConstraint.activate([
            optionBarView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            optionBarView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            optionBarView.topAnchor.constraint(equalTo: root.topAnchor),
            optionBarView.heightAnchor.constraint(equalToConstant: OptionBarView.height),

            documentTabBarView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            documentTabBarView.topAnchor.constraint(equalTo: optionBarView.bottomAnchor),
            documentTabBarView.bottomAnchor.constraint(equalTo: colorBar.topAnchor),
            documentTabBarView.widthAnchor.constraint(equalToConstant: Self.documentTabBarWidth),

            toolboxView.leadingAnchor.constraint(equalTo: documentTabBarView.trailingAnchor),
            toolboxView.topAnchor.constraint(equalTo: optionBarView.bottomAnchor),
            toolboxView.bottomAnchor.constraint(equalTo: colorBar.topAnchor),
            toolboxView.widthAnchor.constraint(equalToConstant: Self.toolboxWidth),

            scrollView.leadingAnchor.constraint(equalTo: toolboxView.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: rightPanelGroup.leadingAnchor),
            scrollView.topAnchor.constraint(equalTo: optionBarView.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: colorBar.topAnchor),

            rightPanelGroup.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            rightPanelGroup.topAnchor.constraint(equalTo: optionBarView.bottomAnchor),
            rightPanelGroup.bottomAnchor.constraint(equalTo: colorBar.topAnchor),
            rightPanelGroup.widthAnchor.constraint(equalToConstant: Self.rightPanelWidth),

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

    /// Builds the right column's panel group: レイヤー (existing
    /// `LayerPanelView`, untouched, flexible height, with a
    /// `layerPanelMinHeight` floor so it can never be squeezed to zero or
    /// negative — issue #7 self-review must-1) stacked above two
    /// frame-only placeholders — プロパティ / ヒストリー — each pinned to a
    /// fixed height (issue #7). Thin 1pt divider views between panels use
    /// `panelDividerColor`, a darker shade than `chromeColor`, so the three
    /// panels read as visually distinct sections even though none of them
    /// draws its own border (issue #7 self-review must-2).
    private func makeRightPanelGroup() -> NSView {
        let group = NSView()
        group.wantsLayer = true
        group.layer?.backgroundColor = Self.chromeColor.cgColor

        // Provisional placement carried over from issue #8: a fixed-width
        // column docked to the right of the canvas. Reproducing the full
        // Photoshop layout is issue #7's scope; `LayerPanelView` itself is
        // untouched here.
        layerPanelView = LayerPanelView(layerStack: canvasView.layerStack)
        layerPanelView.onChange = { [weak self] in
            self?.canvasView.needsDisplay = true
            // Layer add/remove/duplicate/reorder/opacity/visibility changes
            // are content edits too, same as a pencil stroke (issue #4).
            self?.documentManager.activeDocument.isDirty = true
        }
        // Selecting a different layer row is not a content edit (issue #4
        // self-review must): redraw so the canvas reflects the new active
        // layer, but do NOT touch `isDirty`, or opening a saved document
        // and merely clicking another row would spuriously ask to save on
        // close/quit/open. (No AppDelegate-level wiring test exists for
        // this panel per this repo's convention; verified by running the
        // app: open a saved file, click another layer row, confirm no
        // save-changes prompt on quit.)
        layerPanelView.onSelectionChanged = { [weak self] in
            self?.canvasView.needsDisplay = true
        }
        layerPanelView.translatesAutoresizingMaskIntoConstraints = false
        layerPanelView.wantsLayer = true
        layerPanelView.layer?.backgroundColor = Self.chromeColor.cgColor

        let topDivider = makePanelDivider()
        let bottomDivider = makePanelDivider()

        let propertyPanelView = PlaceholderPanelView(title: "プロパティ")
        propertyPanelView.translatesAutoresizingMaskIntoConstraints = false

        let historyPanelView = PlaceholderPanelView(title: "ヒストリー")
        historyPanelView.translatesAutoresizingMaskIntoConstraints = false

        group.addSubview(layerPanelView)
        group.addSubview(topDivider)
        group.addSubview(propertyPanelView)
        group.addSubview(bottomDivider)
        group.addSubview(historyPanelView)

        NSLayoutConstraint.activate([
            layerPanelView.leadingAnchor.constraint(equalTo: group.leadingAnchor),
            layerPanelView.trailingAnchor.constraint(equalTo: group.trailingAnchor),
            layerPanelView.topAnchor.constraint(equalTo: group.topAnchor),
            layerPanelView.bottomAnchor.constraint(equalTo: topDivider.topAnchor),
            layerPanelView.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.layerPanelMinHeight),

            topDivider.leadingAnchor.constraint(equalTo: group.leadingAnchor),
            topDivider.trailingAnchor.constraint(equalTo: group.trailingAnchor),
            topDivider.bottomAnchor.constraint(equalTo: propertyPanelView.topAnchor),
            topDivider.heightAnchor.constraint(equalToConstant: Self.panelDividerThickness),

            propertyPanelView.leadingAnchor.constraint(equalTo: group.leadingAnchor),
            propertyPanelView.trailingAnchor.constraint(equalTo: group.trailingAnchor),
            propertyPanelView.bottomAnchor.constraint(equalTo: bottomDivider.topAnchor),
            propertyPanelView.heightAnchor.constraint(equalToConstant: Self.propertyPanelHeight),

            bottomDivider.leadingAnchor.constraint(equalTo: group.leadingAnchor),
            bottomDivider.trailingAnchor.constraint(equalTo: group.trailingAnchor),
            bottomDivider.bottomAnchor.constraint(equalTo: historyPanelView.topAnchor),
            bottomDivider.heightAnchor.constraint(equalToConstant: Self.panelDividerThickness),

            historyPanelView.leadingAnchor.constraint(equalTo: group.leadingAnchor),
            historyPanelView.trailingAnchor.constraint(equalTo: group.trailingAnchor),
            historyPanelView.bottomAnchor.constraint(equalTo: group.bottomAnchor),
            historyPanelView.heightAnchor.constraint(equalToConstant: Self.historyPanelHeight)
        ])

        return group
    }

    /// A 1pt divider strip between two stacked right-column panels (issue
    /// #7 self-review must-2). `translatesAutoresizingMaskIntoConstraints`
    /// is set here rather than at each call site since every use is
    /// identical — pinned on all four edges by the caller.
    private func makePanelDivider() -> NSView {
        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = Self.panelDividerColor.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        return divider
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

        // Edit / Image / Layer / Select / Window / Help: labels + a handful
        // of decorative items to match Photoshop's menu bar impression
        // (issue #7). None of these are wired to real behavior — that's
        // each feature's own issue — except View's zoom items, which carry
        // over from #2.
        // "選択の解除" used to be a decorative placeholder here (issue #2),
        // duplicating the real, wired "選択を解除" item in "選択範囲" below
        // (issue #11) — two same-labeled-in-spirit items on two different
        // menus looked like a bug, so the dead placeholder is dropped and
        // 選択範囲's own item is the single real entry point.
        mainMenu.addItem(makeMenuItem(title: "編集", placeholders: ["元に戻す", "切り取り", "コピー", "貼り付け"]))

        mainMenu.addItem(makeMenuItem(title: "表示", items: [
            ("拡大", #selector(zoomIn), "+"),
            ("縮小", #selector(zoomOut), "-")
        ], placeholders: ["ツール バー", "カラー ボックス", "ステータス バー"]))

        // "色" (issue #2's standalone Colors menu) is folded into "イメージ"
        // here (issue #7): Photoshop has no top-level Colors menu, so its
        // one placeholder item joins Image's placeholders instead of
        // staying a separate top-level menu.
        mainMenu.addItem(makeMenuItem(title: "イメージ", placeholders: ["反転と回転", "拡大縮小と傾斜", "色の反転", "属性…", "色の編集…"]))
        mainMenu.addItem(makeMenuItem(title: "レイヤー", placeholders: ["新規レイヤー", "レイヤーを複製", "レイヤーを削除", "下のレイヤーと結合"]))
        mainMenu.addItem(makeMenuItem(title: "選択範囲", items: [
            ("すべてを選択", #selector(selectAll), "a"),
            ("選択を解除", #selector(deselectAll), "d"),
            ("選択範囲を反転", #selector(invertSelection), "i")
        ]))
        mainMenu.addItem(makeMenuItem(title: "ウインドウ", placeholders: ["レイヤー", "プロパティ", "ヒストリー"]))
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
        // Selection is per-document state too, same pattern as zoom above
        // (issue #11): write the outgoing document's selection back from
        // `canvasView` before swapping, then apply the newly active
        // document's own remembered selection. Without this, a selection
        // would leak across tabs as shared state on the single `CanvasView`
        // instance instead of following each document independently.
        displayedDocument?.selection = canvasView.selection

        let document = documentManager.activeDocument
        canvasView.replaceLayerStack(document.layerStack)
        canvasView.setZoomScale(document.zoomScale)
        canvasView.selection = document.selection
        layerPanelView.replaceLayerStack(document.layerStack)
        documentTabBarView.reload()
        updateWindowTitle(for: document)

        // No separate options-bar refresh needed here: `setZoomScale(_:)`
        // above synchronously fires `onZoomChanged`, which already calls
        // `updateOptionBar(for: .magnifier)` when the magnifier is active
        // (issue #13) — same thread, same call stack, so `activeTool`
        // can't change in between.

        displayedDocument = document
    }

    // MARK: - Selection menu (issue #11)

    /// Applies a new selection to both `canvasView` (what's actually drawn/
    /// enforced right now) and `documentManager.activeDocument` (what
    /// persists across a tab switch, mirrored by `activateActiveDocument()`
    /// above) in one place, so the three selection menu commands below can't
    /// accidentally update one and forget the other.
    ///
    /// `mask` is normalized the same way `CanvasView.mouseUp(with:)` does
    /// for a dragged selection (issue #11, same decision): an empty mask
    /// collapses to `nil` rather than being kept as a real, all-`false`
    /// `SelectionMask`, since an empty selection would otherwise block all
    /// editing everywhere.
    private func applySelection(_ mask: SelectionMask?) {
        let normalized = (mask?.isEmpty ?? false) ? nil : mask
        canvasView.selection = normalized
        // `displayedDocument` (not `documentManager.activeDocument`) is the
        // document `canvasView` is actually showing right now — see
        // `displayedDocument`'s own doc comment — so writing there keeps
        // this in lock-step with whichever document these menu commands
        // are actually acting on.
        displayedDocument?.selection = normalized
    }

    /// "すべてを選択": selects every pixel of the active document's canvas.
    @objc private func selectAll() {
        let mask = SelectionMask.rectangle(
            x0: 0, y0: 0,
            x1: canvasView.layerStack.width - 1, y1: canvasView.layerStack.height - 1,
            width: canvasView.layerStack.width, height: canvasView.layerStack.height
        )
        applySelection(mask)
    }

    /// "選択を解除": clears the selection back to "no restriction".
    @objc private func deselectAll() {
        applySelection(nil)
    }

    /// "選択範囲を反転". When there's no active selection, `nil` is treated
    /// as "everything is (implicitly) selected" purely for this command's
    /// own reasoning: inverting "everything" would produce an empty
    /// selection, which `applySelection`'s own normalization would collapse
    /// straight back to `nil` anyway — so the actual computation is skipped
    /// and `nil` is passed straight through as a no-op. This is a
    /// *different* rule from `CanvasView.mouseUp(with:)`'s drag-combine
    /// math, which instead treats `nil` as "empty" (see that method's own
    /// doc comment) — the two operations don't share one universal "what
    /// does nil mean" convention, each is reasoned about independently for
    /// its own command's semantics.
    @objc private func invertSelection() {
        guard let selection = canvasView.selection else {
            applySelection(nil)
            return
        }
        applySelection(selection.inverted())
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

        openDocument(from: url)
    }

    /// Loads `url` into a new `Document` and opens it in a new tab. Shared
    /// by `openCanvas()` (panel-driven "開く…") and drag-and-drop (issue
    /// #4) so the `.paintestdoc`-vs-PNG branch and its error handling live
    /// in exactly one place.
    private func openDocument(from url: URL) {
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
    /// close button. Unsaved changes on the tab being closed are confirmed
    /// first (issue #4); a "キャンセル" answer aborts the close entirely.
    @objc private func closeActiveTab() {
        guard resolveUnsavedChanges(for: documentManager.activeDocument) else { return }
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
            document.isDirty = false
            documentTabBarView.reload()
            updateWindowTitle(for: document)
        } catch {
            presentError("ファイルの保存に失敗しました: \(error.localizedDescription)")
        }
    }

    @objc private func saveLayeredCanvas() {
        saveLayeredCanvasWithPanel(documentManager.activeDocument)
    }

    /// Shows the panel for "名前を付けて保存（レイヤー保持）…" for `document`
    /// and writes it as `.paintestdoc`. Factored out of the `@objc` menu
    /// action (issue #4) so `quickSave(_:)` can fall back to this same
    /// panel flow for a document that has never been saved before, instead
    /// of duplicating the panel/write/error-handling logic. Named
    /// distinctly from `saveLayeredCanvas()` (rather than overloaded on
    /// parameters) so `#selector(saveLayeredCanvas)` above stays
    /// unambiguous — Swift's `#selector` cannot disambiguate between
    /// overloads that differ only in parameters.
    @discardableResult
    private func saveLayeredCanvasWithPanel(_ document: Document) -> Bool {
        let panel = NSSavePanel()
        let paintestDocType = UTType(filenameExtension: "paintestdoc") ?? .data
        panel.allowedContentTypes = [paintestDocType]
        panel.nameFieldStringValue = "\(document.displayName).paintestdoc"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            try PaintestDocument.write(document.layerStack, to: url)
            document.displayName = url.deletingPathExtension().lastPathComponent
            document.fileURL = url
            document.isDirty = false
            documentTabBarView.reload()
            updateWindowTitle(for: document)
            return true
        } catch {
            presentError("ドキュメントの保存に失敗しました: \(error.localizedDescription)")
            return false
        }
    }

    /// A quick save that overwrites the document's existing save location
    /// (issue #4), used by the unsaved-changes confirmation dialog's "保存"
    /// button: re-showing a save panel every time that dialog appears would
    /// be an odd UX detour when the document already has a known save
    /// location.
    ///
    /// If `document.fileURL` is set, overwrites it directly — `.paintestdoc`
    /// via `PaintestDocument.write`, anything else (PNG, etc.) via
    /// flattened PNG data. If there is no `fileURL` yet (never saved),
    /// falls back to the layer-preserving save panel rather than the
    /// flattening PNG one: in the confirmation-dialog context, the save
    /// that loses the least information is the more sensible default.
    ///
    /// Returns `true` once the save has actually completed (so the
    /// caller's original operation — closing a tab, quitting — may
    /// proceed), `false` if it failed or the panel was canceled.
    private func quickSave(_ document: Document) -> Bool {
        guard let url = document.fileURL else {
            return saveLayeredCanvasWithPanel(document)
        }

        if url.pathExtension.lowercased() == "paintestdoc" {
            do {
                try PaintestDocument.write(document.layerStack, to: url)
                document.isDirty = false
                documentTabBarView.reload()
                updateWindowTitle(for: document)
                return true
            } catch {
                presentError("ドキュメントの保存に失敗しました: \(error.localizedDescription)")
                return false
            }
        }

        guard let data = document.layerStack.flattenedPNGData() else {
            presentError("PNGへの変換に失敗しました。")
            return false
        }
        do {
            try data.write(to: url)
            document.isDirty = false
            documentTabBarView.reload()
            updateWindowTitle(for: document)
            return true
        } catch {
            presentError("ファイルの保存に失敗しました: \(error.localizedDescription)")
            return false
        }
    }

    /// Unsaved-changes confirmation (issue #4). If `document` is not dirty,
    /// returns `true` immediately without showing anything. Otherwise
    /// shows a 保存/破棄/キャンセル `NSAlert` and acts on the choice.
    ///
    /// Returns `true` if the caller's own operation (closing a tab,
    /// quitting the app) may proceed, `false` if it should be aborted.
    private func resolveUnsavedChanges(for document: Document) -> Bool {
        guard document.isDirty else { return true }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\"\(document.displayName)\" に未保存の変更があります"
        alert.informativeText = "変更を保存しますか？"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "破棄")
        alert.addButton(withTitle: "キャンセル")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return quickSave(document)
        case .alertSecondButtonReturn:
            return true
        default:
            return false
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

    // MARK: - Color and tool wiring (issue #5)

    /// Wires `toolboxView`/`colorPaletteView`/`currentColorIndicator`'s
    /// callbacks to this delegate's `foregroundColor`/`backgroundColor`/
    /// `recentColors` state, and pushes the initial black/white colors onto
    /// `canvasView` and `currentColorIndicator` so both start in sync with
    /// this delegate before the user picks anything.
    private func wireColorAndToolCallbacks() {
        canvasView.foregroundColor = foregroundColor
        canvasView.backgroundColor = backgroundColor
        currentColorIndicator.foregroundColor = foregroundColor
        currentColorIndicator.backgroundColor = backgroundColor

        toolboxView.onToolSelected = { [weak self] tool in
            self?.canvasView.activeTool = tool
            self?.updateOptionBar(for: tool)
        }

        // Eyedropper tool (issue #14): reuses the same `setColor` entry
        // point as the color palette/picker, so foreground/background, the
        // current-color indicator, and recent colors all update together.
        canvasView.onColorPicked = { [weak self] color, isSecondary in
            self?.setColor(color, secondary: isSecondary)
        }

        colorPaletteView.onSwatchSelected = { [weak self] color, isSecondary in
            self?.setColor(color, secondary: isSecondary)
        }

        currentColorIndicator.onForegroundSwatchTapped = { [weak self] in
            guard let self else { return }
            if let picked = ColorPickerDialog.promptForColor(initial: self.foregroundColor) {
                self.setColor(picked, secondary: false)
            }
        }
        currentColorIndicator.onBackgroundSwatchTapped = { [weak self] in
            guard let self else { return }
            if let picked = ColorPickerDialog.promptForColor(initial: self.backgroundColor) {
                self.setColor(picked, secondary: true)
            }
        }
        currentColorIndicator.onResetToDefaultTapped = { [weak self] in
            self?.resetColorsToDefault()
        }
    }

    /// Updates the foreground (`secondary == false`) or background
    /// (`secondary == true`) color, propagating it to `canvasView` and
    /// `currentColorIndicator`, and records it in `recentColors` (issue #5).
    private func setColor(_ color: NSColor, secondary: Bool) {
        if secondary {
            backgroundColor = color
            canvasView.backgroundColor = color
            currentColorIndicator.backgroundColor = color
        } else {
            foregroundColor = color
            canvasView.foregroundColor = color
            currentColorIndicator.foregroundColor = color
        }
        currentColorIndicator.needsDisplay = true

        recentColors = ColorPaletteView.updatedRecentColors(
            adding: color,
            to: recentColors,
            capacity: ColorPaletteView.recentColorsCapacity
        )
        colorPaletteView.updateRecentColors(recentColors)
    }

    /// Populates (or clears) the options bar to match the newly selected
    /// tool (issue #13). The magnifier's zoom-level dropdown and the magic
    /// wand's tolerance slider (issue #11, round 3) are the only tools with
    /// options of their own so far — every other tool just clears the bar
    /// back to its empty frame.
    private func updateOptionBar(for tool: Tool) {
        switch tool {
        case .magnifier:
            optionBarView.showZoomPresets(currentZoomScale: canvasView.zoomScale, levels: CanvasView.zoomLevels) { [weak self] scale in
                self?.canvasView.setZoomScale(scale)
            }
        case .magicWandSelect:
            optionBarView.showMagicWandOptions(currentTolerance: canvasView.magicWandTolerance) { [weak self] tolerance in
                self?.canvasView.magicWandTolerance = tolerance
            }
        default:
            optionBarView.clear()
        }
    }

    /// Restores foreground/background to classic Paint's black/white
    /// default (issue #5). Deliberately does not touch `recentColors` —
    /// resetting to the default isn't "using" a color the way picking one
    /// from the picker or palette is.
    private func resetColorsToDefault() {
        foregroundColor = .black
        backgroundColor = .white
        canvasView.foregroundColor = .black
        canvasView.backgroundColor = .white
        currentColorIndicator.foregroundColor = .black
        currentColorIndicator.backgroundColor = .white
        currentColorIndicator.needsDisplay = true
    }
}
