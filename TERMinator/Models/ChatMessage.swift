import Foundation
import SwiftUI

/// A single chat message from the Firebase Realtime Database.
struct ChatMessage: Identifiable, Equatable {
    let key: String
    let uid: String
    let username: String
    let countryCode: String
    let message: String
    let timestamp: Int64
    let hidden: Bool

    var id: String { key }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    var formattedTime: String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000.0)
        return ChatMessage.timeFormatter.string(from: date)
    }
}

/// The four chat rooms, matching Android's room keys.
enum ChatRoom: String, CaseIterable, Identifiable {
    case bbsChat = "bbs_chat"
    case featuresBugs = "features_bugs"
    case swapMeet = "swap_meet"
    case testing = "testing"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bbsChat: return "BBS Chat"
        case .featuresBugs: return "Features/Bugs"
        case .swapMeet: return "Your BBS"
        case .testing: return "Testing"
        }
    }

    var backgroundColor: Color {
        switch self {
        case .bbsChat: return Color(red: 0.039, green: 0.098, blue: 0.161) // #0A1929
        case .featuresBugs: return Color(red: 0.039, green: 0.102, blue: 0.227) // #0A1A3A
        case .swapMeet: return Color(red: 0.078, green: 0.118, blue: 0.157) // #141E28
        case .testing: return Color(red: 0.039, green: 0.098, blue: 0.161) // #0A1929
        }
    }
}

/// Connection status for the Firebase backend.
enum ServerStatus: Equatable {
    case connected
    case disconnected
    case connecting

    var color: Color {
        switch self {
        case .connected: return Color(red: 0.333, green: 1, blue: 0.333) // #55FF55
        case .disconnected: return Color(red: 1, green: 0.333, blue: 0.333) // #FF5555
        case .connecting: return Color(red: 1, green: 1, blue: 0.333) // #FFFF55
        }
    }

    var label: String {
        switch self {
        case .connected: return "Connected"
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting..."
        }
    }
}

/// Result of attempting to claim a username.
enum ClaimResult {
    case success
    case taken
    case reserved
    case error
}

/// Country codes matching Android's country_codes_alpha3 list.
struct CountryCode: Identifiable, Hashable {
    let code: String
    let name: String

    var id: String { code }

    var displayString: String {
        if code == "---" { return "Not Set" }
        return "\(code) \u{2022} \(name)"
    }

    static let allCountries: [CountryCode] = [
        CountryCode(code: "---", name: "Not Set"),
        CountryCode(code: "ARG", name: "Argentina"),
        CountryCode(code: "AUS", name: "Australia"),
        CountryCode(code: "AUT", name: "Austria"),
        CountryCode(code: "BRA", name: "Brazil"),
        CountryCode(code: "CAN", name: "Canada"),
        CountryCode(code: "CHN", name: "China"),
        CountryCode(code: "DEU", name: "Germany"),
        CountryCode(code: "DNK", name: "Denmark"),
        CountryCode(code: "ESP", name: "Spain"),
        CountryCode(code: "FIN", name: "Finland"),
        CountryCode(code: "FRA", name: "France"),
        CountryCode(code: "GBR", name: "United Kingdom"),
        CountryCode(code: "IND", name: "India"),
        CountryCode(code: "IRL", name: "Ireland"),
        CountryCode(code: "ISR", name: "Israel"),
        CountryCode(code: "ITA", name: "Italy"),
        CountryCode(code: "JPN", name: "Japan"),
        CountryCode(code: "KOR", name: "South Korea"),
        CountryCode(code: "MEX", name: "Mexico"),
        CountryCode(code: "NLD", name: "Netherlands"),
        CountryCode(code: "NOR", name: "Norway"),
        CountryCode(code: "NZL", name: "New Zealand"),
        CountryCode(code: "POL", name: "Poland"),
        CountryCode(code: "PRT", name: "Portugal"),
        CountryCode(code: "RUS", name: "Russia"),
        CountryCode(code: "SWE", name: "Sweden"),
        CountryCode(code: "CHE", name: "Switzerland"),
        CountryCode(code: "TUR", name: "Turkey"),
        CountryCode(code: "UKR", name: "Ukraine"),
        CountryCode(code: "USA", name: "United States"),
        CountryCode(code: "ZAF", name: "South Africa"),
    ]
}

/// Usernames that cannot be claimed by regular users.
let reservedUsernames: Set<String> = [
    "admin", "system", "moderator", "mod", "terminator", "sysop",
    "operator", "server", "bot", "official", "staff", "support",
    "root", "dev", "developer", "sysadmin", "cosysop", "guest",
    "anonymous", "anon", "newuser", "unknown", "syncterm",
    "philw", "omniphil"
]
