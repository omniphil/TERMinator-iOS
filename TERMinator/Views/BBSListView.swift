import SwiftUI
import UIKit

/// Main view showing the list of BBS connections.
struct BBSListView: View {
    @StateObject private var store = BBSEntryStore.shared
    @State private var showingAddSheet = false
    @State private var showingSettings = false
    @State private var editingEntry: BBSEntry?
    @State private var selectedEntry: BBSEntry?
    @State private var showingTerminal = false
    @State private var draggingEntry: BBSEntry?
    @State private var dragOffset: CGFloat = 0
    @State private var draggedOverEntry: BBSEntry?

    var body: some View {
        ZStack {
        NavigationStack {
            Group {
                if store.entries.isEmpty {
                    emptyState
                } else {
                    connectionsList
                }
            }
            .navigationTitle("TERMinator")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gear")
                            .font(.system(size: 14 * UIScale.factor))
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showingAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 14 * UIScale.factor))
                    }
                }
            }
            .fullScreenCover(isPresented: $showingAddSheet) {
                BBSEditView(entry: nil) { newEntry in
                    store.addEntry(newEntry)
                }
            }
            .fullScreenCover(item: $editingEntry) { entry in
                BBSEditView(entry: entry, onSave: { updatedEntry in
                    store.updateEntry(updatedEntry)
                }, onConnect: { connectEntry in
                    selectedEntry = connectEntry
                    showingTerminal = true
                }, onDelete: { deleteEntry in
                    store.deleteEntry(deleteEntry)
                })
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
        }
        // Terminal overlay (non-modal, ESC cannot dismiss)
        if showingTerminal, let entry = selectedEntry {
            TerminalContainerView(entry: entry, onDismiss: { showingTerminal = false })
                .ignoresSafeArea()
                .transition(.move(edge: .bottom))
        }
        } // ZStack
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 60 * UIScale.factor))
                .foregroundColor(.secondary)

            Text("No Connections")
                .font(.system(size: 22 * UIScale.factor, weight: .semibold))

            Text("Add your first BBS connection to get started.")
                .font(.system(size: 15 * UIScale.factor))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button {
                showingAddSheet = true
            } label: {
                Label("Add Connection", systemImage: "plus")
                    .font(.system(size: 17 * UIScale.factor, weight: .semibold))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(10)
            }
            .padding(.top, 10)
        }
    }

    // MARK: - Connections List

    private let rowHeight: CGFloat = 76

    private var connectionsList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(store.entries.enumerated()), id: \.element.id) { index, entry in
                    let isDragging = draggingEntry?.id == entry.id
                    let isTarget = draggedOverEntry?.id == entry.id

                    BBSEntryRow(entry: entry)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(isDragging ? Color(.systemGray4) : Color(.secondarySystemGroupedBackground))
                        )
                        .padding(.horizontal, 16)
                        .padding(.vertical, 2)
                        .opacity(isDragging ? 0.5 : 1)
                        .overlay(alignment: .top) {
                            if isTarget {
                                Rectangle()
                                    .fill(Color.accentColor)
                                    .frame(height: 3)
                                    .padding(.horizontal, 20)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if draggingEntry == nil {
                                editingEntry = entry
                            }
                        }
                        .simultaneousGesture(
                            LongPressGesture(minimumDuration: 0.3)
                                .sequenced(before: DragGesture())
                                .onChanged { value in
                                    switch value {
                                    case .second(true, let drag):
                                        if draggingEntry == nil {
                                            draggingEntry = entry
                                            let generator = UIImpactFeedbackGenerator(style: .medium)
                                            generator.impactOccurred()
                                        }
                                        if let drag = drag {
                                            dragOffset = drag.translation.height
                                            let targetIndex = index + Int((drag.translation.height / rowHeight).rounded())
                                            let clampedIndex = max(0, min(store.entries.count - 1, targetIndex))
                                            if clampedIndex != index {
                                                draggedOverEntry = store.entries[clampedIndex]
                                            } else {
                                                draggedOverEntry = nil
                                            }
                                        }
                                    default:
                                        break
                                    }
                                }
                                .onEnded { value in
                                    if let from = draggingEntry,
                                       let fromIndex = store.entries.firstIndex(where: { $0.id == from.id }) {
                                        let targetIndex = fromIndex + Int((dragOffset / rowHeight).rounded())
                                        let clampedIndex = max(0, min(store.entries.count - 1, targetIndex))
                                        if clampedIndex != fromIndex {
                                            withAnimation {
                                                store.entries.move(
                                                    fromOffsets: IndexSet(integer: fromIndex),
                                                    toOffset: clampedIndex > fromIndex ? clampedIndex + 1 : clampedIndex
                                                )
                                            }
                                            store.saveEntries()
                                        }
                                    }
                                    draggingEntry = nil
                                    dragOffset = 0
                                    draggedOverEntry = nil
                                }
                        )
                }
            }
            .padding(.vertical, 8)
        }
        .background(Color(.systemGroupedBackground))
    }
}

