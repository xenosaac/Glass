import Foundation
import MessageUI
import Observation

/// Pending tool confirmation awaiting user Approve/Deny.
/// The responder fires exactly once — guarded by internal flag.
struct PendingConfirmation: Identifiable {
 let id = UUID()
 let toolUseId: String
 let toolName: String
 let prompt: String
 private let _respond: (Bool) -> Void
 private var fired = false

 init(toolUseId: String, toolName: String, prompt: String, respond: @escaping (Bool) -> Void) {
 self.toolUseId = toolUseId
 self.toolName = toolName
 self.prompt = prompt
 self._respond = respond
 }

 /// Resume the continuation. Safe to call multiple times — only the first fires.
 mutating func respond(_ approved: Bool) {
 guard !fired else { return }
 fired = true
 _respond(approved)
 }
}

/// Unified display type for rendering messages in the chat list.
enum DisplayMessage: Identifiable {
 case user(id: UUID, content: UserContent)
 case assistant(id: UUID, text: String, isStreaming: Bool)
 case toolExecution(id: UUID, toolUseId: String, name: String, status: ToolStatus, input: String, output: String?)
 case contextInjection(id: UUID, source: String)

 var id: UUID {
 switch self {
 case .user(let id, _): return id
 case .assistant(let id, _, _): return id
 case .toolExecution(let id, _, _, _, _, _): return id
 case .contextInjection(let id, _): return id
 }
 }
}

/// Tool execution status.
enum ToolStatus {
 case running
 case success
 case error
}

/// ViewModel for ChatView — manages state and AgentCore interaction.
@Observable
@MainActor
class ChatViewModel {
 // Display state
 var displayMessages: [DisplayMessage] = []
 /// Sanitized live streaming text (safe to display directly). Internal
 /// channel/thought markers are stripped via `AssistantSanitizer` before
 /// this is updated.
 var streamingText: String = ""
 /// Raw, unsanitized streaming accumulator. Sanitization runs over the
 /// full raw buffer on each token so markers that span token boundaries
 /// still get caught (a marker like `<|channel>thought` can arrive as
 /// three separate tokens).
 private var rawStreamingText: String = ""
 var routingTier: ModelTier = .fast
 var isRunning: Bool = false
 var agentStatus: AgentStatus = .idle
 var error: String?
 var sessionTitle: String = "Chat"
 var workspacePath: String?
 /// Full workspace URL for this session (if workspace-backed). The
 /// workspace path is surfaced to the model through the system prompt's
 /// Workspace context line; no UI chip consumes this today, but it's
 /// kept for tool permissions and future UI.
 var workspaceURL: URL?

 /// True while the shared Gemma model host is available. This does NOT
 /// check `agentCore != nil` — `agentCore` is lazily initialized on first
 /// `send`, so gating on it would wrongly block the very first message.
 /// Callers use this as a gate on "can a first send even start."
 var isModelReady: Bool {
 sharedServices.modelHost != nil
 }

 // Voice state
 var voiceEngine: VoiceEngine?
 var isVoiceActive: Bool = false
 /// Dictation result waiting to be drained into the composer text field.
 /// Set non-nil by the dictation completion path; consumed by the view's
 /// `.onChange` observer which copies the text into `composerDraft.text`
 /// and clears this back to nil. Never observed by the agent loop — this
 /// is a view-model ↔ view handoff only.
 var pendingComposerText: String?

 // Confirmation state
 var pendingConfirmation: PendingConfirmation?

 // Compose sheet presentation state (Mail / SMS)
 var pendingMailCompose: MailComposeData?
 var pendingSMSCompose: MessageComposeData?

 // Active tool tracking
 private var activeTools: [String: (name: String, input: String)] = [:]
 private var runningToolOrder: [String] = []

 // Last done message from handleEvent — persisted by send after the event loop
 private var lastDoneMessage: RelayMessage?

 // Dependencies
 private let sessionId: String
 private let sessionIndex: SessionIndex
 private let sharedServices: SharedServices
 private let sessionStore: SessionStore
 private var agentCore: AgentCore?
 /// post-turn bookkeeping lives in this coordinator, not
 /// inline in the view-model. Preserves the prior `persistMemoryForCompletedTurn`
 /// watermark-update behavior.
 private let memoryWritebackCoordinator: MemoryWritebackCoordinator
 private let commitCoordinator: TurnCommitCoordinator

