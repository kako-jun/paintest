import XCTest
@testable import paintestCore

/// `TextToolSettings` (issue #42) is a plain data holder — no logic of its
/// own beyond the three stored properties and one static range — mirroring
/// `PenBrushSettings`' own shape (see `PenBrushSettingsTests`' doc comment
/// for why pinning defaults down as a regression guard matters). Unlike
/// `PenBrushSettings`, there's no "reproduces pre-#42 behavior" contract to
/// match here — the text tool is new, not a refactor of an existing one —
/// so these just pin down the defaults the type's own doc comment declares.
final class TextToolSettingsTests: XCTestCase {
    func testDefaults_fontSizeIs24_isVerticalFalse() {
        let settings = TextToolSettings()

        XCTAssertEqual(settings.fontSize, 24)
        XCTAssertFalse(settings.isVertical, "horizontal writing is the default")
    }

    func testFontSizeRange_is6To200() {
        XCTAssertEqual(TextToolSettings.fontSizeRange, 6...200)
    }
}
