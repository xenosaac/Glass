import SwiftUI

/// Compact navigation glyph that means "open conversation list" rather than
/// "go back". Two aligned horizontal lines intentionally avoid the browser-
/// style chevron mental model.
struct ConversationListGlyph: View {
 var body: some View {
 VStack(alignment: .leading, spacing: 4) {
 RetroCutShape(cut: 1.5)
 .fill(Color.glassBorder)
 .frame(width: 17, height: 2.5)

 RetroCutShape(cut: 1.5)
 .fill(Color.glassBorder)
 .frame(width: 12, height: 2.5)
 }
 .frame(width: 22, height: 18, alignment: .leading)
 .accessibilityHidden(true)
 }
}

#Preview {
 ConversationListGlyph
 .padding
 .background(Color.glassPageBackground)
}
