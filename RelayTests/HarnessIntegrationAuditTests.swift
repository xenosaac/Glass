import XCTest
@testable import Relay

final class HarnessIntegrationAuditTests: XCTestCase {
 private enum Step {
 case result(CactusModelHost.CompletionResult)
 case error(Error)
 case empty
 }

 private final class SequenceModelClient: ModelClient, @unchecked Sendable {
 private let steps: [Step]
 private let lock = NSLock
 private var callCount = 0

 init(steps: [Step]) {
 self.steps = steps
 }

 nonisolated func stream(
 messages: [RelayMessage],
 tools: [any RelayTool],
 options: CactusModelHost.CompletionOptions,
 systemPrompt: String?
 ) -> AsyncThrowingStream<CactusModelHost.StreamEvent, Error> {
 lock.lock
 let idx = callCount
 callCount += 1
 lock.unlock

 let step = idx < steps.count ? steps[idx] : .empty
 return AsyncThrowingStream { continuation in
 switch step {
 case .result(let result):
 if !result.text.isEmpty {
 continuation.yield(.token(result.text))
 }
 continuation.yield(.done(result))
 continuation.finish()
 case .error(let error):
 continuation.finish(throwing: error)
 case .empty:
 continuation.finish()
 }
 }
 }
 }

 private final class StubFileProvider: FileProviderService, @unchecked Sendable {
 let results: [FileSearchResult]
 let fileData: [String: Data]

 init(results: [FileSearchResult] = [], fileData: [String: Data] = [:]) {
 self.results = results
 self.fileData = fileData
 }

 func searchFiles(query: String, inFolder: String?, limit: Int) async throws -> [FileSearchResult] {
 Array(results.prefix(limit))
 }

 func readFile(at path: String) async throws -> Data {
 guard let data = fileData[path] else {
 throw FileProviderError.fileNotFound(path)
 }
 return data
 }
 }

 private struct SlowTool: RelayTool {
 var name: String { "slow_echo" }
 var description: String { "slow test tool" }
 var inputSchema: ToolInputSchema {
 ToolInputSchema(json: #"{"type":"object","properties":{}}"#)
 }
 var isConcurrencySafe: Bool { true }
 var isReadOnly: Bool { true }
 var isDestructive: Bool { false }

 func call(input: ToolInput, context: ToolCallContext) async throws -> ToolResult {
 try await Task.sleep(nanoseconds: 2_000_000_000)
 return ToolResult(toolUseId: "", output: "slow-ok", isError: false)
 }
 }

 private func result(
 text: String,
 toolUses: [ToolUseBlock] = [],
 cloudHandoff: Bool = false
 ) -> CactusModelHost.CompletionResult {
 CactusModelHost.CompletionResult(
 text: text,
 toolUses: toolUses,
 confidence: 1.0,
 cloudHandoff: cloudHandoff,
 prefillTPS: 0,
 decodeTPS: 0,
 timeToFirstTokenMs: 0,
 totalTimeMs: 0,
 ramUsageMB: 0
 )
 }

 private func makeBuilder(
 memoryStore: MemoryStore? = nil,
 attachmentStore: AttachmentStore? = nil,
 workspaceURL: URL? = nil,
 fileProvider: (any FileProviderService)? = nil
 ) -> ContextBuilder {
 ContextBuilder(
 memoryStore: memoryStore,
 attachmentStore: attachmentStore,
 workspaceURL: workspaceURL,
 fileProvider: fileProvider
 )
 }

 private func makeToolContext() -> @Sendable ([RelayMessage]) -> ToolCallContext {
 let session = AgentSession(id: "audit", startedAt: Date)
 let broker: any ApprovalBroker = DefaultApprovalBroker
 let services: any ServiceLocator = DefaultServiceLocator
 return { messages in
 ToolCallContext(
 messages: messages,
 session: session,
 approvalBroker: broker,
 progress: { _ in },
 services: services
 )
 }
 }

 private func cleanSessionDir(_ sessionId: String) {
 try? FileManager.default.removeItem(at: AppPaths.attachments(forSessionId: sessionId))
 }

 private func makeTempDir(_ prefix: String) -> URL {
 let dir = FileManager.default.temporaryDirectory
 .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
 try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
 return dir
 }