// MARK: - BBS Entry Row

struct BBSEntryRow: View {
    let entry: BBSEntry

    private var thumbnailSize: CGFloat {
        60 * UIScale.factor
    }

    var body: some View {
        HStack(spacing: 12) {
            // Snapshot or placeholder
            if let snapshotData = entry.snapshotData,
               let uiImage = UIImage(data: snapshotData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: thumbnailSize, height: thumbnailSize * 0.75)
                    .cornerRadius(6)
                    .clipped()
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(.systemGray5))
                    .frame(width: thumbnailSize, height: thumbnailSize * 0.75)
                    .overlay {
                        Image(systemName: "terminal")
                            .font(.system(size: 20 * UIScale.factor))
                            .foregroundColor(.secondary)
                    }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.name.isEmpty ? entry.host : entry.name)
                    .font(.system(size: 12 * UIScale.factor, weight: .semibold))

                Text(entry.addressDisplay)
                    .font(.system(size: 11 * UIScale.factor))
                    .foregroundColor(.secondary)

                HStack(spacing: 8) {
                    Label(entry.connectionProtocol.displayName, systemImage: protocolIcon)
                        .font(.system(size: 10 * UIScale.factor))
                        .foregroundColor(.secondary)

                    Text(entry.screenMode.displayName)
                        .font(.system(size: 10 * UIScale.factor))
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 12 * UIScale.factor))
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var protocolIcon: String {
        switch entry.connectionProtocol {
        case .telnet: return "network"
        case .ssh: return "lock.shield"
        case .telnetS: return "lock.shield"
        }
    }
}

// MARK: - BBS Edit View

struct BBSEditView: View {
    @Environment(\.dismiss) private var dismiss

    let entry: BBSEntry?
    let onSave: (BBSEntry) -> Void
    var onConnect: ((BBSEntry) -> Void)?
    var onDelete: ((BBSEntry) -> Void)?

    @State private var name: String = ""
    @State private var host: String = ""
    @State private var port: String = "23"
    @State private var connectionProtocol: ConnectionProtocol = .telnet
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var screenMode: ScreenMode = .mode80x25
    @State private var font: TerminalFont = .cp437
    @State private var showStatusBar: Bool = true
    @State private var showButtonBar: Bool = true
    @State private var autoConnect: Bool = false
    @State private var showingDeleteConfirmation = false

