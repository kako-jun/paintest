import AppKit
import XCTest
@testable import paintestCore

/// Tests for `HistoryPanelView` (issue #19 round 2): the read-only history
/// list UI. Following `LayerPanelViewTests`' own documented convention,
/// this doesn't re-derive the panel's full layout — just confirms the
/// row-per-entry structure, current-entry highlight, and click-to-jump
/// wiring actually reflect `entries`/`currentIndex` as given.
final class HistoryPanelViewTests: XCTestCase {
    private func findScrollView(in view: NSView) -> NSScrollView? {
        for subview in view.subviews {
            if let scrollView = subview as? NSScrollView { return scrollView }
            if let found = findScrollView(in: subview) { return found }
        }
        return nil
    }

    /// The history rows, top to bottom (oldest-to-newest — see
    /// `HistoryPanelView`'s own doc comment on display order).
    private func rows(in panel: HistoryPanelView) -> [NSView] {
        guard let scrollView = findScrollView(in: panel), let documentView = scrollView.documentView else { return [] }
        return documentView.subviews
    }

    private func label(in row: NSView) -> NSTextField? {
        row.subviews.compactMap { $0 as? NSTextField }.first
    }

    private func isHighlighted(_ row: NSView) -> Bool {
        row.layer?.backgroundColor != NSColor.clear.cgColor
    }

    private func makeEntries(_ labels: [String]) -> [HistoryEntry] {
        labels.map { HistoryEntry(layerStack: LayerStack(width: 2, height: 2), label: $0) }
    }

    /// `HistoryRowView.mouseDown` ignores its argument entirely
    /// (`onSelectRow?()`), same as `LayerRowView` in `LayerPanelViewTests`.
    private func dummyMouseDownEvent() -> NSEvent {
        NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }

    // MARK: - Row count and labels (test list 20-21)

    func testInit_rowCountMatchesEntriesCount() {
        let entries = makeEntries(["初期状態", "鉛筆", "選択範囲"])
        let panel = HistoryPanelView(entries: entries, currentIndex: 2)

        XCTAssertEqual(rows(in: panel).count, 3)
    }

    func testInit_rowLabelsMatchEntryLabels_oldestToNewestTopToBottom() {
        let entries = makeEntries(["初期状態", "鉛筆", "選択範囲"])
        let panel = HistoryPanelView(entries: entries, currentIndex: 2)

        let texts = rows(in: panel).map { label(in: $0)?.stringValue }
        XCTAssertEqual(texts, ["初期状態", "鉛筆", "選択範囲"])
    }

    // MARK: - Current-entry highlight (test list 22)

    func testInit_onlyTheCurrentIndexRowIsHighlighted() {
        let entries = makeEntries(["初期状態", "鉛筆", "選択範囲"])
        let panel = HistoryPanelView(entries: entries, currentIndex: 1)

        let highlighted = rows(in: panel).map(isHighlighted)
        XCTAssertEqual(highlighted, [false, true, false])
    }

    // MARK: - Click-to-jump (test list 23)

    func testRowClick_firesOnJumpToIndexWithThatRowsIndex() {
        let entries = makeEntries(["初期状態", "鉛筆", "選択範囲"])
        let panel = HistoryPanelView(entries: entries, currentIndex: 0)
        var jumpedTo: Int?
        panel.onJumpToIndex = { jumpedTo = $0 }

        rows(in: panel)[2].mouseDown(with: dummyMouseDownEvent())

        XCTAssertEqual(jumpedTo, 2)
    }

    // MARK: - reload(entries:currentIndex:) rebuilds every row (test list 24, 28)

    func testReload_withMoreEntries_rebuildsAllRowsToTheNewCountAndLabels() {
        let panel = HistoryPanelView(entries: makeEntries(["初期状態"]), currentIndex: 0)

        panel.reload(entries: makeEntries(["初期状態", "鉛筆", "消しゴム"]), currentIndex: 2)

        let rowsAfter = rows(in: panel)
        XCTAssertEqual(rowsAfter.count, 3)
        XCTAssertEqual(rowsAfter.map { label(in: $0)?.stringValue }, ["初期状態", "鉛筆", "消しゴム"])
    }

    func testReload_withFewerEntries_leavesNoStaleRowsBehind() {
        let panel = HistoryPanelView(entries: makeEntries(["初期状態", "鉛筆", "消しゴム"]), currentIndex: 2)

        panel.reload(entries: makeEntries(["初期状態"]), currentIndex: 0)

        XCTAssertEqual(rows(in: panel).count, 1, "reload with fewer entries must not leave the old, extra rows behind")
    }

    // MARK: - Boundary: single entry (test list 25)

    func testInit_singleEntry_showsOneRowAlwaysHighlighted() {
        let panel = HistoryPanelView(entries: makeEntries(["初期状態"]), currentIndex: 0)

        let allRows = rows(in: panel)
        XCTAssertEqual(allRows.count, 1)
        XCTAssertTrue(isHighlighted(allRows[0]))
    }

    // MARK: - Boundary: highlight at the first/last row (test list 26-27)

    func testInit_currentIndexZero_highlightsTheFirstRowOnly() {
        let panel = HistoryPanelView(entries: makeEntries(["初期状態", "鉛筆", "消しゴム"]), currentIndex: 0)

        XCTAssertEqual(rows(in: panel).map(isHighlighted), [true, false, false])
    }

    func testInit_currentIndexLast_highlightsTheLastRowOnly() {
        let entries = makeEntries(["初期状態", "鉛筆", "消しゴム"])
        let panel = HistoryPanelView(entries: entries, currentIndex: entries.count - 1)

        XCTAssertEqual(rows(in: panel).map(isHighlighted), [false, false, true])
    }

    // MARK: - Combination / regression (test list 29-30)

    func testReload_calledRepeatedly_rowClicksAlwaysFireTheCurrentIndex_noStaleClosures() {
        let panel = HistoryPanelView(entries: makeEntries(["初期状態", "鉛筆"]), currentIndex: 1)
        var jumpedTo: Int?
        panel.onJumpToIndex = { jumpedTo = $0 }

        panel.reload(entries: makeEntries(["初期状態", "鉛筆", "消しゴム"]), currentIndex: 2)
        panel.reload(entries: makeEntries(["初期状態", "鉛筆", "消しゴム", "投げ縄"]), currentIndex: 3)

        rows(in: panel)[3].mouseDown(with: dummyMouseDownEvent())
        XCTAssertEqual(jumpedTo, 3, "a row built by the latest reload() must report its own, current index")

        rows(in: panel)[0].mouseDown(with: dummyMouseDownEvent())
        XCTAssertEqual(jumpedTo, 0, "no stale closure from an earlier reload() should still be attached to this row")
    }

    func testRowClick_duplicateLabels_eachRowStillReportsItsOwnDistinctIndex() {
        let entries = makeEntries(["鉛筆", "鉛筆", "鉛筆"])
        let panel = HistoryPanelView(entries: entries, currentIndex: 2)
        var jumpedTo: Int?
        panel.onJumpToIndex = { jumpedTo = $0 }

        rows(in: panel)[0].mouseDown(with: dummyMouseDownEvent())
        XCTAssertEqual(jumpedTo, 0)

        rows(in: panel)[1].mouseDown(with: dummyMouseDownEvent())
        XCTAssertEqual(jumpedTo, 1)

        rows(in: panel)[2].mouseDown(with: dummyMouseDownEvent())
        XCTAssertEqual(jumpedTo, 2)
    }
}
