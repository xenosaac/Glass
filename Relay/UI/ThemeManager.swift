import SwiftUI

/// App-wide theme preference. Persisted via @AppStorage.
enum ThemeMode: String, CaseIterable, Identifiable {
 case system = "system"
 case light = "light"
 case dark = "dark"

 var id: String { rawValue }

 var label: String {
 switch self {
 case .system: return "Follow System"
 case .light: return "Light"
 case .dark: return "Dark"
 }
 }

 var colorScheme: ColorScheme? {
 switch self {
 case .system: return nil // nil = follow system
 case .light: return .light
 case .dark: return .dark
 }
 }
}

/// Observable theme manager. Read by the root app view to apply preferredColorScheme.
@Observable
final class ThemeManager {
 static let shared = ThemeManager()

 var mode: ThemeMode {
 didSet { UserDefaults.standard.set(mode.rawValue, forKey: "glass_theme_mode") }
 }

 private init() {
 let stored = UserDefaults.standard.string(forKey: "glass_theme_mode") ?? "system"
 self.mode = ThemeMode(rawValue: stored) ?? .system
 }
}
