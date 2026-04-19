import SwiftUI

/// Settings sheet with categorized controls.
struct SettingsView: View {
 let sessionIndex: SessionIndex
 let sharedServices: SharedServices
 /// Injected by `RelayAppShell`. Owns atomic storage wipe AND the visible-
 /// state reset (`sessions = []`, `currentSessionId = nil`). The previous
 /// implementation deleted sessions one-by-one inside the settings view
 /// and never told the shell, so the sidebar kept showing ghost rows.
 var onClearAllSessions: (() async -> Void)? = nil

 @Environment(\.dismiss) private var dismiss
 @State private var showingFolderPicker = false
 @State private var authorizedFolders: [URL] = []
 @State private var themeMode: ThemeMode = ThemeManager.shared.mode
 @State private var mcpServerCount = 0
 @State private var isClearingHistory = false
 @State private var showClearHistoryConfirmation = false

 var body: some View {
 NavigationStack {
 List {
 Section {
 NavigationLink {
 MCPServersSection(sharedServices: sharedServices)
 } label: {
 connectionRow(title: "MCP Servers", systemImage: "server.rack") {
 if mcpServerCount > 0 {
 SettingsStatusPill(style: .neutral("\(mcpServerCount)"))
 }
 }
 }
 NavigationLink {
 GmailSettingsSection(sharedServices: sharedServices)
 } label: {
 connectionRow(title: "Gmail", systemImage: "envelope") {
 EmptyView()
 }
 }
 NavigationLink {
 CloudFallbackSection()
 } label: {
 connectionRow(title: "Cloud Fallback", systemImage: "cloud") {
 EmptyView()
 }
 }
 } header: {
 SettingsSectionHeader(title: "Connections")
 }

 Section {
 ForEach(authorizedFolders, id: \.path) { url in
 HStack(spacing: GlassSpacing.s) {
 SettingsMonochromeIcon(systemImage: "folder")
 Text(url.lastPathComponent)
 .glassType(.bodyEmphasis)
 .foregroundStyle(Color.glassText)
 Spacer()
 Text(url.path)
 .glassType(.caption)
 .foregroundStyle(Color.glassTextMuted)
 .lineLimit(1)
 }
 .padding(.horizontal, GlassSpacing.l)
 .padding(.vertical, 14)
 .glassSurface(.row)
 }
 .onDelete(perform: removeFolder)

 Button {
 showingFolderPicker = true
 } label: {
 SettingsRowLabel(title: "Add Folder", systemImage: "plus") {
 EmptyView()
 }
 }
 .buttonStyle(.relaySurfaceFeedback)
 } header: {
 SettingsSectionHeader(title: "Authorized Folders")
 } footer: {
 Text("Files in these folders are accessible to the agent.")
 .glassType(.caption)
 }

 Section {
 NavigationLink {
 MemoryFilesView(store: sharedServices.memoryStore ?? MemoryStore())
 } label: {
 SettingsRowLabel(title: "Memory", systemImage: "brain") {
 EmptyView()
 }
 }
 } header: {
 SettingsSectionHeader(title: "Data")
 }

 Section {
 HStack {
 SettingsMonochromeIcon(systemImage: "circle.lefthalf.filled")
 Text("Theme")
 .glassType(.bodyEmphasis)
 .foregroundStyle(Color.glassText)
 Spacer()
 Picker("Theme", selection: $themeMode) {
 ForEach(ThemeMode.allCases) { mode in
 Text(mode.label).tag(mode)
 }
 }
 .pickerStyle(.menu)
 .labelsHidden()
 }
 .padding(.horizontal, GlassSpacing.l)
 .padding(.vertical, 14)
 .glassSurface(.row)
 } header: {
 SettingsSectionHeader(title: "Appearance")
 }

 Section {
 settingsInfoRow(title: "Version", value: "v0.1 Beta")
 settingsInfoRow(title: "On-device reasoning", value: "Gemma-4-E2B")
 settingsInfoRow(title: "On-device transcription", value: "whisper-small")
 settingsInfoRow(title: "Cloud fallback", value: "Gemini 2.5 Flash-Lite")
 } header: {
 SettingsSectionHeader(title: "About")
 }

 Section {
 SettingsDangerZone {
 Button {
 showClearHistoryConfirmation = true
 } label: {
 clearChatHistoryRow
 }
 .buttonStyle(.relayGlass(.destructive))
 .disabled(isClearingHistory)
 .confirmationDialog(
 "Clear Chat History",
 isPresented: $showClearHistoryConfirmation,
 titleVisibility: .visible
 ) {
 Button("Clear All Sessions", role: .destructive) {
 Task { await clearAllSessions }
 }
 Button("Cancel", role: .cancel) {}
 } message: {
 Text("This will permanently delete all chat sessions. This action cannot be undone.")
 }
 }
 .listRowInsets(EdgeInsets(top: GlassSpacing.s, leading: GlassSpacing.m, bottom: GlassSpacing.s, trailing: GlassSpacing.m))
 .listRowBackground(Color.clear)
 .listRowSeparator(.hidden)
 } header: {
 SettingsSectionHeader(title: "Danger Zone")
 } footer: {
 Text("This permanently deletes every local conversation. Keep it visually and physically separate from normal settings.")
 .glassType(.caption)
 }
 }
 .settingsListChrome()
 .navigationTitle("Settings")
 .navigationBarTitleDisplayMode(.large)
 .safeAreaInset(edge: .top, spacing: 0) {
 SettingsTopActionBar {
 EmptyView()
 } trailing: {
 Button("Done") {
 dismiss
 }
 .buttonStyle(.relayGlass(.secondary, burst: .subtleTap))
 }
 }
 .sheet(isPresented: $showingFolderPicker) {
 FolderPicker { url in
 showingFolderPicker = false
 Task {
 if let fp = sharedServices.fileProvider {
 try? await fp.addAuthorization(url: url)
 }
 await loadFolders()
 }
 } onCancel: {
 showingFolderPicker = false
 }
 }
 .task {
 await loadFolders()
 await refreshConnectionState()
 }
 .onChange(of: themeMode) { _, newMode in
 ThemeManager.shared.mode = newMode
 }
 }
 }

