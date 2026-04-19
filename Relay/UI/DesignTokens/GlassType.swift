import SwiftUI
import UIKit

public enum GlassType: Sendable {
 case display
 case title
 case bodyEmphasis
 case body
 case chatBody
 case assistantBody
 case chatChip
 case chatCTA
 case sectionHeader
 case settingsSectionHeader
 case caption
 case numeric

 private static let displayFontName = "Pixelify Sans"

 public var font: Font {
 switch self {
 case .display:
 return Self.display(size: 30, weight: .semibold)
 case .title:
 return Self.display(size: 22, weight: .semibold)
 case .bodyEmphasis:
 return .system(.body, design: .rounded).weight(.semibold)
 case .body:
 return .system(.body, design: .rounded)
 case .chatBody:
 return .system(size: 18, weight: .regular, design: .rounded)
 case .assistantBody:
 return .system(size: 17, weight: .regular, design: .default)
 case .chatChip:
 return Self.display(size: 18, weight: .medium)
 case .chatCTA:
 return Self.display(size: 20, weight: .medium)
 case .sectionHeader:
 return Self.display(size: 15, weight: .medium)
 case .settingsSectionHeader:
 return Self.display(size: 18, weight: .medium)
 case .caption:
 return .system(.caption, design: .rounded)
 case .numeric:
 return .system(.callout, design: .monospaced)
 }
 }

 private static func display(size: CGFloat, weight: Font.Weight) -> Font {
 if UIFont.fontNames(forFamilyName: displayFontName).isEmpty == false
 || UIFont(name: "PixelifySans-Regular", size: size) != nil {
 return .custom(displayFontName, size: size).weight(weight)
 }
 return .system(size: size, weight: weight, design: .rounded)
 }
}

public extension View {
 func glassType(_ style: GlassType) -> some View {
 font(style.font)
 }
}
