import SwiftUI
import UniformTypeIdentifiers

/// Settings view with all configuration options.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    // Bell Settings
    @ObservedObject private var bellManager = BellManager.shared

    // Display Settings
    @AppStorage("orientation_lock") private var orientationLock = 1 // 1=portrait, 2=landscape (matching Android)

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

                // Display Settings Section
                displaySettingsSection

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

                Text("iOS version by JSONBourne 2026")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("JSONBourne Innovations")
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
