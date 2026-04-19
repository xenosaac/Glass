import SwiftUI

public enum GlassSurfaceStyle: Sendable {
 case card
 case messageBubble
 case cardSubtle
 case pill
 case floating
 case row
 case field
 case composer
 case iconDisc
}

public struct GlassSurfaceModifier: ViewModifier {
 @Environment(\.colorScheme) private var colorScheme
 let style: GlassSurfaceStyle

 public func body(content: Content) -> some View {
 let shape = RetroCutShape(cut: cut)
 content
 .background {
 ZStack {
 shape
 .fill(palette.shadow)
 .offset(y: depth)

 shape
 .fill(palette.fill)

 shape
 .inset(by: 0.75)
 .stroke(palette.border, lineWidth: RetroMetrics.borderWidth)

 shape
 .inset(by: 2)
 .stroke(palette.highlight.opacity(colorScheme == .dark ? 0.55 : 0.8), lineWidth: 1.25)
 .mask(alignment: .top) {
 Rectangle
 .frame(height: highlightBandHeight)
 }

 shape
 .inset(by: 2)
 .stroke(palette.shadow.opacity(colorScheme == .dark ? 0.45 : 0.6), lineWidth: 1)
 .mask(alignment: .bottom) {
 Rectangle
 .frame(height: highlightBandHeight)
 }
 }
 }
 }

 private var depth: CGFloat {
 switch style {
 case .composer:
 return 4
 case .card, .messageBubble, .floating:
 return 3
 case .cardSubtle, .row, .field:
 return 2.5
 case .pill, .iconDisc:
 return 2
 }
 }

 private var cut: CGFloat {
 switch style {
 case .composer:
 return 14
 case .card, .messageBubble:
 return 12
 case .cardSubtle, .field, .floating:
 return 10
 case .row:
 return 9
 case .pill, .iconDisc:
 return 8
 }
 }

 private var highlightBandHeight: CGFloat {
 switch style {
 case .composer, .card, .messageBubble:
 return 24
 case .field, .cardSubtle, .row, .floating:
 return 20
 case .pill, .iconDisc:
 return 14
 }
 }

 private var palette: RetroPalette {
 switch style {
 case .messageBubble:
 return RetroPalette(
 fill: Color.glassAccent,
 border: Color.glassBorder,
 highlight: Color.glassHighlight,
 shadow: Color.glassLowlight,
 foreground: colorScheme == .dark ? .black : Color.glassBorder
 )
 case .composer:
 return RetroPalette(
 fill: Color.glassSurfaceRaised,
 border: Color.glassBorder,
 highlight: Color.glassHighlight,
 shadow: Color.glassPanelShadow,
 foreground: Color.glassText
 )
 case .card:
 return RetroPalette(
 fill: Color.glassSurfaceRaised,
 border: Color.glassBorder,
 highlight: Color.glassHighlight,
 shadow: Color.glassPanelShadow,
 foreground: Color.glassText
 )
 case .cardSubtle, .row:
 return RetroPalette(
 fill: Color.glassSurfaceBase,
 border: Color.glassBorder.opacity(0.92),
 highlight: Color.glassHighlight,
 shadow: Color.glassPanelShadow.opacity(0.92),
 foreground: Color.glassText
 )
 case .field, .floating:
 return RetroPalette(
 fill: Color.glassSurfaceField,
 border: Color.glassBorder,
 highlight: Color.glassHighlight,
 shadow: Color.glassPanelShadow,
 foreground: Color.glassText
 )
 case .pill, .iconDisc:
 return RetroPalette(
 fill: Color.glassSurfaceSubtle,
 border: Color.glassBorder,
 highlight: Color.glassHighlight,
 shadow: Color.glassPanelShadow,
 foreground: Color.glassText
 )
 }
 }
}

public extension View {
 func glassSurface(_ style: GlassSurfaceStyle) -> some View {
 modifier(GlassSurfaceModifier(style: style))
 }
}