    private var isExistingEntry: Bool { entry != nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Connection Section
                    RetroSection(title: "CONNECTION") {
                        VStack(alignment: .leading, spacing: 8) {
                            RetroTextField(label: "Name", placeholder: "BBS Name", text: $name)
                            RetroTextField(label: "Host", placeholder: "hostname.com", text: $host)
                                .keyboardType(.URL)
                                .autocapitalization(.none)
                            RetroTextField(label: "Port", placeholder: "23", text: $port)
                                .keyboardType(.numberPad)

                            RetroPicker(label: "Protocol", selection: $connectionProtocol, displayText: { $0.displayName }) {
                                ForEach(ConnectionProtocol.allCases) { proto in
                                    Text(proto.displayName)
                                        .font(.system(size: 14 * UIScale.factor, design: .monospaced))
                                        .tag(proto)
                                }
                            }
                            .onChange(of: connectionProtocol) { newValue in
                                let oldPort = port
                                // Auto-switch port when changing protocol if on a default port
                                if oldPort == "23" || oldPort == "22" || oldPort == "992" {
                                    switch newValue {
                                    case .telnet: port = "23"
                                    case .ssh: port = "22"
                                    case .telnetS: port = "992"
                                    }
                                }
                            }
                        }
                    }

                    // SSH Credentials Section
                    if connectionProtocol == .ssh {
                        RetroSection(title: "SSH CREDENTIALS") {
                            VStack(alignment: .leading, spacing: 8) {
                                RetroTextField(label: "Username", placeholder: "username", text: $username)
                                    .autocapitalization(.none)
                                RetroSecureField(label: "Password", placeholder: "password", text: $password)
                            }
                        }
                    }

                    // Options Section (only for existing entries, like Android)
                    if isExistingEntry {
                        RetroSection(title: "OPTIONS") {
                            VStack(alignment: .leading, spacing: 8) {
                                RetroPicker(label: "Screen Mode", selection: $screenMode, displayText: { $0.displayName }) {
                                    ForEach(ScreenMode.allCases) { mode in
                                        Text(mode.displayName)
                                            .font(.system(size: 14 * UIScale.factor, design: .monospaced))
                                            .tag(mode)
                                    }
                                }

                                RetroPicker(label: "Font", selection: $font, displayText: { $0.displayName }) {
                                    ForEach(TerminalFont.allCases) { f in
                                        Text(f.displayName)
                                            .font(.system(size: 14 * UIScale.factor, design: .monospaced))
                                            .tag(f)
                                    }
                                }

                                RetroToggle(label: "Show Status Bar", isOn: $showStatusBar)
                                RetroToggle(label: "Show Button Bar", isOn: $showButtonBar)
                            }
                        }
                    }

                    // Buttons - layout differs for new vs existing entries
                    if isExistingEntry {
                        // Existing entry: Save + Connect row
                        HStack(spacing: 12) {
                            // Save button (secondary cyan style)
                            Button {
                                saveEntry()
                            } label: {
                                Text("SAVE")
                                    .font(.system(size: 14 * UIScale.factor, weight: .bold, design: .monospaced))
                                    .foregroundColor(.termLightCyan)
                                    .shadow(color: Color(red: 0, green: 0.27, blue: 0.27), radius: 2, x: 1, y: 1)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 44 * UIScale.factor)
                                    .background(
                                        RoundedRectangle(cornerRadius: 2)
                                            .stroke(Color.termCyan, lineWidth: 2)
                                            .background(RoundedRectangle(cornerRadius: 2).fill(Color(red: 0.04, green: 0.125, blue: 0.125)))
                                    )
                            }
                            .disabled(host.isEmpty)
                            .opacity(host.isEmpty ? 0.5 : 1)

                            // Connect button (primary green style)
                            Button {
                                let savedEntry = buildEntry()
                                onSave(savedEntry)
                                onConnect?(savedEntry)
                                dismiss()
                            } label: {
                                Text("CONNECT")
                                    .font(.system(size: 14 * UIScale.factor, weight: .bold, design: .monospaced))
                                    .foregroundColor(.termLightGreen)
                                    .shadow(color: Color(red: 0, green: 0.27, blue: 0), radius: 2, x: 1, y: 1)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 44 * UIScale.factor)
                                    .background(
                                        RoundedRectangle(cornerRadius: 2)
                                            .stroke(Color.termGreen, lineWidth: 2)
                                            .background(RoundedRectangle(cornerRadius: 2).fill(Color(red: 0.04, green: 0.125, blue: 0.04)))
                                    )
                            }
                            .disabled(host.isEmpty)
                            .opacity(host.isEmpty ? 0.5 : 1)
                        }
                        .padding(.top, 8)

                        // Delete + Cancel row
                        HStack(spacing: 12) {
                            // Delete button (danger red style)
                            Button {
                                showingDeleteConfirmation = true
                            } label: {
                                Text("DELETE")
                                    .font(.system(size: 12 * UIScale.factor, weight: .bold, design: .monospaced))
                                    .foregroundColor(.termLightRed)
                                    .shadow(color: Color(red: 0.27, green: 0, blue: 0), radius: 2, x: 1, y: 1)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 44 * UIScale.factor)
                                    .background(
                                        RoundedRectangle(cornerRadius: 2)
                                            .stroke(Color.termRed, lineWidth: 2)
                                            .background(RoundedRectangle(cornerRadius: 2).fill(Color(red: 0.125, green: 0.04, blue: 0.04)))
                                    )
                            }

