import Foundation
import SwiftUI

/// ViewModel for the chat feature. Creates FirebaseChatManager on connect(),
/// tears it down completely on disconnect(). No Firebase runs outside of chat.
class ChatViewModel: ObservableObject {
    // MARK: - Published State

    @Published var messages: [ChatMessage] = []
    @Published var serverStatus: ServerStatus = .disconnected
    @Published var currentRoom: ChatRoom = .bbsChat
    @Published var isAdmin: Bool = false
    @Published var editingMessageKey: String?
    @Published var toastMessage: String?

    // MARK: - Persisted Settings

    @AppStorage("chat_username") var username: String = ""
    @AppStorage("chat_country") var countryCode: String = "---"
    @AppStorage("chat_text_size") var textSize: Double = 14
    @AppStorage("chat_current_room") private var currentRoomKey: String = "bbs_chat"
    @AppStorage("chat_blocked_uids") private var blockedUidsJson: String = "[]"

    // MARK: - Private State

    private var manager: FirebaseChatManager?
    private var cachedBlockedUids: Set<String> = []
    private var lastSendTime: Date = .distantPast
    private var roomMessages: [String: [ChatMessage]] = [
        ChatRoom.bbsChat.rawValue: [],
        ChatRoom.featuresBugs.rawValue: [],
        ChatRoom.swapMeet.rawValue: [],
        ChatRoom.testing.rawValue: [],
    ]

    static let maxMessageLength = 255
    static let minTextSize: Double = 10
    static let maxTextSize: Double = 24
    static let textSizeStep: Double = 2

    init() {
        if let room = ChatRoom(rawValue: currentRoomKey) {
            currentRoom = room
        }
        reloadBlockedUids()
        loadMessageCache()
        applyFilter()
    }

    // MARK: - Connection Lifecycle

    /// Spin up Firebase, authenticate, attach room listener. Call from onAppear.
    func connect() {
        guard manager == nil else { return }

        serverStatus = .connecting
        let mgr = FirebaseChatManager()
        self.manager = mgr

        mgr.onConnectionStatusChanged = { [weak self] status in
            DispatchQueue.main.async { self?.serverStatus = status }
        }

        mgr.onAdminStatusChanged = { [weak self] admin in
            DispatchQueue.main.async { self?.isAdmin = admin }
        }

        mgr.onMessageReceived = { [weak self] room, message in
            DispatchQueue.main.async { self?.handleMessageReceived(room: room, message: message) }
        }

        mgr.onMessageChanged = { [weak self] room, message in
            DispatchQueue.main.async { self?.handleMessageChanged(room: room, message: message) }
        }

        mgr.onMessageRemoved = { [weak self] room, key in
            DispatchQueue.main.async { self?.handleMessageRemoved(room: room, key: key) }
        }

        mgr.onAuthComplete = { [weak self] uid in
            guard let self = self, uid != nil else { return }
            DispatchQueue.main.async {
                self.manager?.attachRoomListener(room: self.currentRoom.rawValue)
            }
        }

        if !username.isEmpty {
            mgr.signIn(username: username, countryCode: countryCode)
        } else {
            mgr.connectReadOnly()
        }
    }

    /// Tear down Firebase completely. Call from onDisappear.
    func disconnect() {
        saveMessageCache()
        manager?.teardown()
        manager = nil
        serverStatus = .disconnected
    }

    // MARK: - Room Switching

    func switchRoom(to room: ChatRoom) {
        guard room != currentRoom else { return }
        editingMessageKey = nil
        manager?.detachRoomListener(room: currentRoom.rawValue)
        currentRoom = room
        currentRoomKey = room.rawValue
        applyFilter()
        manager?.attachRoomListener(room: room.rawValue)
    }

    // MARK: - Message Handling

    private func handleMessageReceived(room: String, message: ChatMessage) {
        var msgs = roomMessages[room] ?? []
        if !msgs.contains(where: { $0.key == message.key }) {
            msgs.append(message)
            roomMessages[room] = msgs
        }
        if room == currentRoom.rawValue {
            applyFilter()
        }
    }

    private func handleMessageChanged(room: String, message: ChatMessage) {
        guard var msgs = roomMessages[room],
              let index = msgs.firstIndex(where: { $0.key == message.key }) else { return }
        msgs[index] = message
        roomMessages[room] = msgs
        if room == currentRoom.rawValue {
            applyFilter()
        }
    }

    private func handleMessageRemoved(room: String, key: String) {
        guard var msgs = roomMessages[room] else { return }
        msgs.removeAll { $0.key == key }
        roomMessages[room] = msgs
        if room == currentRoom.rawValue {
            applyFilter()
        }
    }

    private func applyFilter() {
        let blocked = cachedBlockedUids
        let allMessages = roomMessages[currentRoom.rawValue] ?? []
        messages = allMessages.filter { msg in
            if isAdmin { return true }
            if blocked.contains(msg.uid) { return false }
            if msg.hidden { return false }
            return true
        }
    }

    // MARK: - Send / Edit

