import SwiftUI

@main
struct RelayApp: App {
 @State private var themeManager = ThemeManager.shared

 init() {
 let config = RelayConfig.shared
 print("[Glass.] Gemini API key: \(config.geminiAPIKey.isEmpty ? "MISSING" : "set")")
 }

 var body: some Scene {
 WindowGroup {
 RelayAppShell
 .preferredColorScheme(themeManager.mode.colorScheme)
 }
 }
}
