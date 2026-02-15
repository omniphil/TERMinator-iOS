import SwiftUI

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
                // App became active
                break
            case .inactive:
                // App became inactive
                break
            case .background:
                // App went to background - save state if needed
                BBSEntryStore.shared.saveEntries()
            @unknown default:
                break
            }
        }
    }
}
