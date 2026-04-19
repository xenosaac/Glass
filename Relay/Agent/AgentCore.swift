import Foundation

/// The long-lived per-chat actor — Relay's equivalent of the reference agent's
/// `QueryEngine`. Owns the conversation state, the `ToolRegistry`, the
/// on-device `CactusModelHost`, and the session config. Each user turn
/// is delegated to `AgentRunner`; this actor is the stable surface that
/// UI + persistence code depends on.
///
/// harness extraction: the per-turn while-loop, message
/// pipeline, system-prompt assembly, and cloud fallback that previously
/// lived inline inside `runTurn` have been moved to `AgentRunner`,
/// `ContextBuilder`, and `MessagePipeline`. The public API on
/// `AgentCore` is unchanged — `ChatViewModel`'s `agentCore: AgentCore?`
/// reference continues to work without modification.
public actor AgentCore {

 // MARK: - Config

 public struct Config: Sendable {
 /// Runtime environment (model, platform, date) — feeds the environment
 /// section of the system prompt.
 public var environment: SystemPrompt.Environment

 public var completionOptions: CactusModelHost.CompletionOptions

 /// Session-scoped key/value pairs appended to the system prompt via
 /// `SystemPrompt.appendSystemContext` every turn. Use for things like
 /// `"Workspace": "/Users/…/projectDir"` — stable for the life of the
 /// AgentCore, but specific to this session.
 public var extraSystemContext: [String: String]

 /// Claude-Code-style persistent memory. When provided, every turn
 /// loads `MEMORY.md` and threads it into the system prompt's memory
 /// section. Nil disables the memory surface entirely.
 public var memoryStore: MemoryStore?

 /// per-session attachment store. When provided, every
 /// turn runs keyword retrieval against the session's ingested
 /// attachments and injects matching chunks as `isMeta: true`
 /// user messages immediately before the real user query. Nil
 /// disables attachment retrieval entirely — behavior
 /// byte-for-byte. `AgentCore.ingest(attachmentAt:displayName:)`
 /// requires this to be non-nil.
 public var attachmentStore: AttachmentStore?

 public init(
 environment: SystemPrompt.Environment = .current,
 completionOptions: CactusModelHost.CompletionOptions = .init(),
 extraSystemContext: [String: String] = [:],
 memoryStore: MemoryStore? = nil,
 attachmentStore: AttachmentStore? = nil
 ) {
 self.environment = environment
 self.completionOptions = completionOptions
 self.extraSystemContext = extraSystemContext
 self.memoryStore = memoryStore
 self.attachmentStore = attachmentStore
 }
 }

 // MARK: - Dependencies

 private let host: CactusModelHost
 public let registry: ToolRegistry
 private let approvalBroker: any ApprovalBroker
 private let serviceLocator: any ServiceLocator
 private let functionGemmaRuntime: SharedFunctionGemmaRuntime?
 private let onConfirmationNeeded: (@Sendable (_ toolUseId: String, _ toolName: String, _ prompt: String) async -> Bool)?
 private let runner: AgentRunner
 private let normalizer: TurnIngressNormalizer

 // MARK: - Conversation state

 /// Explicit long-lived runtime state. replaced the prior
 /// `var messages: [RelayMessage]` field with this struct so the
 /// harness reads/writes through a named container and future
 /// phases (compactor/budgeter/retrieval) have a clean place to
 /// thread their tracking fields.
 private var state: AgentSessionState = .empty
 private let session: AgentSession
 private var config: Config
 private var latestRunArtifactsByTurnID: [UUID: TurnRunArtifacts] = [:]

 // MARK: - Init

 public init(
 host: CactusModelHost,
 registry: ToolRegistry = ToolRegistry,
 config: Config = Config,
 approvalBroker: any ApprovalBroker = DefaultApprovalBroker,
 serviceLocator: any ServiceLocator = DefaultServiceLocator,
 workspaceURL: URL? = nil,
 transcriptSessionId: String = UUID().uuidString,
 onConfirmationNeeded: (@Sendable (_ toolUseId: String, _ toolName: String, _ prompt: String) async -> Bool)? = nil
 ) {
 self.init(
 host: host,
 registry: registry,
 config: config,
 approvalBroker: approvalBroker,
 serviceLocator: serviceLocator,
 functionGemmaRuntime: nil,
 workspaceURL: workspaceURL,
 transcriptSessionId: transcriptSessionId,
 onConfirmationNeeded: onConfirmationNeeded
 )
 }

 internal init(
 host: CactusModelHost,
 registry: ToolRegistry = ToolRegistry,
 config: Config = Config,
 approvalBroker: any ApprovalBroker = DefaultApprovalBroker,
 serviceLocator: any ServiceLocator = DefaultServiceLocator,
 functionGemmaRuntime: SharedFunctionGemmaRuntime? = nil,
 workspaceURL: URL? = nil,
 transcriptSessionId: String = UUID().uuidString,
 onConfirmationNeeded: (@Sendable (_ toolUseId: String, _ toolName: String, _ prompt: String) async -> Bool)? = nil
 ) {
 self.host = host
 self.registry = registry
 self.config = config
 self.approvalBroker = approvalBroker
 self.serviceLocator = serviceLocator
 self.functionGemmaRuntime = functionGemmaRuntime
 self.onConfirmationNeeded = onConfirmationNeeded
 self.runner = AgentRunner
 self.normalizer = TurnIngressNormalizer(sessionId: transcriptSessionId)
 self.session = AgentSession(id: UUID.uuidString, startedAt: Date, workspaceURL: workspaceURL)
 }

 /// Per-attempt Gemini client for the cloud-fallback path. Reads the
 /// current key from `RelayConfig.shared.geminiAPIKey` at call time so
 /// Settings-level edits (Save / Remove) take effect on the next
 /// fallback without having to tear down the session or recreate the
 /// agent. Constructor cost is trivial — struct + URLSession reference.
 private func currentGeminiClient() -> GeminiClient? {
 let key = RelayConfig.shared.geminiAPIKey
 return key.isEmpty ? nil : GeminiClient(apiKey: key)
 }

 /// Pre-populate conversation history from a prior session.
 ///
 /// Runs `ensureToolResultPairing` on the loaded history so display
 /// (built from `self.state.messages` by `ChatViewModel.loadHistory`)
 /// shows the same repaired shape that the API layer will see on
 /// the next inference. implements a placement at
 /// `services/api/claude.ts` where pairing runs before every API
 /// call; doing it here covers the resume-before-first-turn window
 /// where `runTurn` hasn't executed yet.
 ///
 /// also derives `turnCount` from the repaired history —
 /// counting non-meta user messages only. `<system-reminder>`
 /// meta-user messages are excluded from the count (they are model-
 /// facing metadata, not user turns). The runtime increment rule in
 /// `AgentRunner.run(...)` mirrors this so hydrate + runtime agree.
 public func hydrate(history: [RelayMessage]) {
 let (repaired, _) = CactusModelHost.ensureToolResultPairing(history)
 state = AgentSessionState.hydrated(from: repaired)
 }

 /// Clear conversation history (start fresh, keep the model loaded).
 public func clearHistory() {
 state = .empty
 }

 /// Number of messages in the current conversation.
 public var messageCount: Int { state.messages.count }

 /// ingest a user-imported text file as a session-scoped
 /// attachment. Out-of-band API; not part of the turn flow.
 ///
 /// Runs `AttachmentIndexer.ingest(...)` to produce an
 /// `Attachment` value, then persists it via the configured
 /// `AttachmentStore`. Subsequent turns will see matching chunks
 /// retrieved and injected as `isMeta: true` user messages when
 /// the user's query terms overlap with chunk content.
 ///
 /// Throws `AgentCoreError.attachmentStoreNotConfigured` when
 /// `config.attachmentStore == nil`. Rethrows any
 /// `AttachmentError` from the indexer (e.g., `.fileTooLarge`,
 /// `.unsupportedFormat`, `.readFailed`).
 @discardableResult
 public func ingest(
 attachmentAt url: URL,
 displayName: String,
 attachmentID: UUID = UUID()
 ) async throws -> Attachment {
 guard let store = config.attachmentStore else {
 throw AgentCoreError.attachmentStoreNotConfigured
 }
 let attachment = try AttachmentIndexer.ingest(
 fileURL: url,
 displayName: displayName,
 attachmentID: attachmentID
 )
 try await store.ingest(attachment)
 return attachment
 }

 /// Number of real user turns submitted this session (non-meta only).
 /// not yet consumed by external callers; exposed for
 /// tests and for /E compactor triggers.
 public var turnCount: Int { state.turnCount }

 internal func runtimeStateForTesting() -> AgentSessionState {
 state
 }

 internal func consumeRunArtifacts(for turnID: UUID) -> TurnRunArtifacts? {
 latestRunArtifactsByTurnID.removeValue(forKey: turnID)
 }

 // MARK: - Public API

 /// Submit a user turn. Returns a stream of events as the agent processes.
 ///
 /// The stream emits:
 /// `.routingDecision` — which model tier was selected
 /// `.tokenReceived` — streaming text tokens
 /// `.toolCallStarted` / `.toolCallCompleted` — if the model calls tools
 /// `.done(RelayMessage)` — final assistant message (end of turn)
 /// `.failure(message)` — if something goes wrong mid-turn
 public nonisolated func submit(_ userText: String) -> AsyncThrowingStream<TurnEvent, Error> {
 submit(envelope: TurnEnvelope(
 kind: .text,
 visibleText: userText,
 source: .programmatic
 ))
 }

 /// Submit a multimodal user turn with optional audio and image data.
 public nonisolated func submit(text: String, audioURL: URL? = nil, imageURL: URL? = nil) -> AsyncThrowingStream<TurnEvent, Error> {
 let kind: TurnKind
 if audioURL != nil && imageURL != nil {
 kind = .mixed
 } else if audioURL != nil {
 kind = .voice
 } else if imageURL != nil {
 kind = .image
 } else {
 kind = .text
 }
 return submit(envelope: TurnEnvelope(
 kind: kind,
 visibleText: text,
 audioRef: audioURL,
 imageRefs: imageURL.map { [$0] } ?? [],
 source: .programmatic
 ))
 }

 /// Submit a pre-built user message directly.
 public nonisolated func submit(message: RelayMessage) -> AsyncThrowingStream<TurnEvent, Error> {
 submit(envelope: TurnEnvelope(
 kind: .prebuilt,
 source: .programmatic,
 prebuiltMessage: message
 ))
 }

 /// New canonical ingress path. Callers that already own a structured turn
 /// should use this instead of reconstructing legacy overloads.
 public nonisolated func submit(envelope: TurnEnvelope) -> AsyncThrowingStream<TurnEvent, Error> {
 return AsyncThrowingStream { continuation in
 let task = Task {
 do {
 let normalizedTurn = try await self.prepareTurn(envelope)
 try await self.runPreparedTurn(
 normalizedTurn: normalizedTurn,
 continuation: continuation
 )
 continuation.finish()
 } catch {
 continuation.finish(throwing: error)
 }
 }
 continuation.onTermination = { _ in task.cancel }
 }
 }

 /// Canonical model-execution entry after ingress normalization. Exposed
 /// internally so the UI can persist the transcript shape before the model
 /// starts while still reusing the same turn runner.
 nonisolated func submit(normalizedTurn: NormalizedTurn) -> AsyncThrowingStream<TurnEvent, Error> {
 AsyncThrowingStream { continuation in
 let task = Task {
 do {
 try await self.runPreparedTurn(
 normalizedTurn: normalizedTurn,
 continuation: continuation
 )
 continuation.finish()
 } catch {
 continuation.finish(throwing: error)
 }
 }
 continuation.onTermination = { _ in task.cancel }
 }
 }

 public func prepareTurn(_ envelope: TurnEnvelope) async throws -> NormalizedTurn {
 let normalizedTurn = try await normalizer.normalize(envelope)
 try await ingestPendingFiles(normalizedTurn.pendingFileIngestions)
 return normalizedTurn
 }

 // MARK: - Turn entry point

 private func runPreparedTurn(
 normalizedTurn: NormalizedTurn,
 continuation: AsyncThrowingStream<TurnEvent, Error>.Continuation
 ) async throws {
 try await runTurn(
 normalizedTurn: normalizedTurn,
 continuation: continuation
 )
 }

 private func runTurn(
 normalizedTurn: NormalizedTurn,
 continuation: AsyncThrowingStream<TurnEvent, Error>.Continuation
 ) async throws {
 let acceptedUserMessage = normalizedTurn.transcriptMessage
 #if DEBUG
 // Appends the user message conceptually before the log, matching
 // the pre-carve log order. Actual append happens inside
 // `AgentRunner.run(...)`.
 let logMessages = state.messages + [acceptedUserMessage]
 print("[DEBUG_MEMORY] === Turn Start ===")
 print("[DEBUG_MEMORY] Total messages: \(logMessages.count)")
 for (i, msg) in logMessages.enumerated() {
 switch msg {
 case .user(let u):
 let text = u.blocks.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined()
 print("[DEBUG_MEMORY] [\(i)] USER: \(text.prefix(100))...")
 case .assistant(let a):
 let text = a.blocks.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined()
 print("[DEBUG_MEMORY] [\(i)] ASSISTANT: \(text.prefix(100))...")
 case .toolResult(let r):
 print("[DEBUG_MEMORY] [\(i)] TOOL_RESULT: \(r.count) results")
 }
 }
 #endif

 // compaction checkpoint. Runs BEFORE the new user
 // message is appended so the compactor summarizes prior
 // history only — the brand-new input flows into state via
 // `runner.run(..., initialUserMessage: message, ...)` below,
 // AFTER compaction has finalized. Timing pinned by
 // `test_compactor_timing_seesPriorHistoryOnly`.
 let compactor = Compactor(modelClient: host)
 if await compactor.shouldCompact(state: state) {
 let (newState, didCompact) = await compactor.compact(state: state)
 state = newState
 #if DEBUG
 if didCompact {
 print("[DEBUG_MEMORY] Compaction fired: state.messages now \(state.messages.count) (prior history summarized into boundary)")
 }
 #endif
 }

 // Gather tools once per turn (tools don't change mid-turn).
 let requestedAtTurnCount = state.turnCount + (
 {
 if case .user(let content) = acceptedUserMessage, !content.isMeta { return 1 }
 return 0
 }
 )
 let confirmationHandler: (@Sendable (_ toolUseId: String, _ toolName: String, _ prompt: String) async -> Bool)?
 if let onConfirmationNeeded {
 confirmationHandler = { [weak self] toolUseId, toolName, prompt in
 guard let self else { return false }
 return await self.handleApprovalRequest(
 toolUseId: toolUseId,
 toolName: toolName,
 prompt: prompt,
 requestedAtTurnCount: requestedAtTurnCount,
 handler: onConfirmationNeeded
 )
 }
 } else {
 confirmationHandler = nil
 }
 let dispatcher = ToolDispatcher(confirmationHandler: confirmationHandler)
 let initialContext = makeContext(continuation: continuation, overridingMessages: state.messages + [acceptedUserMessage])
 let gatherStart = CFAbsoluteTimeGetCurrent()
 let tools = await registry.gatherAll(for: initialContext)
 let toolCatalog = await registry.catalog(for: initialContext)
 let gatherMs = (CFAbsoluteTimeGetCurrent() - gatherStart) * 1000
 print("[Perf] Tool gather: \(String(format: "%.1f", gatherMs))ms (\(tools.count) tools)")

 let enabledToolNames = Set(tools.map { $0.name })

 // Build per-turn ContextBuilder (memory + pipeline).
 let contextBuilder = ContextBuilder(
 memoryStore: config.memoryStore,
 attachmentStore: config.attachmentStore,
 workspaceURL: session.workspaceURL,
 fileProvider: serviceLocator.fileProvider
 )

 // Resolve cloud client at turn start (matches the prior
 // `currentGeminiClient` semantic: mid-turn key changes apply
 // to the next turn, not this one).
 let onDeviceAdapter = CactusOnDeviceHostAdapter(host: host)
 let cloudAdapter = currentGeminiClient.map { GeminiCloudHostAdapter(client: $0) }
 let toolSpecialistAdapter = functionGemmaRuntime.map { FunctionGemmaToolHostAdapter(runtime: $0) }

 // Capture non-isolated dependencies so the tool-context factory
 // closure is Sendable without re-entering this actor.
 let capturedSession = session
 let capturedApprovalBroker = approvalBroker
 let capturedServices = serviceLocator
 let toolContextFor: @Sendable ([RelayMessage]) -> ToolCallContext = { currentMessages in
 ToolCallContext(
 messages: currentMessages,
 session: capturedSession,
 approvalBroker: capturedApprovalBroker,
 progress: { progress in
 continuation.yield(.toolProgress(
 toolUseId: progress.toolUseId,
 message: progress.message
 ))
 },
 services: capturedServices
 )
 }

 // Hand off to the per-turn state machine.
 let runResult = await runner.runWithArtifacts(
 turnID: normalizedTurn.turnID,
 sessionID: session.id,
 initialTurn: normalizedTurn,
 state: state,
 contextBuilder: contextBuilder,
 onDeviceClient: onDeviceAdapter,
 cloudClient: cloudAdapter,
 toolSpecialistClient: toolSpecialistAdapter,
 dispatcher: dispatcher,
 toolContextFor: toolContextFor,
 tools: tools,
 toolCatalog: toolCatalog,
 enabledToolNames: enabledToolNames,
 environment: config.environment,
 extraSystemContext: config.extraSystemContext,
 options: config.completionOptions,
 recoveryCompactor: compactor,
 continuation: continuation
 )
 let newState = runResult.state
 latestRunArtifactsByTurnID[normalizedTurn.turnID] = runResult.artifacts

 // Runner's returned state is authoritative for this turn
 // (updated messages + incremented turnCount if non-meta).
 if confirmationHandler != nil {
 var mergedState = newState
 mergedState.pendingApprovalState = state.pendingApprovalState
 state = mergedState
 return
 }
 state = newState
 }

 private func ingestPendingFiles(_ pendingFiles: [PendingFileIngestion]) async throws {
 guard !pendingFiles.isEmpty else { return }
 guard let store = config.attachmentStore else {
 throw AgentCoreError.attachmentStoreNotConfigured
 }
 let attachments = try pendingFiles.map { file in
 guard TurnIngressNormalizer.supportsFileType(file.contentTypeIdentifier) else {
 throw TurnIngressError.unsupportedFileType(file.displayName)
 }
 return try AttachmentIndexer.ingest(
 fileURL: file.sourceURL,
 displayName: file.displayName,
 attachmentID: file.attachmentID
 )
 }

 var ingestedIDs: [UUID] = []
 do {
 for attachment in attachments {
 try await store.ingest(attachment)
 ingestedIDs.append(attachment.id)
 }
 } catch {
 for id in ingestedIDs.reversed() {
 try? await store.remove(id)
 }
 throw error
 }
 }

 // MARK: - Helpers

 /// Build a `ToolCallContext` for a given message snapshot. Factored
 /// so `runTurn` can pass both the initial pre-turn messages (for
 /// tool gather) and the per-dispatch accumulated messages (for tool
 /// execution) through the same construction path.
 private func makeContext(
 continuation: AsyncThrowingStream<TurnEvent, Error>.Continuation,
 overridingMessages: [RelayMessage]? = nil
 ) -> ToolCallContext {
 ToolCallContext(
 messages: overridingMessages ?? state.messages,
 session: session,
 approvalBroker: approvalBroker,
 progress: { progress in
 continuation.yield(.toolProgress(
 toolUseId: progress.toolUseId,
 message: progress.message
 ))
 },
 services: serviceLocator
 )
 }

 internal func handleApprovalRequest(
 toolUseId: String,
 toolName: String,
 prompt: String,
 requestedAtTurnCount: Int,
 handler: @Sendable (_ toolUseId: String, _ toolName: String, _ prompt: String) async -> Bool
 ) async -> Bool {
 state.pendingApprovalState.current = PendingApprovalRequest(
 toolUseId: toolUseId,
 toolName: toolName,
 prompt: prompt,
 requestedAtTurnCount: requestedAtTurnCount
 )
 let approved = await handler(toolUseId, toolName, prompt)
 state.pendingApprovalState.current = nil
 state.pendingApprovalState.lastResolution = ApprovalResolution(
 toolUseId: toolUseId,
 toolName: toolName,
 prompt: prompt,
 approved: approved,
 resolvedAtTurnCount: requestedAtTurnCount
 )
 return approved
 }
}

/// Errors surfaced by `AgentCore` public APIs. introduces one
/// case; future phases may extend.
public enum AgentCoreError: Error, Sendable, Equatable {
 /// Thrown by `AgentCore.ingest(attachmentAt:displayName:)` when
 /// `Config.attachmentStore` is nil at the time of the call.
 case attachmentStoreNotConfigured
}
