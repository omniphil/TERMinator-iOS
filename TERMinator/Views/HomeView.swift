import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Home screen with splash image, quick connect slots, and navigation buttons.
/// Matches the Android HomeActivity layout and styling.
struct HomeView: View {
    @StateObject private var store = BBSEntryStore.shared
    @EnvironmentObject var deepLinkManager: DeepLinkManager
    @State private var showingPhonebook = false
    @State private var showingSettings = false
    @State private var showingChat = false
    @State private var selectedEntry: BBSEntry?
    @State private var showingTerminal = false
    @State private var showingQuickConnectPicker: Int? = nil

    @AppStorage("chat_enabled") private var chatEnabled = true

    // Deep link connection state
    @State private var deepLinkEntry: BBSEntry?
    @State private var showingDeepLinkTerminal = false

    // Quick connect state
    @AppStorage("quick_connect_1_id") private var quickConnect1Id: String = ""
    @AppStorage("quick_connect_2_id") private var quickConnect2Id: String = ""

    // Glitch effect state - slice-based for random section displacement
    @State private var glitchSlices: [GlitchSlice] = []
    @State private var glitchTimer: Timer?
    @State private var majorGlitchTimer: Timer?

    // Marquee text matching Android
    private let marqueeText = ">>> You're looking at a fresh zero day drop from JSONBourne <<< TERMinator, a fresh new BBS terminal app for people who live their life 64K at a time. Greetings to all the crews still pushing pixels in 16 colors, all the SysOps who never sleep, and anyone still rocking a 1084S monitor like it's 1989. Special thx to aNACHRONiST (aNSt) for providing his excellent skillz and for making textmode look like pixel CG! If this thing breaks, you get to keep both pieces. Send fixes, not complaints. >>> end of line <<<          "

    // Dark background color used throughout the home screen (matches app theme)
    private let homeBackground = Color.background

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Background - gray for main content area
                homeBackground.ignoresSafeArea()

