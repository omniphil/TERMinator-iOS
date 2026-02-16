import SwiftUI
import UIKit

/// Manages deep link (telnet:// URL) connections
class DeepLinkManager: ObservableObject {
    static let shared = DeepLinkManager()

    @Published var pendingConnection: QuickConnection?

    struct QuickConnection: Identifiable, Equatable {
        let id = UUID()
        let host: String
        let port: Int
        let name: String

        static func == (lhs: QuickConnection, rhs: QuickConnection) -> Bool {
            lhs.id == rhs.id
        }
    }

    /// Parse a telnet:// URL and create a quick connection
    func handleURL(_ url: URL) {
        guard url.scheme == "telnet" else { return }

        let host = url.host ?? ""
        let port = url.port ?? 23

        guard !host.isEmpty else { return }

        pendingConnection = QuickConnection(
            host: host,
            port: port,
            name: "Quick Connect"
        )
    }

    /// Clear the pending connection after handling
    func clearPending() {
        pendingConnection = nil
    }
}

@main
struct TERMinatorApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var deepLinkManager = DeepLinkManager.shared

    /// Background task identifier — keeps the process alive for ~30 seconds
    /// after the app enters background so the TCP connection isn't killed.
    @State private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    init() {
        // Initialize native bridge
        let filesDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
        NativeBridge.shared.setFilesDir(filesDir)
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(deepLinkManager)
                .onOpenURL { url in
                    deepLinkManager.handleURL(url)
                }
        }
        .onChange(of: scenePhase) { newPhase in
            switch newPhase {
            case .active:
                // App returned to foreground — end background task if running
                endBackgroundTask()
            case .inactive:
                break
            case .background:
                BBSEntryStore.shared.saveEntries()
                // Request extended execution time to keep the connection alive
                beginBackgroundTask()
            @unknown default:
                break
            }
        }
    }

    private func beginBackgroundTask() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "KeepConnection") { [self] in
            // Expiration handler — iOS is about to suspend us
            endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }
}
