import SwiftUI

struct StatusBar: View {
 let status: AgentStatus
 let tier: ModelTier?

 var body: some View {
 if case .idle = status {
 EmptyView()
 } else {
 HStack(spacing: GlassSpacing.s) {
 statusView
 if let tier = tier {
 ModelTierBadge(tier: tier)
 }
 }
 .padding(.horizontal, GlassSpacing.m)
 .padding(.vertical, GlassSpacing.xs)
 .glassSurface(.pill)
 .animation(.easeOut(duration: 0.15), value: status)
 }
 }

 @ViewBuilder
 private var statusView: some View {
 switch status {
 case .idle:
 EmptyView()
 case .thinking:
 progressLabel("Thinking", color: Color.glassTextMuted)
 case .callingTool(let name):
 progressLabel(displayName(for: name), color: Color.glassTextMuted)
 case .recovering(let state):
 progressLabel(recoveryLabel(for: state), color: Color.glassTextMuted)
 case .done:
 label(icon: "checkmark", text: "Done", color: Color.glassSuccess)
 case .error(let message):
 label(icon: "exclamationmark.triangle", text: message, color: Color.glassError, lineLimit: 1)
 }
 }

 private func progressLabel(_ text: String, color: Color) -> some View {
 HStack(spacing: GlassSpacing.xs) {
 PixelStepIndicator(
 tint: color,
 inactiveTint: color.opacity(0.24),
 count: 3,
 blockSize: 5,
 spacing: 3
 )
 Text(text)
 .glassType(.caption)
 }
 .foregroundStyle(color)
 }

 private func label(icon: String, text: String, color: Color, lineLimit: Int? = nil) -> some View {
 HStack(spacing: GlassSpacing.xs) {
 Image(systemName: icon)
 .font(.caption2.weight(.semibold))
 Text(text)
 .glassType(.caption)
 .lineLimit(lineLimit)
 }
 .foregroundStyle(color)
 }

 private func displayName(for toolName: String) -> String {
 let pretty = toolName.split(separator: "_")
 .map { $0.capitalized }
 .joined(separator: " ")
 return "Calling \(pretty)"
 }

 private func recoveryLabel(for state: RecoveryDisplayState) -> String {
 switch state {
 case .retryingWithCloud:
 return "Retrying with Cloud"
 case .compactingContext:
 return "Reducing context"
 case .retryingAfterContextReduction:
 return "Retrying turn"
 case .cleaningUpInterruptedTurn:
 return "Cleaning up interrupted turn"
 }
 }
}

enum AgentStatus: Equatable {
 case idle
 case thinking
 case callingTool(String)
 case recovering(RecoveryDisplayState)
 case done
 case error(String)
}
