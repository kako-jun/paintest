import AppKit
import XCTest
@testable import paintestCore

final class LayerStackTests: XCTestCase {
    func testCompositeImage_topLayerPixelOverridesBottomLayerBackground() {
        let stack = LayerStack(width: 4, height: 4, background: .white)
        stack.addLayer()
        XCTAssertEqual(stack.activeLayerIndex, 1)
        stack.activeLayer.canvas.setPixel(x: 1, y: 1, color: .black)

        guard let composite = stack.compositeImage() else {
            XCTFail("compositeImage() returned nil")
            return
        }
        let rep = NSBitmapImageRep(cgImage: composite)
        let blackPixel = rep.colorAt(x: 1, y: 1)
        let whitePixel = rep.colorAt(x: 0, y: 0)

        XCTAssertEqual(blackPixel?.usingColorSpace(.deviceRGB)?.redComponent ?? 1, 0, accuracy: 0.01)
        XCTAssertEqual(whitePixel?.usingColorSpace(.deviceRGB)?.redComponent ?? 0, 1, accuracy: 0.01)
    }
}
