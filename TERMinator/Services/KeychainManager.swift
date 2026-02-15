import Foundation
import Security

/// Manages secure storage of credentials using iOS Keychain.
/// Uses kSecAttrAccessibleWhenUnlocked for security.
class KeychainManager {

    static let shared = KeychainManager()

    private let service = "com.terminator.credentials"

    private init() {}

    // MARK: - Password Management

    /// Save a password for a specific entry ID.
    /// - Parameters:
    ///   - password: The password to store
    ///   - entryId: The unique identifier for the BBS entry
    /// - Returns: True if save was successful
    @discardableResult
    func savePassword(_ password: String, for entryId: UUID) -> Bool {
        guard let passwordData = password.data(using: .utf8) else {
            return false
        }

        // Delete any existing password first
        deletePassword(for: entryId)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: entryId.uuidString,
            kSecValueData as String: passwordData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// Retrieve a password for a specific entry ID.
    /// - Parameter entryId: The unique identifier for the BBS entry
    /// - Returns: The stored password, or nil if not found
    func getPassword(for entryId: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: entryId.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let passwordData = result as? Data,
              let password = String(data: passwordData, encoding: .utf8) else {
            return nil
        }

        return password
    }

    /// Delete a password for a specific entry ID.
    /// - Parameter entryId: The unique identifier for the BBS entry
    /// - Returns: True if deletion was successful or item didn't exist
    @discardableResult
    func deletePassword(for entryId: UUID) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: entryId.uuidString
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Update an existing password for a specific entry ID.
    /// - Parameters:
    ///   - password: The new password
    ///   - entryId: The unique identifier for the BBS entry
    /// - Returns: True if update was successful
    @discardableResult
    func updatePassword(_ password: String, for entryId: UUID) -> Bool {
        guard let passwordData = password.data(using: .utf8) else {
            return false
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: entryId.uuidString
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: passwordData
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        // If item doesn't exist, create it
        if status == errSecItemNotFound {
            return savePassword(password, for: entryId)
        }

        return status == errSecSuccess
    }

    /// Check if a password exists for a specific entry ID.
    /// - Parameter entryId: The unique identifier for the BBS entry
    /// - Returns: True if a password is stored
    func hasPassword(for entryId: UUID) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: entryId.uuidString,
            kSecReturnData as String: false
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// Delete all stored passwords (for app reset/cleanup).
    /// - Returns: True if deletion was successful
    @discardableResult
    func deleteAllPasswords() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - Migration Support

    /// Migrate a plaintext password to secure Keychain storage.
    /// - Parameters:
    ///   - plaintextPassword: The plaintext password to migrate
    ///   - entryId: The unique identifier for the BBS entry
    /// - Returns: True if migration was successful
    @discardableResult
    func migratePassword(_ plaintextPassword: String, for entryId: UUID) -> Bool {
        // Only migrate non-empty passwords
        guard !plaintextPassword.isEmpty else {
            return true
        }

        return savePassword(plaintextPassword, for: entryId)
    }
}
