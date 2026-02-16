import Foundation
import AVFoundation
import MediaPlayer
import Combine

/// Observes hardware volume button presses and publishes scroll direction events.
/// Resets volume to a midpoint so buttons never saturate at 0 or 1.
/// Hides the system volume HUD by placing an MPVolumeView off-screen.
final class VolumeButtonManager: ObservableObject {
    static let shared = VolumeButtonManager()

    enum ScrollDirection {
        case up
        case down
    }

    /// Published each time a volume button is pressed.
    @Published var scrollEvent: ScrollDirection?

    private var observation: NSKeyValueObservation?
    private var volumeView: MPVolumeView?
    private var isObserving = false

    /// The midpoint we reset to after each press.
    private let midpoint: Float = 0.5

    /// Suppress the first KVO callback that fires when we reset volume.
    private var suppressNext = false

    private init() {}

    /// Begin observing volume button presses.
    /// Safe to call multiple times — only starts once.
    func startObserving() {
        guard !isObserving else { return }
        isObserving = true

        let session = AVAudioSession.sharedInstance()
        // BellManager already activates the session; just ensure category allows volume observation
        try? session.setCategory(.ambient, options: .mixWithOthers)
        try? session.setActive(true)

        // Place an MPVolumeView off-screen to hide the system volume HUD
        if volumeView == nil {
            let vv = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 1, height: 1))
            vv.isHidden = false
            // Add to key window so it intercepts the HUD
            if let windowScene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first,
               let window = windowScene.windows.first {
                window.addSubview(vv)
            }
            volumeView = vv

            // Set initial volume to midpoint
            setSystemVolume(midpoint)
        }

        // Observe outputVolume changes via KVO
        observation = session.observe(\.outputVolume, options: [.new, .old]) { [weak self] _, change in
            guard let self = self else { return }

            if self.suppressNext {
                self.suppressNext = false
                return
            }

            guard let newVal = change.newValue, let oldVal = change.oldValue else { return }
            let delta = newVal - oldVal

            // Ignore tiny changes (e.g. rounding when we reset)
            guard abs(delta) > 0.01 else { return }

            let direction: ScrollDirection = delta > 0 ? .up : .down

            DispatchQueue.main.async {
                self.scrollEvent = direction
            }

            // Reset volume back to midpoint so the button keeps working
            self.suppressNext = true
            self.setSystemVolume(self.midpoint)
        }
    }

    /// Stop observing volume buttons and clean up.
    func stopObserving() {
        guard isObserving else { return }
        isObserving = false

        observation?.invalidate()
        observation = nil

        volumeView?.removeFromSuperview()
        volumeView = nil
    }

    /// Set system volume using the MPVolumeView slider.
    private func setSystemVolume(_ value: Float) {
        guard let vv = volumeView else { return }
        // Find the UISlider inside MPVolumeView
        for subview in vv.subviews {
            if let slider = subview as? UISlider {
                slider.value = value
                return
            }
        }
    }
}
