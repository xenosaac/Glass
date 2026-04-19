import SwiftUI

struct AssistantBubble: View {
 let text: String
 let isStreaming: Bool
 @State private var burstTrigger = 0
 @State private var hasActiveStreamBurst = false

 private var renderedMarkdown: AttributedString {
 let options = AttributedString.MarkdownParsingOptions(
 interpretedSyntax: .inlineOnlyPreservingWhitespace
 )
 if let parsed = try? AttributedString(markdown: text, options: options) {
 return parsed
 }
 return AttributedString(text)
 }

 var body: some View {
 VStack(alignment: .leading, spacing: GlassSpacing.xs) {
 Text(renderedMarkdown)
 .glassType(.assistantBody)
 .foregroundStyle(Color.glassText)
 .textSelection(.enabled)
 .fixedSize(horizontal: false, vertical: true)

 if isStreaming {
 streamingIndicator
 }
 }
 .padding(.horizontal, GlassSpacing.l)
 .padding(.vertical, GlassSpacing.m)
 .frame(maxWidth: .infinity, alignment: .leading)
 .glassSurface(.cardSubtle)
 .overlay {
 PixelBurstEmitter(trigger: burstTrigger, style: .assistantReveal)
 }
 .onChange(of: isStreaming) { oldValue, newValue in
 if !oldValue, newValue, !hasActiveStreamBurst {
 hasActiveStreamBurst = true
 burstTrigger += 1
 } else if oldValue, !newValue {
 hasActiveStreamBurst = false
 }
 }
 }

 private var streamingIndicator: some View {
 PixelStepIndicator(
 tint: Color.glassBorder,
 inactiveTint: Color.glassBorder.opacity(0.22),
 count: 4,
 blockSize: 4,
 spacing: 3,
 isAnimating: isStreaming
 )
 .padding(.top, 2)
 }
}
