import SwiftUI
import UniformTypeIdentifiers

/// Settings view with all configuration options.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    // Bell Settings
    @ObservedObject private var bellManager = BellManager.shared

    // Soundtrack Settings
    @AppStorage(SoundtrackManager.keySoundtrackEnabled) private var soundtrackEnabled = true
    @AppStorage(SoundtrackManager.keySoundtrackCacheLimit) private var soundtrackCacheLimit = 50 // MB
    @ObservedObject private var soundtrackManager = SoundtrackManager.shared

    // Display Settings
    @AppStorage("orientation_lock") private var orientationLock = 1 // 1=portrait, 2=landscape (matching Android)

    // Chat Settings
    @AppStorage("chat_enabled") private var chatEnabled = true
    @AppStorage("chat_username") private var chatUsername = ""
    @AppStorage("chat_country") private var chatCountry = "---"
    @State private var isClaiming = false
    @State private var showingBlockedUsers = false
    @State private var showingUsernameDialog = false

    // Import/Export state
    @State private var showingImportPicker = false
    @State private var showingExportSheet = false
    @State private var exportURL: URL?
    @State private var showingAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var showingHelp = false

    var body: some View {
        NavigationStack {
            Form {
                // Bell Settings Section
                bellSettingsSection

                // Soundtrack Settings Section
                soundtrackSettingsSection

                // Display Settings Section
                displaySettingsSection

                // Chat Settings Section
                chatSettingsSection

                // Import/Export Section
                importExportSection

                // Help Section
                helpSection

                // About Section
                aboutSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showingHelp) {
                HelpView()
            }
            .fileImporter(
                isPresented: $showingImportPicker,
                allowedContentTypes: [.zip, .xml],
                onCompletion: handleImport
            )
            .sheet(isPresented: $showingExportSheet) {
                if let url = exportURL {
                    ShareSheet(items: [url])
                }
            }
            .alert(alertTitle, isPresented: $showingAlert) {
                Button("OK") { }
            } message: {
                Text(alertMessage)
            }
            .sheet(isPresented: $showingBlockedUsers) {
                BlockedUsersView()
            }
            .navigationDestination(isPresented: $showingUsernameDialog) {
                UsernameInputSheet(initialUsername: chatUsername) { name in
                    claimChatUsername(name)
                }
            }
        }
    }

    // MARK: - Bell Settings

    private var bellSettingsSection: some View {
        Section {
            Toggle("Sound Enabled", isOn: $bellManager.soundEnabled)

            if bellManager.soundEnabled {
                Picker("Bell Sound", selection: $bellManager.bellSound) {
                    ForEach(BellSound.allCases) { sound in
                        Text(sound.displayName).tag(sound)
                    }
                }

                HStack {
                    Text("Volume")
                    Slider(value: $bellManager.volume, in: 0...1)
                    Text("\(Int(bellManager.volume * 100))%")
                        .frame(width: 40)
                        .foregroundColor(.secondary)
                }

                Button("Test Sound") {
                    bellManager.testSound(bellManager.bellSound)
                }
            }

            Toggle("Vibration", isOn: $bellManager.vibrationEnabled)

            if bellManager.vibrationEnabled {
                Button("Test Vibration") {
                    bellManager.vibrate()
                }
            }
        } header: {
            Text("Bell")
        } footer: {
            Text("Choose a vintage computer bell sound for the terminal BEL character.")
        }
    }

    // MARK: - Soundtrack Settings

    private var soundtrackSettingsSection: some View {
        Section {
            Toggle("Enabled", isOn: $soundtrackEnabled)

            if soundtrackEnabled {
                Picker("Cache Limit", selection: $soundtrackCacheLimit) {
                    Text("10 MB").tag(10)
                    Text("25 MB").tag(25)
                    Text("50 MB").tag(50)
                    Text("100 MB").tag(100)
                    Text("200 MB").tag(200)
                }

                HStack {
                    Text("Cache Used")
                    Spacer()
                    Text(formatBytes(soundtrackManager.cacheSize))
                        .foregroundColor(.secondary)
                }

                Button("Clear Cache") {
                    soundtrackManager.clearCache()
                }
                .foregroundColor(.red)
            }
        } header: {
            Text("TAP - Terminal Audio Protocol")
        } footer: {
            Text("BBSes can stream background music via the Terminal Audio Protocol (OSC 800).")
        }
    }

    /// Format bytes as a human-readable string.
    private func formatBytes(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }

    // MARK: - Display Settings

    private var displaySettingsSection: some View {
        Section {
            Picker("Screen Orientation", selection: $orientationLock) {
                Text("Portrait").tag(1)
                Text("Landscape").tag(2)
            }
        } header: {
            Text("Display")
        } footer: {
            Text("Pinch to zoom while connected. Double-tap to reset to 100%.")
        }
    }

    // MARK: - Chat Settings

    private var chatSettingsSection: some View {
        Section {
            Toggle("Chat Enabled", isOn: $chatEnabled)

            if chatEnabled {
                // Username
                Button {
                    showingUsernameDialog = true
                } label: {
                    HStack {
                        Text("Username")
                            .foregroundColor(.primary)
                        Spacer()
                        if isClaiming {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else {
                            Text(chatUsername.isEmpty ? "Not Set" : chatUsername)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                // Country selector
                Picker("Country", selection: $chatCountry) {
                    ForEach(CountryCode.allCountries) { country in
                        Text(country.displayString).tag(country.code)
                    }
                }

                // Clear chat history
                Button("Clear Chat History") {
                    UserDefaults.standard.removeObject(forKey: "chat_saved_messages")
                    alertTitle = "Chat History Cleared"
                    alertMessage = "All cached messages have been removed."
                    showingAlert = true
                }
                .foregroundColor(.red)

                // Blocked users
                Button {
                    showingBlockedUsers = true
                } label: {
                    HStack {
                        Text("Manage Blocked Users")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundColor(.secondary)
                    }
                }
            }
        } header: {
            Text("BBS Chat System")
        } footer: {
            Text("Chat with other TERMinator users across rooms. Set a username to send messages.")
        }
    }

    private func claimChatUsername(_ inputName: String? = nil) {
        let name = (inputName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        if reservedUsernames.contains(name.lowercased()) {
            alertTitle = "Reserved Username"
            alertMessage = "That username is reserved and cannot be claimed."
            showingAlert = true
            return
        }

        isClaiming = true

        // One-shot: connect, claim, disconnect. No persistent Firebase connection.
        FirebaseChatManager.claimUsernameOneShot(name) { result in
            DispatchQueue.main.async {
                isClaiming = false
                switch result {
                case .success:
                    chatUsername = name
                    alertTitle = "Username Claimed"
                    alertMessage = "You are now \"\(name)\"!"
                    showingAlert = true
                case .taken:
                    alertTitle = "Username Taken"
                    alertMessage = "That username is already claimed by another user."
                    showingAlert = true
                case .reserved:
                    alertTitle = "Reserved Username"
                    alertMessage = "That username is reserved and cannot be claimed."
                    showingAlert = true
                case .error:
                    alertTitle = "Error"
                    alertMessage = "Could not claim username. Check your connection and try again."
                    showingAlert = true
                }
            }
        }
    }

    // MARK: - Import/Export

    private var importExportSection: some View {
        Section {
            Button("Export Connections") {
                exportConnections()
            }

            Button("Import Connections") {
                showingImportPicker = true
            }
        } header: {
            Text("Backup & Restore")
        } footer: {
            Text("Export your connections to share or backup. Passwords are not included for security.")
        }
    }

    // MARK: - Help

    private var helpSection: some View {
        Section {
            Button {
                showingHelp = true
            } label: {
                HStack {
                    Text("View Help")
                    Spacer()
                    Image(systemName: "questionmark.circle")
                        .foregroundColor(.secondary)
                }
            }
        } header: {
            Text("Help")
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section {
            HStack {
                Text("Version")
                Spacer()
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                    .foregroundColor(.secondary)
            }

            HStack {
                Text("Build")
                Spacer()
                Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")
                    .foregroundColor(.secondary)
            }

            // Changelog
            DisclosureGroup("Changelog") {
                changelogEntry("1.1.8",
                    "Chat system (No accounts needed)",
                    "Phonebook display fix for iPhones")
                changelogEntry("1.1.7",
                    "TAP engine updates",
                    "Added better support for 132 columns",
                    "Cursor visibility fixes")
                changelogEntry("1.1.6",
                    "Fix for terminal sizes over 80x25",
                    "Add triple tap for 3 dot menu",
                    "Add per-connection button bar toggle",
                    "Added Copy and Paste (Long press on screen to select text)",
                    "Terminal window placement fixed",
                    "Fact ticker visibility fixed",
                    "External keyboard delete/backspace fix",
                    "TAP playback tweaks")
                changelogEntry("1.1.5",
                    "TAP (Terminal Audio Protocol) support — BBS music & sound effects",
                    "Button bar now stays above virtual keyboard",
                    "Volume keys restored to audio control; swipe to scroll back",
                    "Fixed spurious underlines caused by BBS escape codes")
                changelogEntry("1.1.4",
                    "Phonebook scroll fix, drag-to-reorder, snapshot previews",
                    "Hardware keyboard support: ESC, arrows, tab, ctrl+keys")
                changelogEntry("1.1.3",
                    "TelnetS (Telnet over TLS) support",
                    "Enter key fix")
                changelogEntry("1.1.2",
                    "Scrollback buffer",
                    "Pinch-to-zoom",
                    "Volume button scrollback",
                    "Background keep-alive")
                changelogEntry("1.1.0",
                    "Initial release")
            }

            // Credits
            VStack(alignment: .leading, spacing: 8) {
                Text("Credits")
                    .font(.headline)

                Text("Based on SyncTERM 1.8b")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("Copyright 2007 Stephen Hurd")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("Licensed under GNU GPL v2")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Divider()

                Text("SSH support via cryptlib (Synchronet)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("Copyright 1992-2023 Peter Gutmann")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("Dual licensed: Sleepycat/GPL-compatible")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Divider()

                Text("Tracker playback via libxmp 4.6.0")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("Copyright 1996-2024 Claudio Matsuoka & Hipolito Carraro Jr")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("Licensed under MIT")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Divider()

                Text("iOS version by JSONBourne 2026")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("JSONBourne Innovations")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("jsonbourneinnovations@gmail.com")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Link(destination: URL(string: "https://deadmodemsociety.com")!) {
                    Text("deadmodemsociety.com")
                        .font(.caption)
                        .foregroundColor(.accentColor)
                }

                Divider()

                Text("Special thx to aNACHRONiST (aNSt) for the artwork and testing!")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("He may be reached at: aNSt@absinthebbs.net for collaborations and commissions.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Divider()

                Text("Source Code")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                Text("This application is open source and licensed under the GNU General Public License v2.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Link("GitHub: TERMinator-iOS", destination: URL(string: "https://github.com/omniphil/TERMinator-iOS")!)
                    .font(.caption)
            }
            .padding(.vertical, 4)
        } header: {
            Text("About")
        } footer: {
            Text("TERMinator - BBS Terminal Emulator")
        }
    }

    // MARK: - Changelog Helper

    private func changelogEntry(_ version: String, _ items: String...) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(version)
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(.primary)
            ForEach(items, id: \.self) { item in
                Text("- \(item)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Actions

    private func exportConnections() {
        if let url = ImportExportManager.shared.exportConnections() {
            exportURL = url
            showingExportSheet = true
        } else {
            alertTitle = "Export Failed"
            alertMessage = "No connections to export or an error occurred."
            showingAlert = true
        }
    }

    private func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            // Start accessing security-scoped resource
            guard url.startAccessingSecurityScopedResource() else {
                alertTitle = "Import Failed"
                alertMessage = "Could not access the selected file."
                showingAlert = true
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }

            let count = ImportExportManager.shared.importConnections(from: url, replace: false)
            if count > 0 {
                alertTitle = "Import Successful"
                alertMessage = "Imported \(count) connection(s)."
            } else if count == 0 {
                alertTitle = "Import Complete"
                alertMessage = "No new connections found in the file."
            } else {
                alertTitle = "Import Failed"
                alertMessage = "Could not read the selected file."
            }
            showingAlert = true

        case .failure(let error):
            alertTitle = "Import Failed"
            alertMessage = error.localizedDescription
            showingAlert = true
        }
    }

}

// MARK: - Username Input Sheet (isolated from SettingsView to avoid re-render lag)

struct UsernameInputSheet: View {
    @Environment(\.dismiss) private var dismiss
    let initialUsername: String
    let onClaim: (String) -> Void

    @State private var text = ""

    var body: some View {
        VStack(spacing: 16) {
            Text("Max 15 characters")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .padding(.top, 8)

            TextField("Username", text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
                .onChange(of: text) { newValue in
                    if newValue.count > 15 {
                        text = String(newValue.prefix(15))
                    }
                }

            Text("\(text.count)/15")
                .font(.caption)
                .foregroundColor(text.count >= 15 ? .red : .secondary)

            Button("Claim") {
                onClaim(text)
                dismiss()
            }
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .buttonStyle(.borderedProminent)

            Spacer()
        }
        .navigationTitle("Set Username")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { text = initialUsername }
    }
}

// MARK: - Blocked Users View

struct BlockedUsersView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("chat_blocked_uids") private var blockedUidsJson: String = "[]"
    @State private var blockedUids: [String] = []

    var body: some View {
        NavigationStack {
            List {
                if blockedUids.isEmpty {
                    Text("No blocked users")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(blockedUids, id: \.self) { uid in
                        HStack {
                            Text(uid)
                                .font(.system(.body, design: .monospaced))
                                .lineLimit(1)
                            Spacer()
                            Button("Unblock") {
                                unblock(uid: uid)
                            }
                            .foregroundColor(.red)
                        }
                    }
                }
            }
            .navigationTitle("Blocked Users")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .onAppear { loadBlocked() }
        }
    }

    private func loadBlocked() {
        guard let data = blockedUidsJson.data(using: .utf8),
              let uids = try? JSONDecoder().decode([String].self, from: data) else {
            blockedUids = []
            return
        }
        blockedUids = uids
    }

    private func unblock(uid: String) {
        blockedUids.removeAll { $0 == uid }
        if let data = try? JSONEncoder().encode(blockedUids),
           let json = String(data: data, encoding: .utf8) {
            blockedUidsJson = json
        }
    }
}

// MARK: - Log Files View

struct LogFilesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var logFiles: [URL] = []
    @State private var selectedLog: URL?
    @State private var logContent: String = ""
    @State private var showingLogContent = false

    var body: some View {
        NavigationStack {
            List {
                if logFiles.isEmpty {
                    Text("No log files found")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(logFiles, id: \.absoluteString) { file in
                        Button {
                            selectedLog = file
                            loadLogContent(file)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(file.lastPathComponent)
                                    .font(.body)
                                if let date = getFileDate(file) {
                                    Text(date, style: .date)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                    .onDelete(perform: deleteLogFiles)
                }
            }
            .navigationTitle("Log Files")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showingLogContent) {
                NavigationStack {
                    ScrollView {
                        Text(logContent)
                            .font(.system(.caption, design: .monospaced))
                            .padding()
                    }
                    .navigationTitle(selectedLog?.lastPathComponent ?? "Log")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("Done") {
                                showingLogContent = false
                            }
                        }
                        ToolbarItem(placement: .navigationBarLeading) {
                            if let url = selectedLog {
                                ShareLink(item: url)
                            }
                        }
                    }
                }
            }
            .onAppear {
                loadLogFiles()
            }
        }
    }

    private func loadLogFiles() {
        logFiles = SessionLogger.shared.getLogFiles()
    }

    private func loadLogContent(_ url: URL) {
        logContent = SessionLogger.shared.readLogFile(url) ?? "Could not read file"
        showingLogContent = true
    }

    private func deleteLogFiles(at offsets: IndexSet) {
        for index in offsets {
            _ = SessionLogger.shared.deleteLogFile(logFiles[index])
        }
        loadLogFiles()
    }

    private func getFileDate(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}

// MARK: - Share Sheet

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Preview

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
    }
}
