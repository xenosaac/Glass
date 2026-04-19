import SwiftUI

public enum GlassButtonVariant: Sendable {
 case primary
 case secondary
 case destructive
 case floatingChat
 case iconPrimary
 case iconSecondary
 case iconAccent
 case iconError
 case iconSidebar
}

struct RelayGlassButtonStyle: ButtonStyle {
 let variant: GlassButtonVariant
 let burstStyle: PixelBurstStyle?

 init(variant: GlassButtonVariant, burstStyle: PixelBurstStyle? = nil) {
 self.variant = variant
 self.burstStyle = burstStyle
 }

 func makeBody(configuration: Configuration) -> some View {
 RelayGlassButtonContainer(variant: variant, burstStyle: burstStyle, configuration: configuration)
 }
}

public struct RelaySurfaceFeedbackButtonStyle: ButtonStyle {
 public init() {}

 public func makeBody(configuration: Configuration) -> some View {
 configuration.label
 .brightness(configuration.isPressed ? -0.035 : 0)
 .offset(y: configuration.isPressed ? 2 : 0)
 .scaleEffect(configuration.isPressed ? 0.996 : 1)
 .animation(RetroMotion.surfaceTap, value: configuration.isPressed)
 }
}

private struct RelayGlassButtonContainer: View {
 let variant: GlassButtonVariant
 let burstStyle: PixelBurstStyle?
 let configuration: ButtonStyle.Configuration

 @Environment(\.isEnabled) private var isEnabled
 @Environment(\.colorScheme) private var colorScheme
 @State private var burstTrigger = 0

 private var isIconVariant: Bool {
 switch variant {
 case .iconPrimary, .iconSecondary, .iconAccent, .iconError, .iconSidebar:
 return true
 case .primary, .secondary, .destructive, .floatingChat:
 return false
 }
 }

 private var lift: CGFloat {
 variant == .floatingChat ? 7 : RetroMetrics.buttonLift
 }

 private var pressedFrontOffset: CGFloat {
 configuration.isPressed ? lift - RetroMetrics.pressedLift : 0
 }

 var body: some View {
 let shape = RetroCutShape(cut: isIconVariant ? 8 : 10)

 configuration.label
 .font(labelFont)
 .foregroundStyle(labelColor)
 .padding(.horizontal, horizontalPadding)
 .padding(.vertical, verticalPadding)
 .frame(
 width: isIconVariant ? RetroMetrics.iconButtonSize : nil,
 height: isIconVariant ? RetroMetrics.iconButtonSize : nil
 )
 .frame(
 minWidth: isIconVariant ? nil : minimumWidth,
 minHeight: isIconVariant ? nil : minimumHeight
 )
 .fixedSize(horizontal: false, vertical: true)
 .background {
 buttonChrome(shape: shape)
 }
 .brightness(configuration.isPressed ? -0.04 : 0)
 .offset(y: pressedFrontOffset)
 .overlay {
 if let burstStyle {
 PixelBurstEmitter(trigger: burstTrigger, style: burstStyle)
 }
 }
 // Reserve room for the step shadow without letting the chrome
 // become the layout anchor. The label stays in charge of size.
 .padding(.bottom, lift)
 .contentShape(shape)
 .opacity(isEnabled ? 1 : 0.56)
 .saturation(isEnabled ? 1 : 0.6)
 .scaleEffect(configuration.isPressed ? 0.996 : 1)
 .animation(RetroMotion.buttonPress, value: configuration.isPressed)
 .animation(.easeOut(duration: 0.18), value: isEnabled)
 .onChange(of: configuration.isPressed) { oldValue, newValue in
 if oldValue, !newValue, isEnabled, burstStyle != nil {
 burstTrigger += 1
 }
 }
 }

 private func buttonChrome(shape: RetroCutShape) -> some View {
 ZStack {
 shape
 .fill(palette.shadow.opacity(isEnabled ? 1 : 0.75))
 .offset(y: lift)

 shape
 .fill(frontFill)

 shape.inset(by: 0.75)
 .stroke(palette.border, lineWidth: RetroMetrics.borderWidth)

 shape.inset(by: 2)
 .stroke(palette.highlight.opacity(configuration.isPressed ? 0.3 : 0.95), lineWidth: 1.25)
 .mask(alignment: .top) {
 Rectangle.frame(height: isIconVariant ? 12 : 16)
 }

 shape.inset(by: 2)
 .stroke(palette.shadow.opacity(configuration.isPressed ? 0.25 : 0.6), lineWidth: 1)
 .mask(alignment: .bottom) {
 Rectangle.frame(height: isIconVariant ? 10 : 14)
 }
 }
 }

