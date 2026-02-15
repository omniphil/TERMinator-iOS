import UIKit
import SwiftUI

/// Manages device orientation locking for the terminal view.
class OrientationManager: ObservableObject {
    static let shared = OrientationManager()

    /// Current orientation lock setting from UserDefaults (1=portrait, 2=landscape)
    var orientationLock: Int {
        let lock = UserDefaults.standard.integer(forKey: "orientation_lock")
        // Default to portrait if not set or invalid (matching Android behavior)
        return lock == 2 ? 2 : 1
    }

    /// Get the supported interface orientations based on the lock setting.
    var supportedOrientations: UIInterfaceOrientationMask {
        switch orientationLock {
        case 2: return .landscape
        default: return .portrait
        }
    }

    /// Lock to specific orientation when entering terminal.
    func lockOrientation() {
        guard #available(iOS 16.0, *) else { return }

        // Request the preferred orientation
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            let geometryPreferences: UIWindowScene.GeometryPreferences.iOS

            switch orientationLock {
            case 2: // Landscape
                geometryPreferences = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: .landscape)
            default: // Portrait
                geometryPreferences = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: .portrait)
            }

            windowScene.requestGeometryUpdate(geometryPreferences) { error in
                // Silently handle error - orientation may not be supported
            }
        }
    }

    /// Unlock orientation when leaving terminal.
    func unlockOrientation() {
        guard #available(iOS 16.0, *) else { return }

        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            let geometryPreferences = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: .all)
            windowScene.requestGeometryUpdate(geometryPreferences) { _ in }
        }
    }
}

/// View modifier to apply orientation lock.
struct OrientationLockModifier: ViewModifier {
    @StateObject private var orientationManager = OrientationManager.shared

    func body(content: Content) -> some View {
        content
            .onAppear {
                orientationManager.lockOrientation()
            }
            .onDisappear {
                orientationManager.unlockOrientation()
            }
    }
}

extension View {
    /// Apply orientation lock based on settings.
    func applyOrientationLock() -> some View {
        modifier(OrientationLockModifier())
    }
}
