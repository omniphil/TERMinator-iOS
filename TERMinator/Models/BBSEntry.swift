import Foundation

/// Screen mode presets matching Android implementation.
enum ScreenMode: Int, CaseIterable, Codable, Identifiable {
    case mode80x25 = 0
    case mode80x30 = 1
    case mode80x40 = 5
    case mode80x50 = 2
    case mode132x25 = 3
    case mode132x50 = 4

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .mode80x25: return "80x25"
        case .mode80x30: return "80x30"
        case .mode80x40: return "80x40"
        case .mode80x50: return "80x50"
        case .mode132x25: return "132x25"
        case .mode132x50: return "132x50"
        }
    }

    var columns: Int {
        switch self {
        case .mode80x25, .mode80x30, .mode80x40, .mode80x50: return 80
        case .mode132x25, .mode132x50: return 132
        }
    }

    var rows: Int {
        switch self {
        case .mode80x25, .mode132x25: return 25
        case .mode80x30: return 30
        case .mode80x40: return 40
        case .mode80x50, .mode132x50: return 50
        }
    }
}

/// Connection protocol types.
enum ConnectionProtocol: Int, CaseIterable, Codable, Identifiable {
    case telnet = 3
    case ssh = 5
    case telnetS = 13

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .telnet: return "Telnet"
        case .ssh: return "SSH"
        case .telnetS: return "TelnetS (TLS)"
        }
    }
}

/// Font options for terminal display.
/// Raw values must match font indices in allfonts.c
enum TerminalFont: Int, CaseIterable, Identifiable {
    case cp437 = 0          // Codepage 437 English - Standard DOS font (index 0)
    case topazPlus = 40     // Topaz Plus (Amiga) - Amiga font for Amiga BBSes (index 40)

    var id: Int { rawValue }

    /// Display name shown in UI
    var displayName: String {
        switch self {
        case .cp437: return "Codepage 437 English"
        case .topazPlus: return "Topaz 1200 Plus"
        }
    }

    /// Internal font name that matches SyncTERM allfonts.c descriptions
    var fontName: String {
        switch self {
        case .cp437: return "Codepage 437 English"
        case .topazPlus: return "Topaz Plus (Amiga)"
        }
    }
}

// Custom Codable to handle migration from old rawValue (1) to new (40) for topazPlus
extension TerminalFont: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(Int.self)

        // Handle migration: old value 1 maps to topazPlus (now 40)
        if rawValue == 1 {
            self = .topazPlus
        } else if let font = TerminalFont(rawValue: rawValue) {
            self = font
        } else {
            // Default to cp437 for unknown values
            self = .cp437
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Represents a BBS connection entry with all configuration.
struct BBSEntry: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var host: String
    var port: Int
    var connectionProtocol: ConnectionProtocol
    var username: String
    var screenMode: ScreenMode
    var font: TerminalFont
    var zoomLevel: Int  // 25-200%
    var showStatusBar: Bool
    var autoConnect: Bool
    var snapshotData: Data?  // Thumbnail/snapshot image data
    var createdAt: Date
    var lastConnected: Date?

    // Note: Password is NOT stored here - use KeychainManager instead

    init(
        id: UUID = UUID(),
        name: String = "",
        host: String = "",
        port: Int = 23,
        connectionProtocol: ConnectionProtocol = .telnet,
        username: String = "",
        screenMode: ScreenMode = .mode80x25,
        font: TerminalFont = .cp437,
        zoomLevel: Int = 100,
        showStatusBar: Bool = true,
        autoConnect: Bool = false,
        snapshotData: Data? = nil,
        createdAt: Date = Date(),
        lastConnected: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.connectionProtocol = connectionProtocol
        self.username = username
        self.screenMode = screenMode
        self.font = font
        self.zoomLevel = zoomLevel.clamped(to: 25...200)
        self.showStatusBar = showStatusBar
        self.autoConnect = autoConnect
        self.snapshotData = snapshotData
        self.createdAt = createdAt
        self.lastConnected = lastConnected
    }

    // MARK: - Codable (with defaults for new fields)

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(Int.self, forKey: .port)
        connectionProtocol = try container.decode(ConnectionProtocol.self, forKey: .connectionProtocol)
        username = try container.decode(String.self, forKey: .username)
        screenMode = try container.decode(ScreenMode.self, forKey: .screenMode)
        font = try container.decode(TerminalFont.self, forKey: .font)
        zoomLevel = (try container.decodeIfPresent(Int.self, forKey: .zoomLevel) ?? 100).clamped(to: 25...200)
        showStatusBar = try container.decodeIfPresent(Bool.self, forKey: .showStatusBar) ?? true
        autoConnect = try container.decodeIfPresent(Bool.self, forKey: .autoConnect) ?? false
        snapshotData = try container.decodeIfPresent(Data.self, forKey: .snapshotData)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        lastConnected = try container.decodeIfPresent(Date.self, forKey: .lastConnected)
    }

    // MARK: - Password Management (via Keychain)

    /// Get the password from secure Keychain storage.
    var password: String? {
        KeychainManager.shared.getPassword(for: id)
    }

    /// Set the password in secure Keychain storage.
    func setPassword(_ password: String?) {
        if let password = password, !password.isEmpty {
            KeychainManager.shared.savePassword(password, for: id)
        } else {
            KeychainManager.shared.deletePassword(for: id)
        }
    }

    /// Check if a password is stored for this entry.
    var hasPassword: Bool {
        KeychainManager.shared.hasPassword(for: id)
    }

    // MARK: - Hashable

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: BBSEntry, rhs: BBSEntry) -> Bool {
        // Include snapshotData in equality check so SwiftUI detects thumbnail changes
        lhs.id == rhs.id &&
        lhs.name == rhs.name &&
        lhs.host == rhs.host &&
        lhs.port == rhs.port &&
        lhs.snapshotData == rhs.snapshotData
    }

    // MARK: - Default Port

    /// Get the default port for the current protocol.
    var defaultPort: Int {
        switch connectionProtocol {
        case .telnet: return 23
        case .ssh: return 22
        case .telnetS: return 992
        }
    }

    // MARK: - Display Helpers

    /// Display string for the connection address.
    var addressDisplay: String {
        if port == defaultPort {
            return host
        }
        return "\(host):\(port)"
    }

    /// Connection description for display.
    var connectionDescription: String {
        "\(connectionProtocol.displayName) - \(screenMode.displayName)"
    }
}