                VStack(spacing: 0) {
                    // Header with logo (black background)
                    headerView

                    // Scrolling marquee
                    CrtMarqueeView(text: marqueeText, backgroundColor: homeBackground)

                    // Splash image area with glitch effect
                    splashImageView
                        .frame(maxHeight: .infinity)

                    // History ticker
                    HistoryTickerView(backgroundColor: homeBackground)

                    // Bottom panel with buttons
                    bottomPanel
                }
            }
        }
        .onAppear {
            // Ensure phonebook is populated with defaults on first launch
            // so Quick Connect uses correct screen modes (e.g., 80x40 for Absinthe)
            store.loadEntries()
            startGlitchEffect()
        }
        .onDisappear {
            stopGlitchEffect()
        }
        .overlay {
            if showingPhonebook {
                PhonebookView(onDismissPhonebook: { showingPhonebook = false })
                    .ignoresSafeArea()
                    .transition(.asymmetric(insertion: .move(edge: .bottom), removal: .opacity))
            }
        }
        .overlay {
            if showingChat {
                ChatView(onDismiss: { showingChat = false }, onShowPhonebook: {
                    showingChat = false
                    showingPhonebook = true
                })
                    .ignoresSafeArea(.container)
                    .transition(.asymmetric(insertion: .move(edge: .bottom), removal: .opacity))
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .sheet(item: Binding(
            get: { showingQuickConnectPicker.map { QuickConnectPickerWrapper(slot: $0) } },
            set: { _ in showingQuickConnectPicker = nil }
        )) { wrapper in
            QuickConnectPickerView(slot: wrapper.slot) { entry in
                assignQuickConnect(entry: entry, slot: wrapper.slot)
            }
        }
        .overlay {
            // Terminal overlays (non-modal, ESC cannot dismiss)
            if showingTerminal, let entry = selectedEntry {
                TerminalContainerView(entry: entry, onDismiss: { showingTerminal = false })
                    .ignoresSafeArea()
                    .transition(.asymmetric(insertion: .move(edge: .bottom), removal: .opacity))
            }
            if showingDeepLinkTerminal, let entry = deepLinkEntry {
                TerminalContainerView(entry: entry, onDismiss: { showingDeepLinkTerminal = false })
                    .ignoresSafeArea()
                    .transition(.asymmetric(insertion: .move(edge: .bottom), removal: .opacity))
            }
        }
        .onChange(of: deepLinkManager.pendingConnection) { pending in
            if let connection = pending {
                // Create a temporary BBSEntry for this deep link connection
                deepLinkEntry = BBSEntry(
                    name: connection.name,
                    host: connection.host,
                    port: connection.port
                )
                showingDeepLinkTerminal = true
                // Clear the pending connection after handling
                deepLinkManager.clearPending()
            }
        }
    }

    // MARK: - Glitch Effect

    private func startGlitchEffect() {
        // Schedule first major glitch
        scheduleMajorGlitch()
    }

    private func scheduleMajorGlitch() {
        // Major glitch every 2-5 seconds
        let delay = Double.random(in: 2.0...5.0)
        majorGlitchTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
            triggerMajorGlitch()
        }
    }

    private func triggerMajorGlitch() {
        // Duration: 30-80ms (quick snap)
        let duration = Double.random(in: 0.03...0.08)

        // Get image dimensions for generating slices
        guard let image = UIImage(named: "splash_screen"),
              let cgImage = image.cgImage else {
            scheduleMajorGlitch()
            return
        }

        let imageHeight = cgImage.height

        // Generate 3-6 random glitch slices at different positions
        let sliceCount = Int.random(in: 3...6)
        var newSlices: [GlitchSlice] = []

        for _ in 0..<sliceCount {
            let startY = Int.random(in: 0..<imageHeight)
            let maxHeight = min(imageHeight - startY, imageHeight / 5) // Max 20% of image height
            let height = Int.random(in: 5...max(10, maxHeight))
            let xOffset = CGFloat.random(in: -25...25)
            let rgbShift: CGFloat = Bool.random() ? CGFloat.random(in: 2...6) : 0

            let slice = GlitchSlice(
                startY: startY,
                height: height,
                xOffset: xOffset,
                rgbShift: rgbShift
            )
            newSlices.append(slice)
        }

        glitchSlices = newSlices

        // End glitch
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            self.glitchSlices = []

            // Schedule next major glitch
            self.scheduleMajorGlitch()
        }
    }

    private func stopGlitchEffect() {
        glitchTimer?.invalidate()
        glitchTimer = nil
        majorGlitchTimer?.invalidate()
        majorGlitchTimer = nil
        glitchSlices = []
    }

    // MARK: - Header

    private var headerView: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                // Logo - scales up on iPad
                if let _ = UIImage(named: "header_logo") {
                    Image("header_logo")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: min(300 * UIScale.factor, UIScreen.main.bounds.width * 0.75))
                        .padding(.vertical, 8)
                } else {
                    // Fallback text logo
                    HStack(spacing: 0) {
                        Text("TERM")
                            .font(.system(size: 32 * UIScale.factor, weight: .bold, design: .monospaced))
                            .foregroundColor(.logoTermColor)
                        Text("inator")
                            .font(.system(size: 32 * UIScale.factor, weight: .bold, design: .monospaced))
                            .foregroundColor(.termLightGreen)
                    }
                    .padding(.vertical, 16)
                }

                // Accent line (matches logo_term_color in Android)
                Rectangle()
                    .fill(Color.logoTermColor)
                    .frame(height: 2)
            }

            // Version number in lower right corner
            Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                .font(.system(size: 10 * UIScale.factor, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
                .padding(.trailing, 8)
                .padding(.bottom, 4)
        }
        .background(Color.black)
    }

    // MARK: - Splash Image

    private var splashImageView: some View {
        GeometryReader { geo in
            ZStack {
                homeBackground
                if let uiImage = UIImage(named: "splash_screen") {
                    GlitchImageView(image: uiImage, slices: glitchSlices, backgroundColor: homeBackground)
                } else {
                    // Fallback ASCII art style
                    VStack(spacing: 8) {
                        Text("  ╔══════════════════╗")
                        Text("  ║  TERMinator iOS  ║")
                        Text("  ║   BBS Terminal   ║")
                        Text("  ╚══════════════════╝")
                        Text("")
                        Text("    READY.")
                        Text("    _")
                    }
                    .font(.system(size: 16, design: .monospaced))
                    .foregroundColor(.termLightGreen)
                }
            }
        }
    }

    // MARK: - Bottom Panel

    private var isTablet: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    private var bottomPanel: some View {
        Group {
            if isTablet {
                // Tablet: Single horizontal row with all items centered
                HStack(spacing: 6) {
                    Spacer()

                    // Quick Connect 1 - fixed 180x113
                    quickConnectSlotTablet(slot: 1)
                        .frame(width: 180, height: 113)

                    // Quick Connect 2 - fixed 180x113
                    quickConnectSlotTablet(slot: 2)
                        .frame(width: 180, height: 113)

                    // Phonebook button - fixed 113 wide
                    Button {
                        showingPhonebook = true
                    } label: {
                        RetroButtonTablet(icon: "phone.fill")
                    }
                    .frame(width: 113, height: 113)

                    // Chat button - fixed 113 wide
                    if chatEnabled {
                        Button {
                            showingChat = true
                        } label: {
                            RetroButtonTablet(icon: "bubble.left.and.bubble.right.fill")
                        }
                        .frame(width: 113, height: 113)
                    }

                    // Settings button - fixed 113 wide
                    Button {
                        showingSettings = true
                    } label: {
                        RetroButtonTablet(icon: "gearshape.fill")
                    }
                    .frame(width: 113, height: 113)

                    Spacer()
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 16)
            } else {
                // Phone: Two rows stacked
                VStack(spacing: 12) {
                    // Quick Connect row
                    HStack(spacing: 12) {
                        quickConnectSlot(slot: 1)
                        quickConnectSlot(slot: 2)
                    }

                    // Navigation row
                    HStack(spacing: 12) {
                        // Phonebook button
                        Button {
                            showingPhonebook = true
                        } label: {
                            RetroButton(icon: "phone.fill", label: nil)
                        }

                        // Chat button
                        if chatEnabled {
                            Button {
                                showingChat = true
                            } label: {
                                RetroButton(icon: "bubble.left.and.bubble.right.fill", label: nil)
                            }
                        }

                        // Settings button
                        Button {
                            showingSettings = true
                        } label: {
                            RetroButton(icon: "gearshape.fill", label: nil)
                        }
                    }
                }
                .padding(16)
            }
        }
        .background(homeBackground)
    }

    // MARK: - Tablet Quick Connect Slot (smaller, fixed size)

    private func quickConnectSlotTablet(slot: Int) -> some View {
        let entryId = slot == 1 ? quickConnect1Id : quickConnect2Id
        let entry = store.entries.first { $0.id.uuidString == entryId }

        return Button {
            if let entry = entry {
                selectedEntry = entry
                showingTerminal = true
            } else {
                showingQuickConnectPicker = slot
            }
        } label: {
            QuickConnectSlotViewTablet(slot: slot, entry: entry)
        }
        .contextMenu {
            if entry != nil {
                Button(role: .destructive) {
                    clearQuickConnect(slot: slot)
                } label: {
                    Label("Clear Slot", systemImage: "xmark.circle")
                }
            }
            Button {
                showingQuickConnectPicker = slot
            } label: {
                Label("Assign BBS", systemImage: "plus.circle")
            }
        }
    }

    // MARK: - Quick Connect Slots

    private func quickConnectSlot(slot: Int) -> some View {
        let entryId = slot == 1 ? quickConnect1Id : quickConnect2Id
        let entry = store.entries.first { $0.id.uuidString == entryId }

        return Button {
            if let entry = entry {
                // Launch terminal
                selectedEntry = entry
                showingTerminal = true
            } else {
                // Show picker to assign
                showingQuickConnectPicker = slot
            }
        } label: {
            QuickConnectSlotView(slot: slot, entry: entry)
        }
        .contextMenu {
            if entry != nil {
                Button(role: .destructive) {
                    clearQuickConnect(slot: slot)
                } label: {
                    Label("Clear Slot", systemImage: "xmark.circle")
                }
            }

            Button {
                showingQuickConnectPicker = slot
            } label: {
                Label("Assign BBS", systemImage: "plus.circle")
            }
        }
    }

    // MARK: - Quick Connect Management

    private func assignQuickConnect(entry: BBSEntry, slot: Int) {
        if slot == 1 {
            quickConnect1Id = entry.id.uuidString
        } else {
            quickConnect2Id = entry.id.uuidString
        }
    }

    private func clearQuickConnect(slot: Int) {
        if slot == 1 {
            quickConnect1Id = ""
        } else {
            quickConnect2Id = ""
        }
    }
}

