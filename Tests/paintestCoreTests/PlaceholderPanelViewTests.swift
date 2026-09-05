import AppKit
import XCTest
@testable import paintestCore

final class PlaceholderPanelViewTests: XCTestCase {
    private func findLabels(in view: NSView) -> [NSTextField] {
        var result: [NSTextField] = []
        for subview in view.subviews {
            if let field = subview as? NSTextField {
                result.append(field)
            }
            result.append(contentsOf: findLabels(in: subview))
        }
        return result
    }

    func testInit_doesNotCrash_withPropertyTitle() {
        _ = PlaceholderPanelView(title: "プロパティ")
    }

    func testInit_doesNotCrash_withHistoryTitle() {
        _ = PlaceholderPanelView(title: "ヒストリー")
    }

    func testTitleLabel_displaysGivenTitle() {
        let view = PlaceholderPanelView(title: "プロパティ")

        let labels = findLabels(in: view)
        XCTAssertTrue(labels.contains { $0.stringValue == "プロパティ" }, "the given title should be rendered in a label")
    }

    func testTitleLabel_isBold() {
        let view = PlaceholderPanelView(title: "プロパティ")

        guard let label = findLabels(in: view).first(where: { $0.stringValue == "プロパティ" }) else {
            XCTFail("could not find the title label")
            return
        }
        let expectedBoldFont = NSFont.boldSystemFont(ofSize: 11)
        XCTAssertEqual(label.font, expectedBoldFont, "the panel title must be bold so it reads as a header")
    }
}
