import Foundation
import Network

/// Callback type for connection events
typealias ConnectionCallback = @convention(c) (UnsafePointer<UInt8>?, Int32) -> Void

/// Telnet protocol constants
private enum TelnetCommand: UInt8 {
    case IAC = 255   // Interpret As Command
    case DONT = 254
    case DO = 253
    case WONT = 252
    case WILL = 251
    case SB = 250    // Subnegotiation Begin
    case SE = 240    // Subnegotiation End

    // Options
    static let BINARY: UInt8 = 0
    static let ECHO: UInt8 = 1
    static let SUPPRESS_GO_AHEAD: UInt8 = 3
    static let TERMINAL_TYPE: UInt8 = 24
    static let NAWS: UInt8 = 31  // Negotiate About Window Size
}

/// TCP connection manager using Apple's Network framework.
/// Provides real networking for Telnet connections with protocol negotiation.
@objc class TelnetConnection: NSObject, @unchecked Sendable {

    static let shared = TelnetConnection()

    private var connection: NWConnection?
    private var isConnectedFlag = false
    private let queue = DispatchQueue(label: "com.terminator.telnet", qos: .userInteractive)

    // Receive buffer - thread-safe access
    private var receiveBuffer = Data()
    private let bufferLock = NSLock()

    // Lock for connection state (isConnectedFlag, telnet negotiation state, terminal dimensions)
    private let stateLock = NSLock()

    // Telnet negotiation state (protected by stateLock)
    private var telnetState: TelnetParseState = .normal
    private var telnetCommand: UInt8 = 0
    private var subnegBuffer = Data()
    private var subnegOption: UInt8 = 0
    private var terminalTypeNegotiationComplete = false
    private var pendingData = Data()

    /// When true, bypass telnet IAC parsing and pass raw bytes through.
    /// Used during ZMODEM file transfers to prevent data corruption.
    private var rawMode = false

    private enum TelnetParseState {
        case normal
        case gotIAC
        case gotCommand
        case inSubnegotiation
        case subnegGotIAC
    }

    // Terminal settings (protected by stateLock)
    private var terminalWidth: Int = 80
    private var terminalHeight: Int = 25

    private override init() {
        super.init()
    }

    /// Create TCP parameters with keepalive configured.
    /// Aggressive keepalive (10s idle, 5s interval, 3 probes) helps the connection
    /// survive short app backgrounding and prevents the remote BBS from dropping
    /// an idle connection.
    private func makeTCPParameters() -> NWParameters {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 10      // seconds before first keepalive probe
        tcpOptions.keepaliveInterval = 5   // seconds between probes
        tcpOptions.keepaliveCount = 3      // probes before declaring dead
        tcpOptions.connectionTimeout = 10  // seconds for initial connection

        let params = NWParameters(tls: nil, tcp: tcpOptions)
        params.allowLocalEndpointReuse = true
        return params
    }

    /// Connect to a host and port (async version)
    func connectAsync(host: String, port: Int) async -> Bool {
        guard port >= 1 && port <= 65535 else { return false }

        // Disconnect any existing connection
        disconnect()

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(integerLiteral: UInt16(clamping: port))
        )

        let parameters = makeTCPParameters()
        connection = NWConnection(to: endpoint, using: parameters)