// MARK: - Quick Connect Slot View

struct QuickConnectSlotView: View {
    let slot: Int
    let entry: BBSEntry?

    // Match Android retro_button_primary.xml: green border (#00AA00), dark green fill (#0A200A)
    private let buttonFill = Color(red: 0.039, green: 0.125, blue: 0.039) // #0A200A
    private let buttonBorder = Color.termGreen // #00AA00

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Background with retro border - matches Android retro_button_primary
                RoundedRectangle(cornerRadius: 2)
                    .stroke(buttonBorder, lineWidth: 2)
                    .background(
                        RoundedRectangle(cornerRadius: 2)
                            .fill(buttonFill)
                    )

                if let entry = entry {
                    // Show snapshot or icon + name
                    if let snapshotData = entry.snapshotData,
                       let uiImage = UIImage(data: snapshotData) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                    } else {
                        // Icon + name fallback
                        VStack(spacing: 4) {
                            Image(systemName: "terminal")
                                .font(.system(size: 32))
                                .foregroundColor(.termLightGreen.opacity(0.7))

                            Text(entry.name.isEmpty ? entry.host : entry.name)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.termLightGreen)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                        }
                        .padding(8)
                    }
                } else {
                    // Empty slot - tap to assign
                    Text(slot == 1 ? "QUICK CONNECT 1\n(Tap to Assign)" : "QUICK CONNECT 2\n(Tap to Assign)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.termLightGreen.opacity(0.6))
                        .multilineTextAlignment(.center)
                }
            }
        }
        .aspectRatio(8.0/5.0, contentMode: .fit)
    }
}

