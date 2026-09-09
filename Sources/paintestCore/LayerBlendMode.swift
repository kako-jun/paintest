import AppKit

/// How a layer's pixels combine with whatever is already composited
/// underneath it (issue #37). `.normal` is plain source-over — the only
/// behavior that existed before this type — and stays every layer's
/// default, so a document built before blend modes existed composites
/// exactly as it always did.
///
/// Every case maps 1:1 onto a `CGBlendMode`, so `LayerStack`'s compositing
/// passes need nothing beyond a `context.setBlendMode(_:)` call ahead of
/// each layer's `draw`: Core Graphics already implements the PDF/Photoshop
/// blend formulas. Adding a further mode is therefore one case plus its two
/// `switch` arms below and nothing else.
///
/// `rawValue` is what `.paintestdoc`'s `manifest.json` persists, so the
/// existing string spellings must not be renamed — a saved document would
/// stop round-tripping its blend modes (see `PaintestDocument`, which
/// falls back to `.normal` for an unknown or absent value).
enum LayerBlendMode: String, CaseIterable, Codable, Equatable {
    case normal
    case multiply
    case screen
    case overlay

    var cgBlendMode: CGBlendMode {
        switch self {
        case .normal: return .normal
        case .multiply: return .multiply
        case .screen: return .screen
        case .overlay: return .overlay
        }
    }

    /// Label shown in the layer panel's blend-mode popup, following
    /// Photoshop's Japanese UI wording.
    var displayName: String {
        switch self {
        case .normal: return "通常"
        case .multiply: return "乗算"
        case .screen: return "スクリーン"
        case .overlay: return "オーバーレイ"
        }
    }
}
