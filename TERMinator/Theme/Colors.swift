import SwiftUI

/// Terminal and app theme colors matching the Android version.
extension Color {
    // MARK: - App Theme Colors
    // Note: Using "app" prefix to avoid conflict with SwiftUI's built-in Color.primary

    /// Primary accent color - bright cyan/blue
    static let appPrimary = Color(red: 0, green: 0.667, blue: 1) // #00AAFF

    /// Dark primary variant
    static let appPrimaryDark = Color(red: 0, green: 0.533, blue: 0.867) // #0088DD

    /// Light primary variant
    static let appPrimaryLight = Color(red: 0.588, green: 0.933, blue: 0.973) // #96EEF8

    /// Accent color - bright green/cyan
    static let accent = Color(red: 0, green: 1, blue: 0.667) // #00FFAA

    /// Logo "TERM" stripe color - dark blue
    static let logoTermColor = Color(red: 0.2, green: 0.314, blue: 0.58) // #335094

    // MARK: - DOS 16-Color Palette

    static let termBlack = Color(red: 0, green: 0, blue: 0) // #000000
    static let termBlue = Color(red: 0, green: 0, blue: 0.667) // #0000AA
    static let termGreen = Color(red: 0, green: 0.667, blue: 0) // #00AA00
    static let termCyan = Color(red: 0, green: 0.667, blue: 0.667) // #00AAAA
    static let termRed = Color(red: 0.667, green: 0, blue: 0) // #AA0000
    static let termMagenta = Color(red: 0.667, green: 0, blue: 0.667) // #AA00AA
    static let termBrown = Color(red: 0.667, green: 0.333, blue: 0) // #AA5500
    static let termLightGray = Color(red: 0.667, green: 0.667, blue: 0.667) // #AAAAAA
    static let termDarkGray = Color(red: 0.333, green: 0.333, blue: 0.333) // #555555
    static let termLightBlue = Color(red: 0.333, green: 0.333, blue: 1) // #5555FF
    static let termLightGreen = Color(red: 0.333, green: 1, blue: 0.333) // #55FF55
    static let termLightCyan = Color(red: 0.333, green: 1, blue: 1) // #55FFFF
    static let termLightRed = Color(red: 1, green: 0.333, blue: 0.333) // #FF5555
    static let termLightMagenta = Color(red: 1, green: 0.333, blue: 1) // #FF55FF
    static let termYellow = Color(red: 1, green: 1, blue: 0.333) // #FFFF55
    static let termWhite = Color(red: 1, green: 1, blue: 1) // #FFFFFF

    // MARK: - UI Colors

    /// Background color - dark blue tint
    static let background = Color(red: 0.039, green: 0.098, blue: 0.161) // #0A1929

    /// Surface color - slightly lighter
    static let surface = Color(red: 0.063, green: 0.125, blue: 0.188) // #102030

    /// Darker background for CRT effects
    static let crtBackground = Color(red: 0.031, green: 0.075, blue: 0.125) // #081320

    /// Card/panel background
    static let cardBackground = Color(red: 0.047, green: 0.086, blue: 0.141) // #0C1624

    /// Text on background
    static let onBackground = Color(red: 0.878, green: 0.941, blue: 1) // #E0F0FF

    /// Secondary text color
    static let textSecondary = Color(red: 0.6, green: 0.7, blue: 0.8) // #99B3CC

    /// Control button inactive color
    static let ctrlButtonInactive = Color(red: 0.2, green: 0.2, blue: 0.333) // #333355

    /// Border color for panels
    static let panelBorder = Color(red: 0.133, green: 0.2, blue: 0.267) // #223344

    /// Section header background
    static let sectionHeader = Color(red: 0.055, green: 0.11, blue: 0.165) // #0E1C2A
}

/// Convenience accessors for common UI color needs
extension Color {
    /// The main green color used for retro terminal text
    static var retroGreen: Color { .termLightGreen }

    /// The accent color used for buttons and highlights
    static var retroAccent: Color { .logoTermColor }

    /// Grid pattern color
    static var gridColor: Color { .termGreen.opacity(0.1) }
}
