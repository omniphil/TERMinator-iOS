import Foundation
import FirebaseCore
import FirebaseAuth
import FirebaseDatabase

/// Manages all Firebase Realtime Database and Auth interactions for the chat feature.
/// NOT a singleton — created by ChatViewModel on chat entry, torn down on exit.
/// For one-shot operations (username claim from Settings), use the static helpers.
class FirebaseChatManager {

    // MARK: - Callbacks (set by ChatViewModel)

    var onConnectionStatusChanged: ((ServerStatus) -> Void)?
    var onAdminStatusChanged: ((Bool) -> Void)?
    var onAuthComplete: ((String?) -> Void)?
    var onMessageReceived: ((String, ChatMessage) -> Void)?
    var onMessageChanged: ((String, ChatMessage) -> Void)?
    var onMessageRemoved: ((String, String) -> Void)?

    // MARK: - State

    private(set) var currentUid: String?
    private(set) var isConnected = false

    // MARK: - Firebase References

    private var database: Database { Database.database() }
    private var roomsRef: DatabaseReference { database.reference(withPath: "rooms") }
    private var usersRef: DatabaseReference { database.reference(withPath: "users") }
    private var usernamesRef: DatabaseReference { database.reference(withPath: "usernames") }
    private var adminsRef: DatabaseReference { database.reference(withPath: "admins") }
    private var reportsRef: DatabaseReference { database.reference(withPath: "reports") }
    private var connectedRef: DatabaseReference { database.reference(withPath: ".info/connected") }

    // MARK: - Listener Handles

    private var connectionHandle: DatabaseHandle?
    private var adminHandle: DatabaseHandle?
    private var roomHandles: [String: (added: DatabaseHandle, changed: DatabaseHandle, removed: DatabaseHandle)] = [:]
    private var lastSendTime: Date = .distantPast

    // MARK: - Firebase Configuration

    private static var firebaseConfigured = false

    /// Configure Firebase on first use. Safe to call multiple times.
    static func ensureFirebase() -> Bool {
        if firebaseConfigured { return true }
        guard Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil else { return false }
        if FirebaseApp.app() == nil {
            FirebaseApp.configure()
        }
        firebaseConfigured = true
        return true
    }

    // MARK: - Connection Lifecycle

    /// Sign in anonymously and update user profile.
    func signIn(username: String, countryCode: String) {
        guard FirebaseChatManager.ensureFirebase() else {
            onConnectionStatusChanged?(.disconnected)
            return
        }
        database.goOnline()
        connectAnonymously { [weak self] uid in
            guard let self = self, let uid = uid else { return }
            self.updateUserProfile(uid: uid, username: username, countryCode: countryCode)
            self.onAuthComplete?(uid)
        }
    }

    /// Connect read-only (no profile update).
    func connectReadOnly() {
        guard FirebaseChatManager.ensureFirebase() else {
            onConnectionStatusChanged?(.disconnected)
            return
        }
        database.goOnline()
        connectAnonymously { [weak self] uid in
            self?.onAuthComplete?(uid)
        }
    }

    private func connectAnonymously(completion: @escaping (String?) -> Void) {
        if let user = Auth.auth().currentUser {
            self.currentUid = user.uid
            self.checkAdminStatus(uid: user.uid)
            self.attachConnectionListener()
            completion(user.uid)
            return
        }

        Auth.auth().signInAnonymously { [weak self] result, error in
            guard let self = self else { return }
            if let _ = error {
                self.onConnectionStatusChanged?(.disconnected)
                completion(nil)
                return
            }
            guard let uid = result?.user.uid else {
                self.onConnectionStatusChanged?(.disconnected)
                completion(nil)
                return
            }
            self.currentUid = uid
            self.checkAdminStatus(uid: uid)
            self.attachConnectionListener()
            completion(uid)
        }
    }

    private func updateUserProfile(uid: String, username: String, countryCode: String) {
        let updates: [String: Any] = [
            "username": username,
            "countryCode": countryCode,
            "lastSeen": ServerValue.timestamp()
        ]
        usersRef.child(uid).updateChildValues(updates)
    }

    // MARK: - Admin Status

    private func checkAdminStatus(uid: String) {
        adminHandle = adminsRef.child(uid).observe(.value) { [weak self] snapshot in
            guard let self = self else { return }
            if let value = snapshot.value {
                if let boolVal = value as? Bool {
                    self.onAdminStatusChanged?(boolVal)
                } else if let strVal = value as? String {
                    self.onAdminStatusChanged?(strVal == "true")
                } else {
                    self.onAdminStatusChanged?(false)
                }
            } else {
                self.onAdminStatusChanged?(false)
            }
        }
    }

    // MARK: - Connection Monitoring