                            // Cancel button (secondary gray style)
                            Button {
                                dismiss()
                            } label: {
                                Text("CANCEL")
                                    .font(.system(size: 12 * UIScale.factor, weight: .bold, design: .monospaced))
                                    .foregroundColor(.termDarkGray)
                                    .shadow(color: Color(red: 0.13, green: 0.13, blue: 0.13), radius: 2, x: 1, y: 1)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 44 * UIScale.factor)
                                    .background(
                                        RoundedRectangle(cornerRadius: 2)
                                            .stroke(Color.termDarkGray, lineWidth: 2)
                                            .background(RoundedRectangle(cornerRadius: 2).fill(Color(red: 0.08, green: 0.08, blue: 0.08)))
                                    )
                            }
                        }
                        .padding(.top, 8)
                    } else {
                        // New entry: Save button only + cancel link
                        VStack(spacing: 12) {
                            Button {
                                saveEntry()
                            } label: {
                                Text("SAVE")
                                    .font(.system(size: 14 * UIScale.factor, weight: .bold, design: .monospaced))
                                    .foregroundColor(.termLightGreen)
                                    .shadow(color: Color(red: 0, green: 0.27, blue: 0), radius: 2, x: 1, y: 1)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 44 * UIScale.factor)
                                    .background(
                                        RoundedRectangle(cornerRadius: 2)
                                            .stroke(Color.termGreen, lineWidth: 2)
                                            .background(RoundedRectangle(cornerRadius: 2).fill(Color(red: 0.04, green: 0.125, blue: 0.04)))
                                    )
                            }
                            .disabled(host.isEmpty)
                            .opacity(host.isEmpty ? 0.5 : 1)

                            Button {
                                dismiss()
                            } label: {
                                Text("CANCEL")
                                    .font(.system(size: 12 * UIScale.factor, weight: .bold, design: .monospaced))
                                    .foregroundColor(.termDarkGray)
                                    .shadow(color: Color(red: 0.13, green: 0.13, blue: 0.13), radius: 2, x: 1, y: 1)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 44 * UIScale.factor)
                                    .background(
                                        RoundedRectangle(cornerRadius: 2)
                                            .stroke(Color.termDarkGray, lineWidth: 2)
                                            .background(RoundedRectangle(cornerRadius: 2).fill(Color(red: 0.08, green: 0.08, blue: 0.08)))
                                    )
                            }
                        }
                        .padding(.top, 8)
                    }
                }
                .padding(16)
            }
            .background(Color.background)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 18 * UIScale.factor))
                            .foregroundColor(.termLightGreen)
                    }
                }
                ToolbarItem(placement: .principal) {
                    Text(entry == nil ? "New Connection" : "Edit Connection")
                        .font(.system(size: 17 * UIScale.factor, weight: .semibold))
                        .foregroundColor(.white)
                }
            }
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .onAppear {
                loadEntry()
            }
            .alert("Delete Connection?", isPresented: $showingDeleteConfirmation) {
                Button("Delete", role: .destructive) {
                    if let entry = entry {
                        onDelete?(entry)
                    }
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Are you sure you want to delete this BBS connection?")
            }
        }
    }

    private func buildEntry() -> BBSEntry {
        var newEntry = entry ?? BBSEntry()

        newEntry.name = name
        newEntry.host = host
        newEntry.port = Int(port) ?? 23
        newEntry.connectionProtocol = connectionProtocol
        newEntry.username = username
        newEntry.screenMode = screenMode
        newEntry.font = font
        newEntry.showStatusBar = showStatusBar
        newEntry.showButtonBar = showButtonBar
        newEntry.autoConnect = autoConnect

        // Save password to Keychain
        newEntry.setPassword(password.isEmpty ? nil : password)

        return newEntry
    }

    private func loadEntry() {
        guard let entry = entry else { return }

        name = entry.name
        host = entry.host
        port = String(entry.port)
        connectionProtocol = entry.connectionProtocol
        username = entry.username
        password = entry.password ?? ""
        screenMode = entry.screenMode
        font = entry.font
        showStatusBar = entry.showStatusBar
        showButtonBar = entry.showButtonBar
        autoConnect = entry.autoConnect
    }

    private func saveEntry() {
        let newEntry = buildEntry()
        onSave(newEntry)
        dismiss()
    }
}

// MARK: - Retro UI Components