 /// Callback to refresh the session sidebar (set by ChatView).
 var onSessionUpdated: (() -> Void)?

 // Loaded raw messages for AgentCore hydration
 private var rawHistory: [RelayMessage] = []

 // Workspace polling task was removed with the indexing chip — there's
 // nothing to poll now that MemoryMiner / folder indexing are gone.

 init(
 sessionId: String,
 sessionIndex: SessionIndex,
 sharedServices: SharedServices,
 agentCore: AgentCore? = nil
 ) {
 self.sessionId = sessionId
 self.sessionIndex = sessionIndex
 self.sharedServices = sharedServices
 self.sessionStore = SessionStore(sessionId: sessionId)
 // pass the shared MemoryStore so the
 // coordinator can deterministically write canonical declarative
 // facts ("My name is Isaac") without relying on Gemini to call
 // `memory_write` in cloud handoff. Falls back to nil for headless
 // / smoke-test paths that never set `sharedServices.memoryStore`.
 self.memoryWritebackCoordinator = MemoryWritebackCoordinator(
 sessionIndex: sessionIndex,
 memoryStore: sharedServices.memoryStore
 )
 self.commitCoordinator = TurnCommitCoordinator(
 sessionId: sessionId,
 sessionStore: self.sessionStore,
 sessionIndex: sessionIndex,
 memoryWritebackCoordinator: self.memoryWritebackCoordinator,
 runtimeSidecarStore: RuntimeSidecarStore(sessionId: sessionId)
 )
 self.agentCore = agentCore
 }

 // MARK: - Load

 func loadHistory() async {
 // Load session metadata
 if let metadata = await sessionIndex.get(sessionId) {
 sessionTitle = metadata.title
 workspacePath = metadata.workspaceURL?.lastPathComponent
 workspaceURL = metadata.workspaceURL
 }

 // Load message history (both for display and for AgentCore hydration).
 // Process sequentially (not flatMap) so tool-result replay can index
 // into the already-appended displayMessages array.
 do {
 let messages = try await sessionStore.loadAll()
 rawHistory = messages
 displayMessages = []
 pendingToolDisplayIds = [:]
 for message in messages {
 let items = convertToDisplay(message)
 displayMessages.append(contentsOf: items)
 }
 // Mark any tool calls that never received a result (session interrupted)
 for (_, idx) in pendingToolDisplayIds {
 if idx < displayMessages.count,
 case .toolExecution(let id, let tid, let name, _, let input, _) = displayMessages[idx] {
 displayMessages[idx] = .toolExecution(
 id: id, toolUseId: tid, name: name,
 status: .error, input: input,
 output: "(Session interrupted before result)"
 )
 }
 }
 pendingToolDisplayIds = [:]
 } catch {
 self.error = "Failed to load history: \(error.localizedDescription)"
 }
 }

 // MARK: - Send

 func send(_ text: String) async -> Bool {
 await send(envelope: TurnEnvelope(
 kind: .text,
 visibleText: text,
 source: .composerText
 ))
 }

 // MARK: - Voice

 /// Whether the Whisper model is available for voice input.
 var whisperModelAvailable: Bool {
 AppPaths.resolveWhisperSmall != nil
 }