// MARK: - Retro Button

struct RetroButton: View {
    let icon: String
    let label: String?

    // Match Android retro_button.xml: cyan border (#00AAAA), dark cyan fill (#0A2020)
    private let buttonFill = Color(red: 0.039, green: 0.125, blue: 0.125) // #0A2020
    private let buttonBorder = Color.termCyan // #00AAAA

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 24))

            if let label = label {
                Text(label)
                    .font(.system(size: 14, design: .monospaced))
            }
        }
        .foregroundColor(.termLightCyan) // Match Android cyan icon tint
        .frame(maxWidth: .infinity)
        .frame(height: 56)
        .background(
            RoundedRectangle(cornerRadius: 2)
                .stroke(buttonBorder, lineWidth: 2)
                .background(
                    RoundedRectangle(cornerRadius: 2)
                        .fill(buttonFill)
                )
        )
    }
}

// MARK: - Tablet Quick Connect Slot View (smaller, fixed size)

struct QuickConnectSlotViewTablet: View {
    let slot: Int
    let entry: BBSEntry?

    private let buttonFill = Color(red: 0.039, green: 0.125, blue: 0.039)
    private let buttonBorder = Color.termGreen

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2)
                .stroke(buttonBorder, lineWidth: 2)
                .background(
                    RoundedRectangle(cornerRadius: 2)
                        .fill(buttonFill)
                )

            if let entry = entry {
                if let snapshotData = entry.snapshotData,
                   let uiImage = UIImage(data: snapshotData) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .clipped()
                } else {
                    VStack(spacing: 4) {
                        Image(systemName: "terminal")
                            .font(.system(size: 30 * UIScale.factor))
                            .foregroundColor(.termLightGreen.opacity(0.7))
                        Text(entry.name.isEmpty ? entry.host : entry.name)
                            .font(.system(size: 11 * UIScale.factor, design: .monospaced))
                            .foregroundColor(.termLightGreen)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    }
                    .padding(6)
                }
            } else {
                // Empty slot - tap to assign
                Text("Quick\nConnect\n\(slot)")
                    .font(.system(size: 16 * UIScale.factor, design: .monospaced))
                    .foregroundColor(.termLightGreen.opacity(0.6))
                    .multilineTextAlignment(.center)
            }
        }
    }
}