        return await withCheckedContinuation { continuation in
            var hasResumed = false
            let resumeOnce: (Bool) -> Void = { success in
                guard !hasResumed else { return }
                hasResumed = true
                continuation.resume(returning: success)
            }

            connection?.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.stateLock.lock()
                    self?.isConnectedFlag = true
                    self?.stateLock.unlock()
                    self?.startReceiving()
                    resumeOnce(true)
                case .failed(let error):
                    print("Connection failed: \(error)")
                    self?.stateLock.lock()
                    self?.isConnectedFlag = false
                    self?.stateLock.unlock()
                    resumeOnce(false)
                case .cancelled:
                    self?.stateLock.lock()
                    self?.isConnectedFlag = false
                    self?.stateLock.unlock()
                    resumeOnce(false)
                case .waiting(let error):
                    print("Connection waiting: \(error)")
                default:
                    break
                }
            }

            connection?.start(queue: queue)

            // Timeout after 5 seconds
            DispatchQueue.global().asyncAfter(deadline: .now() + 5.0) { [weak self] in
                guard !hasResumed else { return }
                print("Connection timeout")
                self?.disconnect()
                resumeOnce(false)
            }
        }
    }

    /// Connect to a host and port (synchronous - for C bridge)
    func connect(host: String, port: Int) -> Bool {
        guard port >= 1 && port <= 65535 else { return false }

        // Disconnect any existing connection
        disconnect()

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(integerLiteral: UInt16(clamping: port))
        )

        let parameters = makeTCPParameters()
        connection = NWConnection(to: endpoint, using: parameters)

        let semaphore = DispatchSemaphore(value: 0)
        var connected = false

        connection?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                connected = true
                self?.stateLock.lock()
                self?.isConnectedFlag = true
                self?.stateLock.unlock()
                self?.startReceiving()
                semaphore.signal()
            case .failed(let error):
                print("Connection failed: \(error)")
                self?.stateLock.lock()
                self?.isConnectedFlag = false
                self?.stateLock.unlock()
                semaphore.signal()
            case .cancelled:
                self?.stateLock.lock()
                self?.isConnectedFlag = false
                self?.stateLock.unlock()
                semaphore.signal()
            case .waiting(let error):
                print("Connection waiting: \(error)")
            default:
                break
            }
        }

        connection?.start(queue: queue)

        // Wait for connection with 5 second timeout
        let result = semaphore.wait(timeout: .now() + 5.0)
        if result == .timedOut {
            print("Connection timeout")
            disconnect()
            return false
        }

        return connected
    }

    /// Disconnect from the server
    func disconnect() {
        connection?.cancel()
        connection = nil

        stateLock.lock()
        isConnectedFlag = false
        // Clear all telnet state for clean reconnection
        pendingData.removeAll()
        subnegBuffer.removeAll()
        telnetState = .normal
        telnetCommand = 0
        subnegOption = 0
        terminalTypeNegotiationComplete = false
        stateLock.unlock()

        bufferLock.lock()
        receiveBuffer.removeAll()
        bufferLock.unlock()
    }

    /// Check if connected
    func isConnected() -> Bool {
        stateLock.lock()
        let connected = isConnectedFlag
        stateLock.unlock()
        return connected
    }

    /// Send data to the server (non-blocking for internal use)
    private func sendAsync(data: Data) {
        guard let connection = connection, isConnectedFlag else { return }

        connection.send(content: data, completion: .contentProcessed { error in
            if let error = error {
                print("Send error: \(error)")
            }
        })
    }

    /// Send data to the server (blocking - for external callers)
    func send(data: Data) -> Int {
        guard let connection = connection, isConnectedFlag else { return -1 }

        let semaphore = DispatchSemaphore(value: 0)
        var bytesSent = 0

        connection.send(content: data, completion: .contentProcessed { error in
            if let error = error {
                print("Send error: \(error)")
                bytesSent = -1
            } else {
                bytesSent = data.count
            }
            semaphore.signal()
        })

        // Wait for send to complete - this is critical for proper telnet negotiation
        let result = semaphore.wait(timeout: .now() + 5.0)
        if result == .timedOut {
            return -1
        }
        return bytesSent
    }

    /// Send a single byte
    func sendByte(_ byte: UInt8) -> Int {
        return send(data: Data([byte]))
    }

    /// Send a string
    func sendString(_ string: String) -> Int {
        guard let data = string.data(using: .utf8) else { return -1 }
        return send(data: data)
    }

    /// Enable or disable raw mode (bypasses telnet IAC parsing).
    /// Used during ZMODEM transfers to prevent data corruption.
    func setRawMode(_ enabled: Bool) {
        // Re-negotiate telnet BINARY mode BEFORE changing rawMode so the
        // server's response is handled by normal telnet IAC parsing.
        // Matches Android's telnet_binary_mode_on/off in conn_telnet.c.
        if enabled {
            sendTelnetCommand(.DO, option: TelnetCommand.BINARY)
            sendTelnetCommand(.WILL, option: TelnetCommand.BINARY)
        } else {
            sendTelnetCommand(.DONT, option: TelnetCommand.BINARY)
            sendTelnetCommand(.WONT, option: TelnetCommand.BINARY)
        }

        bufferLock.lock()
        rawMode = enabled
        if enabled {
            // Reset telnet state machine to prevent dangling IAC state
            // from consuming bytes when we return to normal mode
            telnetState = .normal
        }
        bufferLock.unlock()
    }

    /// Check how many bytes are waiting to be read
    func dataWaiting() -> Int {
        bufferLock.lock()
        let count = receiveBuffer.count
        bufferLock.unlock()
        return count
    }

    /// Read data from the receive buffer
    func receive(maxBytes: Int) -> Data {
        bufferLock.lock()
        defer { bufferLock.unlock() }

        let bytesToRead = min(maxBytes, receiveBuffer.count)
        if bytesToRead == 0 {
            return Data()
        }

        let data = receiveBuffer.prefix(bytesToRead)
        receiveBuffer.removeFirst(bytesToRead)
        return Data(data)
    }

    /// Start receiving data in the background
    private func startReceiving() {
        // Reset telnet state
        telnetState = .normal
        subnegBuffer.removeAll()
        terminalTypeNegotiationComplete = false
        pendingData.removeAll()

        // Send initial telnet negotiation (like SyncTERM's send_initial_state)
        sendInitialState()

        receiveData()
    }

    /// Send initial telnet negotiation options (matches SyncTERM behavior exactly)
    private func sendInitialState() {
        // Send all initial options in a single batch for speed
        var batch = Data()

        // Suppress Go Aheads (both directions)
        batch.append(contentsOf: [TelnetCommand.IAC.rawValue, TelnetCommand.WILL.rawValue, TelnetCommand.SUPPRESS_GO_AHEAD])
        batch.append(contentsOf: [TelnetCommand.IAC.rawValue, TelnetCommand.DO.rawValue, TelnetCommand.SUPPRESS_GO_AHEAD])

        // Enable binary mode (both directions)
        batch.append(contentsOf: [TelnetCommand.IAC.rawValue, TelnetCommand.WILL.rawValue, TelnetCommand.BINARY])
        batch.append(contentsOf: [TelnetCommand.IAC.rawValue, TelnetCommand.DO.rawValue, TelnetCommand.BINARY])

        // Request that the server echoes
        batch.append(contentsOf: [TelnetCommand.IAC.rawValue, TelnetCommand.DO.rawValue, TelnetCommand.ECHO])

        // Proactively announce terminal type support
        batch.append(contentsOf: [TelnetCommand.IAC.rawValue, TelnetCommand.WILL.rawValue, TelnetCommand.TERMINAL_TYPE])

        // Proactively announce NAWS support and send window size
        batch.append(contentsOf: [TelnetCommand.IAC.rawValue, TelnetCommand.WILL.rawValue, TelnetCommand.NAWS])
        // Include window size subnegotiation in initial batch
        batch.append(contentsOf: [
            TelnetCommand.IAC.rawValue,
            TelnetCommand.SB.rawValue,
            TelnetCommand.NAWS,
            UInt8((terminalWidth >> 8) & 0xFF),
            UInt8(terminalWidth & 0xFF),
            UInt8((terminalHeight >> 8) & 0xFF),
            UInt8(terminalHeight & 0xFF),
            TelnetCommand.IAC.rawValue,
            TelnetCommand.SE.rawValue
        ])

        // Send all at once (non-blocking is fine here)
        sendAsync(data: batch)
    }

    private func receiveData() {
        guard let connection = connection else { return }

        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self = self else { return }

            if let data = content, !data.isEmpty {
                // Check rawMode under lock for thread safety
                self.bufferLock.lock()
                let isRaw = self.rawMode
                self.bufferLock.unlock()

                if isRaw {
                    // Raw mode: bypass telnet parsing entirely, append directly
                    self.bufferLock.lock()
                    self.receiveBuffer.append(data)
                    self.bufferLock.unlock()
                } else {
                    // Process data through telnet state machine
                    let terminalData = self.processTelnetData(data)

                    if !terminalData.isEmpty {
                        // If terminal type negotiation isn't complete, buffer the data
                        if !self.terminalTypeNegotiationComplete {
                            self.pendingData.append(terminalData)
                        } else {
                            self.bufferLock.lock()
                            self.receiveBuffer.append(terminalData)
                            self.bufferLock.unlock()
                        }
                    }
                }
            }

            if let error = error {
                print("[TelnetConnection] Receive error: \(error)")
                self.stateLock.lock()
                self.isConnectedFlag = false
                self.stateLock.unlock()
                return
            }

            if isComplete {
                print("[TelnetConnection] Connection closed by server")
                self.stateLock.lock()
                self.isConnectedFlag = false
                self.stateLock.unlock()
                return
            }

            // Continue receiving
            self.receiveData()
        }
    }

    // MARK: - Telnet Protocol Handling

    /// Process incoming data through telnet state machine
    /// Returns only the terminal data (with telnet commands stripped out)
    private func processTelnetData(_ data: Data) -> Data {
        // In raw mode (ZMODEM transfer), pass all bytes through unmodified
        // Caller already checked rawMode under lock, but re-check here for safety
        bufferLock.lock()
        let isRaw = rawMode
        bufferLock.unlock()
        if isRaw {
            return data
        }

        var terminalData = Data()

        for byte in data {
            switch telnetState {
            case .normal:
                if byte == TelnetCommand.IAC.rawValue {
                    telnetState = .gotIAC
                } else {
                    terminalData.append(byte)
                }

            case .gotIAC:
                if byte == TelnetCommand.IAC.rawValue {
                    // Escaped IAC (255 255 = literal 255)
                    terminalData.append(byte)
                    telnetState = .normal
                } else if byte == TelnetCommand.SB.rawValue {
                    // Start subnegotiation
                    telnetState = .inSubnegotiation
                    subnegBuffer.removeAll()
                } else if byte >= TelnetCommand.WILL.rawValue && byte <= TelnetCommand.DONT.rawValue {
                    // DO, DONT, WILL, WONT - need one more byte (the option)
                    telnetCommand = byte
                    telnetState = .gotCommand
                } else {
                    // Other command (like SE alone, or unknown)
                    telnetState = .normal
                }

            case .gotCommand:
                // byte is the option for DO/DONT/WILL/WONT
                handleTelnetNegotiation(command: telnetCommand, option: byte)
                telnetState = .normal

            case .inSubnegotiation:
                if byte == TelnetCommand.IAC.rawValue {
                    telnetState = .subnegGotIAC
                } else {
                    if subnegBuffer.isEmpty {
                        subnegOption = byte  // First byte is the option
                    }
                    subnegBuffer.append(byte)
                }

            case .subnegGotIAC:
                if byte == TelnetCommand.SE.rawValue {
                    // End of subnegotiation
                    handleSubnegotiation()
                    subnegBuffer.removeAll()
                    telnetState = .normal
                } else if byte == TelnetCommand.IAC.rawValue {
                    // Escaped IAC in subnegotiation
                    subnegBuffer.append(byte)
                    telnetState = .inSubnegotiation
                } else {
                    // Unexpected, reset
                    telnetState = .normal
                }
            }
        }

        return terminalData
    }

    /// Handle telnet DO/DONT/WILL/WONT negotiation
    private func handleTelnetNegotiation(command: UInt8, option: UInt8) {
        switch command {
        case TelnetCommand.DO.rawValue:
            // Server wants us to DO something
            switch option {
            case TelnetCommand.TERMINAL_TYPE:
                // We support terminal type
                sendTelnetCommand(.WILL, option: option)
            case TelnetCommand.NAWS:
                // We support window size negotiation
                sendTelnetCommand(.WILL, option: option)
                sendWindowSize()
            case TelnetCommand.SUPPRESS_GO_AHEAD:
                // We support suppress go-ahead
                sendTelnetCommand(.WILL, option: option)
            case TelnetCommand.BINARY:
                // We support binary mode
                sendTelnetCommand(.WILL, option: option)
            case TelnetCommand.ECHO:
                // Server wants us to echo - usually we refuse (server should echo)
                sendTelnetCommand(.WONT, option: option)
            default:
                // We don't support this option
                sendTelnetCommand(.WONT, option: option)
            }

        case TelnetCommand.DONT.rawValue:
            // Server tells us not to do something - comply
            sendTelnetCommand(.WONT, option: option)

        case TelnetCommand.WILL.rawValue:
            // Server will do something
            switch option {
            case TelnetCommand.ECHO:
                // Server will echo - good, we accept
                sendTelnetCommand(.DO, option: option)
            case TelnetCommand.SUPPRESS_GO_AHEAD:
                // Server will suppress go-ahead - good
                sendTelnetCommand(.DO, option: option)
            case TelnetCommand.BINARY:
                // Server will do binary - good
                sendTelnetCommand(.DO, option: option)
            default:
                // Don't care about other options
                sendTelnetCommand(.DONT, option: option)
            }

        case TelnetCommand.WONT.rawValue:
            // Server won't do something - acknowledge
            sendTelnetCommand(.DONT, option: option)

        default:
            break
        }
    }

    /// Handle telnet subnegotiation
    private func handleSubnegotiation() {
        guard subnegBuffer.count >= 2 else { return }

        let option = subnegBuffer[0]
        let subCommand = subnegBuffer[1]

        switch option {
        case TelnetCommand.TERMINAL_TYPE:
            if subCommand == 1 {  // SEND
                sendTerminalType()
            }
        default:
            break
        }
    }

    /// Send a telnet command (WILL/WONT/DO/DONT) - non-blocking
    private func sendTelnetCommand(_ command: TelnetCommand, option: UInt8) {
        let response = Data([TelnetCommand.IAC.rawValue, command.rawValue, option])
        sendAsync(data: response)
    }

    /// Send terminal type subnegotiation response
    private func sendTerminalType() {
        // IAC SB TERMINAL-TYPE IS "ANSI" IAC SE
        let termType = "ANSI"
        var response = Data([
            TelnetCommand.IAC.rawValue,
            TelnetCommand.SB.rawValue,
            TelnetCommand.TERMINAL_TYPE,
            0  // IS = 0
        ])
        response.append(contentsOf: termType.utf8)
        response.append(contentsOf: [TelnetCommand.IAC.rawValue, TelnetCommand.SE.rawValue])

        // Send terminal type
        sendAsync(data: response)

        // Send window size
        sendWindowSize()

        // Mark negotiation complete immediately - no delay needed
        terminalTypeNegotiationComplete = true

        // Flush any pending data
        if !pendingData.isEmpty {
            bufferLock.lock()
            receiveBuffer.append(pendingData)
            bufferLock.unlock()
            pendingData.removeAll()
        }
    }

    /// Send window size (NAWS) - non-blocking
    private func sendWindowSize() {
        stateLock.lock()
        let w = terminalWidth
        let h = terminalHeight
        stateLock.unlock()

        let response = Data([
            TelnetCommand.IAC.rawValue,
            TelnetCommand.SB.rawValue,
            TelnetCommand.NAWS,
            UInt8((w >> 8) & 0xFF),
            UInt8(w & 0xFF),
            UInt8((h >> 8) & 0xFF),
            UInt8(h & 0xFF),
            TelnetCommand.IAC.rawValue,
            TelnetCommand.SE.rawValue
        ])
        sendAsync(data: response)
    }

    /// Set terminal dimensions (called from UI)
    func setTerminalSize(width: Int, height: Int) {
        stateLock.lock()
        terminalWidth = width
        terminalHeight = height
        let connected = isConnectedFlag
        stateLock.unlock()
        if connected {
            sendWindowSize()
        }
    }
}