    /// Returns true if the message was accepted (text can be cleared).
    /// Returns false on sync validation failure (keep text in input).
    @discardableResult
    func sendMessage(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard !username.isEmpty else {
            toastMessage = "Set a username in Settings first"
            return false
        }

        if let editKey = editingMessageKey {
            manager?.editMessage(room: currentRoom.rawValue, messageKey: editKey, newText: trimmed) { [weak self] success in
                DispatchQueue.main.async {
                    if success { self?.editingMessageKey = nil }
                }
            }
            return true
        } else {
            // Sync rate limit check — keeps text in input if too fast
            let now = Date()
            if now.timeIntervalSince(lastSendTime) < 2.0 {
                toastMessage = "Please wait a moment before sending again"
                return false
            }
            lastSendTime = now

            manager?.sendMessage(room: currentRoom.rawValue, username: username, countryCode: countryCode, message: trimmed) { [weak self] success, error in
                DispatchQueue.main.async {
                    if let error = error { self?.toastMessage = error }
                }
            }
            return true
        }
    }

    func startEditing(_ message: ChatMessage) -> String {
        editingMessageKey = message.key
        return message.message
    }

    func cancelEditing() {
        editingMessageKey = nil
    }

    // MARK: - Actions

    func reportMessage(_ message: ChatMessage, reason: String) {
        guard let uid = manager?.currentUid else { return }
        manager?.reportMessage(room: currentRoom.rawValue, messageKey: message.key, reporterUid: uid, reason: reason) { [weak self] success in
            DispatchQueue.main.async {
                self?.toastMessage = success ? "Message reported" : "Already reported"
            }
        }
    }

    func adminDeleteMessage(_ message: ChatMessage) {
        manager?.adminDeleteMessage(room: currentRoom.rawValue, messageKey: message.key)
    }

    func adminDeleteFromDb(_ message: ChatMessage) {
        manager?.adminDeleteFromDb(room: currentRoom.rawValue, messageKey: message.key)
    }

    func dismissReports(_ message: ChatMessage) {
        manager?.dismissReports(room: currentRoom.rawValue, messageKey: message.key)
    }

    // MARK: - Current UID

    var currentUid: String? { manager?.currentUid }

    // MARK: - Blocked Users

    var blockedUids: Set<String> { cachedBlockedUids }

    private func reloadBlockedUids() {
        guard let data = blockedUidsJson.data(using: .utf8),
              let uids = try? JSONDecoder().decode([String].self, from: data) else {
            cachedBlockedUids = []
            return
        }
        cachedBlockedUids = Set(uids)
    }

    func blockUser(uid: String) {
        cachedBlockedUids.insert(uid)
        saveBlockedUids()
        applyFilter()
        toastMessage = "User blocked"
    }

    func unblockUser(uid: String) {
        cachedBlockedUids.remove(uid)
        saveBlockedUids()
        applyFilter()
    }

    private func saveBlockedUids() {
        if let data = try? JSONEncoder().encode(Array(cachedBlockedUids)),
           let json = String(data: data, encoding: .utf8) {
            blockedUidsJson = json
        }
    }

    // MARK: - Refresh After Settings

    /// Call after dismissing Settings sheet to pick up blocked user changes.
    func refreshAfterSettings() {
        reloadBlockedUids()
        applyFilter()
    }

    // MARK: - Text Size

    func increaseTextSize() {
        textSize = min(textSize + ChatViewModel.textSizeStep, ChatViewModel.maxTextSize)
    }

    func decreaseTextSize() {
        textSize = max(textSize - ChatViewModel.textSizeStep, ChatViewModel.minTextSize)
    }

    // MARK: - Message Cache

    private let cacheKey = "chat_saved_messages"

    func saveMessageCache() {
        var cache: [String: [[String: Any]]] = [:]
        for (room, msgs) in roomMessages {
            cache[room] = msgs.map { msg in
                var dict: [String: Any] = [
                    "k": msg.key,
                    "i": msg.uid,
                    "u": msg.username,
                    "c": msg.countryCode,
                    "m": msg.message,
                    "t": msg.timestamp
                ]
                if msg.hidden { dict["h"] = true }
                return dict
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: cache) {
            UserDefaults.standard.set(data, forKey: cacheKey)
        }
    }

    private func loadMessageCache() {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let cache = try? JSONSerialization.jsonObject(with: data) as? [String: [[String: Any]]] else {
            return
        }
        for (room, msgDicts) in cache {
            roomMessages[room] = msgDicts.compactMap { dict in
                guard let key = dict["k"] as? String,
                      let uid = dict["i"] as? String,
                      let username = dict["u"] as? String,
                      let countryCode = dict["c"] as? String,
                      let message = dict["m"] as? String,
                      let timestamp = dict["t"] as? Int64 else { return nil }
                let hidden = dict["h"] as? Bool ?? false
                return ChatMessage(key: key, uid: uid, username: username, countryCode: countryCode, message: message, timestamp: timestamp, hidden: hidden)
            }
        }
    }

    func clearMessageCache() {
        roomMessages = [
            ChatRoom.bbsChat.rawValue: [],
            ChatRoom.featuresBugs.rawValue: [],
            ChatRoom.swapMeet.rawValue: [],
            ChatRoom.testing.rawValue: [],
        ]
        UserDefaults.standard.removeObject(forKey: cacheKey)
        applyFilter()
    }
}