struct RetroSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title overlaid on border
            Text(" \(title) ")
                .font(.system(size: 11 * UIScale.factor, weight: .bold, design: .monospaced))
                .foregroundColor(.termCyan)
                .background(Color.background)
                .padding(.leading, 12)
                .offset(y: 8)
                .zIndex(1)

            // Content with border
            VStack(alignment: .leading, spacing: 0) {
                content
                    .padding(12)
            }
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.panelBorder, lineWidth: 1)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.cardBackground))
            )
        }
    }
}

struct RetroTextField: View {
    let label: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 14 * UIScale.factor, design: .monospaced))
                .foregroundColor(.termCyan)

            TextField(placeholder, text: $text)
                .font(.system(size: 14 * UIScale.factor, design: .monospaced))
                .foregroundColor(.onBackground)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.panelBorder, lineWidth: 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.crtBackground))
                )
        }
    }
}

struct RetroSecureField: View {
    let label: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 14 * UIScale.factor, design: .monospaced))
                .foregroundColor(.termCyan)

            SecureField(placeholder, text: $text)
                .font(.system(size: 14 * UIScale.factor, design: .monospaced))
                .foregroundColor(.onBackground)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.panelBorder, lineWidth: 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.crtBackground))
                )
        }
    }
}

struct RetroPicker<SelectionValue: Hashable, Content: View>: View {
    let label: String
    @Binding var selection: SelectionValue
    let displayText: (SelectionValue) -> String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 14 * UIScale.factor, design: .monospaced))
                .foregroundColor(.termCyan)

            Menu {
                Picker(label, selection: $selection) {
                    content
                }
            } label: {
                HStack {
                    Text(displayText(selection))
                        .font(.system(size: 14 * UIScale.factor, design: .monospaced))
                        .foregroundColor(.termLightGreen)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 12 * UIScale.factor))
                        .foregroundColor(.termLightGreen)
                }
                .padding(8 * UIScale.factor)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.panelBorder, lineWidth: 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.crtBackground))
                )
            }
        }
    }
}

struct RetroToggle: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 14 * UIScale.factor, design: .monospaced))
                .foregroundColor(.termCyan)
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(.termLightGreen)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Terminal Container View

struct TerminalContainerView: View {
    @StateObject private var viewModel = TerminalViewModel()
    @State private var ctrlActive = false
    @State private var showMenu = false
    @State private var connectionTime: TimeInterval = 0
    @State private var connectionTimer: Timer?
    @State private var screenshotSaved = false
    @State private var screenshotError: String?
    @State private var showStatusBar: Bool
    @State private var showButtonBar: Bool
    @State private var showingFilePicker = false
    @State private var pasteError = false
    @State private var showDisconnectAlert = false
    @State private var disconnectMessage = ""
    @State private var keyboardHeight: CGFloat = 0
    @State private var textCopied = false

    let entry: BBSEntry
    var onDismiss: (() -> Void)? = nil

    init(entry: BBSEntry, onDismiss: (() -> Void)? = nil) {
        self.entry = entry
        self.onDismiss = onDismiss
        _showStatusBar = State(initialValue: entry.showStatusBar)
        _showButtonBar = State(initialValue: entry.showButtonBar)
    }

