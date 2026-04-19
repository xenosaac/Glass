import SwiftUI

struct ModelTierBadge: View {
 let tier: ModelTier

 var body: some View {
 HStack(spacing: GlassSpacing.xs + 1) {
 RetroPixelBlock(color: tierColor, size: 6)

 Text(tierLabel)
 .glassType(.caption)
 .fontWeight(.medium)
 }
 .foregroundStyle(tierColor)
 .padding(.horizontal, GlassSpacing.s)
 .padding(.vertical, GlassSpacing.xs)
 .glassSurface(.pill)
 }

 private var tierColor: Color {
 switch tier {
 case .fast, .quality:
 return Color.glassSuccess
 case .toolSpecialist:
 return Color.glassWarning
 case .cloud:
 return Color.glassCloud
 }
 }

 private var tierLabel: String {
 switch tier {
 case .fast:
 return "On-device"
 case .quality:
 return "On-device+"
 case .toolSpecialist:
 return "Tool Specialist"
 case .cloud:
 return "Cloud"
 }
 }
}
