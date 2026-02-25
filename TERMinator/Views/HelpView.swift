import SwiftUI

/// Help view with comprehensive usage instructions.
struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Terminal Controls
                    helpSection(title: "Terminal Controls") {
                        helpSubsection(title: "Special Keys Toolbar") {
                            Text("The toolbar at the bottom provides:")
                            bulletPoint("CTL - Control key modifier")
                            bulletPoint("ESC - Escape key")
                            bulletPoint("DEL - Backspace/Delete")
                            bulletPoint("TAB - Tab key")
                            bulletPoint("ENT - Enter/Return")
                            bulletPoint("Arrow keys for navigation")
                            bulletPoint("Menu button (\u{22EE}) for options")
                        }

                        helpSubsection(title: "Menu Options") {
                            Text("Tap the menu button (\u{22EE}) or triple-tap the terminal:")
                            bulletPoint("Paste Text - paste from clipboard")
                            bulletPoint("Show/Hide Cursor")
                            bulletPoint("Show/Hide Status Bar")
                            bulletPoint("Show/Hide Button Bar")
                            bulletPoint("Send File (ZMODEM) - upload a file")
                            bulletPoint("Capture Screenshot - save to Photos")
                            bulletPoint("Save Thumbnail - set Phonebook image")
                            bulletPoint("Toggle Logging - record session")
                            bulletPoint("Disconnect - close connection")
                        }

                        helpSubsection(title: "Triple-Tap Menu") {
                            Text("Triple-tap anywhere on the terminal to open the menu. This works even when the button bar is hidden.")
                        }

                        helpSubsection(title: "Zoom") {
                            bulletPoint("Pinch with two fingers to zoom")
                            bulletPoint("Double-tap to reset to 100%")
                        }

                        helpSubsection(title: "Scrollback") {
                            bulletPoint("Volume Up to scroll back through history")
                            bulletPoint("Volume Down to scroll forward")
                        }

                        helpSubsection(title: "Keyboard") {
                            Text("Tap the terminal to show keyboard.")
                        }

                        helpSubsection(title: "Clickable URLs") {
                            Text("Tap URLs on screen to open in browser.")
                        }

                        helpSubsection(title: "Connection Status Bar") {
                            Text("Shows BBS name, connection time, screen mode, and data transfer stats. Can be toggled per-connection.")
                        }
                    }

                    // Session Logging
                    helpSection(title: "Session Logging") {
                        helpSubsection(title: "Capture Session Transcript") {
                            bulletPoint("Tap menu → \"Toggle Logging\"")
                            bulletPoint("Red \"REC\" indicator appears")
                            bulletPoint("Tap menu → \"Toggle Logging\" again when done")
                            bulletPoint("Logs saved with BBS name and timestamp")
                        }
                    }

                    // File Transfer
                    helpSection(title: "File Transfer (ZMODEM)") {
                        helpSubsection(title: "Auto-Detection") {
                            Text("Downloads start automatically when BBS initiates transfer.")
                        }

                        helpSubsection(title: "Send File") {
                            bulletPoint("Start ZMODEM receive on BBS first")
                            bulletPoint("Tap menu → \"Send File (ZMODEM)\"")
                            bulletPoint("Use document picker to select file")
                            bulletPoint("File will upload automatically")
                        }

                        helpSubsection(title: "Receive File") {
                            bulletPoint("Usually auto-detected")
                            bulletPoint("Saves to app Documents folder")
                        }
                    }

                    // SSH Connections
                    helpSection(title: "SSH Connections") {
                        helpSubsection(title: "SSH Credentials") {
                            bulletPoint("Passwords are encrypted using iOS Keychain")
                            bulletPoint("Passwords are NOT exported with your BBS list")
                            bulletPoint("When editing, leave password empty to keep existing")
                        }
                    }

                    // Home Screen
                    helpSection(title: "Home Screen") {
                        helpSubsection(title: "Quick Connect Buttons") {
                            Text("Two customizable buttons for instant connection to your favorite BBSes.")
                        }

                        helpSubsection(title: "Setting Quick Connect") {
                            Text("Tap an empty Quick Connect button to choose a BBS from your Phonebook.")
                        }

                        helpSubsection(title: "Clearing Quick Connect") {
                            Text("Long-press an assigned Quick Connect button to clear or reassign it.")
                        }
                    }

                    // Phonebook
                    helpSection(title: "Phonebook") {
                        helpSubsection(title: "Reorder") {
                            Text("Long-press and drag to reorder.")
                        }

                        helpSubsection(title: "Edit/Delete") {
                            Text("Tap a connection to open its edit screen where you can modify settings or delete it.")
                        }

                        helpSubsection(title: "Thumbnails") {
                            Text("Snapshots appear as thumbnails in the list.")
                        }
                    }

                    // Settings
                    helpSection(title: "Settings") {
                        helpSubsection(title: "Bell & Notifications") {
                            bulletPoint("Toggle sounds and vibration")
                            bulletPoint("Choose from 30 vintage computer bell tones")
                        }

                        helpSubsection(title: "Display") {
                            bulletPoint("Screen orientation lock")
                        }

                        helpSubsection(title: "Backup & Restore") {
                            bulletPoint("Export/Import BBS list")
                        }
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Help")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    // MARK: - Helper Views

    private func helpSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(.primary)

            content()
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
    }

    private func helpSubsection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
                .foregroundColor(.accentColor)

            content()
                .font(.body)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func bulletPoint(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
            Text(text)
        }
        .font(.body)
        .foregroundColor(.secondary)
    }
}

// MARK: - Preview

struct HelpView_Previews: PreviewProvider {
    static var previews: some View {
        HelpView()
    }
}