 private func textContent(of message: RelayMessage) -> String {
 switch message {
 case .user(let content):
 return content.blocks.compactMap { block -> String? in
 if case .text(let text) = block { return text }
 return nil
 }.joined(separator: "\n")
 case .assistant(let content):
 return content.blocks.compactMap { block -> String? in
 if case .text(let text) = block { return text }
 return nil
 }.joined(separator: "\n")
 case .toolResult(let blocks):
 return blocks.map(\.output).joined(separator: "\n")
 }
 }

 private func lastNonMetaUserText(in messages: [RelayMessage]) -> String? {
 for message in messages.reversed() {
 if case .user(let content) = message, !content.isMeta {
 return textContent(of: .user(content))
 }
 }
 return nil
 }

 private func metaArtifactTexts(in messages: [RelayMessage]) -> [String] {
 messages.compactMap { message in
 guard case .user(let content) = message, content.isMeta else { return nil }
 let text = textContent(of: .user(content))
 return text.contains("<context-artifact>") ? text : nil
 }
 }

 func test_audit_declarativeFactThenFactRecall_keepsVisibleFactWithoutUnrelatedTail() async {
 let builder = makeBuilder
 let state = AgentSessionState(
 messages: [
 .user(UserContent(blocks: [.text("My name is Isaac")])),
 .assistant(AssistantContent(blocks: [.text("The weather in Boston is rainy today.")])),
 .user(UserContent(blocks: [.text("What's my name?")]))
 ],
 turnCount: 2
 )

 let artifacts = await builder.buildArtifacts(
 state: state,
 enabledToolNames: [],
 environment: .current,
 extraSystemContext: [:],
 tools: [],
 options: .init()
 )

 XCTAssertTrue(artifacts.retrievalDecision.artifacts.isEmpty)
 XCTAssertNil(artifacts.retrievalQuery)
 XCTAssertTrue(artifacts.request.systemPrompt.contains("Turn classification: factRecallKnown"))
 XCTAssertTrue(artifacts.request.systemPrompt.contains("Latest visible facts:"))
 XCTAssertTrue(artifacts.request.systemPrompt.contains("- My name is Isaac"))
 XCTAssertFalse(artifacts.request.systemPrompt.contains("Boston is rainy"))
 }

 func test_audit_wrongAnswerThenRepairCue_usesTranscriptVisibleRepairContextOnly() async {
 let builder = makeBuilder
 let state = AgentSessionState(
 messages: [
 .user(UserContent(blocks: [.text("My name is Isaac just fyi")])),
 .assistant(AssistantContent(blocks: [.text("Please provide the text or image, question, or request you would like me to help you with!")])),
 .user(UserContent(blocks: [.text("Tf")]))
 ],
 turnCount: 2
 )

 let artifacts = await builder.buildArtifacts(
 state: state,
 enabledToolNames: [],
 environment: .current,
 extraSystemContext: [:],
 tools: [],
 options: .init()
 )

 XCTAssertTrue(artifacts.retrievalDecision.artifacts.isEmpty)
 XCTAssertTrue(artifacts.request.systemPrompt.contains("Turn classification: repairCue"))
 XCTAssertTrue(artifacts.request.systemPrompt.contains("Latest visible facts:"))
 XCTAssertTrue(artifacts.request.systemPrompt.contains("My name is Isaac just fyi"))
 XCTAssertTrue(artifacts.request.systemPrompt.contains("assistant: Please provide the text or image"))
 XCTAssertFalse(artifacts.request.systemPrompt.contains("Retrieved context available for this turn:"))
 }

