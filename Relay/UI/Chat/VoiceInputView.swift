import SwiftUI

/// Full-screen voice input overlay.
/// Shows waveform, live transcript, and cancel/send controls.
struct VoiceInputView: View {
 let voiceEngine: VoiceEngine
 let onDismiss:  () -> Void
 @State private var pulseOpacity: Double = 1.0
 @State private var loadingPulse: Bool = false
 @Environment(\.colorScheme) private var colorScheme

 var body: some View {
 ZStack {
 Color.glassPageBackground
 .ignoresSafeArea

 VStack(spacing: GlassSpacing.xl) {
 Spacer(minLength: 0)

 VStack(spacing: GlassSpacing.l) {
 phaseLabel

 waveformView
 .frame(height: 72)
 .padding(.horizontal, GlassSpacing.l)
 .padding(.vertical, GlassSpacing.m)
 .glassSurface(.cardSubtle)

 transcriptPanel

 if voiceEngine.phase == .listening {
 Text(formatDuration(voiceEngine.recordingDuration))
 .glassType(.numeric)
 .foregroundStyle(Color.glassTextMuted)
 }
 }
 .frame(maxWidth: 440)

 Spacer(minLength: 0)

 controlBar
 .frame(maxWidth: 440)
 }
 .padding(.horizontal, GlassSpacing.l)
 .padding(.top, GlassSpacing.xl)
 .padding(.bottom, 40)
 }
 .onChange(of: voiceEngine.phase) { _, newPhase in
 // Auto-dismiss after finalize completes (didComplete set before phase → idle)
 if newPhase == .idle && voiceEngine.didComplete {
 onDismiss
 }
 }
 }

 // MARK: - Phase Label

