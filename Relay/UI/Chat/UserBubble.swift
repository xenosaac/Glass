import SwiftUI

struct UserBubble: View {
 let content: UserContent

 var body: some View {
 HStack {
 Spacer(minLength: 60)

 VStack(alignment: .trailing, spacing: GlassSpacing.s) {
 ForEach(Array(content.blocks.enumerated()), id: \.offset) { _, block in
 blockView(block)
 }
 }
 .padding(.horizontal, GlassSpacing.l)
 .padding(.vertical, GlassSpacing.m)
 .foregroundStyle(Color.glassBorder)
 .glassSurface(.messageBubble)
 }
 }

 private func renderMarkdown(_ raw: String) -> AttributedString {
 let options = AttributedString.MarkdownParsingOptions(
 interpretedSyntax: .inlineOnlyPreservingWhitespace
 )
 return (try? AttributedString(markdown: raw, options: options))
 ?? AttributedString(raw)
 }

 @ViewBuilder
 private func blockView(_ block: UserBlock) -> some View {
 switch block {
 case .text(let text):
 Text(renderMarkdown(text))
 .glassType(.chatBody)
 .textSelection(.enabled)

 case .audioRef(let url):
 Label {
 Text("Audio: \(url.lastPathComponent)")
 .glassType(.caption)
 } icon: {
 Image(systemName: "waveform")
 .font(.caption.weight(.medium))
 }
 .foregroundStyle(Color.glassBorder.opacity(0.8))

 case .image(let url):
 AsyncImage(url: url) { image in
 image
 .resizable
 .scaledToFit
 .frame(maxWidth: 200)
 .clipShape(RetroCutShape(cut: 8))
 } placeholder: {
 PixelStepIndicator(
 tint: Color.glassBorder,
 inactiveTint: Color.glassBorder.opacity(0.22),
 count: 3,
 blockSize: 5,
 spacing: 3
 )
 .frame(width: 100, height: 100)
 }

 case .fileRef(let file):
 HStack(spacing: GlassSpacing.s) {
 Image(systemName: "doc.text")
 .font(.body.weight(.medium))
 .foregroundStyle(Color.glassBorder.opacity(0.85))
 VStack(alignment: .leading, spacing: 2) {
 Text(file.displayName)
 .glassType(.bodyEmphasis)
 .lineLimit(1)
 Text(file.contentTypeIdentifier)
 .glassType(.caption)
 .foregroundStyle(Color.glassBorder.opacity(0.75))
 .lineLimit(1)
 }
 Spacer(minLength: 0)
 }
 .padding(.horizontal, GlassSpacing.m)
 .padding(.vertical, GlassSpacing.s)
 .glassSurface(.pill)
 }
 }
}