 func test_audit_transportCheck_staysRetrievalFreeAndSummaryFree() async throws {
 let sessionId = "audit-transport-\(UUID().uuidString)"
 defer { cleanSessionDir(sessionId) }

 let fixtureDir = makeTempDir("AuditTransport")
 defer { try? FileManager.default.removeItem(at: fixtureDir) }
 let fixtureURL = fixtureDir.appendingPathComponent("ResetNotes.txt")
 try "reset the device by holding the power button".data(using: .utf8)!.write(to: fixtureURL)

 let attachment = try AttachmentIndexer.ingest(fileURL: fixtureURL, displayName: "ResetNotes.txt")
 let store = AttachmentStore(sessionId: sessionId)
 try await store.ingest(attachment)

 let state = AgentSessionState(
 messages: [.user(UserContent(blocks: [.text("Can you hear me?")]))],
 turnCount: 1,
 summaryState: SessionSummaryState(
 latestBoundarySummary: "Older reset discussion",
 lastCompactedAtTurnCount: 0,
 latestBoundaryMessageIndex: 0
 )
 )

 let artifacts = await makeBuilder(attachmentStore: store).buildArtifacts(
 state: state,
 enabledToolNames: [],
 environment: .current,
 extraSystemContext: [:],
 tools: [],
 options: .init()
 )

 XCTAssertTrue(artifacts.retrievalDecision.artifacts.isEmpty)
 XCTAssertNil(artifacts.retrievalQuery)
 XCTAssertTrue(artifacts.request.systemPrompt.contains("Turn classification: transportCheck"))
 XCTAssertFalse(artifacts.request.systemPrompt.contains("Relevant recent conversation:"))
 XCTAssertFalse(artifacts.request.systemPrompt.contains("Retrieved context available for this turn:"))
 XCTAssertFalse(artifacts.request.systemPrompt.contains("Compacted history summary:"))
 }

 func test_audit_attachmentBackedQuestionAfterUnrelatedChat_focusAndArtifactsAgree() async throws {
 let sessionId = "audit-attachment-\(UUID().uuidString)"
 defer { cleanSessionDir(sessionId) }

 let fixtureDir = makeTempDir("AuditAttachment")
 defer { try? FileManager.default.removeItem(at: fixtureDir) }
 let fixtureURL = fixtureDir.appendingPathComponent("ResetGuide.txt")
 try "To reset the device, hold the power button for ten seconds.".data(using: .utf8)!.write(to: fixtureURL)

 let attachment = try AttachmentIndexer.ingest(fileURL: fixtureURL, displayName: "ResetGuide.txt")
 let store = AttachmentStore(sessionId: sessionId)
 try await store.ingest(attachment)

 let state = AgentSessionState(
 messages: [
 .user(UserContent(blocks: [.text("Tell me about sci-fi movies")])),
 .assistant(AssistantContent(blocks: [.text("I like Arrival and Blade Runner 2049.")])),
 .user(UserContent(blocks: [.text("How do I reset the device?")]))
 ],
 turnCount: 2
 )

 let artifacts = await makeBuilder(attachmentStore: store).buildArtifacts(
 state: state,
 enabledToolNames: [],
 environment: .current,
 extraSystemContext: [:],
 tools: [],
 options: .init()
 )

 XCTAssertFalse(artifacts.retrievalDecision.artifacts.isEmpty)
 XCTAssertTrue(artifacts.request.systemPrompt.contains("Turn classification: question"))
 XCTAssertTrue(artifacts.request.systemPrompt.contains("Retrieved context available for this turn:"))
 XCTAssertTrue(artifacts.request.systemPrompt.contains("[attachment] ResetGuide.txt"))
 XCTAssertFalse(artifacts.request.systemPrompt.contains("Blade Runner 2049"))
 XCTAssertEqual(lastNonMetaUserText(in: artifacts.request.messages), "How do I reset the device?")

 let metaArtifacts = metaArtifactTexts(in: artifacts.request.messages)
 XCTAssertEqual(metaArtifacts.count, artifacts.retrievalDecision.artifacts.count)
 XCTAssertTrue(metaArtifacts.allSatisfy { $0.contains("<context-artifact>") })
 }

 func test_audit_fileReplayEquivalence_preservesCanonicalTranscriptAndProjectsForModel() async throws {
 let attachmentID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE") ?? UUID()
 let transcriptMessage = RelayMessage.user(UserContent(blocks: [
 .text("Summarize this."),
 .fileRef(ImportedFileRef(
 attachmentID: attachmentID,
 displayName: "Guide.md",
 contentTypeIdentifier: "public.plain-text"
 ))
 ]))

 let repaired = CactusModelHost.ensureToolResultPairing([transcriptMessage]).0
 let state = AgentSessionState.hydrated(from: repaired)
 let request = await makeBuilder.build(
 state: state,
 enabledToolNames: [],
 environment: .current,
 extraSystemContext: [:],
 tools: [],
 options: .init()
 )

 guard case .user(let canonicalContent) = state.messages.first else {
 return XCTFail("expected canonical transcript user message")
 }
 XCTAssertTrue(canonicalContent.blocks.contains { block in
 if case .fileRef(let ref) = block {
 return ref.displayName == "Guide.md"
 }
 return false
 })
 XCTAssertFalse(textContent(of: state.messages[0]).contains("Attached files:"))

 XCTAssertEqual(lastNonMetaUserText(in: request.messages), "Attached files: Guide.md.\n\nSummarize this.")
 }

