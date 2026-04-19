import SwiftUI

struct ToolCard: View {
 let name: String
 let status: ToolStatus
 let input: String
 let output: String?

 @State private var isExpanded = false

 var body: some View {
 VStack(alignment: .leading, spacing: 0) {
 Button {
 withAnimation(RetroMotion.chipToggle) {
 isExpanded.toggle
 }
 } label: {
 header
 }
 .buttonStyle(.relaySurfaceFeedback)

 if isExpanded {
 details
 .transition(.opacity.combined(with: .move(edge: .top)))
 }
 }
 .glassSurface(.cardSubtle)
 }

 private var header: some View {
 HStack(spacing: GlassSpacing.s) {
 statusIcon

 VStack(alignment: .leading, spacing: 2) {
 Text(displayName)
 .glassType(.bodyEmphasis)
 .foregroundStyle(Color.glassText)

 Text(statusText)
 .glassType(.caption)
 .foregroundStyle(statusColor)
 }

 Spacer

 Image(systemName: "chevron.down")
 .font(.caption.weight(.medium))
 .foregroundStyle(Color.glassTextMuted)
 .rotationEffect(.degrees(isExpanded ? 180 : 0))
 .animation(RetroMotion.quickFade, value: isExpanded)
 }
 .padding(.horizontal, GlassSpacing.m)
 .padding(.vertical, GlassSpacing.m)
 }

 private var details: some View {
 VStack(alignment: .leading, spacing: GlassSpacing.m) {
 Divider()
 .overlay(Color.glassBorder.opacity(0.25))
 .padding(.horizontal, GlassSpacing.m)

 VStack(alignment: .leading, spacing: GlassSpacing.xs) {
 Text("Input")
 .glassType(.sectionHeader)
 .foregroundStyle(Color.glassTextMuted)

 Text(formatJson(input))
 .glassType(.numeric)
 .foregroundStyle(Color.glassText)
 .textSelection(.enabled)
 .frame(maxWidth: .infinity, alignment: .leading)
 }

 if let output = output {
 VStack(alignment: .leading, spacing: GlassSpacing.xs) {
 Text("Output")
 .glassType(.sectionHeader)
 .foregroundStyle(Color.glassTextMuted)

 Text(output.prefix(500) + (output.count > 500 ? "…" : ""))
 .glassType(.body)
 .foregroundStyle(Color.glassText)
 .textSelection(.enabled)
 .frame(maxWidth: .infinity, alignment: .leading)
 }
 }
 }
 .padding(.horizontal, GlassSpacing.m)
 .padding(.bottom, GlassSpacing.m)
 }

 private var statusIcon: some View {
 Group {
 switch status {
 case .running:
 PixelStepIndicator(
 tint: Color.glassRunning,
 inactiveTint: Color.glassRunning.opacity(0.24),
 count: 3,
 blockSize: 5,
 spacing: 3
 )
 case .success:
 Image(systemName: "checkmark.circle.fill")
 .foregroundStyle(Color.glassSuccess)
 case .error:
 Image(systemName: "xmark.circle.fill")
 .foregroundStyle(Color.glassError)
 }
 }
 .frame(width: 22, height: 22)
 }

 private var statusText: String {
 switch status {
 case .running: return "Running…"
 case .success: return "Completed"
 case .error: return "Failed"
 }
 }

 private var statusColor: Color {
 switch status {
 case .running: return Color.glassRunning
 case .success: return Color.glassSuccess
 case .error: return Color.glassError
 }
 }

 private var displayName: String {
 name.split(separator: "_")
 .map { $0.capitalized() }
 .joined(separator: " ")
 }

 private func formatJson(_ json: String) -> String {
 guard let data = json.data(using: .utf8),
 let object = try? JSONSerialization.jsonObject(with: data),
 let pretty = try? JSONSerialization.data(withJSONObject: object, options: .prettyPrinted),
 let string = String(data: pretty, encoding: .utf8) else {
 return json
 }
 return string
 }
}

struct ContextBadge: View {
 let source: String

 var body: some View {
 HStack(spacing: GlassSpacing.xs) {
 Image(systemName: "doc.text.magnifyingglass")
 .font(.caption2.weight(.medium))
 Text("Context from \(source)")
 .glassType(.caption)
 }
 .foregroundStyle(Color.glassTextMuted)
 .padding(.horizontal, GlassSpacing.s)
 .padding(.vertical, GlassSpacing.xs)
 .glassSurface(.pill)
 }
}