// MARK: - C Bridge Functions

/// These functions are called from the native C code (syncterm_stubs.c replacement)

@_cdecl("swift_telnet_set_terminal_size")
func swift_telnet_set_terminal_size(_ width: Int32, _ height: Int32) {
    TelnetConnection.shared.setTerminalSize(width: Int(width), height: Int(height))
}

@_cdecl("swift_telnet_connect")
func swift_telnet_connect(_ host: UnsafePointer<CChar>, _ port: Int32) -> Bool {
    let hostString = String(cString: host)
    return TelnetConnection.shared.connect(host: hostString, port: Int(port))
}

@_cdecl("swift_telnet_disconnect")
func swift_telnet_disconnect() {
    TelnetConnection.shared.disconnect()
}

@_cdecl("swift_telnet_is_connected")
func swift_telnet_is_connected() -> Bool {
    return TelnetConnection.shared.isConnected()
}

@_cdecl("swift_telnet_send")
func swift_telnet_send(_ data: UnsafePointer<UInt8>, _ length: Int32) -> Int32 {
    guard length > 0 else { return -1 }
    let dataObj = Data(bytes: data, count: Int(length))
    return Int32(TelnetConnection.shared.send(data: dataObj))
}

@_cdecl("swift_telnet_send_byte")
func swift_telnet_send_byte(_ byte: UInt8) -> Int32 {
    return Int32(TelnetConnection.shared.sendByte(byte))
}

