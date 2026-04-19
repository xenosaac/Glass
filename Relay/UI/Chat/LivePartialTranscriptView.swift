import SwiftUI

struct LivePartialTranscriptView: View {
 let isVisible: Bool
 let partialText: String

 var body: some View {
 if isVisible {
 HStack(alignment: .top, spacing: GlassSpacing.s) {
 RetroPixelBlock(color: Color.glassError, size: 8)
 .padding(.top, 6)
 VStack(alignment: .leading, spacing: 2) {
 Text("Listening")
 .glassType(.sectionHeader)
 .foregroundStyle(Color.glassError)
 .textCase(.uppercase)
 Text(partialText.isEmpty ? "Speak now…" : partialText)
 .glassType(.body)
 .italic
 .foregroundStyle(Color.glassTextMuted)
 .multilineTextAlignment(.leading)
 .frame(maxWidth: .infinity, alignment: .leading)
 }
 }
 .padding(.horizontal, GlassSpacing.m)
 .padding(.vertical, GlassSpacing.s)
 .frame(maxWidth: .infinity, alignment: .leading)
 .glassSurface(.cardSubtle)
 .transition(.asymmetric(
 insertion: .opacity.combined(with: .move(edge: .bottom)),
 removal: .opacity
 ))
 }
 }
}