    private func attachConnectionListener() {
        connectionHandle = connectedRef.observe(.value) { [weak self] snapshot in
            guard let self = self else { return }
            let connected = snapshot.value as? Bool == true
            self.isConnected = connected
            self.onConnectionStatusChanged?(connected ? .connected : .disconnected)
        }
    }

    // MARK: - Room Listeners

    func attachRoomListener(room: String) {
        detachRoomListener(room: room)

        let messagesRef = roomsRef.child(room).child("messages")
        let query = messagesRef.queryOrderedByKey().queryLimited(toLast: 200)

        let addedHandle = query.observe(.childAdded) { [weak self] snapshot in
            guard let self = self, let msg = self.parseMessage(snapshot) else { return }
            self.onMessageReceived?(room, msg)
        }

        let changedHandle = query.observe(.childChanged) { [weak self] snapshot in
            guard let self = self, let msg = self.parseMessage(snapshot) else { return }
            self.onMessageChanged?(room, msg)
        }

        let removedHandle = query.observe(.childRemoved) { [weak self] snapshot in
            guard let self = self else { return }
            self.onMessageRemoved?(room, snapshot.key)
        }

        roomHandles[room] = (added: addedHandle, changed: changedHandle, removed: removedHandle)
    }

    func detachRoomListener(room: String) {
        guard let handles = roomHandles[room] else { return }
        let messagesRef = roomsRef.child(room).child("messages")
        let query = messagesRef.queryOrderedByKey().queryLimited(toLast: 200)
        query.removeObserver(withHandle: handles.added)
        query.removeObserver(withHandle: handles.changed)
        query.removeObserver(withHandle: handles.removed)
        roomHandles.removeValue(forKey: room)
    }

    private func parseMessage(_ snapshot: DataSnapshot) -> ChatMessage? {
        guard let dict = snapshot.value as? [String: Any] else { return nil }
        return ChatMessage(
            key: snapshot.key,
            uid: dict["uid"] as? String ?? "",
            username: dict["username"] as? String ?? "",
            countryCode: dict["countryCode"] as? String ?? "",
            message: dict["message"] as? String ?? "",
            timestamp: dict["timestamp"] as? Int64 ?? 0,
            hidden: dict["hidden"] as? Bool ?? false
        )
    }

    // MARK: - Send Message

    func sendMessage(room: String, username: String, countryCode: String, message: String, completion: ((Bool, String?) -> Void)? = nil) {
        guard let uid = currentUid else {
            completion?(false, "Not authenticated")
            return
        }

        let now = Date()
        if now.timeIntervalSince(lastSendTime) < 2.0 {
            completion?(false, "Please wait a moment before sending again")
            return
        }
        lastSendTime = now

        let msgRef = roomsRef.child(room).child("messages").childByAutoId()
        let msgData: [String: Any] = [
            "uid": uid,
            "username": username,
            "countryCode": countryCode,
            "message": message,
            "timestamp": ServerValue.timestamp()
        ]

        let updates: [String: Any] = [
            "rooms/\(room)/messages/\(msgRef.key!)": msgData,
            "users/\(uid)/lastMessageTime": ServerValue.timestamp()
        ]

        database.reference().updateChildValues(updates) { error, _ in
            if let error = error {
                completion?(false, error.localizedDescription)
            } else {
                completion?(true, nil)
            }
        }
    }

    // MARK: - Edit Message

    func editMessage(room: String, messageKey: String, newText: String, completion: ((Bool) -> Void)? = nil) {
        roomsRef.child(room).child("messages").child(messageKey).child("message").setValue(newText) { error, _ in
            completion?(error == nil)
        }
    }

    // MARK: - Report Message

    func reportMessage(room: String, messageKey: String, reporterUid: String, reason: String, completion: ((Bool) -> Void)? = nil) {
        let reportRef = reportsRef.child(messageKey)

        reportRef.child("reporters").child(reporterUid).observeSingleEvent(of: .value) { [weak self] snapshot in
            guard let self = self else { return }
            if snapshot.exists() {
                completion?(false)
                return
            }

            let reporterData: [String: Any] = [
                "reason": reason,
                "timestamp": ServerValue.timestamp()
            ]
            reportRef.child("reporters").child(reporterUid).setValue(reporterData)

            reportRef.child("reportCount").runTransactionBlock({ currentData in
                let count = currentData.value as? Int ?? 0
                currentData.value = count + 1
                return TransactionResult.success(withValue: currentData)
            }) { error, committed, snapshot in
                if committed, let count = snapshot?.value as? Int, count >= 3 {
                    self.roomsRef.child(room).child("messages").child(messageKey).child("hidden").setValue(true)
                }
                completion?(committed)
            }
        }
    }

    // MARK: - Admin Actions