@_cdecl("swift_telnet_data_waiting")
func swift_telnet_data_waiting() -> Int32 {
    return Int32(TelnetConnection.shared.dataWaiting())
}

@_cdecl("swift_telnet_receive")
func swift_telnet_receive(_ buffer: UnsafeMutablePointer<UInt8>, _ maxLength: Int32) -> Int32 {
    let data = TelnetConnection.shared.receive(maxBytes: Int(maxLength))
    if data.isEmpty {
        return 0
    }
    data.copyBytes(to: buffer, count: data.count)
    return Int32(data.count)
}

@_cdecl("swift_telnet_set_raw_mode")
func swift_telnet_set_raw_mode(_ enabled: Int32) {
    TelnetConnection.shared.setRawMode(enabled != 0)
}

// MARK: - TelnetS (Telnet over TLS) Proxy
//
// Uses a Unix socketpair to bridge NWConnection (TLS) with the C-side rlogin threads.
// The C side gets a plain POSIX socket fd; the Swift side proxies data through
// an NWConnection with TLS enabled. This keeps the existing telnet IAC parsing,
// thread model, and ZMODEM support completely unchanged.

class TelnetSProxy {
    static let shared = TelnetSProxy()

    private var connection: NWConnection?
    private var proxyFD: Int32 = -1  // Swift-side fd (proxies to/from NWConnection)
    private var cFD: Int32 = -1      // C-side fd (becomes rlogin_sock)
    private let queue = DispatchQueue(label: "com.terminator.telnets", qos: .userInteractive)
    private var isRunning = false

