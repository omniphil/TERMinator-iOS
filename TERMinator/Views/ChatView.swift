import SwiftUI

/// Full-screen chat view with retro terminal styling.
/// Firebase connects on appear, fully tears down on disappear.
struct ChatView: View {
    var onDismiss: () -> Void
    var onShowPhonebook: (() -> Void)?

    @StateObject private var viewModel = ChatViewModel()
    @State private var messageText = ""
    @FocusState private var inputFocused: Bool
    @State private var showingSettings = false

    // Chat-specific colors
    private let headerBg = Color(red: 0.039, green: 0.039, blue: 0.082) // #0A0A15
    private let countryColor = Color(red: 0.333, green: 1, blue: 1) // #55FFFF cyan
    private let usernameColor = Color(red: 0.333, green: 1, blue: 0.333) // #55FF55 green
    private let dimmedColor = Color(red: 0.333, green: 0.333, blue: 0.333) // #555555
    private let reportedColor = Color(red: 1, green: 0.533, blue: 0.333) // #FF8855 orange

    private var topSafeArea: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first?.safeAreaInsets.top ?? 0
    }

    private var bottomSafeArea: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first?.safeAreaInsets.bottom ?? 0
    }

    var body: some View {
        VStack(spacing: 0) {
            chatHeader
            roomSelectorBar
            messageList
                .background(viewModel.currentRoom.backgroundColor)
            inputBar
        }
        .padding(.top, topSafeArea)
        .background(viewModel.currentRoom.backgroundColor.ignoresSafeArea())
        .onAppear {
            viewModel.connect()
        }
        .onDisappear {
            viewModel.disconnect()
        }
        .sheet(isPresented: $showingSettings, onDismiss: {
            viewModel.refreshAfterSettings()
        }) {
            SettingsView()
        }
        .overlay(alignment: .bottom) {
            if let toast = viewModel.toastMessage {
                Text(toast)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.85))
                    .cornerRadius(8)
                    .padding(.bottom, 80)
                    .transition(.opacity)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                            withAnimation { viewModel.toastMessage = nil }
                        }
                    }
            }
        }
    }

    // MARK: - Header

    private var chatHeader: some View {
        HStack(spacing: 0) {
            Button { onDismiss() } label: {
                Image(systemName: "house.fill")
                    .font(.system(size: 20 * UIScale.factor))
                    .foregroundColor(.termLightGreen)
                    .padding(12)
            }

            Button { onShowPhonebook?() ?? onDismiss() } label: {
                Image(systemName: "phone.fill")
                    .font(.system(size: 20 * UIScale.factor))
                    .foregroundColor(.termLightCyan)
                    .padding(12)
            }

            Spacer()

            Button { viewModel.decreaseTextSize() } label: {
                Text("A-")
                    .font(.system(size: 16 * UIScale.factor, weight: .bold, design: .monospaced))
                    .foregroundColor(.termLightCyan)
                    .padding(12)
            }

            Button { viewModel.increaseTextSize() } label: {
                Text("A+")
                    .font(.system(size: 16 * UIScale.factor, weight: .bold, design: .monospaced))
                    .foregroundColor(.termLightCyan)
                    .padding(12)
            }

            Button { showingSettings = true } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 20 * UIScale.factor))
                    .foregroundColor(.termLightCyan)
                    .padding(12)
            }
        }
        .background(headerBg)
    }

    // MARK: - Room Selector

    @State private var showingRoomPicker = false

    private var roomSelectorBar: some View {
        HStack(spacing: 8) {
            Text("Rooms:")
                .font(.system(size: 16 * UIScale.factor, weight: .bold, design: .monospaced))
                .foregroundColor(.termLightGreen)

            Button {
                showingRoomPicker = true
            } label: {
                HStack(spacing: 4) {
                    Text(viewModel.currentRoom.displayName)
                        .font(.system(size: 16 * UIScale.factor, weight: .bold, design: .monospaced))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12 * UIScale.factor))
                }
                .foregroundColor(.termLightCyan)
            }
            .confirmationDialog("Select Room", isPresented: $showingRoomPicker, titleVisibility: .visible) {
                ForEach(ChatRoom.allCases) { room in
                    Button(room.displayName) {
                        messageText = ""
                        viewModel.switchRoom(to: room)
                    }
                }
            }

            Spacer()

            HStack(spacing: 6) {
                Circle()
                    .fill(viewModel.serverStatus.color)
                    .frame(width: 10 * UIScale.factor, height: 10 * UIScale.factor)
                Text(viewModel.serverStatus.label)
                    .font(.system(size: 14 * UIScale.factor, design: .monospaced))
                    .foregroundColor(viewModel.serverStatus.color)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(headerBg)
    }

    // MARK: - Message List

    private var messageList: some View {
        ScrollViewReader { proxy in
            GeometryReader { geo in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if viewModel.messages.isEmpty {
                            emptyState
                        } else {
                            ForEach(viewModel.messages) { msg in
                                messageRow(msg)
                                    .id(msg.key)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(minHeight: geo.size.height, alignment: .bottom)
                }
            }
            .onChange(of: viewModel.messages.count) { _ in
                if let lastKey = viewModel.messages.last?.key {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(lastKey, anchor: .bottom)
                    }
                }
            }
            .onAppear {
                if let lastKey = viewModel.messages.last?.key {
                    proxy.scrollTo(lastKey, anchor: .bottom)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                if let lastKey = viewModel.messages.last?.key {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(lastKey, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer().frame(height: 60)
            Text(emptyStateText)
                .font(.system(size: CGFloat(viewModel.textSize), design: .monospaced))
                .foregroundColor(.termLightGreen.opacity(0.6))
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyStateText: String {
        switch viewModel.serverStatus {
        case .connecting: return "Connecting..."
        case .connected: return "No messages yet"
        case .disconnected: return "Disconnected"
        }
    }

    // MARK: - Message Row

    @ViewBuilder
    private func messageRow(_ msg: ChatMessage) -> some View {
        let isOwn = msg.uid == viewModel.currentUid
        let isHidden = msg.hidden

        HStack(alignment: .top, spacing: 0) {
            Text("[\(msg.countryCode)] ")
                .font(.system(size: CGFloat(viewModel.textSize), weight: .bold, design: .monospaced))
                .foregroundColor(isHidden ? dimmedColor : countryColor)

            Text("\(msg.username): ")
                .font(.system(size: CGFloat(viewModel.textSize), weight: .bold, design: .monospaced))
                .foregroundColor(isHidden ? dimmedColor : usernameColor)

            Text(isHidden && !viewModel.isAdmin ? "[Hidden due to reports]" : msg.message)
                .font(.system(size: CGFloat(viewModel.textSize), design: .monospaced))
                .foregroundColor(messageColor(isHidden: isHidden))

            Spacer(minLength: 4)

            Text(msg.formattedTime)
                .font(.system(size: CGFloat(max(viewModel.textSize - 4, 8)), design: .monospaced))
                .foregroundColor(.termLightGray.opacity(0.5))
        }
        .padding(.vertical, 4)
        .contextMenu {
            // Copy message text
            Button {
                UIPasteboard.general.string = msg.message
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }

            if isOwn {
                Button {
                    messageText = viewModel.startEditing(msg)
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
            }

            if !isOwn {
                Button {
                    viewModel.reportMessage(msg, reason: "Inappropriate")
                } label: {
                    Label("Report", systemImage: "exclamationmark.triangle")
                }

                Button(role: .destructive) {
                    viewModel.blockUser(uid: msg.uid)
                } label: {
                    Label("Block User", systemImage: "hand.raised.fill")
                }
            }

            if viewModel.isAdmin {
                Divider()

                Button(role: .destructive) {
                    viewModel.adminDeleteMessage(msg)
                } label: {
                    Label("Delete (Soft)", systemImage: "trash")
                }

                Button(role: .destructive) {
                    viewModel.adminDeleteFromDb(msg)
                } label: {
                    Label("Delete from DB", systemImage: "trash.fill")
                }

                if isHidden {
                    Button {
                        viewModel.dismissReports(msg)
                    } label: {
                        Label("Dismiss Reports", systemImage: "checkmark.circle")
                    }
                }
            }
        }
    }

    private func messageColor(isHidden: Bool) -> Color {
        if isHidden {
            return viewModel.isAdmin ? reportedColor : dimmedColor
        }
        return .white
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        VStack(spacing: 0) {
            if viewModel.editingMessageKey != nil {
                HStack {
                    Text("Editing message...")
                        .font(.system(size: 14 * UIScale.factor, design: .monospaced))
                        .foregroundColor(.termYellow)
                    Spacer()
                    Button("Cancel") {
                        viewModel.cancelEditing()
                        messageText = ""
                    }
                    .font(.system(size: 14 * UIScale.factor, design: .monospaced))
                    .foregroundColor(.termLightRed)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(headerBg)
            }

            HStack(spacing: 12) {
                TextField("Type a message...", text: $messageText)
                    .font(.system(size: 16 * UIScale.factor, design: .monospaced))
                    .foregroundColor(.white)
                    .accentColor(.termLightGreen)
                    .textFieldStyle(.plain)
                    .focused($inputFocused)
                    .onChange(of: messageText) { newValue in
                        if newValue.count > ChatViewModel.maxMessageLength {
                            messageText = String(newValue.prefix(ChatViewModel.maxMessageLength))
                        }
                    }
                    .onSubmit {
                        sendAndClear()
                    }

                Text("\(messageText.count)/\(ChatViewModel.maxMessageLength)")
                    .font(.system(size: 12 * UIScale.factor, design: .monospaced))
                    .foregroundColor(messageText.count >= ChatViewModel.maxMessageLength ? .termLightRed : .termLightGray.opacity(0.5))

                Button {
                    sendAndClear()
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 28 * UIScale.factor))
                        .foregroundColor(messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .termDarkGray : .termLightGreen)
                }
                .disabled(messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .padding(.bottom, bottomSafeArea)
            .background(headerBg)
        }
    }

    private func sendAndClear() {
        let text = messageText
        if viewModel.sendMessage(text) {
            messageText = ""
        }
    }
}