    /// Top safe area inset so content starts below the iOS status bar.
    private var topSafeArea: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first?.safeAreaInsets.top ?? 0
    }

    var body: some View {
        ZStack {
            // Ensure black background covers everything
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                // Terminal view area - aligned to top
                TerminalView(viewModel: viewModel, onTripleTap: {
                    // Hide keyboard
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    showMenu = true
                })
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                // Copy action bar when selecting
                if viewModel.isSelecting {
                    selectionActionBar
                }

                // Connection status bar (like Android row 26)
                if showStatusBar {
                    connectionStatusBar
                }

                // Special keys toolbar
                if showButtonBar {
                    specialKeysToolbar
                }
            }
            .padding(.top, topSafeArea)
            .padding(.bottom, keyboardHeight)
            .animation(.easeOut(duration: 0.25), value: keyboardHeight)

            // Connection status overlay (centered)
            if viewModel.connectionState == .connecting {
                Text("Connecting...")
                    .font(.system(size: 18, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(16)
                    .background(Color.black.opacity(0.8))
                    .cornerRadius(8)
            }


        } // End outer ZStack
        .ignoresSafeArea(.keyboard)
        .preferredColorScheme(.dark)
        .applyOrientationLock()
        .onAppear {
            viewModel.connect(to: entry)
            startConnectionTimer()
        }
        .onDisappear {
            stopConnectionTimer()
            viewModel.cleanup()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { notification in
            if let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
                keyboardHeight = frame.height
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardHeight = 0
        }
        .confirmationDialog("Terminal Menu", isPresented: $showMenu) {
            Button("Paste Text") {
                pasteFromClipboard()
            }
            Button("Select Text") {
                viewModel.startSelectionCentered()
            }
            Button(viewModel.userHideCursor ? "Show Cursor" : "Hide Cursor") {
                viewModel.setCursorVisible(viewModel.userHideCursor)
            }
            Button(showStatusBar ? "Hide Status Bar" : "Show Status Bar") {
                showStatusBar.toggle()
            }
            Button(showButtonBar ? "Hide Button Bar" : "Show Button Bar") {
                showButtonBar.toggle()
            }
            Button("Send File (ZMODEM)") {
                // Delay to let confirmationDialog dismiss before presenting fileImporter
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    showingFilePicker = true
                }
            }
            Button("Capture Screenshot") {
                captureScreenshot()
            }
            Button("Save Thumbnail") {
                saveThumbnail()
            }
            Button("Toggle Logging") {
                if viewModel.isLogging {
                    viewModel.stopLogging()
                } else {
                    viewModel.startLogging()
                }
            }
            Button("Disconnect", role: .destructive) {
                viewModel.disconnect()
                viewModel.cleanup()
                onDismiss?()
            }
            Button("Cancel", role: .cancel) {}
        }
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [.item],
            onCompletion: { result in
                switch result {
                case .success(let url):
                    guard url.startAccessingSecurityScopedResource() else { return }
                    defer { url.stopAccessingSecurityScopedResource() }
                    viewModel.queueUpload(fileURL: url)
                case .failure:
                    break
                }
            }
        )
        .fileImporter(
            isPresented: $viewModel.showUploadPicker,
            allowedContentTypes: [.item],
            onCompletion: { result in
                switch result {
                case .success(let url):
                    guard url.startAccessingSecurityScopedResource() else { return }
                    defer { url.stopAccessingSecurityScopedResource() }
                    // Copy to app sandbox so the security-scoped bookmark isn't needed later
                    let tempDir = FileManager.default.temporaryDirectory
                    let destURL = tempDir.appendingPathComponent(url.lastPathComponent)
                    try? FileManager.default.removeItem(at: destURL)
                    try? FileManager.default.copyItem(at: url, to: destURL)
                    viewModel.startQueuedUpload(path: destURL.path)
                case .failure:
                    break
                }
            }
        )
        .alert("Screenshot Saved", isPresented: $screenshotSaved) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Screenshot saved to Photos")
        }
        .alert("Screenshot Error", isPresented: Binding(
            get: { screenshotError != nil },
            set: { if !$0 { screenshotError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(screenshotError ?? "Unknown error")
        }
        .alert("Nothing to Paste", isPresented: $pasteError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Clipboard is empty")
        }
        .alert("Copied", isPresented: $textCopied) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Text copied to clipboard")
        }
        .alert("Disconnected", isPresented: $showDisconnectAlert) {
            Button("OK") {
                viewModel.cleanup()
                onDismiss?()
            }
        } message: {
            Text(disconnectMessage)
        }
        .onChange(of: viewModel.connectionState) { newState in
            switch newState {
            case .disconnected:
                disconnectMessage = "Connection closed"
                showDisconnectAlert = true
            case .error(let message):
                disconnectMessage = message
                showDisconnectAlert = true
            default:
                break
            }
        }
    }

    // MARK: - Screenshot

    private func captureScreenshot() {
        guard let image = viewModel.captureSnapshot() else {
            screenshotError = "Failed to capture screenshot"
            return
        }

        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
        screenshotSaved = true
    }

    private func saveThumbnail() {
        guard let data = viewModel.captureSnapshotData() else {
            screenshotError = "Failed to capture thumbnail"
            return
        }

        viewModel.saveSnapshot(data)
    }

    // MARK: - Paste from Clipboard

    private func pasteFromClipboard() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            pasteError = true
            return
        }
        viewModel.sendString(text)
    }

    // MARK: - Selection Action Bar

    private var selectionActionBar: some View {
        HStack {
            Button {
                copySelectedText()
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.blue)
            .cornerRadius(6)

            Spacer()

            Button {
                viewModel.cancelSelection()
            } label: {
                Text("Cancel")
                    .font(.system(size: 14))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.85))
    }

    /// Copy the selected text to the clipboard.
    private func copySelectedText() {
        if let text = viewModel.getSelectedText() {
            UIPasteboard.general.string = text
            viewModel.cancelSelection()
            textCopied = true
        }
    }

    // MARK: - Connection Status Bar

    private var connectionStatusBar: some View {
        HStack(spacing: 8) {
            // BBS name and protocol
            Text("\(entry.name.isEmpty ? entry.host : entry.name) (\(entry.connectionProtocol.displayName))")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.termLightGray)
                .lineLimit(1)

            // Connection time
            Text(formatTime(connectionTime))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.termGreen)

            Spacer()

            // Screen mode
            Text("\(viewModel.screenColumns)x\(viewModel.screenRows)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.termLightGray)

            // Logging indicator
            if viewModel.isLogging {
                Text("REC")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.termLightRed)
            }

            // Bytes sent/received indicator
            Text("↑\(formatBytes(viewModel.bytesSent)) ↓\(formatBytes(viewModel.bytesReceived))")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.termCyan)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(Color.crtBackground)
    }

    // MARK: - Special Keys Toolbar

    private var specialKeysToolbar: some View {
        HStack(spacing: 2) {
            SpecialKeyButton(label: "CTL", isActive: ctrlActive) {
                ctrlActive.toggle()
            }
            SpecialKeyButton(label: "ESC") {
                sendKey(27) // ESC
            }
            SpecialKeyButton(label: "DEL") {
                sendKey(127) // DEL/Backspace
            }
            SpecialKeyButton(label: "TAB") {
                sendKey(9) // TAB
            }
            SpecialKeyButton(label: "ENT") {
                sendKey(13) // Enter
            }
            SpecialKeyButton(label: "▲", fontSize: 14) {
                viewModel.sendString("\u{1B}[A")
            }
            SpecialKeyButton(label: "▼", fontSize: 14) {
                viewModel.sendString("\u{1B}[B")
            }
            SpecialKeyButton(label: "◀", fontSize: 14) {
                viewModel.sendString("\u{1B}[D")
            }
            SpecialKeyButton(label: "▶", fontSize: 14) {
                viewModel.sendString("\u{1B}[C")
            }
            SpecialKeyButton(label: "⋮", fontSize: 18) {
                showMenu = true
            }
        }
        .padding(4)
        .background(Color.crtBackground)
    }

    private func sendKey(_ keyCode: Int) {
        if ctrlActive && keyCode >= 64 && keyCode <= 127 {
            // Convert to control character
            viewModel.sendKey(keyCode - 64)
            ctrlActive = false
        } else {
            viewModel.sendKey(keyCode)
        }
    }

    // MARK: - Timer

    private func startConnectionTimer() {
        connectionTime = 0
        connectionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak viewModel] _ in
            Task { @MainActor [weak viewModel] in
                if viewModel?.connectionState == .connected {
                    connectionTime += 1
                }
            }
        }
    }

    private func stopConnectionTimer() {
        connectionTimer?.invalidate()
        connectionTimer = nil
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, secs)
    }

    private func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 {
            return "\(bytes)"
        } else if bytes < 1024 * 1024 {
            return String(format: "%.1fK", Double(bytes) / 1024.0)
        } else {
            return String(format: "%.1fM", Double(bytes) / (1024.0 * 1024.0))
        }
    }
}

// MARK: - Special Key Button

struct SpecialKeyButton: View {
    let label: String
    var fontSize: CGFloat = 10
    var isActive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: fontSize, weight: .medium))
                .foregroundColor(isActive ? .black : .white)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(isActive ? Color.logoTermColor : Color.ctrlButtonInactive)
                .cornerRadius(4)
        }
    }
}

// MARK: - Previews

struct BBSListView_Previews: PreviewProvider {
    static var previews: some View {
        BBSListView()
    }
}

struct BBSEditView_Previews: PreviewProvider {
    static var previews: some View {
        BBSEditView(entry: nil) { _ in }
    }
}