// MARK: - Tablet Retro Button (smaller, square)

struct RetroButtonTablet: View {
    let icon: String

    private let buttonFill = Color(red: 0.039, green: 0.125, blue: 0.125)
    private let buttonBorder = Color.termCyan

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 36))
            .foregroundColor(.termLightCyan)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 2)
                    .stroke(buttonBorder, lineWidth: 2)
                    .background(
                        RoundedRectangle(cornerRadius: 2)
                            .fill(buttonFill)
                    )
            )
    }
}

// MARK: - Grid Pattern View

struct GridPatternView: View {
    var body: some View {
        Canvas { context, size in
            // Fill background with app background color first
            let bgRect = CGRect(origin: .zero, size: size)
            context.fill(Path(bgRect), with: .color(Color.background))

            let gridSize: CGFloat = 20
            let lineColor = Color.background.opacity(0.3) // Subtle lines matching background tint

            // Vertical lines
            var x: CGFloat = 0
            while x < size.width {
                let path = Path { p in
                    p.move(to: CGPoint(x: x, y: 0))
                    p.addLine(to: CGPoint(x: x, y: size.height))
                }
                context.stroke(path, with: .color(lineColor), lineWidth: 0.5)
                x += gridSize
            }

            // Horizontal lines
            var y: CGFloat = 0
            while y < size.height {
                let path = Path { p in
                    p.move(to: CGPoint(x: 0, y: y))
                    p.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(path, with: .color(lineColor), lineWidth: 0.5)
                y += gridSize
            }
        }
    }
}

// MARK: - Quick Connect Picker

struct QuickConnectPickerWrapper: Identifiable {
    let id = UUID()
    let slot: Int
}

extension Optional where Wrapped == Int {
    func map<T>(_ transform: (Int) -> T) -> T? {
        switch self {
        case .some(let value):
            return transform(value)
        case .none:
            return nil
        }
    }
}

struct QuickConnectPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = BBSEntryStore.shared

    let slot: Int
    let onSelect: (BBSEntry) -> Void

