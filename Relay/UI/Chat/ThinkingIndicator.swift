import SwiftUI

struct ThinkingIndicator: View {
 let isVisible: Bool

 var body: some View {
 if isVisible {
 HStack(spacing: GlassSpacing.s) {
 PixelStepIndicator(tint: Color.glassBorder, count: 4, blockSize: 5, spacing: 3)
 Text("Thinking…")
 .glassType(.caption)
 .foregroundStyle(Color.glassTextMuted)
 }
 .padding(.horizontal, GlassSpacing.m)
 .padding(.vertical, GlassSpacing.s)
 .frame(maxWidth: .infinity, alignment: .leading)
 .glassSurface(.pill)
 .transition(.opacity)
 }
 }
}