 /// voice agent mode. Tap → record → VAD-finalize
 /// → AUTO-SUBMIT as a user turn. Replaces the older dictation flow
 /// (which landed transcript in `pendingComposerText` for manual review).
 /// Safety: the existing empty-transcript filter + R7-A+++ hallucination
 /// filter + 1.0s minRecordingSeconds gate prevent garbage submits.
 ///
 /// The dictation-into-composer code path is preserved as `startVoiceDictation`
 /// below for any future opt-in setting; the inline mic uses agent mode by default.
 func startVoice() {
 guard whisperModelAvailable else {
 error = "Voice is unavailable because Whisper is missing from the app bundle."
 return
 }

 guard let runtime = sharedServices.voiceRuntime else {
 error = "Voice runtime not initialized. Try restarting the app."
 return
 }

 if voiceEngine == nil {
 voiceEngine = VoiceEngine(voiceRuntime: runtime)
 }
 isVoiceActive = true

 voiceEngine?.startDictation(
 onTranscript: { [weak self] transcript in
 Task { @MainActor [weak self] in
 guard let self else { return }
 let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
 #if DEBUG
 print("VOICE_AGENT transcript_len=\(trimmed.count) auto-submitting")
 #endif
 self.isVoiceActive = false
 guard !trimmed.isEmpty else { return }
 // Auto-submit as a voice-source user turn — the agent
 // loop kicks immediately, no "hit send" step.
 let envelope = TurnEnvelope(
 kind: .voice,
 visibleText: trimmed,
 source: .composerVoice
 )
 Task { _ = await self.send(envelope: envelope) }
 }
 },
 onCancel: { [weak self] in
 Task { @MainActor [weak self] in
 self?.isVoiceActive = false
 }
 },
 onFailedTranscription: { [weak self] message in
 Task { @MainActor [weak self] in
 self?.isVoiceActive = false
 self?.error = message
 }
 }
 )
 }

 /// Manual-review dictation path — kept available but unwired from the
 /// inline mic post-R7-B. Lands transcript in `pendingComposerText`
 /// instead of auto-submitting. Reserved for a future opt-in setting.
 func startVoiceDictation() {
 guard whisperModelAvailable else {
 error = "Voice is unavailable because Whisper is missing from the app bundle."
 return
 }
 guard let runtime = sharedServices.voiceRuntime else {
 error = "Voice runtime not initialized. Try restarting the app."
 return
 }
 if voiceEngine == nil {
 voiceEngine = VoiceEngine(voiceRuntime: runtime)
 }
 isVoiceActive = true
 voiceEngine?.startDictation(
 onTranscript: { [weak self] transcript in
 Task { @MainActor [weak self] in
 let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
 #if DEBUG
 print("VOICE_DICTATION transcript_len=\(trimmed.count)")
 #endif
 self?.isVoiceActive = false
 if !trimmed.isEmpty {
 self?.pendingComposerText = trimmed
 }
 }
 },
 onCancel: { [weak self] in
 Task { @MainActor [weak self] in self?.isVoiceActive = false }
 },
 onFailedTranscription: { [weak self] message in
 Task { @MainActor [weak self] in
 self?.isVoiceActive = false
 self?.error = message
 }
 }
 )
 }

 /// Stop an in-progress recording and finalize. In voice-agent mode the
 /// transcript auto-submits; in dictation mode it lands in the composer.
 func stopVoice() {
 voiceEngine?.finishAndSubmit()
 }

 /// Cancel an in-progress dictation without transcribing. Used by
 /// explicit dismiss gestures (not wired today but available for future
 /// cancel affordance).
 func cancelVoice() {
 voiceEngine?.cancel()
 }