    var body: some View {
        NavigationStack {
            List {
                if store.entries.isEmpty {
                    Text("No BBS connections available.\nAdd connections in the Phonebook first.")
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding()
                } else {
                    ForEach(store.entries) { entry in
                        Button {
                            onSelect(entry)
                            dismiss()
                        } label: {
                            HStack {
                                // Thumbnail or icon
                                if let snapshotData = entry.snapshotData,
                                   let uiImage = UIImage(data: snapshotData) {
                                    Image(uiImage: uiImage)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 60, height: 38)
                                        .cornerRadius(4)
                                        .clipped()
                                } else {
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color(.systemGray5))
                                        .frame(width: 60, height: 38)
                                        .overlay {
                                            Image(systemName: "terminal")
                                                .foregroundColor(.secondary)
                                        }
                                }

                                VStack(alignment: .leading) {
                                    Text(entry.name.isEmpty ? entry.host : entry.name)
                                        .font(.headline)
                                        .foregroundColor(.primary)
                                    Text("\(entry.host):\(entry.port)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }

                                Spacer()
                            }
                        }
                    }
                }
            }
            .navigationTitle("Assign to Slot \(slot)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Phonebook View (Updated BBSListView)

struct PhonebookView: View {
    var onDismissPhonebook: (() -> Void)? = nil
    @StateObject private var store = BBSEntryStore.shared
    @State private var showingAddSheet = false
    @State private var editingEntry: BBSEntry?
    @State private var selectedEntry: BBSEntry?
    @State private var pendingConnection: BBSEntry?
    @State private var draggedEntryId: UUID?
    @State private var previewSnapshotData: Data?

    /// Top safe area inset so content starts below the iOS status bar / notch.
    private var topSafeArea: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first?.safeAreaInsets.top ?? 0
    }

    var body: some View {
        VStack(spacing: 0) {
            // Custom header matching main screen
            phonebookHeader

            // Content area
            if store.entries.isEmpty {
                emptyState
            } else {
                connectionsList
            }
        }
        .padding(.top, topSafeArea)
        .background(GridPatternView().ignoresSafeArea().allowsHitTesting(false))
        .background(Color.background.ignoresSafeArea())
        .fullScreenCover(isPresented: $showingAddSheet) {
            BBSEditView(entry: nil) { newEntry in
                store.addEntry(newEntry)
            }
        }
        .fullScreenCover(item: $editingEntry, onDismiss: {
            // Check if we have a pending connection after the sheet dismisses
            if let entry = pendingConnection {
                pendingConnection = nil
                // Small delay to allow sheet dismiss animation to complete
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    selectedEntry = entry
                }
            }
        }) { entry in
            BBSEditView(
                entry: entry,
                onSave: { updatedEntry in
                    store.updateEntry(updatedEntry)
                },
                onConnect: { connectEntry in
                    // Store the entry to connect after sheet dismisses
                    pendingConnection = connectEntry
                },
                onDelete: { deleteEntry in
                    store.deleteEntry(deleteEntry)
                }
            )
        }
        .overlay {
            if let entry = selectedEntry {
                TerminalContainerView(entry: entry, onDismiss: { selectedEntry = nil })
                    .ignoresSafeArea()
                    .transition(.move(edge: .bottom))
            }
        }
        .overlay {
            // Snapshot image preview
            if let data = previewSnapshotData,
               let uiImage = UIImage(data: data) {
                Color.black.opacity(0.85)
                    .ignoresSafeArea()
                    .onTapGesture { previewSnapshotData = nil }
                    .overlay {
                        GeometryReader { geo in
                            Image(uiImage: uiImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: geo.size.width * 0.9)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .onTapGesture { previewSnapshotData = nil }
                    }
            }
        }
    }

    // MARK: - Phonebook Header

    private var phonebookHeader: some View {
        VStack(spacing: 0) {
            HStack {
                // Home button
                Button {
                    onDismissPhonebook?()
                } label: {
                    Image(systemName: "house.fill")
                        .font(.system(size: 20 * UIScale.factor))
                        .foregroundColor(.termLightGreen)
                        .padding(12)
                }

                Spacer()

                // Logo - scales with UIScale
                if let _ = UIImage(named: "header_logo") {
                    Image("header_logo")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: min(300 * UIScale.factor, UIScreen.main.bounds.width * 0.75))
                } else {
                    HStack(spacing: 0) {
                        Text("TERM")
                            .font(.system(size: 32 * UIScale.factor, weight: .bold, design: .monospaced))
                            .foregroundColor(.logoTermColor)
                        Text("inator")
                            .font(.system(size: 32 * UIScale.factor, weight: .bold, design: .monospaced))
                            .foregroundColor(.termLightGreen)
                    }
                }

                Spacer()

                // Add button
                Button {
                    showingAddSheet = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 20 * UIScale.factor))
                        .foregroundColor(.termLightGreen)
                        .padding(12)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 8)

            // Accent line
            Rectangle()
                .fill(Color.logoTermColor)
                .frame(height: 2)
        }
        .background(Color.black)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "terminal")
                .font(.system(size: 80 * UIScale.factor))
                .foregroundColor(.termLightGreen.opacity(0.6))

            Text("No BBS Connections")
                .font(.system(size: 22 * UIScale.factor, weight: .bold))
                .foregroundColor(.appPrimaryLight)

            Text("Tap + to add your first BBS")
                .font(.system(size: 15 * UIScale.factor))
                .foregroundColor(.termLightGreen.opacity(0.6))

            Text("_ READY")
                .font(.system(size: 16 * UIScale.factor, design: .monospaced))
                .foregroundColor(.accent)
                .padding(.top, 20)

            Button {
                showingAddSheet = true
            } label: {
                Label("Add Connection", systemImage: "plus")
                    .font(.system(size: 17 * UIScale.factor, weight: .semibold))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Color.logoTermColor)
                    .foregroundColor(.white)
                    .cornerRadius(8)
            }
            .padding(.top, 10)
        }
    }

    // MARK: - Connections List

    private var connectionsList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(store.entries) { entry in
                    PhonebookEntryRow(entry: entry, onImageTap: entry.snapshotData != nil ? {
                        previewSnapshotData = entry.snapshotData
                    } : nil)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(red: 0.102, green: 0.145, blue: 0.208))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color(red: 0.165, green: 0.208, blue: 0.271), lineWidth: 1)
                                )
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            editingEntry = entry
                        }
                        .onDrag {
                            draggedEntryId = entry.id
                            return NSItemProvider(object: entry.id.uuidString as NSString)
                        }
                        .onDrop(of: [UTType.text], delegate: PhonebookDropDelegate(
                            entry: entry,
                            store: store,
                            draggedEntryId: $draggedEntryId
                        ))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }
}

