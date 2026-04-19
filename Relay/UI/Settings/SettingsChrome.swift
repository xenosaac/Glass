import SwiftUI

struct SettingsSectionHeader: View {
 let title: String

 var body: some View {
 Text(title)
 .glassType(.settingsSectionHeader)
 .foregroundStyle(Color.glassText)
 .textCase(nil)
 .padding(.top, GlassSpacing.s)
 }
}

struct SettingsMonochromeIcon: View {
 let systemImage: String

 var body: some View {
 Image(systemName: systemImage)
 .font(.system(size: 16, weight: .semibold))
 .foregroundStyle(Color.glassBorder)
 .frame(width: 22, height: 22)
 }
}

struct SettingsStatusPill: View {
 enum Style {
 case neutral(String)
 case connected(String = "Connected")
 case destructive(String)
 }

 let style: Style

 var body: some View {
 HStack(spacing: GlassSpacing.xs) {
 if case .connected = style {
 RetroPixelBlock(color: Color.glassSuccess, size: 7)
 }

 Text(label)
 .glassType(.caption)
 .fontWeight(.medium)
 .foregroundStyle(labelColor)
 }
 .padding(.horizontal, GlassSpacing.s)
 .padding(.vertical, 6)
 .glassSurface(.pill)
 }

 private var label: String {
 switch style {
 case .neutral(let value), .connected(let value), .destructive(let value):
 return value
 }
 }

 private var labelColor: Color {
 switch style {
 case .neutral:
 return Color.glassTextMuted
 case .connected:
 return Color.glassSuccess
 case .destructive:
 return Color.glassError
 }
 }
}

struct SettingsTopActionBar<Leading: View, Trailing: View>: View {
 private let leading: Leading
 private let trailing: Trailing

 init(
 @ViewBuilder leading:  () -> Leading,
 @ViewBuilder trailing:  () -> Trailing
 ) {
 self.leading = leading()
 self.trailing = trailing()
 }

 var body: some View {
 HStack(spacing: GlassSpacing.s) {
 leading
 Spacer(minLength: GlassSpacing.s)
 trailing
 }
 .padding(.horizontal, GlassSpacing.m)
 .padding(.vertical, GlassSpacing.s)
 .glassSurface(.cardSubtle)
 .padding(.horizontal, GlassSpacing.m)
 .padding(.top, GlassSpacing.xs)
 .background(Color.glassPageBackground)
 }
}

struct SettingsRowLabel<Trailing: View>: View {
 let title: String
 let systemImage: String
 @ViewBuilder var trailing: Trailing

 var body: some View {
 HStack(spacing: GlassSpacing.m) {
 SettingsMonochromeIcon(systemImage: systemImage)

 Text(title)
 .glassType(.bodyEmphasis)
 .foregroundStyle(Color.glassText)

 Spacer(minLength: GlassSpacing.s)
 trailing
 }
 .padding(.horizontal, GlassSpacing.l)
 .padding(.vertical, 14)
 .frame(maxWidth: .infinity, alignment: .leading)
 .glassSurface(.row)
 }
}

struct SettingsInfoCard<Content: View>: View {
 @ViewBuilder var content: Content

 var body: some View {
 VStack(alignment: .leading, spacing: GlassSpacing.m) {
 content
 }
 .frame(maxWidth: .infinity, alignment: .leading)
 .padding(GlassSpacing.l)
 .glassSurface(.card)
 }
}

struct SettingsFieldRow<Content: View>: View {
 @ViewBuilder var content: Content

 var body: some View {
 VStack(alignment: .leading, spacing: GlassSpacing.s) {
 content
 }
 .frame(maxWidth: .infinity, alignment: .leading)
 .padding(.horizontal, GlassSpacing.l)
 .padding(.vertical, 14)
 .glassSurface(.field)
 }
}

struct SettingsDangerZone<Content: View>: View {
 @ViewBuilder var content: Content

 var body: some View {
 VStack(alignment: .leading, spacing: GlassSpacing.s) {
 content
 }
 .frame(maxWidth: .infinity, alignment: .leading)
 .padding(GlassSpacing.l)
 .glassSurface(.card)
 }
}

private struct SettingsListChrome: ViewModifier {
 func body(content: Content) -> some View {
 content
 .scrollContentBackground(.hidden)
 .background(Color.glassPageBackground)
 .listStyle(.plain)
 .environment(\.defaultMinListRowHeight, 54)
 }
}

extension View {
 func settingsListChrome() -> some View {
 modifier(SettingsListChrome())
 }
}