 func send(
 envelope: TurnEnvelope,
 onAccepted: (() -> Void)? = nil
 ) async -> Bool {
 guard !isRunning else { return false }
 let hasUserVisibleContent = envelope.prebuiltMessage != nil
 || !envelope.visibleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
 || envelope.audioRef != nil
 || !envelope.imageRefs.isEmpty
 || !envelope.fileRefs.isEmpty
 guard hasUserVisibleContent else { return false }

 isRunning = true
 agentStatus = .thinking
 error = nil
 streamingText = ""
 rawStreamingText = ""

 // Initialize AgentCore if needed
 if agentCore == nil {
 await initializeAgentCore()
 }

 guard let core = agentCore else {
 self.error = "Agent not initialized"
 isRunning = false
 agentStatus = .idle
 return false
 }

 let normalizedTurn: NormalizedTurn
 do {
 normalizedTurn = try await core.prepareTurn(envelope)
 } catch {
 self.error = error.localizedDescription
 isRunning = false
 agentStatus = .error(error.localizedDescription)
 return false
 }

 var didAcceptTurn = false
 if case .user(let userContent) = normalizedTurn.transcriptMessage {
 displayMessages.append(.user(id: UUID(), content: userContent))
 didAcceptTurn = true
 }

 let commitTrace = await commitCoordinator.commitAcceptedUserTurn(
 turnID: normalizedTurn.turnID,
 message: normalizedTurn.transcriptMessage,
 firstUserText: firstUserText(
 for: normalizedTurn.transcriptMessage,
 fallback: envelope.visibleText
 )
 )
 if commitTrace.didSucceed(.acceptedUserTranscriptAppended) {
 rawHistory.append(normalizedTurn.transcriptMessage)
 }
 if let metadata = await sessionIndex.get(sessionId) {
 sessionTitle = metadata.title
 }
 if didAcceptTurn {
 onAccepted?()
 }

 lastDoneMessage = nil
 do {
 for try await event in core.submit(normalizedTurn: normalizedTurn) {
 handleEvent(event)
 }
 } catch {
 self.error = error.localizedDescription
 agentStatus = .error(error.localizedDescription)
 }

 let runArtifacts = await core.consumeRunArtifacts(for: normalizedTurn.turnID)
 let completedWithDoneMessage = lastDoneMessage != nil
 if let msg = lastDoneMessage {
 let completedTrace = await commitCoordinator.commitCompletedTurn(
 acceptedUserMessage: normalizedTurn.transcriptMessage,
 assistantMessage: msg,
 wasVoiceTurn: envelope.audioRef != nil,
 trace: commitTrace
 )
 if completedTrace.didSucceed(.completedAssistantTranscriptAppended) {
 rawHistory.append(msg)
 }

 lastDoneMessage = nil
 } else if let runArtifacts, runArtifacts.exit.failureKind != nil {
 _ = await commitCoordinator.commitFailedTurn(
 runArtifacts: runArtifacts,
 canonicalTranscriptSnapshot: rawHistory,
 trace: commitTrace
 )
 }

 isRunning = false
 if !completedWithDoneMessage, error == nil, runningToolOrder.isEmpty {
 agentStatus = .idle
 }
 onSessionUpdated?()
 return didAcceptTurn
 }

 // MARK: - Event Handling

