import Foundation

/**
 * SSH Connection Manager - Stub Implementation
 *
 * This file provides the SSH connection infrastructure for TERMinator.
 * Currently implemented as a stub that returns "not supported" status.
 *
 * To enable full SSH support, you need to:
 * 1. Add an SSH library (e.g., SwiftSH via CocoaPods, or implement using SwiftNIO SSH)
 * 2. Uncomment the SwiftSH import and implementation below
 * 3. Add the appropriate package/pod dependency
 *
 * The SwiftSH SPM package currently has broken dependencies. Options:
 * - Install CocoaPods and use: pod 'SwiftSH'
 * - Use Carthage: github "Frugghi/SwiftSH"
 * - Implement using apple/swift-nio-ssh (requires more code)
 * - Wait for SwiftSH dependency fix
 */

/// SSH connection manager - stub implementation
/// Provides the C bridge interface but returns "not connected" until
/// a proper SSH library is integrated.
@objc class SSHConnection: NSObject {

    static let shared = SSHConnection()

    private var isConnectedFlag = false

    // Receive buffer - thread-safe access (for future use)
    private var receiveBuffer = Data()
    private let bufferLock = NSLock()

    // Connection credentials (stored for future implementation)
    private var currentHost: String = ""
    private var currentPort: UInt16 = 22
    private var currentUsername: String = ""
    private var currentPassword: String = ""

    // Terminal settings
    private var terminalWidth: UInt = 80
    private var terminalHeight: UInt = 25

    private override init() {
        super.init()
    }

    // MARK: - Connection Management (Stub)

    /// Connect to an SSH server - currently returns false (not supported)
    func connect(host: String, port: Int, username: String, password: String) -> Bool {
        print("[SSHConnection] SSH support is not yet enabled. To enable:")
        print("  1. Install CocoaPods: sudo gem install cocoapods")
        print("  2. Add 'pod SwiftSH' to Podfile")
        print("  3. Run 'pod install'")
        print("  4. Uncomment SSH implementation in SSHConnection.swift")

        currentHost = host
        currentPort = UInt16(port)
        currentUsername = username
        currentPassword = password

        // Return false - SSH not supported yet
        return false
    }

    /// Connect with public key - currently returns false
    func connectWithKey(host: String, port: Int, username: String, privateKey: String, publicKey: String?, passphrase: String?) -> Bool {
        print("[SSHConnection] SSH key authentication not yet supported")
        return false
    }

    /// Disconnect from the server
    func disconnect() {
        isConnectedFlag = false
        bufferLock.lock()
        receiveBuffer.removeAll()
        bufferLock.unlock()
    }

    /// Check if connected - always false until SSH is implemented
    func isConnected() -> Bool {
        return isConnectedFlag
    }

    // MARK: - Data Transfer (Stub)

    /// Send data - returns -1 (not connected)
    func send(data: Data) -> Int {
        return -1
    }

    /// Send a single byte - returns -1
    func sendByte(_ byte: UInt8) -> Int {
        return -1
    }

    /// Send a string - returns -1
    func sendString(_ string: String) -> Int {
        return -1
    }

    /// Check how many bytes are waiting - returns 0
    func dataWaiting() -> Int {
        return 0
    }

    /// Read data from the receive buffer - returns empty
    func receive(maxBytes: Int) -> Data {
        return Data()
    }

    // MARK: - Terminal Settings

    /// Set terminal dimensions (saved for when SSH is implemented)
    func setTerminalSize(width: Int, height: Int) {
        terminalWidth = UInt(width)
        terminalHeight = UInt(height)
    }
}

// MARK: - C Bridge Functions

/// These functions are called from the native C code

@_cdecl("swift_ssh_connect")
func swift_ssh_connect(_ host: UnsafePointer<CChar>, _ port: Int32,
                       _ username: UnsafePointer<CChar>, _ password: UnsafePointer<CChar>) -> Bool {
    let hostString = String(cString: host)
    let usernameString = String(cString: username)
    let passwordString = String(cString: password)
    return SSHConnection.shared.connect(host: hostString, port: Int(port),
                                        username: usernameString, password: passwordString)
}

@_cdecl("swift_ssh_connect_with_key")
func swift_ssh_connect_with_key(_ host: UnsafePointer<CChar>, _ port: Int32,
                                 _ username: UnsafePointer<CChar>,
                                 _ privateKey: UnsafePointer<CChar>,
                                 _ publicKey: UnsafePointer<CChar>?,
                                 _ passphrase: UnsafePointer<CChar>?) -> Bool {
    let hostString = String(cString: host)
    let usernameString = String(cString: username)
    let privateKeyString = String(cString: privateKey)
    let publicKeyString = publicKey.map { String(cString: $0) }
    let passphraseString = passphrase.map { String(cString: $0) }
    return SSHConnection.shared.connectWithKey(host: hostString, port: Int(port),
                                               username: usernameString,
                                               privateKey: privateKeyString,
                                               publicKey: publicKeyString,
                                               passphrase: passphraseString)
}

@_cdecl("swift_ssh_disconnect")
func swift_ssh_disconnect() {
    SSHConnection.shared.disconnect()
}

@_cdecl("swift_ssh_is_connected")
func swift_ssh_is_connected() -> Bool {
    return SSHConnection.shared.isConnected()
}

@_cdecl("swift_ssh_send")
func swift_ssh_send(_ data: UnsafePointer<UInt8>, _ length: Int32) -> Int32 {
    let dataObj = Data(bytes: data, count: Int(length))
    return Int32(SSHConnection.shared.send(data: dataObj))
}

@_cdecl("swift_ssh_send_byte")
func swift_ssh_send_byte(_ byte: UInt8) -> Int32 {
    return Int32(SSHConnection.shared.sendByte(byte))
}

@_cdecl("swift_ssh_data_waiting")
func swift_ssh_data_waiting() -> Int32 {
    return Int32(SSHConnection.shared.dataWaiting())
}

@_cdecl("swift_ssh_receive")
func swift_ssh_receive(_ buffer: UnsafeMutablePointer<UInt8>, _ maxLength: Int32) -> Int32 {
    let data = SSHConnection.shared.receive(maxBytes: Int(maxLength))
    if data.isEmpty {
        return 0
    }
    data.copyBytes(to: buffer, count: data.count)
    return Int32(data.count)
}

@_cdecl("swift_ssh_set_terminal_size")
func swift_ssh_set_terminal_size(_ width: Int32, _ height: Int32) {
    SSHConnection.shared.setTerminalSize(width: Int(width), height: Int(height))
}
