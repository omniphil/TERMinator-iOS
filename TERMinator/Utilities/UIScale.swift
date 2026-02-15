import UIKit

/// Single source of truth for UI scaling across iPhone and iPad.
/// Base: iPhone width ~390pt = 1.0x. Clamped to 1.0...2.0.
enum UIScale {
    static var factor: CGFloat {
        min(2.0, max(1.0, UIScreen.main.bounds.width / 600.0))
    }
}