 func handleEvent(_ event: TurnEvent) {
 switch event {
 case .tokenReceived(let token):
 // Accumulate raw, render streaming-sanitized. The regex-based
 // `sanitize` only strips CLOSED blocks, so while a reasoning
 // block is still open it would let partial thought text flicker
 // into the bubble for a few frames before the closing marker
 // arrived and the regex retroactively removed it. The streaming
 // sanitizer is a state machine that drops the body of an open
 // hidden block entirely, preferring a momentarily-blank bubble
 // over ever showing the chain-of-thought. The authoritative
 // final cleanup still runs via `sanitize` in `.done` below.
 rawStreamingText += token
 streamingText = AssistantSanitizer.sanitizeStreaming(rawStreamingText)

 case .toolCallStarted(let name, let toolUseId, let inputJson):
 activeTools[toolUseId] = (name, inputJson)
 runningToolOrder.append(toolUseId)
 agentStatus = runningToolOrder.count == 1
 ? .callingTool(name)
 : .callingTool("\(runningToolOrder.count) tools")
 displayMessages.append(.toolExecution(
 id: UUID(),
 toolUseId: toolUseId,
 name: name,
 status: .running,
 input: inputJson,
 output: nil
 ))

 case .toolCallCompleted(let toolUseId, let result):
 // Find and update the tool card by toolUseId (not name — concurrent calls with same name exist)
 if let index = displayMessages.lastIndex(where: {
 if case .toolExecution(_, let tid, _, .running, _, _) = $0 {
 return tid == toolUseId
 }
 return false
 }) {
 if case .toolExecution(let id, let tid, let name, _, let input, _) = displayMessages[index] {
 displayMessages[index] = .toolExecution(
 id: id,
 toolUseId: tid,
 name: name,
 status: result.isError ? .error : .success,
 input: input,
 output: result.output
 )
 }
 }
 activeTools.removeValue(forKey: toolUseId)
 runningToolOrder.removeAll() { $0 == toolUseId }
 if runningToolOrder.isEmpty {
 agentStatus = .thinking
 } else if runningToolOrder.count == 1 {
 agentStatus = .callingTool(activeTools[runningToolOrder[0]]?.name ?? "tool")
 } else {
 agentStatus = .callingTool("\(runningToolOrder.count) tools")
 }

 // Handle UI presentation requests (Mail/SMS compose sheets)
 if result.metadata["requiresUIPresentation"] == "true",
 let uiType = result.metadata["uiType"],
 let payload = result.metadata["payload"] {
 switch uiType {
 case "mailCompose":
 if let data = MailComposeData.from(payload: payload) {
 pendingMailCompose = data
 }
 case "messageCompose":
 if let data = MessageComposeData.from(payload: payload) {
 pendingSMSCompose = data
 }
 default:
 break
 }
 }

 case .toolProgress(let toolUseId, let message):
 // Append progress to running tool card's output
 if let index = displayMessages.lastIndex(where: {
 if case .toolExecution(_, let tid, _, .running, _, _) = $0 { return tid == toolUseId }
 return false
 }) {
 if case .toolExecution(let id, let tid, let name, let status, let input, let existing) = displayMessages[index] {
 let updated = (existing ?? "") + (existing != nil ? "\n" : "") + message
 displayMessages[index] = .toolExecution(
 id: id, toolUseId: tid, name: name, status: status, input: input, output: updated
 )
 }
 }

 case .contextAdded(let source, _):
 displayMessages.append(.contextInjection(id: UUID(), source: source))

 case .routingDecision(let tier, _):
 routingTier = tier

 case .recoveryStateChanged(let state):
 agentStatus = .recovering(state)

 case .clearProvisionalOutput:
 streamingText = ""
 rawStreamingText = ""

 case .done(let message):
 // Sanitize the finalized message once, authoritatively. This
 // intercepts at the message-handling boundary so BOTH the
 // displayed assistant bubble AND the persisted RelayMessage
 // (via lastDoneMessage → sessionStore.append) are clean.
 let sanitizedMessage = Self.sanitizeAssistantMessage(message)
 let sanitizedText = Self.extractAssistantText(sanitizedMessage)

 #if DEBUG
 let rawText = Self.extractAssistantText(message)
 if AssistantSanitizer.hasInternalMarkup(rawText) {
 print("ASSISTANT_SANITIZE stripped raw_len=\(rawText.count) sanitized_len=\(sanitizedText.count)")
 }
 #endif

 if !sanitizedText.isEmpty {
 displayMessages.append(.assistant(id: UUID(), text: sanitizedText, isStreaming: false))
 } else if !rawStreamingText.isEmpty {
 // Sanitization stripped everything — the model produced
 // only internal-channel junk. Surface explicitly instead
 // of dropping silently or showing raw protocol markup.
 error = "The assistant produced no user-facing answer. Please try again."
 }
 streamingText = ""
 rawStreamingText = ""
 // Note: persistence moved to send after the event loop
 // so sidebar refresh sees the updated state. Store for caller.
 lastDoneMessage = sanitizedMessage
 agentStatus = .done
 // Auto-clear to idle after delay so "Done" is visible
 Task { @MainActor in
 try? await Task.sleep(for: .seconds(1.5))
 if agentStatus == .done { agentStatus = .idle }
 }

 case .failure(let message):
 streamingText = ""
 rawStreamingText = ""
 error = message
 agentStatus = .error(message)
 }
 }

 // MARK: - Helpers

