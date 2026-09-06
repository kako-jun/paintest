import AppKit
import XCTest
@testable import paintestCore

/// `Document.isDirty` (issue #4: unsaved-changes tracking) must default to
/// `false` regardless of how the document came to exist — a brand-new
/// document and one already pointing at a `fileURL` (e.g. reconstructed
/// after a load) both start out "not diverged from disk yet".
final class DocumentTests: XCTestCase {
    func testInit_isDirtyDefaultsToFalse() {
        let document = Document(layerStack: LayerStack(width: 4, height: 4), fileURL: nil)

        XCTAssertFalse(document.isDirty, "a freshly created document must not start out dirty")
    }

    func testInit_withNonNilFileURL_isDirtyStillDefaultsToFalse() {
        let document = Document(layerStack: LayerStack(width: 4, height: 4), fileURL: URL(fileURLWithPath: "/tmp/example.paintestdoc"))

        XCTAssertFalse(document.isDirty, "supplying a fileURL at init time must not itself mark the document dirty")
    }
}