 @ViewBuilder
 private var phaseLabel: some View {
 switch voiceEngine.phase {
 case .idle:
 EmptyView
 case .loadingWhisper:
 VStack(spacing: 12) {
 Image(systemName: "waveform")
 .font(.system(size: 28))
 .foregroundStyle(Color.glassBorder)
 .opacity(loadingPulse ? 0.3 : 0.8)
 .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: loadingPulse)
 .onAppear { loadingPulse = true }
 HStack(spacing: 8) {
 PixelStepIndicator(tint: Color.glassBorder, count: 3, blockSize: 5, spacing: 3)
 Text("Loading speech model…")
 .glassType(.body)
 .foregroundStyle(Color.glassTextMuted)
 }
 }
 .padding(.horizontal, GlassSpacing.l)
 .padding(.vertical, GlassSpacing.m)
 .glassSurface(.pill)
 case .listening:
 HStack(spacing: 8) {
 RetroPixelBlock(color: Color.glassError, size: 8)
 .opacity(pulseOpacity)
 .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulseOpacity)
 .onAppear { pulseOpacity = 0.4 }
 Text("Listening")
 .glassType(.body)
 .foregroundStyle(Color.glassTextMuted)
 }
 .padding(.horizontal, GlassSpacing.l)
 .padding(.vertical, GlassSpacing.m)
 .glassSurface(.pill)
 case .processing:
 HStack(spacing: 8) {
 PixelStepIndicator(tint: Color.glassBorder, count: 3, blockSize: 5, spacing: 3)
 Text("Finishing…")
 .glassType(.body)
 .foregroundStyle(Color.glassTextMuted)
 }
 .padding(.horizontal, GlassSpacing.l)
 .padding(.vertical, GlassSpacing.m)
 .glassSurface(.pill)
 case .error(let msg):
 HStack(spacing: 8) {
 Image(systemName: "exclamationmark.triangle.fill")
 .foregroundStyle(Color.glassError)
 Text(msg)
 .glassType(.body)
 .foregroundStyle(Color.glassTextMuted)
 .lineLimit(2)
 }
 .padding(.horizontal, GlassSpacing.l)
 .padding(.vertical, GlassSpacing.m)
 .glassSurface(.card)
 }
 }

 // MARK: - Waveform

 private let barCount = 16

 private var waveformView: some View {
 GeometryReader { geo in
 let spacing: CGFloat = 4
 let totalSpacing = spacing * CGFloat(barCount - 1)
 let barWidth = max(3, (geo.size.width - totalSpacing) / CGFloat(barCount))

 HStack(spacing: spacing) {
 ForEach(0..<barCount, id: \.self) { i in
 // Capsule (permitted exception — see DESIGN.md): waveform
 // bars are a visual primitive, not a card surface, so the
 // "no bespoke RoundedRectangle.fill" rule doesn't apply.
 // Capsule also sizes its rounding naturally to the bar
 // width, so we don't have to pick a hard-coded radius.
 Capsule
 .fill(voiceEngine.phase == .listening ? Color.glassAccent : Color.glassTextMuted.opacity(0.35))
 .frame(width: barWidth, height: barHeight(index: i, maxHeight: geo.size.height))
 }
 }
 .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
 .animation(.easeInOut(duration: 0.12), value: voiceEngine.audioLevel)
 }
 }

 // MARK: - Transcript

 private var transcriptPanel: some View {
 VStack(alignment: .leading, spacing: GlassSpacing.s) {
 transcriptView
 .frame(maxHeight: 140, alignment: .center)
 }
 .frame(maxWidth: .infinity)
 .padding(.horizontal, GlassSpacing.l)
 .padding(.vertical, GlassSpacing.l)
 .glassSurface(.card)
 }

 @ViewBuilder
 private var transcriptView: some View {
 let text = voiceEngine.partialTranscript
 if text.isEmpty {
 Text("Start speaking…")
 .glassType(.title)
 .foregroundStyle(Color.glassTextMuted)
 .italic
 .frame(maxWidth: .infinity)
 } else {
 ScrollView {
 Text(text)
 .glassType(.title)
 .foregroundStyle(Color.glassText)
 .multilineTextAlignment(.center)
 .frame(maxWidth: .infinity)
 }
 }
 }

 // MARK: - Controls

 private var controlBar: some View {
 HStack(spacing: 48) {
 Button {
 voiceEngine.cancel
 onDismiss
 } label: {
 Image(systemName: "xmark")
 .font(.system(size: 20, weight: .semibold))
 .frame(width: 56, height: 56)
 }
 .buttonStyle(.relayGlass(.iconSecondary))
 .disabled(voiceEngine.phase == .processing)

 if !isErrorPhase {
 let canSend = voiceEngine.phase == .listening
 Button {
 voiceEngine.finishAndSubmit
 } label: {
 Image(systemName: "arrow.up")
 .font(.system(size: 22, weight: .semibold))
 .frame(width: 60, height: 60)
 .scaleEffect(canSend ? 1.0 + CGFloat(voiceEngine.audioLevel) * 0.12 : 1.0)
 .animation(.easeOut(duration: 0.1), value: voiceEngine.audioLevel)
 }
 .buttonStyle(.relayGlass(.iconPrimary))
 .disabled(!canSend)
 }
 }
 .frame(maxWidth: .infinity)
 .padding(.horizontal, GlassSpacing.xl)
 .padding(.vertical, GlassSpacing.l)
 .glassSurface(colorScheme == .dark ? .card : .cardSubtle)
 }

 private var isErrorPhase: Bool {
 if case .error = voiceEngine.phase { return true }
 return false
 }

 // MARK: - Helpers

 private func barHeight(index: Int, maxHeight: CGFloat) -> CGFloat {
 let level = voiceEngine.audioLevel
 let base: CGFloat = 4
 // Deterministic variation per bar based on index + level
 let seed = sin(Double(index) * 1.3 + Double(level) * 10) * 0.5 + 0.5
 let variation = CGFloat(0.5 + seed * 0.5)
 let height = base + CGFloat(level) * (maxHeight - base) * variation
 return max(base, min(height, maxHeight))
 }

 private func formatDuration(_ seconds: TimeInterval) -> String {
 let mins = Int(seconds) / 60
 let secs = Int(seconds) % 60
 return String(format: "%d:%02d", mins, secs)
 }
}