 // MARK: - Connection row helpers

 /// Shared label for a connection row. The optional trailing view slot is
 /// where a state pill (count / connected) goes so MCP, Gmail, and any
 /// future connection read as the same vocabulary.
 @ViewBuilder
 private func connectionRow<Trailing: View>(
 title: String,
 systemImage: String,
 @ViewBuilder trailing:  () -> Trailing
 ) -> some View {
 SettingsRowLabel(title: title, systemImage: systemImage) {
 trailing()
 }
 }

 @ViewBuilder
 private func settingsInfoRow(title: String, value: String) -> some View {
 HStack {
 Text(title)
 .glassType(.bodyEmphasis)
 .foregroundStyle(Color.glassText)
 Spacer()
 Text(value)
 .glassType(.body)
 .foregroundStyle(Color.glassTextMuted)
 }
 .padding(.horizontal, GlassSpacing.l)
 .padding(.vertical, 14)
 .glassSurface(.row)
 }

 private func refreshConnectionState() async {
 mcpServerCount = await MCPConfigStore.shared.enabledServers().count
 }

 private func loadFolders() async {
 // Load from BookmarkStore
 let store = BookmarkStore()
 try? await store.loadAll()
 authorizedFolders = await store.allResolved()
 }

 private func removeFolder(at offsets: IndexSet) {
 let paths = offsets.map { authorizedFolders[$0].path }
 authorizedFolders.remove(atOffsets: offsets)
 Task {
 let store = BookmarkStore()
 try? await store.loadAll()
 for path in paths {
 try? await store.remove(path: path)
 }
 }
 }

 private func clearAllSessions() async {
 guard !isClearingHistory else { return }
 isClearingHistory = true
 defer { isClearingHistory = false }
 // Delegate to shell-owned closure: atomic `sessionIndex.deleteAll`
 // storage wipe + `RelayAppShell.sessions = []` /
 // `currentSessionId = nil` visible-state refresh, on MainActor.
 // SettingsView no longer reaches into storage — that was the cause
 // of the ghost-row bug.
 await onClearAllSessions?()
 }

 private var clearChatHistoryRow: some View {
 HStack {
 SettingsMonochromeIcon(systemImage: "trash")
 .foregroundStyle(Color.glassError)
 Text("Clear Chat History")
 .glassType(.bodyEmphasis)
 .foregroundStyle(Color.glassError)
 Spacer()
 if isClearingHistory {
 PixelStepIndicator(
 tint: Color.glassError,
 inactiveTint: Color.glassError.opacity(0.22),
 count: 3,
 blockSize: 5,
 spacing: 3
 )
 }
 }
 .contentShape(Rectangle())
 }
}