 private func initializeAgentCore() async {
 // Wait for shared services if still loading
 // Pass sessionIndex through so a memory-palace rebuild path that
 // happens lazily from here (rare — usually the shell's pre-entry
 // task already ran loadIfNeeded() with sessionIndex) still has the
 // rehydration context.
 await sharedServices.loadIfNeeded(sessionIndex: sessionIndex)

 guard let host = sharedServices.modelHost else {
 if case .failed(let msg) = sharedServices.state {
 self.error = msg
 } else {
 self.error = "Model not available"
 }
 return
 }

 // Register tool providers (registry is per-session, lightweight)
 let registry = ToolRegistry()
 await registry.register(BuiltinToolProvider())
 await registry.register(FileToolProvider())
 await registry.register(AppIntentsToolProvider())
 await registry.register(GmailToolProvider())
 if let mcp = sharedServices.mcpProvider {
 await registry.register(mcp)
 }

 // Shared MemoryStore actor — both the agent (for loading MEMORY.md
 // into the system prompt each turn) and MemoryWriteTool (via the
 // service locator) must point at the same instance. Prefer the
 // process-wide singleton on SharedServices; fall back to a fresh
 // actor for smoke-test / headless paths that bypass the shell.
 let memoryStore = sharedServices.memoryStore ?? MemoryStore()
 let attachmentStore = AttachmentStore(sessionId: sessionId)

 // Build service locator from shared services
 let locator = DefaultServiceLocator(
 fileProvider: sharedServices.fileProvider,
 mcpProvider: sharedServices.mcpProvider,
 appIntents: sharedServices.appIntentsService,
 gmail: sharedServices.gmailService,
 memoryStore: memoryStore
 )

 // Session-scoped context. Workspace path feeds the `appendSystemContext`
 // path, which tags it as a "Workspace: ..." block at the tail of the
 // system prompt (standard pattern — utils/api.ts:437-447).
 let metadata = await sessionIndex.get(sessionId)
 let workspace = metadata?.workspaceURL
 var extraContext: [String: String] = [:]
 if let workspaceURL = workspace {
 extraContext["Workspace"] = workspaceURL.path
 }

 let core = AgentCore(
 host: host,
 registry: registry,
 config: .init(
 extraSystemContext: extraContext,
 memoryStore: memoryStore,
 attachmentStore: attachmentStore
 ),
 serviceLocator: locator,
 functionGemmaRuntime: sharedServices.functionGemmaRuntime,
 workspaceURL: workspace,
 transcriptSessionId: sessionId,
 onConfirmationNeeded: { [weak self] toolUseId, toolName, prompt in
 await withCheckedContinuation { continuation in
 Task { @MainActor in
 self?.pendingConfirmation = PendingConfirmation(
 toolUseId: toolUseId,
 toolName: toolName,
 prompt: prompt,
 respond: { approved in
 continuation.resume(returning: approved)
 }
 )
 }
 }
 }
 )

 // Hydrate conversation history so resumed sessions have context
 if !rawHistory.isEmpty {
 await core.hydrate(history: rawHistory)
 }

 agentCore = core
 }

 private func firstUserText(for message: RelayMessage, fallback: String) -> String? {
 let trimmedFallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
 if !trimmedFallback.isEmpty {
 return trimmedFallback
 }

 guard case .user(let content) = message else { return nil }
 let fileNames = content.blocks.compactMap { block -> String? in
 if case .fileRef(let file) = block { return file.displayName }
 return nil
 }
 if !fileNames.isEmpty {
 return "Attached: \(fileNames.joined(separator: ", "))"
 }
 if content.blocks.contains(where: {
 if case .image = $0 { return true }
 return false
 }) {
 return "Shared an image"
 }
 return nil
 }

 /// Pending tool uses from assistant messages, awaiting matching toolResult blocks.
 /// Keyed by toolUseId. Populated during convertToDisplay of assistant messages,
 /// consumed during convertToDisplay of toolResult messages.
 private var pendingToolDisplayIds: [String: Int] = [:]

 // MARK: - Assistant-text sanitization helpers

 /// Return a new `RelayMessage` with every assistant `.text` block's content
 /// run through `AssistantSanitizer`. Assistant `.toolUse` blocks are
 /// preserved unchanged. Empty-after-sanitize text blocks are dropped so a
 /// thought-only response collapses rather than persisting a `.text("")`.
 nonisolated static func sanitizeAssistantMessage(_ message: RelayMessage) -> RelayMessage {
 guard case .assistant(let content) = message else { return message }
 let scrubbed: [AssistantBlock] = content.blocks.compactMap { block in
 switch block {
 case .text(let raw):
 let clean = AssistantSanitizer.sanitize(raw)
 return clean.isEmpty ? nil : .text(clean)
 case .toolUse:
 return block
 }
 }
 return .assistant(AssistantContent(blocks: scrubbed))
 }

