import SwiftUI

/// Brand design tokens for Glass's retro 3D visual system.
extension Color {
 static let glassPageBackground = Color(light: 0xD3C6AA, dark: 0x1F201E)
 static let glassSurfaceBase = Color(light: 0xDDD0B6, dark: 0x2A2C29)
 static let glassSurfaceRaised = Color(light: 0xE7DDC8, dark: 0x32342F)
 static let glassSurfaceSubtle = Color(light: 0xCEC09D, dark: 0x262825)
 static let glassSurfaceField = Color(light: 0xE9DFC8, dark: 0x242623)
 static let glassAccent = Color(hex: 0xA7C080)
 static let glassAccentPressed = Color(light: 0x95B06F, dark: 0x8EAB65)
 static let glassBorder = Color(hex: 0x2D353B)
 static let glassText = Color(light: 0x30312E, dark: 0xF8FAF6)
 static let glassTextMuted = Color(light: 0x5E5A50, dark: 0xD5D8D2)
 static let glassRunning = Color(light: 0xC89B54, dark: 0xD2AA69)
 static let glassSuccess = Color(hex: 0xA7C080)
 static let glassWarning = Color(light: 0xC89B54, dark: 0xD2AA69)
 static let glassError = Color(light: 0xC75C53, dark: 0xE07B73)
 static let glassCloud = Color(light: 0x8C7B58, dark: 0xC1B08F)
 static let glassPanelShadow = Color(light: 0x87765A, dark: 0x111311, opacity: 0.9)
 static let glassHighlight = Color(light: 0xFFF4D8, dark: 0xF4F5E9, opacity: 0.9)
 static let glassLowlight = Color(light: 0x6E6557, dark: 0x111311, opacity: 0.95)
 static let glassDangerFill = Color(light: 0xD26B60, dark: 0xB14E46)
 static let glassPixelPrimary = Color(light: 0x687C4D, dark: 0x7F9760)
 static let glassPixelShadow = Color(light: 0x435045, dark: 0x2A332E)
 static let glassPixelDust = Color(light: 0x9B8F71, dark: 0x615C4F)
}

enum GlassRadius {
 static let small: CGFloat = 12
 static let medium: CGFloat = 18
 static let large: CGFloat = 24
 static let hero: CGFloat = 30
}

struct GlassShadow: ViewModifier {
 var up: Bool = false

 func body(content: Content) -> some View {
 content.shadow(color: Color.glassPanelShadow.opacity(up ? 0.18 : 0.24), radius: 0, y: up ? -2 : 4)
 }
}

extension View {
 func glassShadow() -> some View {
 modifier(GlassShadow)
 }

 func glassShadowUp() -> some View {
 modifier(GlassShadow(up: true))
 }
}
