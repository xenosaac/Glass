import Observation
import SwiftUI

@MainActor
@Observable
final class CloudFallbackSectionModel {
 struct Dependencies {
 var loadResolvedKey: @Sendable  () -> String
 var saveKey: @Sendable (String) throws -> Void
 var deleteKey: @Sendable  () -> Void
 var reloadConfig: @Sendable  () -> Void
 var validateKey: @Sendable (String) async throws -> Void

 static let live = Dependencies(
 loadResolvedKey: { RelayConfig.shared.geminiAPIKey },
 saveKey: { try GeminiKeyStore.save($0) },
 deleteKey: { GeminiKeyStore.delete },
 reloadConfig: { RelayConfig.reloadGeminiKey },
 validateKey: { key in try await GeminiKeyValidator.validate(key) }
 )
 }

 var draftKey: String = ""
 var maskedStoredKey: String?
 var isWorking = false
 var errorMessage: String?

 private let dependencies: Dependencies

 init(dependencies: Dependencies = .live) {
 self.dependencies = dependencies
 }

 var trimmedDraft: String {
 draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
 }

 var hasStoredKey: Bool {
 maskedStoredKey != nil
 }

 var showsMaskedStoredKey: Bool {
 maskedStoredKey != nil && trimmedDraft.isEmpty
 }

 var canSave: Bool {
 !hasStoredKey && !trimmedDraft.isEmpty && !isWorking
 }

 var canRemove: Bool {
 hasStoredKey && !isWorking
 }

 func refresh() {
 let resolved = dependencies.loadResolvedKey.trimmingCharacters(in: .whitespacesAndNewlines)
 maskedStoredKey = resolved.isEmpty ? nil : Self.maskedKey(for: resolved)
 }

 func save() async -> Bool {
 guard !hasStoredKey else {
 errorMessage = "Remove the current key before saving a new one."
 return false
 }

 guard !trimmedDraft.isEmpty else {
 errorMessage = "Paste an API key first."
 return false
 }

 isWorking = true
 defer { isWorking = false }
 errorMessage = nil

 do {
 try await dependencies.validateKey(trimmedDraft)
 try dependencies.saveKey(trimmedDraft)
 dependencies.reloadConfig
 draftKey = ""
 refresh
 return true
 } catch {
 errorMessage = error.localizedDescription
 return false
 }
 }

 func remove() {
 errorMessage = nil
 dependencies.deleteKey
 dependencies.reloadConfig
 draftKey = ""
 refresh
 }

 private static func maskedKey(for key: String) -> String {
 let suffix = String(key.suffix(4))
 let maskCount = max(8, key.count - 4)
 return String(repeating: "•", count: maskCount) + suffix
 }
}

/// Settings sub-page for the Google Gemini cloud fallback.
///
/// The key now lives in a single inline field flow:
/// empty state: editable secure field + Save
/// configured state: masked stored key inline + Remove
/// changing keys requires Remove -> Paste new key -> Save
struct CloudFallbackSection: View {
 @State private var model = CloudFallbackSectionModel

 var body: some View {
 List {
 Section {
 statusCard
 .listRowInsets(EdgeInsets(
 top: GlassSpacing.s,
 leading: GlassSpacing.m,
 bottom: GlassSpacing.s,
 trailing: GlassSpacing.m
 ))
 .listRowBackground(Color.clear)
 .listRowSeparator(.hidden)
 } header: {
 SettingsSectionHeader(title: "Status")
 }

 Section {
 keyEditorCard
 .listRowInsets(EdgeInsets(
 top: GlassSpacing.s,
 leading: GlassSpacing.m,
 bottom: GlassSpacing.s,
 trailing: GlassSpacing.m
 ))
 .listRowBackground(Color.clear)
 .listRowSeparator(.hidden)
 } header: {
 SettingsSectionHeader(title: "API Key")
 } footer: {
 Text("Get a key at aistudio.google.com/apikey")
 .glassType(.caption)
 .foregroundStyle(Color.glassTextMuted)
 }

 Section {
 Text("When the on-device Gemma model flags a turn for cloud handoff, Glass re-runs it through Google Gemini 2.5 Flash-Lite. Invalid keys are not saved; Glass tests the key with a tiny greeting request before enabling cloud fallback.")
 .glassType(.caption)
 .foregroundStyle(Color.glassTextMuted)
 } header: {
 SettingsSectionHeader(title: "About")
 }
 }
 .settingsListChrome
 .navigationTitle("Cloud Fallback")
 .navigationBarTitleDisplayMode(.large)
 .task { model.refresh }
 }

