import SwiftUI

enum ChatHeaderModel: String, Sendable {
 case gemma = "Gemma"
 case gemini = "Gemini"

 var inactiveTint: Color {
 Color.glassTextMuted
 }

 func tint(active: Bool) -> Color {
 guard active else { return inactiveTint }
 switch self {
 case .gemma:
 return Color.glassText
 case .gemini:
 return Color.glassCloud
 }
 }

 var alternate: ChatHeaderModel {
 switch self {
 case .gemma:
 return .gemini
 case .gemini:
 return .gemma
 }
 }
}

struct ChatModelChip: View {
 let model: ChatHeaderModel
 var active: Bool = true

 private static let fixedWidth: CGFloat = 120

 var body: some View {
 HStack(spacing: GlassSpacing.xs) {
 RetroPixelBlock(color: model.tint(active: true), size: 7)
 .opacity(active ? 1 : 0.55)
 Text(model.rawValue)
 .glassType(.chatChip)
 .foregroundStyle(model.tint(active: active))
 }
 .frame(width: Self.fixedWidth, alignment: .center)
 .padding(.vertical, GlassSpacing.s)
 .frame(minHeight: 44)
 .glassSurface(.pill)
 .contentShape(RetroCutShape(cut: RetroMetrics.pillCut))
 .accessibilityElement(children: .ignore)
 .accessibilityLabel("Current model: \(model.rawValue)")
 }
}