    private init() {}

    /// Connect to host:port via TLS. Returns the C-side socketpair fd, or -1 on failure.
    func connect(host: String, port: Int) -> Int32 {
        disconnect()

        // Create socketpair
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            return -1
        }
        proxyFD = fds[0]  // Swift side
        cFD = fds[1]      // C side (will become rlogin_sock)

        // Create TLS parameters
        let tlsOptions = NWProtocolTLS.Options()

        // Accept ALL certificates including self-signed (most BBS sysops use self-signed)
        sec_protocol_options_set_verify_block(tlsOptions.securityProtocolOptions, { _, trust, completionHandler in
            completionHandler(true)
        }, queue)

        // Set minimum TLS version to 1.2
        sec_protocol_options_set_min_tls_protocol_version(tlsOptions.securityProtocolOptions, .TLSv12)

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 10
        tcpOptions.keepaliveInterval = 5
        tcpOptions.keepaliveCount = 3
        tcpOptions.connectionTimeout = 15

        let params = NWParameters(tls: tlsOptions, tcp: tcpOptions)

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(integerLiteral: UInt16(clamping: port))
        )

        connection = NWConnection(to: endpoint, using: params)

        let semaphore = DispatchSemaphore(value: 0)
        var connected = false

        connection?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                connected = true
                self?.isRunning = true
                semaphore.signal()
            case .failed(let error):
                print("[TelnetS] Connection failed: \(error)")
                semaphore.signal()
            case .cancelled:
                self?.isRunning = false
                semaphore.signal()
            case .waiting(let error):
                print("[TelnetS] Connection waiting: \(error)")
            default:
                break
            }
        }

        connection?.start(queue: queue)

        let result = semaphore.wait(timeout: .now() + 15.0)
        if result == .timedOut || !connected {
            print("[TelnetS] Connection timeout or failed")
            disconnect()
            return -1
        }

        // Start proxy loops
        startProxyFromNetwork()
        startProxyFromSocket()

        return cFD
    }

    /// Disconnect and clean up
    func disconnect() {
        isRunning = false
        connection?.cancel()
        connection = nil

        if proxyFD >= 0 {
            close(proxyFD)
            proxyFD = -1
        }
        // Don't close cFD here - the C side (rlogin threads) owns it
        cFD = -1
    }

    // MARK: - Proxy Loops

    /// Read from NWConnection (TLS) → write to proxyFD → C side reads from cFD
    private func startProxyFromNetwork() {
        guard let connection = connection else { return }

        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self = self, self.isRunning else { return }

            if let data = content, !data.isEmpty {
                data.withUnsafeBytes { buffer in
                    guard let ptr = buffer.baseAddress else { return }
                    var remaining = data.count
                    var offset = 0
                    while remaining > 0 && self.isRunning {
                        let written = write(self.proxyFD, ptr + offset, remaining)
                        if written <= 0 {
                            self.isRunning = false
                            return
                        }
                        offset += written
                        remaining -= written
                    }
                }
            }

            if isComplete || error != nil {
                self.isRunning = false
                // Close proxy fd to unblock the C side recv()
                if self.proxyFD >= 0 {
                    close(self.proxyFD)
                    self.proxyFD = -1
                }
                return
            }

            // Continue receiving
            self.startProxyFromNetwork()
        }
    }

    /// Read from proxyFD (C side writes to cFD) → send to NWConnection (TLS)
    private func startProxyFromSocket() {
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self = self else { return }

            let bufferSize = 65536
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }

            while self.isRunning && self.proxyFD >= 0 {
                let bytesRead = read(self.proxyFD, buffer, bufferSize)
                if bytesRead <= 0 {
                    // Socket closed or error
                    self.isRunning = false
                    break
                }

                let data = Data(bytes: buffer, count: bytesRead)
                let semaphore = DispatchSemaphore(value: 0)

                self.connection?.send(content: data, completion: .contentProcessed { error in
                    if error != nil {
                        self.isRunning = false
                    }
                    semaphore.signal()
                })

                let result = semaphore.wait(timeout: .now() + 10.0)
                if result == .timedOut {
                    self.isRunning = false
                    break
                }
            }
        }
    }
}

// MARK: - TelnetS C Bridge Functions

@_cdecl("swift_telnets_connect")
func swift_telnets_connect(_ host: UnsafePointer<CChar>, _ port: Int32) -> Int32 {
    let hostString = String(cString: host)
    return TelnetSProxy.shared.connect(host: hostString, port: Int(port))
}

@_cdecl("swift_telnets_disconnect")
func swift_telnets_disconnect() {
    TelnetSProxy.shared.disconnect()
}