 private var keyEditorCard: some View {
 SettingsInfoCard {
 VStack(alignment: .leading, spacing: GlassSpacing.m) {
 keyField

 HStack(spacing: GlassSpacing.s) {
 if model.canSave || model.isWorking {
 Button {
 Task {
 _ = await model.save
 }
 } label: {
 HStack(spacing: GlassSpacing.xs) {
 Label("Save Key", systemImage: "tray.and.arrow.down")
 .glassType(.body)
 if model.isWorking {
 PixelStepIndicator(
 tint: Color.glassBorder,
 inactiveTint: Color.glassTextMuted.opacity(0.22),
 count: 3,
 blockSize: 5,
 spacing: 3
 )
 }
 }
 }
 .buttonStyle(.relayGlass(.primary, burst: .buttonTap))
 .disabled(!model.canSave)
 }

 if model.canRemove {
 Button(role: .destructive) {
 model.remove
 } label: {
 Label("Remove Key", systemImage: "trash")
 .glassType(.body)
 }
 .buttonStyle(.relayGlass(.destructive, burst: .subtleTap))
 }
 }

 if let errorMessage = model.errorMessage {
 Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
 .glassType(.caption)
 .foregroundStyle(Color.glassError)
 .fixedSize(horizontal: false, vertical: true)
 }
 }
 }
 }

 private var statusCard: some View {
 SettingsInfoCard {
 HStack(alignment: .center, spacing: GlassSpacing.m) {
 Image(systemName: model.hasStoredKey ? "cloud.fill" : "cloud")
 .font(.system(size: 18, weight: .semibold))
 .foregroundStyle(model.hasStoredKey ? Color.glassSuccess : Color.glassTextMuted)

 VStack(alignment: .leading, spacing: 4) {
 Text(model.hasStoredKey ? "Connected" : "Not configured")
 .glassType(.bodyEmphasis)
 .foregroundStyle(model.hasStoredKey ? Color.glassSuccess : Color.glassText)

 Text(
 model.hasStoredKey
 ? "Gemini cloud fallback is ready to use."
 : "Add an API key to enable Gemini cloud fallback."
 )
 .glassType(.body)
 .foregroundStyle(Color.glassTextMuted)
 .fixedSize(horizontal: false, vertical: true)
 }

 Spacer(minLength: 0)
 }
 }
 }

 private var keyField: some View {
 HStack(spacing: GlassSpacing.s) {
 SettingsMonochromeIcon(systemImage: "key")

 Group {
 if let masked = model.maskedStoredKey, model.showsMaskedStoredKey {
 Text(masked)
 .glassType(.numeric)
 .foregroundStyle(Color.glassText)
 .lineLimit(1)
 } else {
 SecureField("Paste API key", text: $model.draftKey)
 .textContentType(.password)
 .autocorrectionDisabled
 .textInputAutocapitalization(.never)
 .glassType(.body)
 .accessibilityLabel("Gemini API key")
 }
 }

 Spacer(minLength: 0)
 }
 .padding(.horizontal, GlassSpacing.l)
 .padding(.vertical, GlassSpacing.m)
 .glassSurface(.field)
 }
}

#Preview {
 NavigationStack {
 CloudFallbackSection
 }
}