 func test_audit_cloudRetryRecovery_withholdsFailureAndPreservesOrdering() async throws {
 let onDevice = SequenceModelClient(steps: [
 .result(result(text: "on-device draft", cloudHandoff: true))
 ])
 let cloud = SequenceModelClient(steps: [
 .result(result(text: "cloud final"))
 ])
 let runner = AgentRunner

 let (stream, continuation) = AsyncThrowingStream<TurnEvent, Error>.makeStream
 async let runnerResult: (state: AgentSessionState, exit: AgentRunner.TurnExit) = {
 let result = await runner.run(
 initialUserMessage: .user(UserContent(blocks: [.text("summarize")])) ,
 state: .empty,
 contextBuilder: makeBuilder,
 onDeviceClient: onDevice,
 cloudClient: cloud,
 dispatcher: ToolDispatcher,
 toolContextFor: makeToolContext,
 tools: [],
 enabledToolNames: [],
 environment: .current,
 extraSystemContext: [:],
 options: .init(),
 continuation: continuation
 )
 continuation.finish()
 return result
 }

 var sawRecovery = false
 var clearCount = 0
 var failures: [String] = []
 var doneText: String?
 for try await event in stream {
 switch event {
 case .recoveryStateChanged(.retryingWithCloud):
 sawRecovery = true
 case .clearProvisionalOutput:
 clearCount += 1
 case .failure(let message):
 failures.append(message)
 case .done(let message):
 doneText = textContent(of: message)
 default:
 break
 }
 }

 let (state, exit) = await runnerResult
 XCTAssertEqual(exit, .completed)
 XCTAssertTrue(sawRecovery)
 XCTAssertGreaterThanOrEqual(clearCount, 1)
 XCTAssertTrue(failures.isEmpty)
 XCTAssertEqual(doneText, "cloud final")
 XCTAssertEqual(state.recoveryState.lastContinuationReason, .cloudRetry)
 XCTAssertTrue(state.recoveryState.cloudFallbackUsedLastTurn)
 }

 func test_audit_promptTooLongRecovery_retriesOnceAndPreservesCurrentUserTurn() async throws {
 let onDevice = SequenceModelClient(steps: [
 .error(CactusModelHost.HostError.inferenceFailed("prompt too long")),
 .result(result(text: "recovered answer"))
 ])
 let compactorClient = SequenceModelClient(steps: [.result(result(text: "compact summary"))])
 let recoveryCompactor = Compactor(modelClient: compactorClient)
 let runner = AgentRunner

 let priorState = AgentSessionState(
 messages: [
 .user(UserContent(blocks: [.text("older one")])),
 .assistant(AssistantContent(blocks: [.text("reply one")])),
 .user(UserContent(blocks: [.text("older two")])),
 .assistant(AssistantContent(blocks: [.text("reply two")]))
 ],
 turnCount: 2
 )
 let currentUser = RelayMessage.user(UserContent(blocks: [.text("new question")]))

 let (stream, continuation) = AsyncThrowingStream<TurnEvent, Error>.makeStream
 async let runnerResult: (state: AgentSessionState, exit: AgentRunner.TurnExit) = {
 let result = await runner.run(
 initialUserMessage: currentUser,
 state: priorState,
 contextBuilder: makeBuilder,
 onDeviceClient: onDevice,
 cloudClient: nil,
 dispatcher: ToolDispatcher,
 toolContextFor: makeToolContext,
 tools: [],
 enabledToolNames: [],
 environment: .current,
 extraSystemContext: [:],
 options: .init(),
 recoveryCompactor: recoveryCompactor,
 continuation: continuation
 )
 continuation.finish()
 return result
 }

 var failures: [String] = []
 for try await event in stream {
 if case .failure(let message) = event {
 failures.append(message)
 }
 }

 let (state, exit) = await runnerResult
 XCTAssertEqual(exit, .completed)
 XCTAssertTrue(failures.isEmpty)
 XCTAssertEqual(
 state.messages.filter { textContent(of: $0) == "new question" }.count,
 1
 )
 XCTAssertEqual(state.recoveryState.recoveryAttemptCountLastTurn, 1)
 XCTAssertEqual(state.recoveryState.lastContinuationReason, .promptTooLongRetry)
 }

