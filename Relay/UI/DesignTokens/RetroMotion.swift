import SwiftUI

enum RetroMotion {
 static let buttonPress = Animation.interactiveSpring(response: 0.16, dampingFraction: 0.72)
 static let surfaceTap = Animation.interactiveSpring(response: 0.18, dampingFraction: 0.78)
 static let chipToggle = Animation.interactiveSpring(response: 0.22, dampingFraction: 0.82)
 static let drawerSpring = Animation.interactiveSpring(response: 0.26, dampingFraction: 0.84)
 static let assistantReveal = Animation.interactiveSpring(response: 0.28, dampingFraction: 0.82)
 static let quickFade = Animation.easeOut(duration: 0.18)
}

enum PixelBurstTone {
 case primary
 case shadow
 case dust
}

struct PixelBurstPalette {
 let primary: Color
 let shadow: Color
 let dust: Color

 static let accent = PixelBurstPalette(
 primary: Color.glassPixelPrimary,
 shadow: Color.glassPixelShadow,
 dust: Color.glassPixelDust
 )

 static let darkAccent = PixelBurstPalette(
 primary: Color.glassPixelShadow,
 shadow: Color.glassBorder,
 dust: Color.glassPixelDust
 )
}

struct PixelBurstParticle: Identifiable {
 let id = UUID()
 let dx: CGFloat
 let dy: CGFloat
 let size: CGFloat
 let tone: PixelBurstTone
 let start: CGFloat
}

public struct PixelBurstStyle {
 let palette: PixelBurstPalette
 let particles: [PixelBurstParticle]
 let duration: Double
 let alignment: Alignment

 static let buttonTap = PixelBurstStyle(
 palette: .accent,
 particles: [
 .init(dx: -18, dy: -12, size: 4, tone: .primary, start: 0.00),
 .init(dx: -10, dy: -22, size: 5, tone: .shadow, start: 0.04),
 .init(dx: -2, dy: -28, size: 4, tone: .dust, start: 0.08),
 .init(dx: 8, dy: -24, size: 5, tone: .primary, start: 0.02),
 .init(dx: 18, dy: -14, size: 4, tone: .shadow, start: 0.06),
 .init(dx: 14, dy: -28, size: 3, tone: .dust, start: 0.12)
 ],
 duration: 0.46,
 alignment: .top
 )

 static let subtleTap = PixelBurstStyle(
 palette: .accent,
 particles: [
 .init(dx: -12, dy: -10, size: 4, tone: .dust, start: 0.00),
 .init(dx: 0, dy: -18, size: 3, tone: .primary, start: 0.08),
 .init(dx: 12, dy: -10, size: 4, tone: .shadow, start: 0.05)
 ],
 duration: 0.36,
 alignment: .top
 )

 static let microphoneTap = PixelBurstStyle(
 palette: .darkAccent,
 particles: [
 .init(dx: -14, dy: -10, size: 4, tone: .primary, start: 0.00),
 .init(dx: -8, dy: 4, size: 3, tone: .dust, start: 0.06),
 .init(dx: 0, dy: -20, size: 4, tone: .shadow, start: 0.04),
 .init(dx: 10, dy: -8, size: 4, tone: .primary, start: 0.10),
 .init(dx: 14, dy: 6, size: 3, tone: .dust, start: 0.14)
 ],
 duration: 0.42,
 alignment: .center
 )

 static let drawerOpen = PixelBurstStyle(
 palette: .accent,
 particles: [
 .init(dx: -28, dy: -10, size: 4, tone: .shadow, start: 0.00),
 .init(dx: -14, dy: -20, size: 4, tone: .primary, start: 0.06),
 .init(dx: 0, dy: -14, size: 3, tone: .dust, start: 0.10),
 .init(dx: 16, dy: -22, size: 4, tone: .primary, start: 0.02),
 .init(dx: 30, dy: -12, size: 4, tone: .shadow, start: 0.07)
 ],
 duration: 0.40,
 alignment: .top
 )