// MARK: - Comparable Extension

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        return min(max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - BBSEntry Storage

/// Manages persistent storage of BBS entries.
class BBSEntryStore: ObservableObject {
    static let shared = BBSEntryStore()

    // Fixed UUID for Dead Modem Society so Quick Connect 2 can default to it
    static let deadModemSocietyUUID = UUID(uuidString: "DEADBEEF-DEAD-DEAD-DEAD-DEAD00DE0500")!

    @Published var entries: [BBSEntry] = []

    private let storageKey = "bbs_entries"

    private init() {
        loadEntries()
    }

    func loadEntries() {
        if let data = UserDefaults.standard.data(forKey: storageKey) {
            do {
                entries = try JSONDecoder().decode([BBSEntry].self, from: data)
            } catch {
                print("Failed to decode BBS entries: \(error)")
                entries = []
            }
        }

        if entries.isEmpty {
            addDefaultEntries()
        } else {
            migrateDefaults()
        }

        // Fill in missing snapshots for default entries from bundle
        repairDefaultSnapshots()
    }

    /// Fill in missing snapshot images for default BBS entries from app bundle.
    private func repairDefaultSnapshots() {
        let snapshotMap: [String: String] = [
            "absinthebbs.net": "snapshot_absinthe",
            "telnet.deadmodemsociety.com": "snapshot_deadmodem",
            "20forbeers.com": "snapshot_20forbeers",
            "bbs.bottomlessabyss.net": "snapshot_bottomlessabyss",
            "sbbs.dmine.net": "snapshot_diamondmine",
            "bbs.erb.pw": "snapshot_quantumwormhole"
        ]
        var changed = false
        for i in entries.indices {
            guard entries[i].snapshotData == nil,
                  let resource = snapshotMap[entries[i].host],
                  let url = Bundle.main.url(forResource: resource, withExtension: "png"),
                  let data = try? Data(contentsOf: url) else { continue }
            entries[i].snapshotData = data
            changed = true
        }
        if changed {
            saveEntries()
        }
    }

    /// All default BBSes with their configuration and bundle snapshot resource names.
    private static let allDefaults: [(name: String, host: String, port: Int, screenMode: ScreenMode, font: TerminalFont, id: UUID?, snapshotResource: String?)] = [
        ("aBSiNTHE BBS", "absinthebbs.net", 1940, .mode80x40, .topazPlus, nil, "snapshot_absinthe"),
        ("Dead Modem Society", "telnet.deadmodemsociety.com", 1337, .mode80x25, .cp437, deadModemSocietyUUID, "snapshot_deadmodem"),
        ("20 For Beers", "20forbeers.com", 1337, .mode80x25, .cp437, nil, "snapshot_20forbeers"),
        ("The Bottomless Abyss", "bbs.bottomlessabyss.net", 2023, .mode80x25, .cp437, nil, "snapshot_bottomlessabyss"),
        ("Diamond Mine Online", "sbbs.dmine.net", 24, .mode80x25, .cp437, nil, "snapshot_diamondmine"),
        ("The Quantum Wormhole", "bbs.erb.pw", 23, .mode80x25, .cp437, nil, "snapshot_quantumwormhole"),
    ]

    private static let currentDefaultsVersion = 2

    /// Add default BBS connections on fresh install.
    private func addDefaultEntries() {
        entries = BBSEntryStore.allDefaults.map { def in
            let snapshot: Data? = def.snapshotResource.flatMap { resource in
                Bundle.main.url(forResource: resource, withExtension: "png")
                    .flatMap { try? Data(contentsOf: $0) }
            }
            return BBSEntry(
                id: def.id ?? UUID(),
                name: def.name,
                host: def.host,
                port: def.port,
                connectionProtocol: .telnet,
                screenMode: def.screenMode,
                font: def.font,
                showStatusBar: true,
                snapshotData: snapshot
            )
        }
        UserDefaults.standard.set(BBSEntryStore.currentDefaultsVersion, forKey: "defaults_version")
        saveEntries()
    }

    /// Migrate new default BBSes for existing users, skipping duplicates by host+port.
    private func migrateDefaults() {
        let version = UserDefaults.standard.integer(forKey: "defaults_version")
        if version >= BBSEntryStore.currentDefaultsVersion { return }

        let existing = Set(entries.map { "\($0.host):\($0.port)" })
        var added = 0

        for def in BBSEntryStore.allDefaults {
            let key = "\(def.host):\(def.port)"
            if existing.contains(key) { continue }

            let snapshot: Data? = def.snapshotResource.flatMap { resource in
                Bundle.main.url(forResource: resource, withExtension: "png")
                    .flatMap { try? Data(contentsOf: $0) }
            }
            let entry = BBSEntry(
                id: def.id ?? UUID(),
                name: def.name,
                host: def.host,
                port: def.port,
                connectionProtocol: .telnet,
                screenMode: def.screenMode,
                font: def.font,
                showStatusBar: true,
                snapshotData: snapshot
            )
            entries.append(entry)
            added += 1
        }

        UserDefaults.standard.set(BBSEntryStore.currentDefaultsVersion, forKey: "defaults_version")
        if added > 0 {
            saveEntries()
        }
    }

    func saveEntries() {
        do {
            let data = try JSONEncoder().encode(entries)
            UserDefaults.standard.set(data, forKey: storageKey)
        } catch {
            print("Failed to encode BBS entries: \(error)")
        }
    }

    func addEntry(_ entry: BBSEntry) {
        entries.append(entry)
        saveEntries()
    }

    func updateEntry(_ entry: BBSEntry) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
            saveEntries()
        }
    }

    func deleteEntry(_ entry: BBSEntry) {
        // Delete password from Keychain
        KeychainManager.shared.deletePassword(for: entry.id)
        // Remove from entries
        entries.removeAll { $0.id == entry.id }
        saveEntries()
    }

    func deleteEntries(at offsets: IndexSet) {
        for index in offsets {
            KeychainManager.shared.deletePassword(for: entries[index].id)
        }
        entries.remove(atOffsets: offsets)
        saveEntries()
    }

    func moveEntries(from source: IndexSet, to destination: Int) {
        entries.move(fromOffsets: source, toOffset: destination)
        saveEntries()
    }

    func updateLastConnected(for entry: BBSEntry) {
        if var updatedEntry = entries.first(where: { $0.id == entry.id }) {
            updatedEntry.lastConnected = Date()
            updateEntry(updatedEntry)
        }
    }

    func updateSnapshot(_ data: Data?, for entry: BBSEntry) {
        if var updatedEntry = entries.first(where: { $0.id == entry.id }) {
            updatedEntry.snapshotData = data
            updateEntry(updatedEntry)
        }
    }

    /// Import entries from decoded array, merging or replacing existing.
    func importEntries(_ newEntries: [BBSEntry], replace: Bool = false) {
        if replace {
            // Delete all existing passwords
            for entry in entries {
                KeychainManager.shared.deletePassword(for: entry.id)
            }
            entries = newEntries
        } else {
            // Merge: update existing or add new
            for newEntry in newEntries {
                if let index = entries.firstIndex(where: { $0.id == newEntry.id }) {
                    entries[index] = newEntry
                } else {
                    entries.append(newEntry)
                }
            }
        }
        saveEntries()
    }
}
