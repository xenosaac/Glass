import SwiftUI

/// Minimal listing of the on-device memory directory. Replaces the old
/// `MemoryBrowseView` (wings → halls → entries backed by the vector index)
/// with a plain file browser matching the Claude-Code-style file layout.
///
/// Shows: `MEMORY.md` if present, then each topic file with its filename
/// and (if parseable) the `description:` line from YAML frontmatter.
/// Swipe-to-delete drops the file via `MemoryStore`. No search, no
/// hierarchy — the files ARE the user-facing surface.
struct MemoryFilesView: View {
 let store: MemoryStore

 @State private var files: [FileRow] = []
 @State private var indexPreview: String?
 @State private var isLoading = true
 @State private var showClearConfirm = false

 struct FileRow: Identifiable, Equatable {
 let id: String
 let description: String?
 var path: String { id }
 }

 var body: some View {
 List {
 if isLoading {
 Section {
 SettingsInfoCard {
 HStack(spacing: GlassSpacing.s) {
 PixelStepIndicator(
 tint: Color.glassBorder,
 inactiveTint: Color.glassTextMuted.opacity(0.22),
 count: 3,
 blockSize: 5,
 spacing: 3
 )
 Text("Loading…")
 .glassType(.body)
 .foregroundStyle(Color.glassTextMuted)
 }
 .frame(maxWidth: .infinity, alignment: .leading)
 }
 }
 } else {
 if let preview = indexPreview {
 Section {
 SettingsInfoCard {
 Text(preview)
 .glassType(.caption)
 .foregroundStyle(Color.glassTextMuted)
 .textSelection(.enabled)
 }
 } header: {
 SettingsSectionHeader(title: "MEMORY.md")
 } footer: {
 Text("Loaded every turn into the system prompt. Trim it yourself or ask the model.")
 .glassType(.caption)
 }
 }

 Section {
 if files.isEmpty {
 SettingsInfoCard {
 Text("No memory files yet. Tell the agent something to remember.")
 .glassType(.caption)
 .foregroundStyle(Color.glassTextMuted)
 }
 } else {
 ForEach(files) { file in
 VStack(alignment: .leading, spacing: 2) {
 Text(file.path)
 .glassType(.bodyEmphasis)
 .foregroundStyle(Color.glassText)
 if let d = file.description {
 Text(d)
 .glassType(.caption)
 .foregroundStyle(Color.glassTextMuted)
 .lineLimit(2)
 }
 }
 .frame(maxWidth: .infinity, alignment: .leading)
 .padding(.horizontal, GlassSpacing.l)
 .padding(.vertical, 14)
 .glassSurface(.row)
 }
 .onDelete(perform: delete)
 }
 } header: {
 SettingsSectionHeader(title: "Topic files")
 }

 if !files.isEmpty || indexPreview != nil {
 Section {
 SettingsDangerZone {
 Button(role: .destructive) {
 showClearConfirm = true
 } label: {
 Label("Clear all memory", systemImage: "trash")
 }
 .buttonStyle(.relayGlass(.destructive, burst: .subtleTap))
 }
 .listRowInsets(EdgeInsets(top: GlassSpacing.s, leading: GlassSpacing.m, bottom: GlassSpacing.s, trailing: GlassSpacing.m))
 .listRowBackground(Color.clear)
 .listRowSeparator(.hidden)
 } header: {
 SettingsSectionHeader(title: "Danger Zone")
 }
 }
 }
 }
 .navigationTitle("Memory")
 .navigationBarTitleDisplayMode(.large)
 .settingsListChrome()
 .task { await refresh() }
 .refreshable { await refresh() }
 .confirmationDialog(
 "Clear all memory?",
 isPresented: $showClearConfirm,
 titleVisibility: .visible
 ) {
 Button("Delete everything", role: .destructive) {
 Task { await clearAll() }
 }
 Button("Cancel", role: .cancel) {}
 } message: {
 Text("Removes MEMORY.md and every topic file. This cannot be undone.")
 }
 }

 private func refresh() async {
 isLoading = true
 defer { isLoading = false }
 let index = await store.loadIndex(maxBytes: 4_000)
 indexPreview = index
 do {
 let names = try await store.listFiles()
 var rows: [FileRow] = []
 for name in names {
 let desc = try? await descriptionFromFrontmatter(path: name)
 rows.append(FileRow(id: name, description: desc))
 }
 files = rows
 } catch {
 files = []
 }
 }

 private func descriptionFromFrontmatter(path: String) async throws -> String? {
 let body = try await store.readFile(path)
 guard body.hasPrefix("---") else { return nil }
 let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
 for line in lines.dropFirst() {
 if line == "---" { break }
 if let range = line.range(of: "description:") {
 return line[range.upperBound...]
 .trimmingCharacters(in: .whitespaces)
 }
 }
 return nil
 }

 private func delete(at offsets: IndexSet) {
 let targets = offsets.map { files[$0].path }
 Task {
 for path in targets {
 try? await store.deleteFile(path)
 }
 await refresh()
 }
 }

 private func clearAll() async {
 try? await store.clearAll()
 await refresh()
 }
}