 static let assistantReveal = PixelBurstStyle(
 palette: .accent,
 particles: [
 .init(dx: 10, dy: -16, size: 4, tone: .primary, start: 0.00),
 .init(dx: 18, dy: -6, size: 3, tone: .dust, start: 0.04),
 .init(dx: 24, dy: 8, size: 4, tone: .shadow, start: 0.08),
 .init(dx: 30, dy: -22, size: 5, tone: .primary, start: 0.02),
 .init(dx: 38, dy: 2, size: 3, tone: .dust, start: 0.10),
 .init(dx: 46, dy: -10, size: 4, tone: .shadow, start: 0.12)
 ],
 duration: 0.52,
 alignment: .topLeading
 )

 static let heroSimmer = PixelBurstStyle(
 palette: .accent,
 particles: [
 .init(dx: -24, dy: -8, size: 3, tone: .dust, start: 0.00),
 .init(dx: -12, dy: -20, size: 4, tone: .primary, start: 0.08),
 .init(dx: 0, dy: -28, size: 3, tone: .shadow, start: 0.12),
 .init(dx: 12, dy: -18, size: 4, tone: .primary, start: 0.04),
 .init(dx: 22, dy: -6, size: 3, tone: .dust, start: 0.10)
 ],
 duration: 0.65,
 alignment: .bottom
 )
}

struct PixelBurstEmitter: View {
 let trigger: Int
 let style: PixelBurstStyle

 @State private var progress: CGFloat = 1
 @State private var isVisible = false
 @State private var generation = 0

 var body: some View {
 ZStack {
 if isVisible {
 ZStack {
 ForEach(style.particles) { particle in
 let particleProgress = localProgress(for: particle)
 RetroPixelBlock(color: toneColor(particle.tone), size: particle.size)
 .offset(x: particle.dx * particleProgress)
 .offset(y: (particle.dy * particleProgress) + (8 * particleProgress * particleProgress))
 .scaleEffect(1 - (particleProgress * 0.18))
 .opacity(1 - particleProgress)
 }
 }
 .frame(width: 1, height: 1)
 .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: style.alignment)
 }
 }
 .allowsHitTesting(false)
 .onChange(of: trigger) { oldValue, newValue in
 guard newValue != oldValue else { return }
 launch
 }
 }

 private func launch() {
 generation += 1
 let currentGeneration = generation
 progress = 0
 isVisible = true

 DispatchQueue.main.async {
 withAnimation(.easeOut(duration: style.duration)) {
 progress = 1
 }
 }

 DispatchQueue.main.asyncAfter(deadline: .now + style.duration + 0.08) {
 guard generation == currentGeneration else { return }
 isVisible = false
 }
 }

 private func localProgress(for particle: PixelBurstParticle) -> CGFloat {
 let clamped = max(0, progress - particle.start)
 let span = max(0.001, 1 - particle.start)
 return min(1, clamped / span)
 }

 private func toneColor(_ tone: PixelBurstTone) -> Color {
 switch tone {
 case .primary:
 return style.palette.primary
 case .shadow:
 return style.palette.shadow
 case .dust:
 return style.palette.dust
 }
 }
}

struct PixelStepIndicator: View {
 var tint: Color = Color.glassBorder
 var inactiveTint: Color = Color.glassTextMuted.opacity(0.28)
 var count: Int = 4
 var blockSize: CGFloat = 6
 var spacing: CGFloat = 4
 var isAnimating: Bool = true

 @State private var phase = 0
 private let timer = Timer.publish(every: 0.18, on: .main, in: .common).autoconnect

 var body: some View {
 HStack(spacing: spacing) {
 ForEach(0..<count, id: \.self) { index in
 RetroPixelBlock(
 color: phase == index ? tint : inactiveTint,
 size: blockSize
 )
 .offset(y: phase == index ? -1 : 0)
 .animation(RetroMotion.quickFade, value: phase)
 }
 }
 .onReceive(timer) { _ in
 guard isAnimating else { return }
 phase = (phase + 1) % max(1, count)
 }
 }
}