 func test_audit_interruptedToolTurn_repairsContinuityAndHydratesPairedHistory() async throws {
 let use = ToolUseBlock(id: "call_interrupt", name: "slow_echo", inputJson: "{}")
 let onDevice = SequenceModelClient(steps: [
 .result(result(text: "", toolUses: [use]))
 ])
 let runner = AgentRunner

 let (stream, continuation) = AsyncThrowingStream<TurnEvent, Error>.makeStream
 let task = Task<(state: AgentSessionState, exit: AgentRunner.TurnExit), Never> {
 let result = await runner.run(
 initialUserMessage: .user(UserContent(blocks: [.text("run slow tool")])) ,
 state: .empty,
 contextBuilder: makeBuilder,
 onDeviceClient: onDevice,
 cloudClient: nil,
 dispatcher: ToolDispatcher,
 toolContextFor: makeToolContext,
 tools: [SlowTool],
 enabledToolNames: ["slow_echo"],
 environment: .current,
 extraSystemContext: [:],
 options: .init(),
 continuation: continuation
 )
 continuation.finish()
 return result
 }

 var completedToolIds: [String] = []
 for try await event in stream {
 switch event {
 case .toolCallStarted:
 task.cancel
 case .toolCallCompleted(let toolUseId, _):
 completedToolIds.append(toolUseId)
 default:
 break
 }
 }

 let (state, exit) = await task.value
 XCTAssertEqual(exit, .interrupted)
 XCTAssertEqual(completedToolIds, ["call_interrupt"])
 XCTAssertTrue(state.recentToolState.activeToolUses.isEmpty)
 guard case .toolResult(let blocks) = state.messages.last else {
 return XCTFail("expected synthetic tool result on interruption")
 }
 XCTAssertEqual(blocks.count, 1)
 XCTAssertEqual(blocks[0].toolUseId, "call_interrupt")
 XCTAssertTrue(blocks[0].isError)

 let host = CactusModelHost(modelPath: "/dev/null")
 let core = AgentCore(host: host)
 await core.hydrate(history: state.messages)
 let hydrated = await core.runtimeStateForTesting
 XCTAssertEqual(hydrated.messages.count, state.messages.count)
 XCTAssertEqual(hydrated.recentToolState.lastCompletedBatch.count, 1)
 }

 func test_audit_broadReferentialQuestionAfterCompaction_allowsSummaryWithoutStealingAnchor() async {
 let builder = makeBuilder
 let boundary = MessageFactory.compactBoundary(summary: "Older project summary and context")
 let state = AgentSessionState(
 messages: [
 boundary,
 .user(UserContent(blocks: [.text("Can you recap where we are on the project and what we should do next?")]))
 ],
 turnCount: 1,
 summaryState: SessionSummaryState(
 latestBoundarySummary: "Older project summary and context",
 lastCompactedAtTurnCount: 0,
 latestBoundaryMessageIndex: 0
 )
 )

 let artifacts = await builder.buildArtifacts(
 state: state,
 enabledToolNames: [],
 environment: .current,
 extraSystemContext: [:],
 tools: [],
 options: .init()
 )

 XCTAssertTrue(artifacts.request.systemPrompt.contains("Turn classification: question"))
 XCTAssertTrue(artifacts.request.systemPrompt.contains("Compacted history summary:"))
 XCTAssertTrue(artifacts.request.systemPrompt.contains("Older project summary and context"))
 }

 @MainActor
 func test_audit_duplicateSendGuard_rejectsSecondAcceptedTurnWhileRunning() async {
 let viewModel = ChatViewModel(
 sessionId: "audit-duplicate-guard",
 sessionIndex: SessionIndex,
 sharedServices: SharedServices
 )
 viewModel.isRunning = true
 viewModel.displayMessages = [.assistant(id: UUID, text: "existing", isStreaming: false)]

 let accepted = await viewModel.send("hello")

 XCTAssertFalse(accepted)
 XCTAssertEqual(viewModel.displayMessages.count, 1)
 XCTAssertEqual(viewModel.agentStatus, .idle)
 XCTAssertEqual(viewModel.error, nil)
 }
}
