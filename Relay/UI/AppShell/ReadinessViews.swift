import SwiftUI

struct PreparingView: View {
 @State private var simmerTrigger = 0
 @State private var logoSettled = false
 private let simmerTimer = Timer.publish(every: 0.95, on: .main, in: .common).autoconnect()

 var body: some View {
 ZStack {
 Color.glassPageBackground.ignoresSafeArea()

 VStack(spacing: GlassSpacing.l) {
 Image("AppLogo")
 .resizable()
 .scaledToFit()
 .frame(width: 72, height: 72)
 .clipShape(RetroCutShape(cut: 10))
 .overlay {
 PixelBurstEmitter(trigger: simmerTrigger, style: .heroSimmer)
 }
 .scaleEffect(logoSettled ? 1 : 0.94)
 .offset(y: logoSettled ? 0 : 6)
 .animation(RetroMotion.assistantReveal, value: logoSettled)

 Text("Glass")
 .glassType(.display)
 .foregroundStyle(Color.glassText)

 VStack(spacing: GlassSpacing.s) {
 PixelStepIndicator(
 tint: Color.glassAccent,
 inactiveTint: Color.glassAccent.opacity(0.24),
 count: 4,
 blockSize: 6,
 spacing: 4
 )
 Text("Preparing on-device model")
 .glassType(.caption)
 .foregroundStyle(Color.glassTextMuted)
 }
 .padding(.horizontal, GlassSpacing.l)
 .padding(.vertical, GlassSpacing.m)
 .glassSurface(.cardSubtle)
 }
 .padding(GlassSpacing.xl)
 }
 .onAppear {
 logoSettled = true
 simmerTrigger += 1
 }
 .onReceive(simmerTimer) { _ in
 simmerTrigger += 1
 }
 }
}

struct ModelUnavailableView: View {
 let message: String
 let whisperMissing: Bool
 let onRetry:  () -> Void

 var body: some View {
 ZStack {
 Color.glassPageBackground.ignoresSafeArea()

 VStack(spacing: GlassSpacing.l) {
 VStack(spacing: GlassSpacing.s) {
 Text("Glass is offline")
 .glassType(.title)
 .foregroundStyle(Color.glassText)

 Text(message)
 .glassType(.body)
 .multilineTextAlignment(.center)
 .foregroundStyle(Color.glassTextMuted)
 .frame(maxWidth: .infinity)

 if whisperMissing {
 Text("Voice is also unavailable because Whisper is missing from the bundle.")
 .glassType(.caption)
 .foregroundStyle(Color.glassTextMuted)
 .multilineTextAlignment(.center)
 }
 }
 .padding(GlassSpacing.l)
 .glassSurface(.card)

 Button {
 onRetry()
 } label: {
 Text("Retry")
 }
 .buttonStyle(.relayGlass(.primary, burst: .buttonTap))
 }
 .frame(maxWidth: 420)
 .padding(GlassSpacing.l)
 }
 }
}