// MARK: - Phonebook Entry Row

struct PhonebookEntryRow: View {
    let entry: BBSEntry
    var onImageTap: (() -> Void)? = nil

    private var thumbnailWidth: CGFloat {
        120 * UIScale.factor
    }

    private var thumbnailHeight: CGFloat {
        75 * UIScale.factor
    }

    var body: some View {
        HStack(spacing: 12) {
            // Larger snapshot or placeholder (120x75 like Android, scaled for iPad)
            if let snapshotData = entry.snapshotData,
               let uiImage = UIImage(data: snapshotData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: thumbnailWidth, height: thumbnailHeight)
                    .cornerRadius(4)
                    .clipped()
                    .onTapGesture {
                        onImageTap?()
                    }
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.black)
                    .frame(width: thumbnailWidth, height: thumbnailHeight)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.panelBorder, lineWidth: 1)
                    )
                    .overlay {
                        Image(systemName: "terminal")
                            .font(.system(size: 30 * UIScale.factor))
                            .foregroundColor(.termLightGreen.opacity(0.5))
                    }
            }

            VStack(alignment: .leading, spacing: 4) {
                // BBS Name - light cyan, bold
                Text(entry.name.isEmpty ? entry.host : entry.name)
                    .font(.system(size: 15 * UIScale.factor, weight: .bold, design: .monospaced))
                    .foregroundColor(.appPrimaryLight) // #96EEF8 like Android

                // Host:Port - medium blue, 14sp equivalent
                Text(entry.addressDisplay)
                    .font(.system(size: 14 * UIScale.factor, design: .monospaced))
                    .foregroundColor(.textSecondary.opacity(0.8))
            }

            Spacer()

            // Drag handle indicator (like Android)
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 24 * UIScale.factor))
                .foregroundColor(.termLightGray.opacity(0.3))
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
    }
}

// MARK: - Phonebook Drop Delegate

struct PhonebookDropDelegate: DropDelegate {
    let entry: BBSEntry
    let store: BBSEntryStore
    @Binding var draggedEntryId: UUID?

