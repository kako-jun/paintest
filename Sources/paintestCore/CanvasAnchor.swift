import Foundation

/// A 9-point anchor position (Photoshop's own "カンバスサイズ" dialog grid),
/// used by `LayerStack.resized(toWidth:toHeight:anchor:)` (issue #39) to
/// decide where existing pixel content lands within a newly-sized canvas:
/// the anchor names the edge/corner/center of the *old* content that stays
/// fixed in place, with new space (or clipping, if the canvas shrinks)
/// distributed away from it.
enum CanvasAnchor: CaseIterable {
    case topLeft, top, topRight
    case left, center, right
    case bottomLeft, bottom, bottomRight

    /// `0` = the old content's left edge stays put (space is only ever
    /// added/removed on the right), `1` = its right edge stays put (space
    /// only on the left), `0.5` = centered horizontally.
    var horizontalFraction: Double {
        switch self {
        case .topLeft, .left, .bottomLeft: return 0
        case .top, .center, .bottom: return 0.5
        case .topRight, .right, .bottomRight: return 1
        }
    }

    /// Same idea as `horizontalFraction`, vertically: `0` = the old
    /// content's top edge stays put, `1` = its bottom edge stays put —
    /// `(0, 0)` is top-left in this app's pixel coordinate space (see
    /// `PixelCanvas.setPixel`'s own doc comment), so `0` here means "top",
    /// not "bottom" the way a bottom-up graphics coordinate space would.
    var verticalFraction: Double {
        switch self {
        case .topLeft, .top, .topRight: return 0
        case .left, .center, .right: return 0.5
        case .bottomLeft, .bottom, .bottomRight: return 1
        }
    }
}