 /// Concatenate every `.text` block of an assistant message into a single
 /// display string. Tool-use blocks are rendered separately as tool cards,
 /// so they are intentionally excluded here.
 nonisolated static func extractAssistantText(_ message: RelayMessage) -> String {
 guard case .assistant(let content) = message else { return "" }
 return content.blocks.compactMap { block -> String? in
 if case .text(let t) = block { return t }
 return nil
 }.joined()
 }

 private static let systemReminderRegex: NSRegularExpression? = try? NSRegularExpression(
 pattern: "<system-reminder>[\\s\\S]*?</system-reminder>",
 options: [.dotMatchesLineSeparators, .caseInsensitive]
 )

 /// Remove any `<system-reminder>…</system-reminder>` substrings from a
 /// user turn's text blocks before display. Idempotent on clean input.
 private static func stripSystemReminders(from content: UserContent) -> UserContent {
 guard let regex = systemReminderRegex else { return content }
 let newBlocks: [UserBlock] = content.blocks.compactMap { block in
 switch block {
 case .text(let raw):
 let ns = raw as NSString
 let cleaned = regex.stringByReplacingMatches(
 in: raw,
 options: [],
 range: NSRange(location: 0, length: ns.length),
 withTemplate: ""
 ).trimmingCharacters(in: .whitespacesAndNewlines)
 return cleaned.isEmpty ? nil : .text(cleaned)
 case .audioRef, .image, .fileRef:
 return block
 }
 }
 return UserContent(blocks: newBlocks, isMeta: content.isMeta)
 }

 private func convertToDisplay(_ message: RelayMessage) -> [DisplayMessage] {
 switch message {
 case .user(let content):
 // Meta user messages (`<system-reminder>` injections, tool wrappers)
 // are delivered to the model but hidden from the transcript. Ports
 // the reference agent's `shouldShowUserMessage` at utils/messages.ts:4658.
 if content.isMeta { return [] }
 // Defense in depth: if a `<system-reminder>` block ever leaks into
 // a persisted user turn (e.g. a future refactor forgets to isMeta
 // it), strip it at display time so it never surfaces in the bubble.
 let cleaned = Self.stripSystemReminders(from: content)
 return [.user(id: UUID(), content: cleaned)]

 case .assistant(let content):
 var results: [DisplayMessage] = []
 var textBuffer = ""

 for block in content.blocks {
 switch block {
 case .text(let text):
 // Defensive read-side sanitize: pre-fix sessions may hold
 // persisted channel/thought markup. Authoritative write-
 // side sanitize happens in handleEvent(.done).
 textBuffer += AssistantSanitizer.sanitize(text)
 case .toolUse(let toolUse):
 if !textBuffer.isEmpty {
 results.append(.assistant(id: UUID(), text: textBuffer, isStreaming: false))
 textBuffer = ""
 }
 // Created as .success with nil output. toolResult block will overwrite
 // with actual output/status. Unresolved ones are caught in loadHistory.
 let idx = displayMessages.count + results.count
 pendingToolDisplayIds[toolUse.id] = idx
 results.append(.toolExecution(
 id: UUID(),
 toolUseId: toolUse.id,
 name: toolUse.name,
 status: .success,
 input: toolUse.inputJson,
 output: nil
 ))
 }
 }

 if !textBuffer.isEmpty {
 results.append(.assistant(id: UUID(), text: textBuffer, isStreaming: false))
 }

 return results

 case .toolResult(let blocks):
 // Retroactively update the matching tool cards with output and status
 for block in blocks {
 if let idx = pendingToolDisplayIds[block.toolUseId],
 idx < displayMessages.count,
 case .toolExecution(let id, let tid, let name, _, let input, _) = displayMessages[idx] {
 displayMessages[idx] = .toolExecution(
 id: id,
 toolUseId: tid,
 name: name,
 status: block.isError ? .error : .success,
 input: input,
 output: block.output
 )
 }
 pendingToolDisplayIds.removeValue(forKey: block.toolUseId)
 }
 return []
 }
 }
}