    func performDrop(info: DropInfo) -> Bool {
        draggedEntryId = nil
        store.saveEntries()
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let draggedId = draggedEntryId,
              draggedId != entry.id,
              let fromIndex = store.entries.firstIndex(where: { $0.id == draggedId }),
              let toIndex = store.entries.firstIndex(where: { $0.id == entry.id })
        else { return }

        withAnimation {
            store.entries.move(
                fromOffsets: IndexSet(integer: fromIndex),
                toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex
            )
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

// MARK: - Glitch Slice Data

struct GlitchSlice {
    let startY: Int        // Start row in pixels (in source image coordinates)
    let height: Int        // Height in pixels
    let xOffset: CGFloat   // Horizontal displacement in display points
    let rgbShift: CGFloat  // RGB separation amount (0 = none)
}

// MARK: - Glitch Image View

/// Renders an image with slice-based glitch effects where random horizontal
/// sections are displaced independently for an authentic digital corruption look.
struct GlitchImageView: View {
    let image: UIImage
    let slices: [GlitchSlice]
    var backgroundColor: Color = Color(red: 0.85, green: 0.85, blue: 0.85)

    var body: some View {
        ZStack {
            // Background color layer
            backgroundColor

            Canvas(opaque: false) { context, size in
                guard let cgImage = image.cgImage else { return }

                // Calculate display size (aspect fit)
                let imageAspect = CGFloat(cgImage.width) / CGFloat(cgImage.height)
                let containerAspect = size.width / size.height

                let displaySize: CGSize
                if imageAspect > containerAspect {
                    displaySize = CGSize(width: size.width, height: size.width / imageAspect)
                } else {
                    displaySize = CGSize(width: size.height * imageAspect, height: size.height)
                }

                let originX = (size.width - displaySize.width) / 2
                let originY = (size.height - displaySize.height) / 2

                // Scale factor from image pixels to display points
                let scale = displaySize.height / CGFloat(cgImage.height)

                if slices.isEmpty {
                    // No glitch - draw normally
                    let destRect = CGRect(x: originX, y: originY, width: displaySize.width, height: displaySize.height)
                    context.draw(Image(decorative: cgImage, scale: 1.0), in: destRect)
                } else {
                // Draw image in horizontal strips, offsetting glitched slices
                let imageHeight = cgImage.height
                var y = 0

                while y < imageHeight {
                    // Check if this row is part of a glitch slice
                    var sliceForRow: GlitchSlice? = nil
                    var sliceEnd = imageHeight

                    for slice in slices {
                        if y >= slice.startY && y < slice.startY + slice.height {
                            sliceForRow = slice
                            sliceEnd = slice.startY + slice.height
                            break
                        } else if slice.startY > y {
                            sliceEnd = min(sliceEnd, slice.startY)
                        }
                    }

                    let stripHeight = (sliceForRow != nil) ? min(sliceEnd - y, imageHeight - y) : min(sliceEnd - y, imageHeight - y)
                    guard stripHeight > 0 else { break }

                    // Crop this strip from the source image
                    let cropRect = CGRect(x: 0, y: y, width: cgImage.width, height: stripHeight)
                    guard let stripImage = cgImage.cropping(to: cropRect) else {
                        y += stripHeight
                        continue
                    }

                    let displayY = originY + CGFloat(y) * scale
                    let displayH = CGFloat(stripHeight) * scale
                    let xOffset = sliceForRow?.xOffset ?? 0
                    let rgbShift = sliceForRow?.rgbShift ?? 0

                    // Draw RGB shift layers if needed
                    if rgbShift > 0 {
                        // Red channel shifted right
                        let redRect = CGRect(x: originX + xOffset + rgbShift, y: displayY, width: displaySize.width, height: displayH)
                        context.drawLayer { ctx in
                            ctx.opacity = 0.35
                            ctx.draw(Image(decorative: stripImage, scale: 1.0), in: redRect)
                        }

                        // Cyan channel shifted left
                        let cyanRect = CGRect(x: originX + xOffset - rgbShift, y: displayY, width: displaySize.width, height: displayH)
                        context.drawLayer { ctx in
                            ctx.opacity = 0.35
                            ctx.draw(Image(decorative: stripImage, scale: 1.0), in: cyanRect)
                        }
                    }

                    // Draw main strip
                    let destRect = CGRect(x: originX + xOffset, y: displayY, width: displaySize.width, height: displayH)
                    context.draw(Image(decorative: stripImage, scale: 1.0), in: destRect)

                    y += stripHeight
                }
            }
        }
        }
    }
}

// MARK: - Preview

struct HomeView_Previews: PreviewProvider {
    static var previews: some View {
        HomeView()
    }
}
