import SwiftUI
import MessageUI

struct ContentView: View {
 @State private var log: [String] = []
 @State private var isRunning = false
 @State private var showingFolderPicker = false
 @State private var fileProvider: FileProvider?
 @State private var authorizedFolders: [URL] = []
 @State private var mcpProvider: MCPToolProvider?
 @State private var appIntentsService: SystemIntentsService?

 // MessageUI presentation state
 @State private var pendingMailCompose: MailComposeData?
 @State private var pendingSMSCompose: MessageComposeData?

 var body: some View {
 NavigationStack {
 ScrollView {
 LazyVStack(alignment: .leading, spacing: 4) {
 // Authorized folders section
 if !authorizedFolders.isEmpty {
 Text("Authorized Folders:")
 .font(.headline)
 .padding(.top, 8)
 ForEach(authorizedFolders, id: \.path) { url in
 Text(" \(url.lastPathComponent)")
 .font(.system(.caption, design: .monospaced))
 .foregroundStyle(.secondary)
 }
 Divider()
 .padding(.vertical, 8)
 }

 // Log output
 ForEach(Array(log.enumerated()), id: \.offset) { _, line in
 Text(line)
 .font(.system(.caption, design: .monospaced))
 .textSelection(.enabled)
 }
 }
 .padding()
 }
 .navigationTitle("Glass")
 .toolbar {
 ToolbarItemGroup(placement: .primaryAction) {
 Button("Add Folder") {
 showingFolderPicker = true
 }
 Button(isRunning ? "Running..." : "Run Smoke Test") {
 Task { await runSmokeTest }
 }
 .disabled(isRunning)
 }
 }
 .sheet(isPresented: $showingFolderPicker) {
 FolderPicker { url in
 showingFolderPicker = false
 Task { await addFolder(url) }
 } onCancel: {
 showingFolderPicker = false
 }
 }
 .sheet(item: $pendingMailCompose) { data in
 if canSendMail() {
 MailComposeView(data: data) { result in
 pendingMailCompose = nil
 switch result {
 case .sent:
 log.append("Email sent successfully")
 case .saved:
 log.append("Email saved as draft")
 case .cancelled:
 log.append("Email cancelled")
 case .failed(let error):
 log.append("Email failed: \(error?.localizedDescription ?? "unknown")")
 }
 }
 } else {
 VStack {
 Text("Cannot send email")
 .font(.headline)
 Text("Mail is not configured on this device")
 .foregroundStyle(.secondary)
 Button("Dismiss") { pendingMailCompose = nil }
 .padding()
 }
 }
 }
 .sheet(item: $pendingSMSCompose) { data in
 if canSendText() {
 MessageComposeView(data: data) { result in
 pendingSMSCompose = nil
 switch result {
 case .sent:
 log.append("Message sent successfully")
 case .cancelled:
 log.append("Message cancelled")
 case .failed:
 log.append("Message failed")
 }
 }
 } else {
 VStack {
 Text("Cannot send messages")
 .font(.headline)
 Text("iMessage is not configured on this device")
 .foregroundStyle(.secondary)
 Button("Dismiss") { pendingSMSCompose = nil }
 .padding()
 }
 }
 }
 }
 .task {
 await initializeProviders()
 }
 .onAppear {
 log.append("AppIntent Agent")
 log.append("Tap 'Add Folder' to grant file access.")
 log.append("Tap 'Run Smoke Test' to verify the agent loop.")
 }
 }

 @MainActor
 private func initializeProviders() async {
 // Initialize FileProvider
 let fp = FileProvider()
 do {
 try await fp.initialize()
 fileProvider = fp
 authorizedFolders = await fp.authorizedFolders()
 log.append("✅ FileProvider initialized (\(authorizedFolders.count) folders)")
 } catch {
 log.append("⚠️ FileProvider init failed: \(error)")
 fileProvider = fp
 }

 // Initialize MCPToolProvider
 if RelayConfig.shared.mcpEnabled {
 mcpProvider = MCPToolProvider()
 let serverCount = await MCPConfigStore.shared.enabledServers().count
 log.append("✅ MCPToolProvider initialized (\(serverCount) servers)")
 } else {
 log.append("⚠️ MCP disabled via MCP_ENABLED=false")
 }

 // Initialize SystemIntentsService (Calendar, Reminders, Mail, SMS)
 appIntentsService = SystemIntentsService()
 log.append("✅ SystemIntentsService initialized")
 }

 @MainActor
 private func addFolder(_ url: URL) async {
 guard let provider = fileProvider else {
 log.append("❌ FileProvider not initialized")
 return
 }
 do {
 try await provider.addAuthorization(url: url)
 authorizedFolders = await provider.authorizedFolders()
 log.append("✅ Added folder: \(url.lastPathComponent)")
 } catch {
 log.append("❌ Failed to add folder: \(error)")
 }
 }