    func adminDeleteMessage(room: String, messageKey: String) {
        roomsRef.child(room).child("messages").child(messageKey).child("message").setValue("[Deleted by admin]")
    }

    func adminDeleteFromDb(room: String, messageKey: String) {
        roomsRef.child(room).child("messages").child(messageKey).removeValue()
        reportsRef.child(messageKey).removeValue()
    }

    func dismissReports(room: String, messageKey: String) {
        reportsRef.child(messageKey).removeValue()
        roomsRef.child(room).child("messages").child(messageKey).child("hidden").setValue(false)
    }

    // MARK: - Username Claiming (instance method)

    func claimUsername(_ username: String, completion: @escaping (ClaimResult) -> Void) {
        guard let uid = currentUid else {
            completion(.error)
            return
        }
        FirebaseChatManager.performClaim(username: username, uid: uid, usernamesRef: usernamesRef, usersRef: usersRef, completion: completion)
    }

    // MARK: - Full Teardown

    /// Detach all listeners, go offline. After this, the instance should be discarded.
    func teardown() {
        let rooms = Array(roomHandles.keys)
        for room in rooms {
            detachRoomListener(room: room)
        }
        if let handle = connectionHandle {
            connectedRef.removeObserver(withHandle: handle)
            connectionHandle = nil
        }
        if let handle = adminHandle {
            adminsRef.removeObserver(withHandle: handle)
            adminHandle = nil
        }
        onConnectionStatusChanged = nil
        onAdminStatusChanged = nil
        onAuthComplete = nil
        onMessageReceived = nil
        onMessageChanged = nil
        onMessageRemoved = nil
        isConnected = false
        if FirebaseChatManager.firebaseConfigured {
            Database.database().goOffline()
        }
    }

    // MARK: - One-Shot Username Claim (for Settings, no persistent connection)

    /// Connect to Firebase, claim the username, then fully disconnect.
    /// Use this from Settings — does NOT leave Firebase running.
    static func claimUsernameOneShot(_ username: String, completion: @escaping (ClaimResult) -> Void) {
        let lowercased = username.lowercased()
        if reservedUsernames.contains(lowercased) {
            completion(.reserved)
            return
        }

        guard ensureFirebase() else {
            completion(.error)
            return
        }

        let db = Database.database()
        db.goOnline()

        let doClaimAndDisconnect = { (uid: String) in
            let usernamesRef = db.reference(withPath: "usernames")
            let usersRef = db.reference(withPath: "users")
            performClaim(username: username, uid: uid, usernamesRef: usernamesRef, usersRef: usersRef) { result in
                // Fully disconnect after claim completes
                db.goOffline()
                completion(result)
            }
        }

        if let user = Auth.auth().currentUser {
            doClaimAndDisconnect(user.uid)
        } else {
            Auth.auth().signInAnonymously { result, error in
                if let uid = result?.user.uid {
                    doClaimAndDisconnect(uid)
                } else {
                    db.goOffline()
                    completion(.error)
                }
            }
        }
    }

    // MARK: - Shared Claim Logic

    private static func performClaim(username: String, uid: String, usernamesRef: DatabaseReference, usersRef: DatabaseReference, completion: @escaping (ClaimResult) -> Void) {
        let lowercased = username.lowercased()
        let usernameRef = usernamesRef.child(lowercased)

        usernameRef.runTransactionBlock({ currentData in
            if let existing = currentData.value as? [String: Any] {
                if let existingUid = existing["uid"] as? String, existingUid == uid {
                    return TransactionResult.success(withValue: currentData)
                }
                return TransactionResult.abort()
            }
            currentData.value = [
                "uid": uid,
                "claimedAt": ServerValue.timestamp()
            ] as [String: Any]
            return TransactionResult.success(withValue: currentData)
        }) { error, committed, snapshot in
            if let _ = error {
                completion(.error)
                return
            }
            if !committed {
                completion(.taken)
                return
            }

            if let data = snapshot?.value as? [String: Any],
               let ownerUid = data["uid"] as? String,
               ownerUid == uid {
                // Release old username if any
                releaseOldUsername(newUsername: lowercased, uid: uid, usernamesRef: usernamesRef)
                usersRef.child(uid).child("username").setValue(username)
                completion(.success)
            } else {
                completion(.taken)
            }
        }
    }

    private static func releaseOldUsername(newUsername: String, uid: String, usernamesRef: DatabaseReference) {
        usernamesRef.observeSingleEvent(of: .value) { snapshot in
            guard let children = snapshot.children.allObjects as? [DataSnapshot] else { return }
            for child in children {
                if child.key == newUsername { continue }
                if let data = child.value as? [String: Any],
                   let ownerUid = data["uid"] as? String,
                   ownerUid == uid {
                    usernamesRef.child(child.key).removeValue()
                }
            }
        }
    }
}
