import XCTest
@testable import paintestCore

/// `PenBrushSettings` (issue #20) is a plain data holder — no logic of its
/// own beyond the four stored properties and two static ranges — but its
/// defaults carry an explicit contract worth pinning down as a regression
/// guard: "reproduces the pre-#20 pen exactly" (see the type's own doc
/// comment). If a future change ever drifts a default, these tests catch it
/// immediately rather than surfacing as a subtle visual regression in the
/// pen tool.
final class PenBrushSettingsTests: XCTestCase {
    func testDefaults_matchPreIssue20PenBehavior() {
        let settings = PenBrushSettings()

        XCTAssertEqual(settings.size, 3, "must match the old fixed CanvasView.penLineWidth constant")
        XCTAssertEqual(settings.hardness, 1.0, "hardness 1 collapses drawPenDab's radial falloff to a plain solid disc, matching the pre-#20 pen")
        XCTAssertEqual(settings.opacity, 1.0, "no stroke-level cap below 100% by default")
        XCTAssertEqual(settings.flow, 1.0, "no per-dab buildup below full coverage by default")
    }

    func testSizeRange_is1To50() {
        XCTAssertEqual(PenBrushSettings.sizeRange, 1...50)
    }

    func testUnitRange_is0To1() {
        XCTAssertEqual(PenBrushSettings.unitRange, 0...1)
    }
}