 private var frontFill: Color {
 switch variant {
 case .primary, .iconAccent:
 return configuration.isPressed ? Color.glassAccentPressed : Color.glassAccent
 case .iconPrimary, .floatingChat:
 return colorScheme == .dark
 ? Color.glassSurfaceRaised
 : Color.glassText
 case .secondary, .iconSecondary, .iconSidebar:
 return colorScheme == .dark
 ? Color.glassSurfaceBase
 : Color.glassSurfaceRaised
 case .destructive, .iconError:
 return Color.glassDangerFill
 }
 }

 private var palette: RetroPalette {
 switch variant {
 case .primary, .iconAccent:
 return RetroPalette(
 fill: Color.glassAccent,
 border: Color.glassBorder,
 highlight: Color.glassHighlight,
 shadow: Color.glassLowlight,
 foreground: Color.glassBorder
 )
 case .iconPrimary, .floatingChat:
 return RetroPalette(
 fill: colorScheme == .dark ? Color.glassSurfaceRaised : Color.glassText,
 border: Color.glassBorder,
 highlight: colorScheme == .dark ? Color.glassHighlight : Color.white.opacity(0.72),
 shadow: Color.glassLowlight,
 foreground: colorScheme == .dark ? Color.glassBorder : .white
 )
 case .secondary, .iconSecondary, .iconSidebar:
 return RetroPalette(
 fill: colorScheme == .dark ? Color.glassSurfaceBase : Color.glassSurfaceRaised,
 border: Color.glassBorder,
 highlight: Color.glassHighlight,
 shadow: Color.glassPanelShadow,
 foreground: Color.glassText
 )
 case .destructive, .iconError:
 return RetroPalette(
 fill: Color.glassDangerFill,
 border: Color.glassBorder,
 highlight: Color.glassHighlight,
 shadow: Color.glassLowlight,
 foreground: .white
 )
 }
 }

 private var labelColor: Color {
 switch variant {
 case .primary, .iconAccent:
 return Color.glassBorder
 case .secondary, .iconSecondary, .iconSidebar:
 return Color.glassText
 case .destructive, .iconError:
 return .white
 case .iconPrimary, .floatingChat:
 return colorScheme == .dark ? Color.glassBorder : .white
 }
 }

 private var horizontalPadding: CGFloat {
 switch variant {
 case .floatingChat:
 return 18
 case .primary, .secondary, .destructive:
 return 16
 case .iconPrimary, .iconSecondary, .iconAccent, .iconError, .iconSidebar:
 return 0
 }
 }

 private var verticalPadding: CGFloat {
 switch variant {
 case .floatingChat:
 return 12
 case .primary, .secondary, .destructive:
 return 10
 case .iconPrimary, .iconSecondary, .iconAccent, .iconError, .iconSidebar:
 return 0
 }
 }

 private var minimumWidth: CGFloat {
 switch variant {
 case .floatingChat:
 return 108
 case .primary, .secondary, .destructive:
 return 0
 case .iconPrimary, .iconSecondary, .iconAccent, .iconError, .iconSidebar:
 return RetroMetrics.iconButtonSize
 }
 }

 private var minimumHeight: CGFloat {
 switch variant {
 case .floatingChat:
 return 52
 case .primary, .secondary, .destructive:
 return 46
 case .iconPrimary, .iconSecondary, .iconAccent, .iconError, .iconSidebar:
 return RetroMetrics.iconButtonSize
 }
 }

 private var labelFont: Font {
 switch variant {
 case .floatingChat:
 return GlassType.chatCTA.font
 case .primary, .secondary, .destructive:
 return GlassType.bodyEmphasis.font
 case .iconPrimary, .iconSecondary, .iconAccent, .iconError, .iconSidebar:
 return GlassType.bodyEmphasis.font
 }
 }
}

extension ButtonStyle where Self == RelayGlassButtonStyle {
 static func relayGlass(_ variant: GlassButtonVariant, burst: PixelBurstStyle? = nil) -> RelayGlassButtonStyle {
 RelayGlassButtonStyle(variant: variant, burstStyle: burst)
 }
}

public extension ButtonStyle where Self == RelaySurfaceFeedbackButtonStyle {
 static var relaySurfaceFeedback: RelaySurfaceFeedbackButtonStyle {
 RelaySurfaceFeedbackButtonStyle
 }
}
