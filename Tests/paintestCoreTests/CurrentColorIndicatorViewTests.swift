import AppKit
import XCTest
@testable import paintestCore

final class CurrentColorIndicatorViewTests: XCTestCase {
    func testInit_doesNotCrash() {
        _ = CurrentColorIndicatorView()
    }

    func testDefaultColors_areBlackForegroundAndWhiteBackground() {
        let view = CurrentColorIndicatorView()
        XCTAssertEqual(view.foregroundColor, .black)
        XCTAssertEqual(view.backgroundColor, .white)
    }
}