 @MainActor
 private func runSmokeTest() async {
 isRunning = true
 log = ["--- smoke test start ---"]

 // Ensure directories exist
 do {
 try AppPaths.createIfNeeded()
 } catch {
 log.append("⚠️ Failed to create app directories: \(error)")
 }

 // Bundle-first, but device loads hydrate the bundled model into a
 // writable cache before Cactus initializes.
 let resolved: AppPaths.ResolvedModel
 do {
 guard let prepared = try await AppPaths.prepareGemmaE2BForLoad() else {
 log.append("❌ Gemma-4-E2B not found in app bundle or Documents fallback.")
 log.append("This should not happen in a properly built app — reinstall to recover.")
 isRunning = false
 return
 }
 resolved = prepared
 } catch {
 log.append("❌ Failed to prepare Gemma-4-E2B: \(error.localizedDescription)")
 isRunning = false
 return
 }
 let modelPath = resolved.url.path
 log.append("📦 model source: \(resolved.source.rawValue)")
 log.append("📁 model path: \(modelPath)")

 let host = CactusModelHost(modelPath: modelPath)

 log.append("Loading model from \(modelPath)...")
 do {
 try await host.load()
 log.append("✅ model loaded")
 } catch {
 log.append("❌ load failed: \(error)")
 isRunning = false
 return
 }

 // MemoryPalace removed — the smoke test now runs without RAG.
 // Work Stream C will introduce MemoryStore; add its init here then.

 // Register tool providers
 let registry = ToolRegistry()
 await registry.register(EchoToolProvider())
 await registry.register(BuiltinToolProvider())
 await registry.register(FileToolProvider())
 await registry.register(AppIntentsToolProvider())
 log.append("✅ AppIntentsToolProvider registered")
 await registry.register(GmailToolProvider())
 log.append("✅ GmailToolProvider registered")

 // Register MCP provider if available
 if let mcp = mcpProvider {
 await registry.register(mcp)
 let mcpTools = await mcp.tools(for: ToolCallContext(
 messages: [],
 session: AgentSession(id: "init", startedAt: Date()),
 approvalBroker: DefaultApprovalBroker(),
 progress: { _ in },
 services: DefaultServiceLocator()
 ))
 log.append("✅ MCPToolProvider registered (\(mcpTools.count) tools)")
 }

 // Inject all available services into service locator
 let locator = DefaultServiceLocator(
 fileProvider: fileProvider,
 mcpProvider: mcpProvider,
 appIntents: appIntentsService,
 gmail: GmailServiceImpl()
 )
 var services: [String] = []
 if fileProvider != nil { services.append("Files(\(authorizedFolders.count))") }
 if mcpProvider != nil { services.append("MCP") }
 if appIntentsService != nil { services.append("AppIntents") }
 log.append("\u{2705} Services: \(services.joined(separator: ", "))")

 let core = AgentCore(
 host: host,
 registry: registry,
 config: .init(
 completionOptions: .init(maxTokens: 100)
 ),
 serviceLocator: locator
 )

 log.append("Submitting: 'Say hello in one sentence.'")

 do {
 for try await event in core.submit("Say hello in one sentence.") {
 switch event {
 case .routingDecision(let tier, let reason):
 log.append("🔀 route: \(tier.rawValue) — \(reason)")
 case .recoveryStateChanged(let state):
 log.append("♻️ recovery: \(state.rawValue)")
 case .clearProvisionalOutput:
 log.append("🧹 clear provisional output")
 case .tokenReceived(let t):
 if let last = log.last, last.hasPrefix("💬 ") {
 log[log.count - 1] += t
 } else {
 log.append("💬 " + t)
 }
 case .toolCallStarted(let name, let id, _):
 log.append("🔧 tool call: \(name) [\(id.prefix(8))...]")
 case .toolCallCompleted(let id, let result):
 log.append(" \u{2192} \(result.isError ? "\u{274C}" : "\u{2705}") \(result.output.prefix(100))")
 _ = id
 // Handle UI presentation requests from tools
 if result.metadata["requiresUIPresentation"] == "true",
 let uiType = result.metadata["uiType"],
 let payload = result.metadata["payload"] {
 switch uiType {
 case "mailCompose":
 if let data = MailComposeData.from(payload: payload) {
 pendingMailCompose = data
 log.append("📧 Opening Mail compose...")
 }
 case "messageCompose":
 if let data = MessageComposeData.from(payload: payload) {
 pendingSMSCompose = data
 log.append("💬 Opening Message compose...")
 }
 default:
 log.append("⚠️ Unknown UI type: \(uiType)")
 }
 }
 case .toolProgress(let id, let msg):
 log.append(" ⏳ [\(id.prefix(8))] \(msg)")
 case .contextAdded(let source, _):
 log.append("📎 context: \(source)")
 case .done(let msg):
 if case .assistant(let content) = msg {
 let text = content.blocks.compactMap { block -> String? in
 if case .text(let t) = block { return t }
 return nil
 }.joined()
 log.append("✅ done: \(text.prefix(200))")
 } else {
 log.append("✅ done")
 }
 case .failure(let message):
 log.append("❌ failure: \(message)")
 }
 }
 } catch {
 log.append("❌ stream error: \(error)")
 }

 log.append("--- smoke test end ---")
 isRunning = false
 }
}

// MARK: - Test fixtures (inline, for smoke test only)

/// A simple tool that echoes its input. Used to verify the AgentCore turn loop.
private struct EchoTool: RelayTool {
 var name: String { "echo" }
 var description: String { "Echoes the input message back. Use this to test tool calling." }
 var inputSchema: ToolInputSchema {
 ToolInputSchema(json: #"{"type":"object","properties":{"message":{"type":"string","description":"The message to echo"}},"required":["message"]}"#)
 }
 var isConcurrencySafe: Bool { true }
 var isReadOnly: Bool { true }
 var isDestructive: Bool { false }

 func call(input: ToolInput, context: ToolCallContext) async throws -> ToolResult {
 let text = String(data: input.json, encoding: .utf8) ?? "{}"
 return ToolResult(toolUseId: "", output: "Echo: \(text)")
 }

 func policyDescriptor(input: ToolInput, context: ToolCallContext) async -> ToolPolicyDescriptor {
 .readOnly(domain: .builtin, operation: .read, summary: description)
 }
}

/// Wraps EchoTool as a ToolProvider so it can be registered with ToolRegistry.
private struct EchoToolProvider: ToolProvider {
 var providerName: String { "echo-test" }

 func tools(for context: ToolCallContext) async -> [any RelayTool] {
 [EchoTool()]
 }
}

#Preview {
 ContentView()
}
