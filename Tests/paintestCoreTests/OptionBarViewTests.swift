import AppKit
import XCTest
@testable import paintestCore

final class OptionBarViewTests: XCTestCase {
    private func makeView() -> OptionBarView {
        OptionBarView()
    }

    func testInit_doesNotCrash() {
        _ = makeView()
    }

    func testHeight_matchesStaticHeightConstant() {
        XCTAssertEqual(OptionBarView.height, 30)
    }

    func testWantsLayer_isTrue() {
        let view = makeView()
        XCTAssertTrue(view.wantsLayer, "the option bar must have a backing layer so it can be chrome-colored")
    }
}