// MARK: - MCP Types

struct HeaderPair: Identifiable {
 let id = UUID()
 var key: String
 var value: String
}

struct ServerHealthSnapshot {
 let toolCount: Int?
 let toolNames: [String]
 let error: String?
 let checkedAt: Date
 let diagnostics: [MCPConnectionDiagnostic]
 let negotiatedProtocolVersion: String?

 var overallState: MCPConnectionPhaseState {
 if diagnostics.contains(where: { $0.state == .failure }) {
 return .failure
 }
 if diagnostics.contains(where: { $0.state == .warning }) {
 return .warning
 }
 if diagnostics.contains(where: { $0.state == .success }) {
 return .success
 }
 return .skipped
 }

 var primaryFailure: MCPConnectionFailure? {
 diagnostics.first(where: { $0.failure != nil })?.failure
 }
}

private func isSensitiveKey(_ key: String) -> Bool {
 let lower = key.lowercased()
 return lower.contains("authorization") || lower.contains("token")
 || lower.contains("secret") || lower.contains("api-key")
}

private func headersFromPairs(_ pairs: [HeaderPair]) -> [String: String] {
 var dict: [String: String] = [:]
 for pair in pairs {
 let key = pair.key.trimmingCharacters(in: .whitespacesAndNewlines)
 var value = pair.value.trimmingCharacters(in: .whitespacesAndNewlines)
 guard !key.isEmpty, !value.isEmpty else { continue }
 // SecureField hides the value, so paste mistakes (extra space, accidental
 // "Bearer " prefix on a raw-token header) are invisible until the first
 // tool call returns 401. Defend at save time: strip "Bearer " from
 // headers that take a raw token (Canvas, GitHub raw-PAT-style, etc.) —
 // the Authorization header is exempt because it legitimately starts
 // with "Bearer ".
 let lowerKey = key.lowercased()
 let rawTokenKey = lowerKey.contains("token")
 || lowerKey.contains("secret")
 || lowerKey.contains("api-key")
 if rawTokenKey, value.lowercased().hasPrefix("bearer ") {
 value = String(value.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
 guard !value.isEmpty else { continue }
 }
 dict[key] = value
 }
 return dict
}

private func pairsFromHeaders(_ headers: [String: String]) -> [HeaderPair] {
 headers.map { HeaderPair(key: $0.key, value: $0.value) }
}

private func hasDuplicateKeys(_ pairs: [HeaderPair]) -> Bool {
 let keys = pairs.map { $0.key.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
 .filter { !$0.isEmpty }
 return keys.count != Set(keys).count
}

// MARK: - MCP Servers Section

struct MCPServersSection: View {
 let sharedServices: SharedServices
 @State private var servers: [MCPServerConfig] = []
 @State private var showAddServer = false
 @State private var serverHealth: [String: ServerHealthSnapshot] = [:]

 var body: some View {
 List {
 if servers.isEmpty {
 Section {
 Text("No servers configured")
 .glassType(.body)
 .foregroundStyle(Color.glassTextMuted)
 } footer: {
 Text("Connect to external services like Canvas, GitHub, or Slack via MCP servers.")
 .glassType(.caption)
 }
 } else {
 Section {
 ForEach(servers) { server in
 NavigationLink {
 MCPServerDetail(
 server: server,
 sharedServices: sharedServices,
 onUpdate: { await loadServers() },
 onTestResult: { id, snapshot in serverHealth[id] = snapshot }
 )
 } label: {
 HStack {
 VStack(alignment: .leading, spacing: 2) {
 Text(server.name)
 .glassType(.bodyEmphasis)
 .foregroundStyle(Color.glassText)
 Text(server.baseURL.absoluteString)
 .glassType(.caption)
 .foregroundStyle(Color.glassTextMuted)
 .lineLimit(1)
 }
 Spacer()
 healthDot(for: server)
 }
 .padding(.horizontal, GlassSpacing.l)
 .padding(.vertical, 14)
 .glassSurface(.row)
 }
 }
 .onDelete { offsets in Task { await deleteServers(at: offsets) } }
 } header: {
 SettingsSectionHeader(title: "Servers (\(servers.count))")
 }
 }

 Section {
 Button { showAddServer = true } label: {
 SettingsRowLabel(title: "Add Server", systemImage: "plus") {
 EmptyView()
 }
 }
 .buttonStyle(.relaySurfaceFeedback)
 } header: {
 SettingsSectionHeader(title: "Actions")
 }
 }
 .navigationTitle("MCP Servers")
 .navigationBarTitleDisplayMode(.large)
 .settingsListChrome()
 .sheet(isPresented: $showAddServer) {
 MCPAddServerView(sharedServices: sharedServices,
 onSave: { Task { await loadServers } },
 onTestResult: { id, snapshot in serverHealth[id] = snapshot })
 }
 .task { await loadServers() }
 }

 @ViewBuilder
 private func healthDot(for server: MCPServerConfig) -> some View {
 if let health = serverHealth[server.id] {
 switch health.overallState {
 case .failure:
 HStack(spacing: 4) {
 RetroPixelBlock(color: Color.glassError, size: 8)
 }
 case .warning:
 HStack(spacing: 4) {
 if let count = health.toolCount {
 Text("\(count)")
 .glassType(.caption)
 .foregroundStyle(Color.glassTextMuted)
 }
 RetroPixelBlock(color: Color.glassWarning, size: 8)
 }
 case .success:
 HStack(spacing: 4) {
 if let count = health.toolCount {
 Text("\(count)")
 .glassType(.caption)
 .foregroundStyle(Color.glassTextMuted)
 }
 RetroPixelBlock(
 color: server.isEnabled ? Color.glassSuccess : Color.glassTextMuted.opacity(0.28),
 size: 8
 )
 }
 case .skipped:
 RetroPixelBlock(color: Color.glassTextMuted.opacity(0.28), size: 8)
 }
 } else {
 RetroPixelBlock(color: Color.glassTextMuted.opacity(0.28), size: 8)
 }
 }

 private func loadServers() async {
 servers = await MCPConfigStore.shared.allServers()
 }

 private func deleteServers(at offsets: IndexSet) async {
 for index in offsets {
 let server = servers[index]
 await sharedServices.mcpProvider?.removeClient(id: server.id)
 await MCPConfigStore.shared.remove(id: server.id)
 serverHealth.removeValue(forKey: server.id)
 }
 await loadServers()
 }
}

private struct MCPDiagnosticsCard: View {
 let snapshot: ServerHealthSnapshot

 var body: some View {
 VStack(alignment: .leading, spacing: GlassSpacing.s) {
 ForEach(snapshot.diagnostics) { diagnostic in
 HStack(spacing: GlassSpacing.s) {
 Text(diagnostic.phase.title)
 .glassType(.caption)
 Spacer()
 HStack(spacing: 6) {
 Image(systemName: iconName(for: diagnostic.state))
 .foregroundStyle(color(for: diagnostic.state))
 Text(diagnostic.message ?? "—")
 .glassType(.caption)
 .foregroundStyle(Color.glassTextMuted)
 .multilineTextAlignment(.trailing)
 }
 }
 }

 if let failure = snapshot.primaryFailure {
 Divider()
 VStack(alignment: .leading, spacing: 4) {
 Text(failure.headline)
 .glassType(.caption)
 if let detail = failure.detail, !detail.isEmpty {
 Text(detail)
 .glassType(.caption)
 .foregroundStyle(Color.glassTextMuted)
 .fixedSize(horizontal: false, vertical: true)
 }
 if let remediation = failure.remediation, !remediation.isEmpty {
 Text("Try: \(remediation)")
 .glassType(.caption)
 .foregroundStyle(Color.glassTextMuted)
 .fixedSize(horizontal: false, vertical: true)
 }
 }
 }

 if !snapshot.toolNames.isEmpty {
 Divider()
 VStack(alignment: .leading, spacing: 2) {
 ForEach(snapshot.toolNames, id: \.self) { name in
 Text("• \(name)")
 .glassType(.caption)
 .foregroundStyle(Color.glassTextMuted)
 }
 }
 }

 if let negotiatedProtocolVersion = snapshot.negotiatedProtocolVersion {
 Divider()
 Text("Protocol \(negotiatedProtocolVersion)")
 .glassType(.caption)
 .foregroundStyle(Color.glassTextMuted)
 }
 }
 .frame(maxWidth: .infinity, alignment: .leading)
 .padding(GlassSpacing.m)
 .glassSurface(.card)
 }

 private func iconName(for state: MCPConnectionPhaseState) -> String {
 switch state {
 case .success:
 return "checkmark.circle.fill"
 case .warning:
 return "exclamationmark.triangle.fill"
 case .failure:
 return "xmark.circle.fill"
 case .skipped:
 return "minus.circle"
 }
 }

 private func color(for state: MCPConnectionPhaseState) -> Color {
 switch state {
 case .success:
 return Color.glassSuccess
 case .warning:
 return Color.glassWarning
 case .failure:
 return Color.glassError
 case .skipped:
 return .secondary
 }
 }
}

// MARK: - Add Server

struct MCPAddServerView: View {
 let sharedServices: SharedServices
 let onSave:  () -> Void
 var onTestResult: ((String, ServerHealthSnapshot) -> Void)?

 @Environment(\.dismiss) private var dismiss
 /// Stable draft ID — shared between test and save so health snapshot attaches to the persisted server.
 @State private var draftId = UUID().uuidString
 @State private var name = ""
 @State private var baseURL = ""
 @State private var headerPairs: [HeaderPair] = []
 @State private var timeout: Double = 30
 @State private var testSnapshot: ServerHealthSnapshot?
 @State private var isTesting = false
 @State private var isSaving = false

 var body: some View {
 NavigationStack {
 Form {
 Section {
 SettingsFieldRow {
 TextField("Name", text: $name, prompt: Text("e.g. GitHub"))
 .glassType(.body)
 .foregroundStyle(Color.glassText)
 }
 SettingsFieldRow {
 TextField("Base URL", text: $baseURL, prompt: Text("https://mcp.example.com"))
 .glassType(.body)
 .foregroundStyle(Color.glassText)
 .textInputAutocapitalization(.never)
 .autocorrectionDisabled()
 }
 } header: {
 SettingsSectionHeader(title: "Server")
 }

 // Presets
 Section {
 Button {
 name = "Canvas"
 baseURL = "https://mcp.illinihunt.org/mcp"
 headerPairs = [
 HeaderPair(key: "X-Canvas-Token", value: ""),
 HeaderPair(key: "X-Canvas-URL", value: "")
 ]
 } label: {
 SettingsRowLabel(title: "Canvas LMS", systemImage: "graduationcap") {
 EmptyView()
 }
 }
 .buttonStyle(.relaySurfaceFeedback)

 Button {
 name = "GitHub"
 baseURL = "https://api.githubcopilot.com/mcp/"
 headerPairs = [
 HeaderPair(key: "Authorization", value: "Bearer ")
 ]
 } label: {
 SettingsRowLabel(title: "GitHub", systemImage: "chevron.left.forwardslash.chevron.right") {
 EmptyView()
 }
 }
 .buttonStyle(.relaySurfaceFeedback)

 Button {
 name = "Notion"
 baseURL = "https://mcp.notion.com/mcp"
 headerPairs = [
 HeaderPair(key: "Authorization", value: "Bearer ")
 ]
 } label: {
 SettingsRowLabel(title: "Notion", systemImage: "doc.text") {
 EmptyView()
 }
 }
 .buttonStyle(.relaySurfaceFeedback)
 } header: {
 SettingsSectionHeader(title: "Quick Setup")
 }

 // Headers
 Section {
 ForEach($headerPairs) { $pair in
 SettingsFieldRow {
 HStack(spacing: GlassSpacing.s) {
 TextField("Key", text: $pair.key)
 .glassType(.body)
 .foregroundStyle(Color.glassText)
 .textInputAutocapitalization(.never)
 .autocorrectionDisabled()
 .frame(maxWidth: .infinity)
 if isSensitiveKey(pair.key) {
 SecureField("Value", text: $pair.value)
 .glassType(.body)
 .foregroundStyle(Color.glassText)
 .frame(maxWidth: .infinity)
 } else {
 TextField("Value", text: $pair.value)
 .glassType(.body)
 .foregroundStyle(Color.glassText)
 .textInputAutocapitalization(.never)
 .autocorrectionDisabled()
 .frame(maxWidth: .infinity)
 }
 Button { headerPairs.removeAll() { $0.id == pair.id } } label: {
 Image(systemName: "minus")
 .font(.system(size: 12, weight: .bold))
 .frame(width: 22, height: 22)
 }
 .buttonStyle(.relayGlass(.iconError))
 .accessibilityLabel("Remove header")
 }
 }
 }
 Button { headerPairs.append(HeaderPair(key: "", value: "")) } label: {
 Label("Add Header", systemImage: "plus")
 .glassType(.body)
 }
 .buttonStyle(.relayGlass(.secondary, burst: .subtleTap))
 if hasDuplicateKeys(headerPairs) {
 Text("Duplicate header keys detected")
 .glassType(.caption)
 .foregroundStyle(Color.glassError)
 }
 } header: {
 SettingsSectionHeader(title: "Headers")
 } footer: {
 Text("Values for keys like Authorization, Token, or Secret are trimmed before saving, and sensitive keys still use secure entry automatically.")
 .glassType(.caption)
 }

 Section {
 SettingsFieldRow {
 HStack {
 Text("Timeout").glassType(.body)
 Spacer()
 Text("\(Int(timeout))s")
 .glassType(.numeric)
 .foregroundStyle(Color.glassTextMuted)
 }
 }
 SettingsFieldRow {
 Slider(value: $timeout, in: 5...120, step: 5)
 .tint(Color.glassAccent)
 }
 } header: {
 SettingsSectionHeader(title: "Options")
 }

 Section {
 Button { Task { await testConnection } } label: {
 HStack {
 Label("Test Connection", systemImage: "network")
 .glassType(.body)
 Spacer()
 if isTesting {
 PixelStepIndicator(
 tint: Color.glassText,
 inactiveTint: Color.glassTextMuted.opacity(0.22),
 count: 3,
 blockSize: 5,
 spacing: 3
 )
 }
 }
 }
 .buttonStyle(.relayGlass(.secondary, burst: .subtleTap))
 .disabled(isTesting || !isValid)
 } header: {
 SettingsSectionHeader(title: "Connection")
 }

 if let snapshot = testSnapshot {
 Section {
 MCPDiagnosticsCard(snapshot: snapshot)
 .listRowInsets(EdgeInsets(
 top: GlassSpacing.s,
 leading: GlassSpacing.m,
 bottom: GlassSpacing.s,
 trailing: GlassSpacing.m
 ))
 .listRowBackground(Color.clear)
 .listRowSeparator(.hidden)
 }
 }
 }
 .navigationTitle("Add Server")
 .navigationBarTitleDisplayMode(.large)
 .settingsListChrome()
 .safeAreaInset(edge: .top, spacing: 0) {
 SettingsTopActionBar {
 Button("Cancel") { dismiss }
 .buttonStyle(.relayGlass(.secondary, burst: .subtleTap))
 } trailing: {
 Button("Save") { Task { await save } }
 .buttonStyle(.relayGlass(.primary, burst: .buttonTap))
 .disabled(!isValid || isSaving || hasDuplicateKeys(headerPairs))
 }
 }
 }
 }

 private var isValid: Bool {
 !name.trimmingCharacters(in: .whitespaces).isEmpty &&
 URL(string: baseURL) != nil && baseURL.hasPrefix("http")
 }

 private func buildConfig() -> MCPServerConfig? {
 guard let url = URL(string: baseURL) else { return nil }
 return MCPServerConfig(id: draftId, name: name.trimmingCharacters(in: .whitespaces),
 baseURL: url, headers: headersFromPairs(headerPairs), timeout: timeout)
 }

 private func testConnection() async {
 guard let config = buildConfig() else {
 let snapshot = invalidURLSnapshot
 testSnapshot = snapshot()
 onTestResult?(draftId, snapshot())
 return
 }
 isTesting = true
 testSnapshot = nil
 let client = MCPClient(config: config)
 let report = await client.runConnectionDiagnostics(forceRefresh: true)
 let snapshot = snapshot(from: report)
 onTestResult?(config.id, snapshot)
 testSnapshot = snapshot
 isTesting = false
 }

 private func save() async {
 guard let config = buildConfig() else { return }
 isSaving = true
 await MCPConfigStore.shared.add(config)
 isSaving = false
 onSave()
 dismiss()
 }

 private func snapshot(from report: MCPConnectionReport) -> ServerHealthSnapshot {
 ServerHealthSnapshot(toolCount: report.toolCount,
 toolNames: report.toolNames,
 error: report.errorMessage,
 checkedAt: report.checkedAt,
 diagnostics: report.diagnostics,
 negotiatedProtocolVersion: report.negotiatedProtocolVersion)
 }

 private func invalidURLSnapshot() -> ServerHealthSnapshot {
 let failure = MCPConnectionFailure(
 category: .malformedResponse,
 headline: "Invalid URL",
 detail: "Base URL must be a valid http(s) endpoint.",
 remediation: "Fix the server URL before retrying Test Connection."
 )
 return ServerHealthSnapshot(
 toolCount: nil,
 toolNames: [],
 error: failure.headline,
 checkedAt: Date(),
 diagnostics: [
 .failure(.reachability, failure: failure),
 .skipped(.protocolCompatibility),
 .skipped(.initialize),
 .skipped(.discovery)
 ],
 negotiatedProtocolVersion: nil
 )
 }
}

// MARK: - Server Detail

struct MCPServerDetail: View {
 let server: MCPServerConfig
 let sharedServices: SharedServices
 let onUpdate:  () async -> Void
 var onTestResult: ((String, ServerHealthSnapshot) -> Void)?

 @Environment(\.dismiss) private var dismiss
 @State private var name: String = ""
 @State private var baseURL: String = ""
 @State private var headerPairs: [HeaderPair] = []
 @State private var timeout: Double = 30
 @State private var isEnabled: Bool = true
 @State private var testSnapshot: ServerHealthSnapshot?
 @State private var isTesting = false
 @State private var showDeleteConfirm = false

 var body: some View {
 Form {
 Section {
 SettingsFieldRow {
 TextField("Name", text: $name)
 .glassType(.body)
 .foregroundStyle(Color.glassText)
 }
 SettingsFieldRow {
 TextField("Base URL", text: $baseURL)
 .glassType(.body)
 .foregroundStyle(Color.glassText)
 .textInputAutocapitalization(.never)
 .autocorrectionDisabled()
 }
 } header: {
 SettingsSectionHeader(title: "Server")
 }

 Section {
 ForEach($headerPairs) { $pair in
 SettingsFieldRow {
 HStack(spacing: GlassSpacing.s) {
 TextField("Key", text: $pair.key)
 .glassType(.body)
 .foregroundStyle(Color.glassText)
 .textInputAutocapitalization(.never)
 .autocorrectionDisabled()
 .frame(maxWidth: .infinity)
 if isSensitiveKey(pair.key) {
 SecureField("Value", text: $pair.value)
 .glassType(.body)
 .foregroundStyle(Color.glassText)
 .frame(maxWidth: .infinity)
 } else {
 TextField("Value", text: $pair.value)
 .glassType(.body)
 .foregroundStyle(Color.glassText)
 .textInputAutocapitalization(.never)
 .autocorrectionDisabled()
 .frame(maxWidth: .infinity)
 }
 Button { headerPairs.removeAll() { $0.id == pair.id } } label: {
 Image(systemName: "minus")
 .font(.system(size: 12, weight: .bold))
 .frame(width: 22, height: 22)
 }
 .buttonStyle(.relayGlass(.iconError))
 .accessibilityLabel("Remove header")
 }
 }
 }
 Button { headerPairs.append(HeaderPair(key: "", value: "")) } label: {
 Label("Add Header", systemImage: "plus")
 .glassType(.body)
 }
 .buttonStyle(.relayGlass(.secondary, burst: .subtleTap))
 if hasDuplicateKeys(headerPairs) {
 Text("Duplicate header keys detected")
 .glassType(.caption)
 .foregroundStyle(Color.glassError)
 }
 } header: {
 SettingsSectionHeader(title: "Headers")
 }

 Section {
 SettingsFieldRow {
 Toggle("Enabled", isOn: $isEnabled)
 .glassType(.body)
 .tint(Color.glassAccent)
 }
 SettingsFieldRow {
 HStack {
 Text("Timeout").glassType(.body)
 Spacer()
 Text("\(Int(timeout))s")
 .glassType(.numeric)
 .foregroundStyle(Color.glassTextMuted)
 }
 }
 SettingsFieldRow {
 Slider(value: $timeout, in: 5...120, step: 5)
 .tint(Color.glassAccent)
 }
 } header: {
 SettingsSectionHeader(title: "Options")
 }

 Section {
 Button { Task { await testConnection } } label: {
 HStack {
 Label("Test Connection", systemImage: "network")
 .glassType(.body)
 Spacer()
 if isTesting {
 PixelStepIndicator(
 tint: Color.glassText,
 inactiveTint: Color.glassTextMuted.opacity(0.22),
 count: 3,
 blockSize: 5,
 spacing: 3
 )
 }
 }
 }
 .buttonStyle(.relayGlass(.secondary, burst: .subtleTap))
 .disabled(isTesting)
 } header: {
 SettingsSectionHeader(title: "Connection")
 }

 if let snapshot = testSnapshot {
 Section {
 MCPDiagnosticsCard(snapshot: snapshot)
 .listRowInsets(EdgeInsets(
 top: GlassSpacing.s,
 leading: GlassSpacing.m,
 bottom: GlassSpacing.s,
 trailing: GlassSpacing.m
 ))
 .listRowBackground(Color.clear)
 .listRowSeparator(.hidden)
 }
 }

 Section {
 Button("Delete Server", role: .destructive) { showDeleteConfirm = true }
 .buttonStyle(.relayGlass(.destructive, burst: .subtleTap))
 } header: {
 SettingsSectionHeader(title: "Actions")
 }
 }
 .navigationTitle(server.name)
 .navigationBarTitleDisplayMode(.large)
 .settingsListChrome()
 .safeAreaInset(edge: .top, spacing: 0) {
 SettingsTopActionBar {
 EmptyView()
 } trailing: {
 Button("Save") { Task { await saveChanges } }
 .buttonStyle(.relayGlass(.primary, burst: .buttonTap))
 .disabled(!isValid || hasDuplicateKeys(headerPairs))
 }
 }
 .onAppear {
 name = server.name
 baseURL = server.baseURL.absoluteString
 headerPairs = pairsFromHeaders(server.headers)
 timeout = server.timeout
 isEnabled = server.isEnabled
 }
 .confirmationDialog("Delete \(server.name)?", isPresented: $showDeleteConfirm) {
 Button("Delete", role: .destructive) { Task { await deleteServer } }
 } message: { Text("This server and its tools will be removed.") }
 }

 private var isValid: Bool {
 !name.trimmingCharacters(in: .whitespaces).isEmpty && URL(string: baseURL) != nil
 }

 private func testConnection() async {
 guard let url = URL(string: baseURL) else {
 let snapshot = invalidURLSnapshot
 testSnapshot = snapshot()
 onTestResult?(server.id, snapshot())
 return
 }
 isTesting = true
 testSnapshot = nil
 let config = MCPServerConfig(id: server.id, name: name, baseURL: url,
 headers: headersFromPairs(headerPairs), timeout: timeout)
 let client = MCPClient(config: config)
 let report = await client.runConnectionDiagnostics(forceRefresh: true)
 let snapshot = snapshot(from: report)
 testSnapshot = snapshot
 onTestResult?(server.id, snapshot)
 isTesting = false
 }

 private func saveChanges() async {
 guard let url = URL(string: baseURL) else { return }
 let updated = MCPServerConfig(id: server.id, name: name.trimmingCharacters(in: .whitespaces),
 baseURL: url, headers: headersFromPairs(headerPairs),
 isEnabled: isEnabled, timeout: timeout)
 await sharedServices.mcpProvider?.removeClient(id: server.id)
 await MCPConfigStore.shared.add(updated)
 await onUpdate()
 }

 private func deleteServer() async {
 await sharedServices.mcpProvider?.removeClient(id: server.id)
 await MCPConfigStore.shared.remove(id: server.id)
 await onUpdate()
 dismiss
 }

 private func snapshot(from report: MCPConnectionReport) -> ServerHealthSnapshot {
 ServerHealthSnapshot(toolCount: report.toolCount,
 toolNames: report.toolNames,
 error: report.errorMessage,
 checkedAt: report.checkedAt,
 diagnostics: report.diagnostics,
 negotiatedProtocolVersion: report.negotiatedProtocolVersion)
 }

 private func invalidURLSnapshot() -> ServerHealthSnapshot {
 let failure = MCPConnectionFailure(
 category: .malformedResponse,
 headline: "Invalid URL",
 detail: "Base URL must be a valid http(s) endpoint.",
 remediation: "Fix the server URL before retrying Test Connection."
 )
 return ServerHealthSnapshot(
 toolCount: nil,
 toolNames: [],
 error: failure.headline,
 checkedAt: Date(),
 diagnostics: [
 .failure(.reachability, failure: failure),
 .skipped(.protocolCompatibility),
 .skipped(.initialize),
 .skipped(.discovery)
 ],
 negotiatedProtocolVersion: nil
 )
 }
}

#Preview {
 SettingsView(sessionIndex: SessionIndex(), sharedServices: SharedServices())
}
