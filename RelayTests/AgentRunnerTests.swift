import XCTest
@testable import Relay

/// harness-extraction tests. Exercise `AgentRunner`'s state
/// machine through a hand-rolled `MockModelClient` that conforms to
/// `ModelClient` and returns a predetermined sequence of
/// `CactusModelHost.CompletionResult` values. No real inference
/// backend is touched.
///
/// Three cases:
/// 1. Text-only response → one iteration, `TurnExit.completed`.
/// 2. Tool-use then text → two iterations, one tool dispatch,
/// `TurnExit.completed`.
/// 3. Empty stream (no `.done` event) → `TurnExit.noCompletion`
/// and an exact-string `.failure` event.
final class AgentRunnerTests: XCTestCase {

 private enum HostStep {
 case response(CompiledTurnResponse, streamedTokens: [String] = [])
 case error(Error)
 case empty
 }

 // MARK: - Mock model clients

 /// Returns a predetermined sequence of results across successive
 /// `stream(...)` invocations. Thread-safety for the call counter
 /// is guaranteed by a simple lock — tests run sequentially so the
 /// counter is only read from one producer Task at a time, but we
 /// still mark the class `@unchecked Sendable` explicitly.
 private final class MockModelClient: ModelClient, @unchecked Sendable {
 private let responses: [CactusModelHost.CompletionResult]
 private let lock = NSLock
 private var callCount = 0

 init(responses: [CactusModelHost.CompletionResult]) {
 self.responses = responses
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

 let result = idx < responses.count ? responses[idx] : nil

 return AsyncThrowingStream { continuation in
 if let r = result {
 if !r.text.isEmpty {
 continuation.yield(.token(r.text))
 }
 continuation.yield(.done(r))
 }
 continuation.finish()
 }
 }
 }

 /// Yields nothing and finishes — simulates a backend that returns
 /// an empty stream (no `.done` event).
 private final class EmptyMockModelClient: ModelClient, @unchecked Sendable {
 nonisolated func stream(
 messages: [RelayMessage],
 tools: [any RelayTool],
 options: CactusModelHost.CompletionOptions,
 systemPrompt: String?
 ) -> AsyncThrowingStream<CactusModelHost.StreamEvent, Error> {
 AsyncThrowingStream { continuation in
 continuation.finish()
 }
 }
 }

 private final class MockHostAdapter: ModelHostAdapter, @unchecked Sendable {
 let profileID: PromptProfileID
 let tier: ModelTier
 private let steps: [HostStep]
 private let lock = NSLock
 private var callCount = 0
 private var recordedRequests: [CompiledTurnRequest] = []

 init(
 profileID: PromptProfileID,
 tier: ModelTier,
 steps: [HostStep]
 ) {
 self.profileID = profileID
 self.tier = tier
 self.steps = steps
 }

 nonisolated func streamTurn(_ request: CompiledTurnRequest) -> AsyncThrowingStream<HostStreamEvent, Error> {
 lock.lock
 let idx = callCount
 callCount += 1
 recordedRequests.append(request)
 lock.unlock

 let step = idx < steps.count ? steps[idx] : .empty
 return AsyncThrowingStream { continuation in
 switch step {
 case .response(let response, let streamedTokens):
 for token in streamedTokens {
 continuation.yield(.token(token))
 }
 continuation.yield(.finished(response))
 continuation.finish()
 case .error(let error):
 continuation.finish(throwing: error)
 case .empty:
 continuation.finish()
 }
 }
 }

 func snapshotRequests() -> [CompiledTurnRequest] {
 lock.lock
 defer { lock.unlock }
 return recordedRequests
 }
 }

 // MARK: - Fixtures

 private func makeContextBuilder(attachmentStore: AttachmentStore? = nil) -> ContextBuilder {
 ContextBuilder(memoryStore: nil, attachmentStore: attachmentStore)
 }

 private func cleanSessionDir(_ sessionId: String) {
 try? FileManager.default.removeItem(at: AppPaths.attachments(forSessionId: sessionId))
 }

 private func makeToolContext() -> @Sendable ([RelayMessage]) -> ToolCallContext {
 let session = AgentSession(id: "test", startedAt: Date)
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

 private func compiledResponse(
 tier: ModelTier,
 text: String,
 toolCalls: [ParsedToolCall] = [],
 finishReason: FinishReason? = nil,
 cloudHandoff: Bool = false
 ) -> CompiledTurnResponse {
 let resolvedFinishReason: FinishReason
 if let finishReason {
 resolvedFinishReason = finishReason
 } else if !toolCalls.isEmpty {
 resolvedFinishReason = .toolCalls
 } else if cloudHandoff {
 resolvedFinishReason = .cloudHandoff
 } else if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
 resolvedFinishReason = .empty
 } else {
 resolvedFinishReason = .message
 }

 return CompiledTurnResponse(
 tier: tier,
 outputText: text,
 toolCalls: toolCalls,
 finishReason: resolvedFinishReason,
 rawCompletion: CompletionSnapshot(
 text: text,
 toolCalls: toolCalls,
 confidence: 1.0,
 cloudHandoff: cloudHandoff,
 prefillTPS: 0,
 decodeTPS: 0,
 timeToFirstTokenMs: 0,
 totalTimeMs: 0,
 ramUsageMB: 0
 )
 )
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

 // MARK: - Test 1: text-only response

 func test_runner_textOnlyResponse_completesInOneIteration() async throws {
 let mock = MockModelClient(responses: [result(text: "hello back")])
 let runner = AgentRunner
 let userMessage: RelayMessage = .user(UserContent(blocks: [.text("hi")]))

 let (stream, continuation) = AsyncThrowingStream<TurnEvent, Error>.makeStream

 async let runnerResult: (state: AgentSessionState, exit: AgentRunner.TurnExit) = {
 let r = await runner.run(
 initialUserMessage: userMessage,
 state: .empty,
 contextBuilder: self.makeContextBuilder,
 onDeviceClient: mock,
 cloudClient: nil,
 dispatcher: ToolDispatcher,
 toolContextFor: self.makeToolContext,
 tools: [],
 enabledToolNames: [],
 environment: .current,
 extraSystemContext: [:],
 options: .init(),
 continuation: continuation
 )
 continuation.finish()
 return r
 }

 var sawDone = false
 for try await event in stream {
 if case .done = event { sawDone = true }
 }

 let (newState, exit) = await runnerResult
 XCTAssertTrue(sawDone, "expected a .done event")
 XCTAssertEqual(newState.messages.count, 2, "expected [user, assistant(text)]")
 XCTAssertEqual(newState.turnCount, 1, "one non-meta user turn submitted")
 XCTAssertEqual(newState.recoveryState.lastExit, .completed)
 XCTAssertEqual(newState.recoveryState.lastContinuationReason, .completed)
 XCTAssertNil(newState.recoveryState.lastWithheldRecoverableError)
 XCTAssertFalse(newState.recoveryState.cloudFallbackUsedLastTurn)
 XCTAssertEqual(newState.recoveryState.consecutiveFailures, 0)
 XCTAssertEqual(newState.recoveryState.lastCompletedAtTurnCount, 1)
 XCTAssertEqual(newState.recoveryState.recoveryAttemptCountLastTurn, 0)

 guard case .user = newState.messages[0] else {
 return XCTFail("expected user at index 0")
 }
 guard case .assistant(let content) = newState.messages[1] else {
 return XCTFail("expected assistant at index 1")
 }
 let text = content.blocks.compactMap { block -> String? in
 if case .text(let t) = block { return t } else { return nil }
 }.joined()
 XCTAssertEqual(text, "hello back")

 if case .completed = exit {
 // expected
 } else {
 XCTFail("expected .completed exit, got \(exit)")
 }
 }

 // MARK: - Test 2: cloud handoff

 func test_runner_cloudHandoff_retriesWithCloudClient() async throws {
 let onDevice = MockModelClient(responses: [
 result(text: "on-device draft", cloudHandoff: true)
 ])
 let cloud = MockModelClient(responses: [
 result(text: "cloud final")
 ])
 let runner = AgentRunner
 let userMessage: RelayMessage = .user(UserContent(blocks: [.text("summarize")]))

 let (stream, continuation) = AsyncThrowingStream<TurnEvent, Error>.makeStream

 async let runnerResult: (state: AgentSessionState, exit: AgentRunner.TurnExit) = {
 let r = await runner.run(
 initialUserMessage: userMessage,
 state: .empty,
 contextBuilder: self.makeContextBuilder,
 onDeviceClient: onDevice,
 cloudClient: cloud,
 dispatcher: ToolDispatcher,
 toolContextFor: self.makeToolContext,
 tools: [],
 enabledToolNames: [],
 environment: .current,
 extraSystemContext: [:],
 options: .init(),
 continuation: continuation
 )
 continuation.finish()
 return r
 }

 var routingTiers: [ModelTier] = []
 var tokenStream: [String] = []
 var doneText: String?
 var recoveryStates: [RecoveryDisplayState] = []
 var clearCount = 0
 var failureCount = 0

 for try await event in stream {
 switch event {
 case .routingDecision(let tier, _):
 routingTiers.append(tier)
 case .recoveryStateChanged(let state):
 recoveryStates.append(state)
 case .clearProvisionalOutput:
 clearCount += 1
 case .tokenReceived(let token):
 tokenStream.append(token)
 case .done(let message):
 if case .assistant(let content) = message {
 doneText = content.blocks.compactMap { block -> String? in
 if case .text(let t) = block { return t }
 return nil
 }.joined()
 }
 case .failure:
 failureCount += 1
 default:
 break
 }
 }

 let (newState, exit) = await runnerResult
 XCTAssertEqual(routingTiers, [.fast, .cloud])
 XCTAssertEqual(recoveryStates, [.retryingWithCloud])
 XCTAssertEqual(clearCount, 1)
 XCTAssertEqual(failureCount, 0)
 XCTAssertTrue(tokenStream.contains("cloud final"))
 XCTAssertEqual(doneText, "cloud final")
 XCTAssertEqual(newState.messages.count, 2, "expected [user, assistant(text)] after cloud fallback")
 XCTAssertEqual(newState.turnCount, 1, "cloud fallback is still one user turn")
 XCTAssertEqual(newState.recoveryState.lastExit, .completed)
 XCTAssertEqual(newState.recoveryState.lastContinuationReason, .cloudRetry)
 XCTAssertEqual(newState.recoveryState.recoveryAttemptCountLastTurn, 1)
 XCTAssertTrue(newState.recoveryState.cloudFallbackUsedLastTurn)

 if case .completed = exit {
 // expected
 } else {
 XCTFail("expected .completed exit, got \(exit)")
 }
 }

 func test_runner_canonicalHostAdapters_useCompiledRequestsForCloudRetry() async throws {
 let onDevice = MockHostAdapter(
 profileID: .gemmaLocal,
 tier: .fast,
 steps: [
 .response(
 compiledResponse(
 tier: .fast,
 text: "on-device draft",
 finishReason: .cloudHandoff,
 cloudHandoff: true
 ),
 streamedTokens: ["on-device draft"]
 )
 ]
 )
 let cloud = MockHostAdapter(
 profileID: .geminiCloud,
 tier: .cloud,
 steps: [
 .response(compiledResponse(tier: .cloud, text: "cloud final"), streamedTokens: ["cloud final"])
 ]
 )
 let runner = AgentRunner
 let userMessage: RelayMessage = .user(UserContent(blocks: [.text("summarize")]))
 let (stream, continuation) = AsyncThrowingStream<TurnEvent, Error>.makeStream

 async let runnerResult: (state: AgentSessionState, exit: AgentRunner.TurnExit) = {
 let r = await runner.run(
 sessionID: "session-cloud",
 initialUserMessage: userMessage,
 state: .empty,
 contextBuilder: self.makeContextBuilder,
 onDeviceClient: onDevice,
 cloudClient: cloud,
 dispatcher: ToolDispatcher,
 toolContextFor: self.makeToolContext,
 tools: [],
 toolCatalog: [],
 enabledToolNames: [],
 environment: .current,
 extraSystemContext: [:],
 options: .init(),
 continuation: continuation
 )
 continuation.finish()
 return r
 }

 for try await _ in stream {}

 let (newState, exit) = await runnerResult
 XCTAssertEqual(exit, .completed)
 XCTAssertEqual(newState.recoveryState.lastContinuationReason, .cloudRetry)
 XCTAssertEqual(onDevice.snapshotRequests.count, 1)
 XCTAssertEqual(cloud.snapshotRequests.count, 1)
 XCTAssertEqual(onDevice.snapshotRequests.first?.profileID, .gemmaLocal)
 XCTAssertEqual(cloud.snapshotRequests.first?.profileID, .geminiCloud)
 XCTAssertEqual(onDevice.snapshotRequests.first?.sessionID, "session-cloud")
 XCTAssertEqual(cloud.snapshotRequests.first?.sessionID, "session-cloud")
 XCTAssertEqual(cloud.snapshotRequests.first?.hostOptions.allowCloudHandoff, false)
 }

 // MARK: - Test 3: cloud fallback unavailable

 func test_runner_cloudHandoff_withoutCloudClient_fallsBackToTextOnly() async throws {
 let onDevice = MockModelClient(responses: [
 result(text: "on-device draft", cloudHandoff: true)
 ])
 let runner = AgentRunner
 let userMessage: RelayMessage = .user(UserContent(blocks: [.text("summarize")]))

 let (stream, continuation) = AsyncThrowingStream<TurnEvent, Error>.makeStream

 async let runnerResult: (state: AgentSessionState, exit: AgentRunner.TurnExit) = {
 let r = await runner.run(
 initialUserMessage: userMessage,
 state: .empty,
 contextBuilder: self.makeContextBuilder,
 onDeviceClient: onDevice,
 cloudClient: nil,
 dispatcher: ToolDispatcher,
 toolContextFor: self.makeToolContext,
 tools: [],
 enabledToolNames: [],
 environment: .current,
 extraSystemContext: [:],
 options: .init(),
 continuation: continuation
 )
 continuation.finish()
 return r
 }

 var routingTiers: [ModelTier] = []
 var doneText: String?

 for try await event in stream {
 switch event {
 case .routingDecision(let tier, _):
 routingTiers.append(tier)
 case .done(let message):
 if case .assistant(let content) = message {
 doneText = content.blocks.compactMap { block -> String? in
 if case .text(let t) = block { return t }
 return nil
 }.joined()
 }
 default: break
 }
 }

 let (newState, exit) = await runnerResult
 XCTAssertEqual(routingTiers, [.fast])
 XCTAssertEqual(doneText, "on-device draft\n\n[Cloud fallback unavailable — showing on-device response]")
 XCTAssertEqual(newState.messages.count, 2, "expected [user, assistant(text)] after text-only fallback")
 XCTAssertEqual(newState.turnCount, 1, "one user turn despite cloud path unavailable")
 XCTAssertEqual(newState.recoveryState.lastContinuationReason, .completed)
 XCTAssertEqual(newState.recoveryState.recoveryAttemptCountLastTurn, 0)
 XCTAssertFalse(newState.recoveryState.cloudFallbackUsedLastTurn)

 if case .completed = exit {
 // expected
 } else {
 XCTFail("expected .completed exit, got \(exit)")
 }
 }

 // MARK: - Test 4: tool-use then text

 /// Minimal read-only tool that always returns "ok". Used only by
 /// `test_runner_toolUseThenText_loopsOnceAndCompletes`.
 private struct EchoTool: RelayTool {
 var name: String { "echo" }
 var description: String { "test echo" }
 var inputSchema: ToolInputSchema {
 ToolInputSchema(json: #"{"type":"object","properties":{}}"#)
 }
 var isConcurrencySafe: Bool { true }
 var isReadOnly: Bool { true }
 var isDestructive: Bool { false }

 func call(input: ToolInput, context: ToolCallContext) async throws -> ToolResult {
 ToolResult(toolUseId: "", output: "ok", isError: false)
 }
 }

 private struct FailingTool: RelayTool {
 var name: String { "failing_tool" }
 var description: String { "test failing tool" }
 var inputSchema: ToolInputSchema {
 ToolInputSchema(json: #"{"type":"object","properties":{}}"#)
 }
 var isConcurrencySafe: Bool { true }
 var isReadOnly: Bool { true }
 var isDestructive: Bool { false }

 func call(input: ToolInput, context: ToolCallContext) async throws -> ToolResult {
 ToolResult(
 toolUseId: "",
 output: "Error fetching upcoming assignments: Request failed: Remote server 500",
 isError: true
 )
 }
 }

 func test_runner_toolUseThenText_loopsOnceAndCompletes() async throws {
 let use = ToolUseBlock(id: "call_1", name: "echo", inputJson: "{}")
 let mock = MockModelClient(responses: [
 result(text: "", toolUses: [use]),
 result(text: "done"),
 ])
 let runner = AgentRunner
 let userMessage: RelayMessage = .user(UserContent(blocks: [.text("run echo")]))

 let (stream, continuation) = AsyncThrowingStream<TurnEvent, Error>.makeStream

 async let runnerResult: (state: AgentSessionState, exit: AgentRunner.TurnExit) = {
 let r = await runner.run(
 initialUserMessage: userMessage,
 state: .empty,
 contextBuilder: self.makeContextBuilder,
 onDeviceClient: mock,
 cloudClient: nil,
 dispatcher: ToolDispatcher,
 toolContextFor: self.makeToolContext,
 tools: [EchoTool],
 enabledToolNames: ["echo"],
 environment: .current,
 extraSystemContext: [:],
 options: .init(),
 continuation: continuation
 )
 continuation.finish()
 return r
 }

 var toolStartedCount = 0
 var toolCompletedCount = 0
 var doneCount = 0

 for try await event in stream {
 switch event {
 case .toolCallStarted: toolStartedCount += 1
 case .toolCallCompleted: toolCompletedCount += 1
 case .done: doneCount += 1
 default: break
 }
 }

 let (newState, exit) = await runnerResult
 XCTAssertEqual(toolStartedCount, 1)
 XCTAssertEqual(toolCompletedCount, 1)
 XCTAssertEqual(doneCount, 1)

 XCTAssertEqual(
 newState.messages.count, 4,
 "expected [user, assistant(toolUse), toolResult, assistant(text)]"
 )
 XCTAssertEqual(newState.turnCount, 1, "tool loop is still one user turn")
 XCTAssertTrue(newState.recentToolState.activeToolUses.isEmpty)
 XCTAssertEqual(newState.recentToolState.lastCompletedBatch.count, 1)
 XCTAssertEqual(newState.recentToolState.lastCompletedBatch[0].toolUseId, "call_1")
 XCTAssertEqual(newState.recentToolState.lastCompletedBatch[0].outputPreview, "ok")
 XCTAssertEqual(newState.recentToolState.lastCompletedAtTurnCount, 1)
 XCTAssertEqual(newState.recoveryState.lastExit, .completed)
 XCTAssertEqual(newState.recoveryState.lastContinuationReason, .toolFollowup)
 XCTAssertEqual(newState.recoveryState.recoveryAttemptCountLastTurn, 0)

 if case .completed = exit {
 // expected
 } else {
 XCTFail("expected .completed exit, got \(exit)")
 }
 }

 func test_runner_allErrorToolBatch_shortCircuitsWithoutSynthesisFollowup() async throws {
 let toolUse = ParsedToolCall(id: "fail_1", name: "failing_tool", inputJSON: "{}")
 let onDevice = MockHostAdapter(
 profileID: .gemmaLocal,
 tier: .fast,
 steps: [
 .response(compiledResponse(tier: .fast, text: "", toolCalls: [toolUse])),
 .response(
 compiledResponse(tier: .fast, text: "SHOULD NOT BE CALLED"),
 streamedTokens: ["SHOULD NOT BE CALLED"]
 )
 ]
 )
 let runner = AgentRunner
 let userMessage: RelayMessage = .user(UserContent(blocks: [.text("check canvas homework")]))
 let (stream, continuation) = AsyncThrowingStream<TurnEvent, Error>.makeStream

 async let runnerResult: (state: AgentSessionState, exit: AgentRunner.TurnExit) = {
 let r = await runner.run(
 sessionID: "all-error-tool-batch",
 initialUserMessage: userMessage,
 state: .empty,
 contextBuilder: self.makeContextBuilder,
 onDeviceClient: onDevice,
 cloudClient: nil,
 dispatcher: ToolDispatcher,
 toolContextFor: self.makeToolContext,
 tools: [FailingTool],
 toolCatalog: [FailingTool.catalogEntry(source: .builtin)],
 enabledToolNames: ["failing_tool"],
 environment: .current,
 extraSystemContext: [:],
 options: .init(),
 continuation: continuation
 )
 continuation.finish()
 return r
 }

 var doneText: String?
 for try await event in stream {
 if case .done(let message) = event {
 doneText = textContent(of: message)
 }
 }

 let (newState, exit) = await runnerResult
 XCTAssertEqual(exit, .completed)
 XCTAssertEqual(
 onDevice.snapshotRequests.count, 1,
 "all-error tool batch should terminate before a synthesis follow-up iteration"
 )
 XCTAssertEqual(
 doneText,
 "Error fetching upcoming assignments: Request failed: Remote server 500"
 )
 XCTAssertEqual(textContent(of: newState.messages.last!), doneText)
 XCTAssertFalse(
 newState.messages.contains(where: { message in
 guard case .user(let content) = message, content.isMeta else { return false }
 return textContent(of: message).contains(AgentRunner.synthesisReminderBody)
 }),
 "all-error short-circuit must not inject the synthesis reminder"
 )
 }

 func test_runner_mixedToolBatch_keepsNormalSynthesisFollowup() async throws {
 let okUse = ParsedToolCall(id: "echo_1", name: "echo", inputJSON: "{}")
 let failUse = ParsedToolCall(id: "fail_1", name: "failing_tool", inputJSON: "{}")
 let onDevice = MockHostAdapter(
 profileID: .gemmaLocal,
 tier: .fast,
 steps: [
 .response(compiledResponse(tier: .fast, text: "", toolCalls: [okUse, failUse])),
 .response(compiledResponse(tier: .fast, text: "done"), streamedTokens: ["done"])
 ]
 )
 let runner = AgentRunner
 let tools: [any RelayTool] = [EchoTool, FailingTool]
 let userMessage: RelayMessage = .user(UserContent(blocks: [.text("run both tools")]))
 let (stream, continuation) = AsyncThrowingStream<TurnEvent, Error>.makeStream

 async let runnerResult: (state: AgentSessionState, exit: AgentRunner.TurnExit) = {
 let r = await runner.run(
 sessionID: "mixed-tool-batch",
 initialUserMessage: userMessage,
 state: .empty,
 contextBuilder: self.makeContextBuilder,
 onDeviceClient: onDevice,
 cloudClient: nil,
 dispatcher: ToolDispatcher,
 toolContextFor: self.makeToolContext,
 tools: tools,
 toolCatalog: tools.map { $0.catalogEntry(source: .builtin) },
 enabledToolNames: Set(tools.map { $0.name }),
 environment: .current,
 extraSystemContext: [:],
 options: .init(),
 continuation: continuation
 )
 continuation.finish()
 return r
 }

 for try await _ in stream {}

 let (newState, exit) = await runnerResult
 XCTAssertEqual(exit, .completed)
 XCTAssertEqual(
 onDevice.snapshotRequests.count, 2,
 "mixed batches should still run the follow-up synthesis iteration"
 )
 XCTAssertEqual(textContent(of: newState.messages.last!), "done")
 }

 func test_runner_toolSpecialistOverridesPrimaryToolPlan_andRecordsArtifacts() async throws {
 let primaryUse = ParsedToolCall(id: "primary_1", name: "wrong_echo", inputJSON: "{}")
 let specialistUse = ParsedToolCall(id: "spec_1", name: "echo", inputJSON: "{}")

 let onDevice = MockHostAdapter(
 profileID: .gemmaLocal,
 tier: .fast,
 steps: [
 .response(compiledResponse(tier: .fast, text: "", toolCalls: [primaryUse])),
 .response(compiledResponse(tier: .fast, text: "done"), streamedTokens: ["done"])
 ]
 )
 let specialist = MockHostAdapter(
 profileID: .functionGemmaTool,
 tier: .toolSpecialist,
 steps: [
 .response(compiledResponse(tier: .toolSpecialist, text: "", toolCalls: [specialistUse]))
 ]
 )
 let runner = AgentRunner
 let tool = EchoTool
 let userMessage: RelayMessage = .user(UserContent(blocks: [.text("run echo")]))
 let (stream, continuation) = AsyncThrowingStream<TurnEvent, Error>.makeStream

 async let runResult: AgentRunner.RunResult = {
 let result = await runner.runWithArtifacts(
 turnID: UUID,
 sessionID: "session-tools",
 initialUserMessage: userMessage,
 state: .empty,
 contextBuilder: self.makeContextBuilder,
 onDeviceClient: onDevice,
 cloudClient: nil,
 toolSpecialistClient: specialist,
 dispatcher: ToolDispatcher,
 toolContextFor: self.makeToolContext,
 tools: [tool],
 toolCatalog: [tool.catalogEntry(source: .builtin)],
 enabledToolNames: ["echo"],
 environment: .current,
 extraSystemContext: [:],
 options: .init(),
 continuation: continuation
 )
 continuation.finish()
 return result
 }

 var routingTiers: [ModelTier] = []
 var seenTokens: [String] = []
 for try await event in stream {
 switch event {
 case .routingDecision(let tier, _):
 routingTiers.append(tier)
 case .tokenReceived(let token):
 seenTokens.append(token)
 default:
 break
 }
 }

 let result = await runResult
 XCTAssertEqual(result.exit, .completed)
 XCTAssertTrue(routingTiers.contains(.toolSpecialist))
 XCTAssertEqual(seenTokens, ["done"])
 XCTAssertEqual(result.state.recentToolState.lastCompletedBatch.count, 1)
 XCTAssertEqual(result.state.recentToolState.lastCompletedBatch.first?.toolUseId, "spec_1")
 XCTAssertEqual(result.state.recentToolState.lastCompletedBatch.first?.outputPreview, "ok")
 XCTAssertEqual(result.artifacts.toolExecutions?.count, 1)
 XCTAssertEqual(result.artifacts.toolExecutions?.first?.toolName, "echo")
 XCTAssertEqual(result.artifacts.approvalDecisions?.count, 1)
 XCTAssertEqual(result.artifacts.approvalDecisions?.first?.toolName, "echo")
 XCTAssertTrue(result.artifacts.attempts.allSatisfy { $0.compiledRequest != nil })
 XCTAssertTrue(result.artifacts.attempts.compactMap(\.compiledResponse).count >= 2)
 XCTAssertTrue(
 result.artifacts.attempts.contains(where: {
 $0.modelTier == .toolSpecialist &&
 $0.compiledRequest?.profileID == .functionGemmaTool &&
 $0.compiledResponse?.toolCalls.first?.name == "echo"
 })
 )
 }

 func test_runner_toolSpecialistEmptyFallback_usesPrimaryToolPlanExactlyOnce() async throws {
 let primaryUse = ParsedToolCall(id: "primary_1", name: "echo", inputJSON: "{}")

 let onDevice = MockHostAdapter(
 profileID: .gemmaLocal,
 tier: .fast,
 steps: [
 .response(compiledResponse(tier: .fast, text: "", toolCalls: [primaryUse])),
 .response(compiledResponse(tier: .fast, text: "done"), streamedTokens: ["done"])
 ]
 )
 let specialist = MockHostAdapter(
 profileID: .functionGemmaTool,
 tier: .toolSpecialist,
 steps: [
 .response(compiledResponse(tier: .toolSpecialist, text: "", finishReason: .empty))
 ]
 )
 let runner = AgentRunner
 let tool = EchoTool
 let userMessage: RelayMessage = .user(UserContent(blocks: [.text("run echo")]))
 let (stream, continuation) = AsyncThrowingStream<TurnEvent, Error>.makeStream

 async let runResult: AgentRunner.RunResult = {
 let result = await runner.runWithArtifacts(
 turnID: UUID,
 sessionID: "session-tools-fallback",
 initialUserMessage: userMessage,
 state: .empty,
 contextBuilder: self.makeContextBuilder,
 onDeviceClient: onDevice,
 cloudClient: nil,
 toolSpecialistClient: specialist,
 dispatcher: ToolDispatcher,
 toolContextFor: self.makeToolContext,
 tools: [tool],
 toolCatalog: [tool.catalogEntry(source: .builtin)],
 enabledToolNames: ["echo"],
 environment: .current,
 extraSystemContext: [:],
 options: .init(),
 continuation: continuation
 )
 continuation.finish()
 return result
 }

 for try await _ in stream {}

 let result = await runResult
 XCTAssertEqual(result.exit, .completed)
 XCTAssertEqual(result.state.recentToolState.lastCompletedBatch.count, 1)
 XCTAssertEqual(result.state.recentToolState.lastCompletedBatch.first?.toolUseId, "primary_1")
 XCTAssertEqual(result.artifacts.toolExecutions?.count, 1)
 XCTAssertEqual(result.artifacts.approvalDecisions?.count, 1)
 XCTAssertTrue(
 result.artifacts.attempts.contains(where: {
 $0.modelTier == .toolSpecialist &&
 ($0.errorSummary?.contains("falling back to the primary tool plan") == true)
 })
 )
 }

 func test_cactusHostAdapterWrap_suppressesTokensWhenRequestDisablesVisibleTokens() async throws {
 let tool = EchoTool
 let builder = makeContextBuilder
 let request = await builder.buildCompiledTurn(
 turnID: UUID,
 sessionID: "session-hidden",
 state: AgentSessionState(
 messages: [.user(UserContent(blocks: [.text("run echo")]))],
 turnCount: 1
 ),
 enabledToolNames: ["echo"],
 environment: .current,
 extraSystemContext: [:],
 toolCatalog: [tool.catalogEntry(source: .builtin)],
 options: .init()
 ).with(
 hostOptions: HostExecutionOptions(
 completionOptions: .init(),
 toolMode: .required,
 emitVisibleTokens: false,
 allowCloudHandoff: false
 )
 )

 let stream = AsyncThrowingStream<CactusModelHost.StreamEvent, Error> { continuation in
 continuation.yield(.token("hidden token"))
 continuation.yield(.done(self.result(text: "tool plan")))
 continuation.finish()
 }

 var visibleTokens: [String] = []
 var completions: [CompiledTurnResponse] = []
 for try await event in CactusOnDeviceHostAdapter.wrap(stream, request: request, tier: .toolSpecialist) {
 switch event {
 case .token(let token):
 visibleTokens.append(token)
 case .finished(let response):
 completions.append(response)
 }
 }

 XCTAssertTrue(visibleTokens.isEmpty)
 XCTAssertEqual(completions.count, 1)
 XCTAssertEqual(completions.first?.tier, .toolSpecialist)
 XCTAssertEqual(completions.first?.outputText, "tool plan")
 }

 // MARK: - Test 5: empty stream

 func test_runner_emptyStream_exitsWithNoCompletion() async throws {
 let mock = EmptyMockModelClient
 let runner = AgentRunner
 let userMessage: RelayMessage = .user(UserContent(blocks: [.text("hi")]))

 let (stream, continuation) = AsyncThrowingStream<TurnEvent, Error>.makeStream

 async let runnerResult: (state: AgentSessionState, exit: AgentRunner.TurnExit) = {
 let r = await runner.run(
 initialUserMessage: userMessage,
 state: .empty,
 contextBuilder: self.makeContextBuilder,
 onDeviceClient: mock,
 cloudClient: nil,
 dispatcher: ToolDispatcher,
 toolContextFor: self.makeToolContext,
 tools: [],
 enabledToolNames: [],
 environment: .current,
 extraSystemContext: [:],
 options: .init(),
 continuation: continuation
 )
 continuation.finish()
 return r
 }

 var failureMessage: String?
 for try await event in stream {
 if case .failure(let m) = event { failureMessage = m }
 }

 let (failedState, exit) = await runnerResult
 XCTAssertEqual(failureMessage, "No completion result from model")
 XCTAssertEqual(failedState.recoveryState.lastExit, .noCompletion)
 XCTAssertEqual(failedState.recoveryState.lastContinuationReason, .fatalError)
 XCTAssertEqual(failedState.recoveryState.lastErrorMessage, "No completion result from model")
 XCTAssertEqual(failedState.recoveryState.consecutiveFailures, 1)

 if case .noCompletion = exit {
 // expected
 } else {
 XCTFail("expected .noCompletion, got \(exit)")
 }
 }

 // MARK: - Test 6: retrieval state updates

 func test_runner_recordsRetrievalStateWhenAttachmentChunksMatch() async throws {
 let sessionId = "runner-hit-\(UUID().uuidString)"
 defer { cleanSessionDir(sessionId) }

 let fixtureDir = FileManager.default.temporaryDirectory
 .appendingPathComponent("RelayRunner-\(UUID().uuidString)", isDirectory: true)
 try FileManager.default.createDirectory(at: fixtureDir, withIntermediateDirectories: true)
 let fixtureURL = fixtureDir.appendingPathComponent("ResetGuide.txt")
 try "reset the device by holding the power button".data(using: .utf8)!.write(to: fixtureURL)

 let attachment = try AttachmentIndexer.ingest(fileURL: fixtureURL, displayName: "ResetGuide.txt")
 let store = AttachmentStore(sessionId: sessionId)
 try await store.ingest(attachment)

 let mock = MockModelClient(responses: [result(text: "here")])
 let runner = AgentRunner
 let userMessage: RelayMessage = .user(UserContent(blocks: [.text("how do I reset the device?")]))

 let (stream, continuation) = AsyncThrowingStream<TurnEvent, Error>.makeStream
 async let runnerResult: (state: AgentSessionState, exit: AgentRunner.TurnExit) = {
 let r = await runner.run(
 initialUserMessage: userMessage,
 state: .empty,
 contextBuilder: self.makeContextBuilder(attachmentStore: store),
 onDeviceClient: mock,
 cloudClient: nil,
 dispatcher: ToolDispatcher,
 toolContextFor: self.makeToolContext,
 tools: [],
 enabledToolNames: [],
 environment: .current,
 extraSystemContext: [:],
 options: .init(),
 continuation: continuation
 )
 continuation.finish()
 return r
 }

 for try await _ in stream {}

 let (newState, exit) = await runnerResult
 XCTAssertEqual(exit, .completed)
 XCTAssertEqual(newState.retrievalState.lastQuery, "how do I reset the device?")
 XCTAssertEqual(newState.retrievalState.lastPlannedAtTurnCount, 1)
 XCTAssertNotNil(newState.retrievalState.lastDecision)
 XCTAssertEqual(newState.retrievalState.lastDecision?.injectedArtifactCount, 1)
 XCTAssertEqual(newState.retrievalState.lastDecision?.selectedArtifacts.first?.sourceDisplayName, "ResetGuide.txt")
 }

 func test_runner_recordsRetrievalMissWithoutSelectedChunks() async throws {
 let sessionId = "runner-miss-\(UUID().uuidString)"
 defer { cleanSessionDir(sessionId) }

 let fixtureDir = FileManager.default.temporaryDirectory
 .appendingPathComponent("RelayRunner-\(UUID().uuidString)", isDirectory: true)
 try FileManager.default.createDirectory(at: fixtureDir, withIntermediateDirectories: true)
 let fixtureURL = fixtureDir.appendingPathComponent("GreetingNotes.txt")
 try "greeting greeting greeting".data(using: .utf8)!.write(to: fixtureURL)

 let attachment = try AttachmentIndexer.ingest(fileURL: fixtureURL, displayName: "GreetingNotes.txt")
 let store = AttachmentStore(sessionId: sessionId)
 try await store.ingest(attachment)

 let mock = MockModelClient(responses: [result(text: "here")])
 let runner = AgentRunner
 let userMessage: RelayMessage = .user(UserContent(blocks: [.text("how do I reset the device?")]))

 let (stream, continuation) = AsyncThrowingStream<TurnEvent, Error>.makeStream
 async let runnerResult: (state: AgentSessionState, exit: AgentRunner.TurnExit) = {
 let r = await runner.run(
 initialUserMessage: userMessage,
 state: .empty,
 contextBuilder: self.makeContextBuilder(attachmentStore: store),
 onDeviceClient: mock,
 cloudClient: nil,
 dispatcher: ToolDispatcher,
 toolContextFor: self.makeToolContext,
 tools: [],
 enabledToolNames: [],
 environment: .current,
 extraSystemContext: [:],
 options: .init(),
 continuation: continuation
 )
 continuation.finish()
 return r
 }

 for try await _ in stream {}

 let (newState, exit) = await runnerResult
 XCTAssertEqual(exit, .completed)
 XCTAssertEqual(newState.retrievalState.lastQuery, "how do I reset the device?")
 XCTAssertEqual(newState.retrievalState.lastPlannedAtTurnCount, 1)
 XCTAssertNil(newState.retrievalState.lastDecision)
 }

 // MARK: - Test 7: turnCount increments once per call

 /// `AgentRunner.run(...)` must increment `turnCount` by
 /// exactly 1 per invocation, not per inner loop iteration. Two
 /// successive calls starting from `state.turnCount = 0` must end
 /// with `turnCount == 2`.
 func test_runner_incrementsTurnCountExactlyOncePerCall() async throws {
 let mock = MockModelClient(responses: [
 result(text: "reply 1"),
 result(text: "reply 2"),
 ])
 let runner = AgentRunner

 func runOnce(state: AgentSessionState, userText: String) async -> AgentSessionState {
 let userMessage: RelayMessage = .user(UserContent(blocks: [.text(userText)]))
 let (stream, continuation) = AsyncThrowingStream<TurnEvent, Error>.makeStream
 async let r: (state: AgentSessionState, exit: AgentRunner.TurnExit) = {
 let result = await runner.run(
 initialUserMessage: userMessage,
 state: state,
 contextBuilder: self.makeContextBuilder,
 onDeviceClient: mock,
 cloudClient: nil,
 dispatcher: ToolDispatcher,
 toolContextFor: self.makeToolContext,
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
 do { for try await _ in stream {} } catch {}
 let (newState, _) = await r
 return newState
 }

 let afterFirst = await runOnce(state: .empty, userText: "one")
 XCTAssertEqual(afterFirst.turnCount, 1, "first call should increment to 1")

 let afterSecond = await runOnce(state: afterFirst, userText: "two")
 XCTAssertEqual(afterSecond.turnCount, 2, "second call should increment to 2")
 XCTAssertEqual(afterSecond.messages.count, 4, "two turns of [user, assistant]")
 }

 // MARK: - Test 8: meta user messages do not increment turnCount (regression)

 /// regression: `<system-reminder>` meta-user messages
 /// (`UserContent.isMeta == true`) must NOT increment `turnCount`.
 /// Hydrate derives the same way (see
 /// `test_derivedTurnCount_skipsMetaUserMessages`), and the runtime
 /// increment rule must agree so resume + live turns stay consistent.
 func test_runner_metaUserMessage_doesNotIncrementTurnCount() async throws {
 let mock = MockModelClient(responses: [result(text: "ack")])
 let runner = AgentRunner

 let metaMessage: RelayMessage = .user(UserContent(
 blocks: [.text("<system-reminder>\ncontext\n</system-reminder>")],
 isMeta: true
 ))

 let (stream, continuation) = AsyncThrowingStream<TurnEvent, Error>.makeStream
 async let runnerResult: (state: AgentSessionState, exit: AgentRunner.TurnExit) = {
 let r = await runner.run(
 initialUserMessage: metaMessage,
 state: .empty,
 contextBuilder: self.makeContextBuilder,
 onDeviceClient: mock,
 cloudClient: nil,
 dispatcher: ToolDispatcher,
 toolContextFor: self.makeToolContext,
 tools: [],
 enabledToolNames: [],
 environment: .current,
 extraSystemContext: [:],
 options: .init(),
 continuation: continuation
 )
 continuation.finish()
 return r
 }

 do { for try await _ in stream {} } catch {}

 let (newState, _) = await runnerResult
 XCTAssertEqual(newState.turnCount, 0, "meta user messages must not count as user turns")
 XCTAssertEqual(newState.messages.count, 2, "message still appended (user-meta + assistant)")
 }

 func test_runner_runtimeAudit_fiveTurnScript_keepsCanonicalLatestUserDominance() async throws {
 let host = MockHostAdapter(
 profileID: .gemmaLocal,
 tier: .fast,
 steps: [
 .response(compiledResponse(tier: .fast, text: "I'm doing well, thanks. What's on your mind?")),
 .response(compiledResponse(tier: .fast, text: "My name is Glass.")),
 .response(compiledResponse(tier: .fast, text: "I don't know your name yet. Tell me and I'll remember it.")),
 .response(compiledResponse(tier: .fast, text: "Got it. Your name is Isaac.")),
 .response(compiledResponse(tier: .fast, text: "Your name is Isaac."))
 ]
 )
 let runner = AgentRunner
 let script: [(text: String, classification: TurnClassification, expectedReply: String)] = [
 ("Hi, how are you?", .socialOpener, "I'm doing well, thanks. What's on your mind?"),
 ("What is your name?", .question, "My name is Glass."),
 ("What is my name?", .factRecallUnknown, "I don't know your name yet. Tell me and I'll remember it."),
 ("My name is Isaac. Please remember that.", .declarativeFact, "Got it. Your name is Isaac."),
 ("What is my name?", .factRecallKnown, "Your name is Isaac.")
 ]

 var state = AgentSessionState.empty

 for (index, step) in script.enumerated() {
 let normalizedTurn = NormalizedTurn(
 transcriptMessage: .user(UserContent(blocks: [.text(step.text)])),
 modelMessage: .user(UserContent(blocks: [.text(step.text)]))
 )
 let currentState = state
 let (stream, continuation) = AsyncThrowingStream<TurnEvent, Error>.makeStream

 async let runResult: AgentRunner.RunResult = {
 let result = await runner.runWithArtifacts(
 turnID: normalizedTurn.turnID,
 sessionID: "runtime-audit",
 initialTurn: normalizedTurn,
 state: currentState,
 contextBuilder: self.makeContextBuilder,
 onDeviceClient: host,
 cloudClient: nil,
 toolSpecialistClient: nil,
 dispatcher: ToolDispatcher,
 toolContextFor: self.makeToolContext,
 tools: [],
 toolCatalog: [],
 enabledToolNames: [],
 environment: .current,
 extraSystemContext: [:],
 options: .init(),
 continuation: continuation
 )
 continuation.finish()
 return result
 }

 for try await _ in stream {}

 let result = await runResult
 state = result.state

 let request = try XCTUnwrap(host.snapshotRequests[safe: index])
 XCTAssertEqual(lastNonMetaUserText(in: request.messages), step.text)
 XCTAssertEqual(request.diagnostics.latestNonMetaUserText, step.text)
 XCTAssertEqual(request.bindingContext?.classification, step.classification)
 XCTAssertEqual(request.diagnostics.turnClassification, step.classification)
 XCTAssertFalse(step.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
 XCTAssertFalse(request.diagnostics.latestNonMetaUserText?.isEmpty ?? true)

 let focus = try XCTUnwrap(request.diagnostics.currentTurnFocus)
 XCTAssertTrue(
 focus.contains("Latest user message:\n\(step.text)"),
 "turn \(index + 1) focus should anchor the latest user text"
 )

 let visibleReply = try XCTUnwrap(result.state.messages.last)
 XCTAssertEqual(textContent(of: visibleReply), step.expectedReply)

 switch index {
 case 0:
 XCTAssertFalse(step.expectedReply.localizedCaseInsensitiveContains("open-ended"))
 XCTAssertFalse(step.expectedReply.localizedCaseInsensitiveContains("how can i help you today"))
 case 1:
 XCTAssertFalse(step.expectedReply.localizedCaseInsensitiveContains("gemma 4"))
 case 2:
 XCTAssertFalse(step.expectedReply.localizedCaseInsensitiveContains("please tell me what you would like to do next"))
 XCTAssertFalse(step.expectedReply.localizedCaseInsensitiveContains("how can i help you today"))
 default:
 break
 }
 }
 }

 func test_runner_canonicalCurrentTurnModelPath_preservesFileProjectionInHostRequest() async throws {
 let attachmentID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE") ?? UUID()
 let normalizedTurn = NormalizedTurn(
 transcriptMessage: .user(
 UserContent(
 blocks: [
 .text("Summarize this."),
 .fileRef(
 ImportedFileRef(
 attachmentID: attachmentID,
 displayName: "Guide.md",
 contentTypeIdentifier: "public.plain-text"
 )
 )
 ]
 )
 ),
 modelMessage: .user(
 UserContent(
 blocks: [
 .text("Attached files: Guide.md.\n\nSummarize this.")
 ]
 )
 )
 )
 let host = MockHostAdapter(
 profileID: .gemmaLocal,
 tier: .fast,
 steps: [
 .response(compiledResponse(tier: .fast, text: "Summary ready."))
 ]
 )
 let runner = AgentRunner
 let (stream, continuation) = AsyncThrowingStream<TurnEvent, Error>.makeStream

 async let runResult: AgentRunner.RunResult = {
 let result = await runner.runWithArtifacts(
 turnID: normalizedTurn.turnID,
 sessionID: "file-projection",
 initialTurn: normalizedTurn,
 state: .empty,
 contextBuilder: self.makeContextBuilder,
 onDeviceClient: host,
 cloudClient: nil,
 toolSpecialistClient: nil,
 dispatcher: ToolDispatcher,
 toolContextFor: self.makeToolContext,
 tools: [],
 toolCatalog: [],
 enabledToolNames: [],
 environment: .current,
 extraSystemContext: [:],
 options: .init(),
 continuation: continuation
 )
 continuation.finish()
 return result
 }

 for try await _ in stream {}
 _ = await runResult

 let request = try XCTUnwrap(host.snapshotRequests.first)
 XCTAssertEqual(lastNonMetaUserText(in: request.messages), "Attached files: Guide.md.\n\nSummarize this.")
 XCTAssertEqual(request.diagnostics.latestNonMetaUserText, "Attached files: Guide.md.\n\nSummarize this.")
 XCTAssertTrue(
 request.diagnostics.currentTurnFocus?.contains("Latest user message:\nSummarize this.") == true,
 "focus should still reflect the user-visible transcript text"
 )
 }

 // MARK: - textOnlyFallback ( empty-output guard)

 /// Device rerun round 4, Turn 2: primary early-aborted (synthesizing
 /// `CompiledTurnResponse` with `outputText: ""`), cloud Gemini also
 /// failed re-validation, so `textOnlyFallback(from:reason:)` was called with
 /// an empty `outputText`. Prior implementation appended
 /// `"\n\n[Cloud fallback unavailable...]"` to `""`, producing a
 /// near-empty assistant bubble. The guard now swaps in a user-facing
 /// sentence instead.
 func test_textOnlyFallback_cloudResponseRejected_whenOutputIsEmpty_returnsUserFacingMessage() {
 let emptyResult = CompiledTurnResponse(
 tier: .fast,
 outputText: "",
 toolCalls: [],
 finishReason: .message,
 rawCompletion: nil
 )
 let fallback = AgentRunner.textOnlyFallback(
 from: emptyResult,
 reason: .cloudResponseRejected
 )
 XCTAssertEqual(fallback.outputText, AgentRunner.emptyFallbackMessage)
 XCTAssertEqual(fallback.toolCalls.count, 0)
 XCTAssertEqual(fallback.finishReason, .message)
 }

 /// Quality failure, not availability failure: cloud was actually
 /// called but its response was rejected by the validator, so the
 /// user should silently see the on-device text with NO unavailable
 /// disclaimer.
 func test_textOnlyFallback_cloudResponseRejected_whenOutputIsNonEmpty_isSilent() {
 let nonEmptyResult = CompiledTurnResponse(
 tier: .fast,
 outputText: "The capital of France is Paris.",
 toolCalls: [],
 finishReason: .message,
 rawCompletion: nil
 )
 let fallback = AgentRunner.textOnlyFallback(
 from: nonEmptyResult,
 reason: .cloudResponseRejected
 )
 XCTAssertEqual(fallback.outputText, "The capital of France is Paris.")
 XCTAssertEqual(fallback.toolCalls.count, 0)
 XCTAssertEqual(fallback.finishReason, .message)
 }

 /// Regression guard: true availability failures still append the
 /// unavailable disclaimer to non-empty on-device text.
 func test_textOnlyFallback_noCloudClient_whenOutputIsNonEmpty_appendsDisclaimer() {
 let nonEmptyResult = CompiledTurnResponse(
 tier: .fast,
 outputText: "The capital of France is Paris.",
 toolCalls: [],
 finishReason: .message,
 rawCompletion: nil
 )
 let fallback = AgentRunner.textOnlyFallback(
 from: nonEmptyResult,
 reason: .noCloudClient
 )
 XCTAssertTrue(fallback.outputText.hasPrefix("The capital of France is Paris."))
 XCTAssertTrue(
 fallback.outputText.contains("[Cloud fallback unavailable — showing on-device response]")
 )
 XCTAssertEqual(fallback.toolCalls.count, 0)
 XCTAssertEqual(fallback.finishReason, .message)
 }

 func test_textOnlyFallback_cloudRetryFailed_whenOutputIsNonEmpty_appendsDisclaimer() {
 let nonEmptyResult = CompiledTurnResponse(
 tier: .fast,
 outputText: "The capital of France is Paris.",
 toolCalls: [],
 finishReason: .message,
 rawCompletion: nil
 )
 let fallback = AgentRunner.textOnlyFallback(
 from: nonEmptyResult,
 reason: .cloudRetryFailed
 )
 XCTAssertTrue(fallback.outputText.hasPrefix("The capital of France is Paris."))
 XCTAssertTrue(
 fallback.outputText.contains("[Cloud fallback unavailable — showing on-device response]")
 )
 XCTAssertEqual(fallback.toolCalls.count, 0)
 XCTAssertEqual(fallback.finishReason, .message)
 }

 // MARK: - T13 long-context summarization pre-route

 /// When the user asks to summarize the current conversation, pre-route
 /// fires BEFORE on-device Gemma is invoked. Assert: on-device adapter
 /// is never called; cloud adapter is called exactly once; final
 /// assistant text comes from cloud.
 func test_runner_preRoutesConversationSummarization_bypassesOnDevice() async throws {
 let onDevice = MockHostAdapter(
 profileID: .gemmaLocal,
 tier: .fast,
 steps: [
 .response(
 compiledResponse(
 tier: .fast,
 text: "If we ran, we'd hallucinate a brief conversation.",
 finishReason: .message
 ),
 streamedTokens: ["If we ran, we'd hallucinate a brief conversation."]
 )
 ]
 )
 let cloud = MockHostAdapter(
 profileID: .geminiCloud,
 tier: .cloud,
 steps: [
 .response(
 compiledResponse(
 tier: .cloud,
 text: "We talked about project prep, validator fixes, and the T13 issue."
 ),
 streamedTokens: ["We talked about project prep, validator fixes, and the T13 issue."]
 )
 ]
 )
 let runner = AgentRunner
 let userMessage: RelayMessage = .user(UserContent(blocks: [.text("Summarize our conversation so far")]))
 let (stream, continuation) = AsyncThrowingStream<TurnEvent, Error>.makeStream

 async let runnerResult: (state: AgentSessionState, exit: AgentRunner.TurnExit) = {
 let r = await runner.run(
 sessionID: "t13-preroute-session",
 initialUserMessage: userMessage,
 state: .empty,
 contextBuilder: self.makeContextBuilder,
 onDeviceClient: onDevice,
 cloudClient: cloud,
 dispatcher: ToolDispatcher,
 toolContextFor: self.makeToolContext,
 tools: [],
 toolCatalog: [],
 enabledToolNames: [],
 environment: .current,
 extraSystemContext: [:],
 options: .init(),
 continuation: continuation
 )
 continuation.finish()
 return r
 }

 for try await _ in stream {}
 let (newState, exit) = await runnerResult

 XCTAssertEqual(exit, .completed)
 XCTAssertEqual(
 onDevice.snapshotRequests.count, 0,
 "pre-route should bypass on-device Gemma entirely"
 )
 XCTAssertEqual(
 cloud.snapshotRequests.count, 1,
 "cloud should be called exactly once (no infinite pre-route loop)"
 )
 XCTAssertEqual(newState.recoveryState.cloudFallbackUsedLastTurn, true)

 // Final assistant text came from cloud, not on-device.
 guard case .assistant(let content) = newState.messages.last else {
 return XCTFail("expected assistant message as last entry")
 }
 let assistantText = content.blocks.compactMap { block -> String? in
 if case .text(let t) = block { return t } else { return nil }
 }.joined()
 XCTAssertTrue(
 assistantText.contains("project prep"),
 "expected cloud response; got: \(assistantText)"
 )
 }

 /// Negative case: arbitrary summarization that isn't about the
 /// conversation itself (e.g., summarizing an attached article) must
 /// stay on-device. Pre-route must NOT fire.
 func test_runner_doesNotPreRouteArbitrarySummarization() async throws {
 let onDevice = MockHostAdapter(
 profileID: .gemmaLocal,
 tier: .fast,
 steps: [
 .response(
 compiledResponse(tier: .fast, text: "Short summary: rain in Spain."),
 streamedTokens: ["Short summary: rain in Spain."]
 )
 ]
 )
 let cloud = MockHostAdapter(
 profileID: .geminiCloud,
 tier: .cloud,
 steps: [
 .response(
 compiledResponse(tier: .cloud, text: "SHOULD NOT BE CALLED"),
 streamedTokens: ["SHOULD NOT BE CALLED"]
 )
 ]
 )
 let runner = AgentRunner
 let userMessage: RelayMessage = .user(UserContent(blocks: [.text("Summarize this article for me")]))
 let (stream, continuation) = AsyncThrowingStream<TurnEvent, Error>.makeStream

 async let runnerResult: (state: AgentSessionState, exit: AgentRunner.TurnExit) = {
 let r = await runner.run(
 sessionID: "t13-no-preroute-session",
 initialUserMessage: userMessage,
 state: .empty,
 contextBuilder: self.makeContextBuilder,
 onDeviceClient: onDevice,
 cloudClient: cloud,
 dispatcher: ToolDispatcher,
 toolContextFor: self.makeToolContext,
 tools: [],
 toolCatalog: [],
 enabledToolNames: [],
 environment: .current,
 extraSystemContext: [:],
 options: .init(),
 continuation: continuation
 )
 continuation.finish()
 return r
 }

 for try await _ in stream {}
 _ = await runnerResult

 XCTAssertEqual(
 onDevice.snapshotRequests.count, 1,
 "on-device must handle non-conversation-scope summarization"
 )
 XCTAssertEqual(
 cloud.snapshotRequests.count, 0,
 "cloud must not be called when pre-route doesn't match"
 )
 }

 /// Recall-phrase path: "What have we discussed?" triggers pre-route
 /// just like "Summarize our conversation" — no verb-match required.
 func test_runner_preRoutesRecallPhrase_bypassesOnDevice() async throws {
 let onDevice = MockHostAdapter(
 profileID: .gemmaLocal,
 tier: .fast,
 steps: [
 .response(
 compiledResponse(tier: .fast, text: "Wrong: short hallucinated recall."),
 streamedTokens: ["Wrong: short hallucinated recall."]
 )
 ]
 )
 let cloud = MockHostAdapter(
 profileID: .geminiCloud,
 tier: .cloud,
 steps: [
 .response(
 compiledResponse(tier: .cloud, text: "We covered topic A, topic B, and topic C."),
 streamedTokens: ["We covered topic A, topic B, and topic C."]
 )
 ]
 )
 let runner = AgentRunner
 let userMessage: RelayMessage = .user(UserContent(blocks: [.text("What have we discussed?")]))
 let (stream, continuation) = AsyncThrowingStream<TurnEvent, Error>.makeStream

 async let runnerResult: (state: AgentSessionState, exit: AgentRunner.TurnExit) = {
 let r = await runner.run(
 sessionID: "t13-recall-session",
 initialUserMessage: userMessage,
 state: .empty,
 contextBuilder: self.makeContextBuilder,
 onDeviceClient: onDevice,
 cloudClient: cloud,
 dispatcher: ToolDispatcher,
 toolContextFor: self.makeToolContext,
 tools: [],
 toolCatalog: [],
 enabledToolNames: [],
 environment: .current,
 extraSystemContext: [:],
 options: .init(),
 continuation: continuation
 )
 continuation.finish()
 return r
 }

 for try await _ in stream {}
 _ = await runnerResult

 XCTAssertEqual(onDevice.snapshotRequests.count, 0)
 XCTAssertEqual(cloud.snapshotRequests.count, 1)
 }

 // MARK: - Round-5 long-context pre-route

 /// Build a session state with `pairCount` alternating user/assistant
 /// turn pairs, plus an empty `turnCount` derived from those messages.
 /// Used by the long-context pre-route tests to push history past
 /// the threshold without depending on test-internal turn loops.
 private func makeStateWithHistory(pairCount: Int) -> AgentSessionState {
 var messages: [RelayMessage] = []
 for i in 0..<pairCount {
 messages.append(.user(UserContent(blocks: [.text("user msg \(i)")])))
 messages.append(.assistant(AssistantContent(blocks: [.text("assistant reply \(i)")])))
 }
 return AgentSessionState(messages: messages, turnCount: pairCount)
 }

 /// At history >= 10 messages, ANY classification gets pre-routed to
 /// cloud (Gemma's effective context window). Asserts on-device is
 /// bypassed and cloud is called once even for an arbitrary
 /// `.question` ("What's the capital of Japan?") that the T13
 /// summarization pre-route would NOT match.
 func test_runner_longContextPreRoute_atTenMessages_bypassesOnDevice() async throws {
 let onDevice = MockHostAdapter(
 profileID: .gemmaLocal,
 tier: .fast,
 steps: [
 .response(
 compiledResponse(tier: .fast, text: "SHOULD NOT BE CALLED"),
 streamedTokens: ["SHOULD NOT BE CALLED"]
 )
 ]
 )
 let cloud = MockHostAdapter(
 profileID: .geminiCloud,
 tier: .cloud,
 steps: [
 .response(
 compiledResponse(tier: .cloud, text: "Tokyo."),
 streamedTokens: ["Tokyo."]
 )
 ]
 )
 let runner = AgentRunner
 // 5 prior user-assistant pairs = 10 prior messages; the new user
 // message brings the request to 11 messages — past the threshold.
 let priorState = makeStateWithHistory(pairCount: 5)
 let userMessage: RelayMessage = .user(UserContent(blocks: [.text("What's the capital of Japan?")]))
 let (stream, continuation) = AsyncThrowingStream<TurnEvent, Error>.makeStream

 async let runnerResult: (state: AgentSessionState, exit: AgentRunner.TurnExit) = {
 let r = await runner.run(
 sessionID: "longctx-preroute",
 initialUserMessage: userMessage,
 state: priorState,
 contextBuilder: self.makeContextBuilder,
 onDeviceClient: onDevice,
 cloudClient: cloud,
 dispatcher: ToolDispatcher,
 toolContextFor: self.makeToolContext,
 tools: [],
 toolCatalog: [],
 enabledToolNames: [],
 environment: .current,
 extraSystemContext: [:],
 options: .init(),
 continuation: continuation
 )
 continuation.finish()
 return r
 }

 for try await _ in stream {}
 let (newState, exit) = await runnerResult

 XCTAssertEqual(exit, .completed)
 XCTAssertEqual(
 onDevice.snapshotRequests.count, 0,
 "long-context pre-route should bypass on-device Gemma"
 )
 XCTAssertEqual(
 cloud.snapshotRequests.count, 1,
 "cloud should be called exactly once via long-context pre-route"
 )
 XCTAssertEqual(newState.recoveryState.cloudFallbackUsedLastTurn, true)
 }

 /// Boundary: with only 4 prior pairs (8 prior messages + 1 new = 9
 /// total), pre-route does NOT fire. On-device handles the turn.
 func test_runner_longContextPreRoute_belowThreshold_runsOnDevice() async throws {
 let onDevice = MockHostAdapter(
 profileID: .gemmaLocal,
 tier: .fast,
 steps: [
 .response(
 compiledResponse(tier: .fast, text: "Tokyo."),
 streamedTokens: ["Tokyo."]
 )
 ]
 )
 let cloud = MockHostAdapter(
 profileID: .geminiCloud,
 tier: .cloud,
 steps: [
 .response(
 compiledResponse(tier: .cloud, text: "SHOULD NOT BE CALLED"),
 streamedTokens: ["SHOULD NOT BE CALLED"]
 )
 ]
 )
 let runner = AgentRunner
 let priorState = makeStateWithHistory(pairCount: 4)
 let userMessage: RelayMessage = .user(UserContent(blocks: [.text("What's the capital of Japan?")]))
 let (stream, continuation) = AsyncThrowingStream<TurnEvent, Error>.makeStream

 async let runnerResult: (state: AgentSessionState, exit: AgentRunner.TurnExit) = {
 let r = await runner.run(
 sessionID: "longctx-belowthreshold",
 initialUserMessage: userMessage,
 state: priorState,
 contextBuilder: self.makeContextBuilder,
 onDeviceClient: onDevice,
 cloudClient: cloud,
 dispatcher: ToolDispatcher,
 toolContextFor: self.makeToolContext,
 tools: [],
 toolCatalog: [],
 enabledToolNames: [],
 environment: .current,
 extraSystemContext: [:],
 options: .init(),
 continuation: continuation
 )
 continuation.finish()
 return r
 }

 for try await _ in stream {}
 _ = await runnerResult

 XCTAssertEqual(
 onDevice.snapshotRequests.count, 1,
 "below-threshold turns must run on-device"
 )
 XCTAssertEqual(
 cloud.snapshotRequests.count, 0,
 "cloud must not be called below the threshold"
 )
 }

 // MARK: - direct-dispatch shortcut

 /// Reuse-friendly DateTime tool that returns the SAME multi-line
 /// shape as production `DateTimeTool` so the formatter test can run
 /// against a deterministic input.
 private struct FakeDateTimeTool: RelayTool {
 var name: String { "get_current_datetime" }
 var description: String { "test datetime tool" }
 var inputSchema: ToolInputSchema {
 ToolInputSchema(json: #"{"type":"object","properties":{}}"#)
 }
 var isConcurrencySafe: Bool { true }
 var isReadOnly: Bool { true }
 var isDestructive: Bool { false }

 func call(input: ToolInput, context: ToolCallContext) async throws -> ToolResult {
 let output = """
 Date: 2026-04-16
 Time: 11:39:00
 Weekday: Thursday
 Timezone: America/Los_Angeles (UTC-7)
 ISO8601: 2026-04-16T11:39:00-07:00
 """
 return ToolResult(toolUseId: "", output: output, isError: false)
 }
 }

 func test_runner_directDispatch_firesOnExactWhatTimeIsIt() async throws {
 // Mock primary that should NEVER be called — if the shortcut
 // doesn't fire, this would error on the empty step list.
 let onDevice = MockHostAdapter(profileID: .gemmaLocal, tier: .fast, steps: [])
 let runner = AgentRunner
 let userMessage: RelayMessage = .user(UserContent(blocks: [.text("What time is it?")]))
 let (stream, continuation) = AsyncThrowingStream<TurnEvent, Error>.makeStream

 async let runnerResult: (state: AgentSessionState, exit: AgentRunner.TurnExit) = {
 let r = await runner.run(
 sessionID: "shortcut-time",
 initialUserMessage: userMessage,
 state: .empty,
 contextBuilder: self.makeContextBuilder,
 onDeviceClient: onDevice,
 cloudClient: nil,
 dispatcher: ToolDispatcher,
 toolContextFor: self.makeToolContext,
 tools: [FakeDateTimeTool],
 toolCatalog: [FakeDateTimeTool.catalogEntry(source: .builtin)],
 enabledToolNames: ["get_current_datetime"],
 environment: .current,
 extraSystemContext: [:],
 options: .init(),
 continuation: continuation
 )
 continuation.finish()
 return r
 }

 for try await _ in stream {}
 let (newState, exit) = await runnerResult

 XCTAssertEqual(exit, .completed)
 XCTAssertEqual(
 onDevice.snapshotRequests.count, 0,
 "shortcut must bypass the model loop entirely — no on-device requests"
 )
 // Final assistant message is the formatted Glass-shaped sentence.
 guard case .assistant(let content) = newState.messages.last else {
 return XCTFail("expected assistant message as last entry")
 }
 let assistantText = content.blocks.compactMap { block -> String? in
 if case .text(let t) = block { return t } else { return nil }
 }.joined()
 XCTAssertEqual(
 assistantText,
 "It's 11:39 on Thursday, 2026-04-16.",
 "expected formatted shortcut sentence; got: \(assistantText)"
 )
 }

 func test_runner_directDispatch_doesNotFireOnLongerPromptContainingPhrase() async throws {
 // "Tell me about the time complexity of merge sort" contains
 // "the time" — substring match would hijack this. Tight whitelist
 // requires exact match, so this falls through to the model loop.
 let onDevice = MockHostAdapter(
 profileID: .gemmaLocal,
 tier: .fast,
 steps: [
 .response(
 compiledResponse(tier: .fast, text: "Merge sort is O(n log n)."),
 streamedTokens: ["Merge sort is O(n log n)."]
 )
 ]
 )
 let runner = AgentRunner
 let userMessage: RelayMessage = .user(UserContent(blocks: [.text("Tell me about the time complexity of merge sort")]))
 let (stream, continuation) = AsyncThrowingStream<TurnEvent, Error>.makeStream

 async let runnerResult: (state: AgentSessionState, exit: AgentRunner.TurnExit) = {
 let r = await runner.run(
 sessionID: "shortcut-no-hijack",
 initialUserMessage: userMessage,
 state: .empty,
 contextBuilder: self.makeContextBuilder,
 onDeviceClient: onDevice,
 cloudClient: nil,
 dispatcher: ToolDispatcher,
 toolContextFor: self.makeToolContext,
 tools: [FakeDateTimeTool],
 toolCatalog: [FakeDateTimeTool.catalogEntry(source: .builtin)],
 enabledToolNames: ["get_current_datetime"],
 environment: .current,
 extraSystemContext: [:],
 options: .init(),
 continuation: continuation
 )
 continuation.finish()
 return r
 }

 for try await _ in stream {}
 _ = await runnerResult

 XCTAssertGreaterThanOrEqual(
 onDevice.snapshotRequests.count, 1,
 "longer prompt must fall through to the normal model loop"
 )
 }

 func test_runner_directDispatch_doesNotFireOnDeclarativeFact() async throws {
 // Declarative facts route to the normal loop ( deterministic
 // writeback fires there). Shortcut must not hijack them.
 let onDevice = MockHostAdapter(
 profileID: .gemmaLocal,
 tier: .fast,
 steps: [
 .response(
 compiledResponse(tier: .fast, text: "Got it, Isaac."),
 streamedTokens: ["Got it, Isaac."]
 )
 ]
 )
 let runner = AgentRunner
 let userMessage: RelayMessage = .user(UserContent(blocks: [.text("My name is Isaac")]))
 let (stream, continuation) = AsyncThrowingStream<TurnEvent, Error>.makeStream

 async let runnerResult: (state: AgentSessionState, exit: AgentRunner.TurnExit) = {
 let r = await runner.run(
 sessionID: "shortcut-no-hijack-fact",
 initialUserMessage: userMessage,
 state: .empty,
 contextBuilder: self.makeContextBuilder,
 onDeviceClient: onDevice,
 cloudClient: nil,
 dispatcher: ToolDispatcher,
 toolContextFor: self.makeToolContext,
 tools: [FakeDateTimeTool],
 toolCatalog: [FakeDateTimeTool.catalogEntry(source: .builtin)],
 enabledToolNames: ["get_current_datetime"],
 environment: .current,
 extraSystemContext: [:],
 options: .init(),
 continuation: continuation
 )
 continuation.finish()
 return r
 }

 for try await _ in stream {}
 _ = await runnerResult

 XCTAssertGreaterThanOrEqual(
 onDevice.snapshotRequests.count, 1,
 "declarative facts must not be hijacked by the shortcut"
 )
 }

 func test_runner_directDispatch_gracefullyHandlesMissingTool() async throws {
 // Shortcut matches but the tool isn't registered. We should
 // surface a clear user-facing message; never crash.
 let onDevice = MockHostAdapter(profileID: .gemmaLocal, tier: .fast, steps: [])
 let runner = AgentRunner
 let userMessage: RelayMessage = .user(UserContent(blocks: [.text("What time is it?")]))
 let (stream, continuation) = AsyncThrowingStream<TurnEvent, Error>.makeStream

 async let runnerResult: (state: AgentSessionState, exit: AgentRunner.TurnExit) = {
 let r = await runner.run(
 sessionID: "shortcut-missing-tool",
 initialUserMessage: userMessage,
 state: .empty,
 contextBuilder: self.makeContextBuilder,
 onDeviceClient: onDevice,
 cloudClient: nil,
 dispatcher: ToolDispatcher,
 toolContextFor: self.makeToolContext,
 tools: [], // ← no tools registered
 toolCatalog: [],
 enabledToolNames: [],
 environment: .current,
 extraSystemContext: [:],
 options: .init(),
 continuation: continuation
 )
 continuation.finish()
 return r
 }

 for try await _ in stream {}
 let (newState, exit) = await runnerResult

 XCTAssertEqual(exit, .completed, "missing tool must not crash the run")
 guard case .assistant(let content) = newState.messages.last else {
 return XCTFail("expected assistant message as last entry")
 }
 let assistantText = content.blocks.compactMap { block -> String? in
 if case .text(let t) = block { return t } else { return nil }
 }.joined()
 XCTAssertTrue(
 assistantText.contains("get_current_datetime"),
 "missing-tool fallback message should name the tool"
 )
 }

 func test_formatDateTimeShortcutResult_rendersCleanSentence() {
 let raw = """
 Date: 2026-04-16
 Time: 11:39:00
 Weekday: Thursday
 Timezone: America/Los_Angeles (UTC-7)
 ISO8601: 2026-04-16T11:39:00-07:00
 """
 XCTAssertEqual(
 AgentRunner.formatDateTimeShortcutResult(raw),
 "It's 11:39 on Thursday, 2026-04-16."
 )
 }

 func test_formatDateTimeShortcutResult_fallsBackToRawOnMalformedInput() {
 let raw = "garbage output"
 XCTAssertEqual(AgentRunner.formatDateTimeShortcutResult(raw), raw)
 }

 // MARK: - calendar + reminders shortcuts

 private struct FakeCalendarListTool: RelayTool {
 let output: String
 var name: String { "calendar_list_events" }
 var description: String { "test calendar list tool" }
 var inputSchema: ToolInputSchema {
 ToolInputSchema(json: #"{"type":"object","properties":{}}"#)
 }
 var isConcurrencySafe: Bool { true }
 var isReadOnly: Bool { true }
 var isDestructive: Bool { false }
 func call(input: ToolInput, context: ToolCallContext) async throws -> ToolResult {
 ToolResult(toolUseId: "", output: output, isError: false)
 }
 }

 private struct FakeRemindersListTool: RelayTool {
 let output: String
 var name: String { "reminders_list" }
 var description: String { "test reminders list tool" }
 var inputSchema: ToolInputSchema {
 ToolInputSchema(json: #"{"type":"object","properties":{}}"#)
 }
 var isConcurrencySafe: Bool { true }
 var isReadOnly: Bool { true }
 var isDestructive: Bool { false }
 func call(input: ToolInput, context: ToolCallContext) async throws -> ToolResult {
 ToolResult(toolUseId: "", output: output, isError: false)
 }
 }

 func test_runner_directDispatch_firesOnExactWhatsOnMyCalendar() async throws {
 let onDevice = MockHostAdapter(profileID: .gemmaLocal, tier: .fast, steps: [])
 let tool = FakeCalendarListTool(output: """
 Found 2 events:
 - 9:00 AM: Standup @ Zoom [Work]
 - 1:00 PM: Lunch with Sarah [Personal]
 """)
 let runner = AgentRunner
 let userMessage: RelayMessage = .user(UserContent(blocks: [.text("What's on my calendar?")]))
 let (stream, continuation) = AsyncThrowingStream<TurnEvent, Error>.makeStream

 async let runnerResult: (state: AgentSessionState, exit: AgentRunner.TurnExit) = {
 let r = await runner.run(
 sessionID: "shortcut-calendar",
 initialUserMessage: userMessage,
 state: .empty,
 contextBuilder: self.makeContextBuilder,
 onDeviceClient: onDevice,
 cloudClient: nil,
 dispatcher: ToolDispatcher,
 toolContextFor: self.makeToolContext,
 tools: [tool],
 toolCatalog: [tool.catalogEntry(source: .builtin)],
 enabledToolNames: ["calendar_list_events"],
 environment: .current,
 extraSystemContext: [:],
 options: .init(),
 continuation: continuation
 )
 continuation.finish()
 return r
 }

 for try await _ in stream {}
 let (newState, exit) = await runnerResult

 XCTAssertEqual(exit, .completed)
 XCTAssertEqual(onDevice.snapshotRequests.count, 0, "shortcut must bypass model loop")
 guard case .assistant(let content) = newState.messages.last else {
 return XCTFail("expected assistant message")
 }
 let text = content.blocks.compactMap { block -> String? in
 if case .text(let t) = block { return t } else { return nil }
 }.joined()
 XCTAssertTrue(text.contains("2 events"), "expected count; got: \(text)")
 XCTAssertTrue(text.contains("Standup"), "expected first event title")
 XCTAssertTrue(text.contains("Lunch with Sarah"), "expected second event title")
 }

 func test_runner_directDispatch_doesNotFireOnLongerCalendarPrompt() async throws {
 let onDevice = MockHostAdapter(
 profileID: .gemmaLocal,
 tier: .fast,
 steps: [
 .response(
 compiledResponse(tier: .fast, text: "Sure, let me check."),
 streamedTokens: ["Sure, let me check."]
 )
 ]
 )
 let tool = FakeCalendarListTool(output: "")
 let runner = AgentRunner
 let userMessage: RelayMessage = .user(UserContent(blocks: [.text("What's on my calendar this Friday at 3 PM about the Q2 review")]))
 let (stream, continuation) = AsyncThrowingStream<TurnEvent, Error>.makeStream

 async let runnerResult: (state: AgentSessionState, exit: AgentRunner.TurnExit) = {
 let r = await runner.run(
 sessionID: "no-shortcut-long-calendar",
 initialUserMessage: userMessage,
 state: .empty,
 contextBuilder: self.makeContextBuilder,
 onDeviceClient: onDevice,
 cloudClient: nil,
 dispatcher: ToolDispatcher,
 toolContextFor: self.makeToolContext,
 tools: [tool],
 toolCatalog: [tool.catalogEntry(source: .builtin)],
 enabledToolNames: ["calendar_list_events"],
 environment: .current,
 extraSystemContext: [:],
 options: .init(),
 continuation: continuation
 )
 continuation.finish()
 return r
 }

 for try await _ in stream {}
 _ = await runnerResult
 XCTAssertGreaterThanOrEqual(onDevice.snapshotRequests.count, 1, "longer prompt must run model")
 }

 func test_formatCalendarListShortcutResult_rendersCleanSentence() {
 let raw = """
 Found 3 events:
 - 9:00 AM: Standup @ Zoom [Work]
 - 1:00 PM: Lunch with Sarah [Personal]
 - 3:30 PM: Design review [Work]
 """
 let out = AgentRunner.formatCalendarListShortcutResult(raw)
 XCTAssertTrue(out.contains("3 events coming up"))
 XCTAssertTrue(out.contains("Standup"))
 XCTAssertTrue(out.contains("Lunch with Sarah"))
 XCTAssertTrue(out.contains("Design review"))
 XCTAssertFalse(out.contains("@"), "location should be stripped")
 XCTAssertFalse(out.contains("[Work]"), "calendar tag should be stripped")
 }

 func test_formatCalendarListShortcutResult_handlesEmptyEvents() {
 XCTAssertEqual(
 AgentRunner.formatCalendarListShortcutResult("No events found in the specified range."),
 "Your calendar is clear for the next 7 days."
 )
 }

 func test_formatCalendarListShortcutResult_passesThroughErrors() {
 let raw = "Error: Calendar access denied."
 XCTAssertEqual(AgentRunner.formatCalendarListShortcutResult(raw), raw)
 }

 /// 2 regression guard — `CalendarListEventsTool`
 /// now emits a "(N more this period)" suffix per row when grouping
 /// collapsed multiple instances of the same title. The shortcut
 /// formatter strips at the first " [" (calendar tag); the new
 /// suffix sits after the tag, so it is dropped cleanly with no
 /// formatter change.
 func test_formatCalendarListShortcutResult_handlesGroupedToolOutput() {
 let raw = """
 Found 14 events (3 unique):
 - 9:00 AM: Standup @ Zoom [Work] (4 more this period)
 - 1:00 PM: Lunch with Sarah [Personal]
 - 3:30 PM: Design review [Work] (1 more this period)
 """
 let out = AgentRunner.formatCalendarListShortcutResult(raw)
 XCTAssertTrue(out.contains("3 events coming up"))
 XCTAssertTrue(out.contains("Standup"))
 XCTAssertTrue(out.contains("Lunch with Sarah"))
 XCTAssertTrue(out.contains("Design review"))
 XCTAssertFalse(out.contains("more this period"), "grouping suffix should be stripped")
 XCTAssertFalse(out.contains("[Work]"), "calendar tag should be stripped")
 XCTAssertFalse(out.contains("@"), "location should be stripped")
 }

 // MARK: - calendar shortcut + range parser tests

 func test_resolveDirectDispatchShortcut_firesOnTomorrow() {
 let userMessage: RelayMessage = .user(UserContent(blocks: [.text("What's on my calendar tomorrow?")]))
 let shortcut = AgentRunner.resolveDirectDispatchShortcut(initialUserMessage: userMessage)
 XCTAssertNotNil(shortcut, "tomorrow variant should fire shortcut")
 XCTAssertEqual(shortcut?.toolName, "calendar_list_events")
 let json = shortcut?.inputJson ?? ""
 XCTAssertTrue(json.contains("\"start_date\""), "input must include start_date")
 XCTAssertTrue(json.contains("\"end_date\""), "input must include end_date")
 // Sanity: tomorrow's range must NOT be the empty-default `"{}"`
 XCTAssertNotEqual(json, "{}", "tomorrow qualifier must produce a date range, not the default")
 }

 func test_resolveDirectDispatchShortcut_firesOnThisWeek() {
 let userMessage: RelayMessage = .user(UserContent(blocks: [.text("What's on my calendar this week?")]))
 let shortcut = AgentRunner.resolveDirectDispatchShortcut(initialUserMessage: userMessage)
 XCTAssertNotNil(shortcut)
 XCTAssertEqual(shortcut?.toolName, "calendar_list_events")
 XCTAssertTrue((shortcut?.inputJson ?? "").contains("\"start_date\""))
 }

 func test_resolveDirectDispatchShortcut_firesOnNextWeek() {
 let userMessage: RelayMessage = .user(UserContent(blocks: [.text("What's on my calendar next week?")]))
 let shortcut = AgentRunner.resolveDirectDispatchShortcut(initialUserMessage: userMessage)
 XCTAssertNotNil(shortcut)
 XCTAssertEqual(shortcut?.toolName, "calendar_list_events")
 XCTAssertTrue((shortcut?.inputJson ?? "").contains("\"start_date\""))
 }

 /// "in my calendar" is a normal English
 /// variant Isaac used on device; the whitelist must honor it so the
 /// shortcut bypass fires instead of dumping the turn into the slow
 /// CPU-prefill on-device Gemma path.
 func test_resolveDirectDispatchShortcut_firesOnInMyCalendarToday() {
 let userMessage: RelayMessage = .user(UserContent(blocks: [.text("What's in my calendar today?")]))
 let shortcut = AgentRunner.resolveDirectDispatchShortcut(initialUserMessage: userMessage)
 XCTAssertNotNil(shortcut, "\"in my calendar today\" variant should fire shortcut")
 XCTAssertEqual(shortcut?.toolName, "calendar_list_events")
 let json = shortcut?.inputJson ?? ""
 XCTAssertTrue(json.contains("\"start_date\""))
 XCTAssertTrue(json.contains("\"end_date\""))
 XCTAssertNotEqual(json, "{}")
 }

 func test_resolveDirectDispatchShortcut_firesOnInMyCalendarTomorrow() {
 let userMessage: RelayMessage = .user(UserContent(blocks: [.text("What's in my calendar tomorrow?")]))
 let shortcut = AgentRunner.resolveDirectDispatchShortcut(initialUserMessage: userMessage)
 XCTAssertNotNil(shortcut)
 XCTAssertEqual(shortcut?.toolName, "calendar_list_events")
 XCTAssertTrue((shortcut?.inputJson ?? "").contains("\"start_date\""))
 }

 func test_calendarRangeJSON_returnsTomorrowDateRangeForTomorrowQualifier() {
 let json = AgentRunner.calendarRangeJSON(forNormalized: "what s on my calendar tomorrow")
 XCTAssertTrue(json.contains("\"start_date\""))
 XCTAssertTrue(json.contains("\"end_date\""))
 XCTAssertNotEqual(json, "{}", "tomorrow must NOT collapse to the default range")

 // Decode start_date and end_date and assert they are exactly one day apart
 // (within 1 second tolerance for the endOfDay -1s arithmetic).
 let payload = json.data(using: .utf8) ?? Data
 let dict = (try? JSONSerialization.jsonObject(with: payload)) as? [String: String] ?? [:]
 let iso = ISO8601DateFormatter()
 iso.formatOptions = [.withInternetDateTime]
 guard let startStr = dict["start_date"], let endStr = dict["end_date"],
 let start = iso.date(from: startStr),
 let end = iso.date(from: endStr) else {
 return XCTFail("invalid ISO dates in payload: \(json)")
 }
 let delta = end.timeIntervalSince(start)
 XCTAssertGreaterThan(delta, 23 * 3600 - 5, "start→end should span ~24 hours")
 XCTAssertLessThan(delta, 24 * 3600 + 5, "start→end should not exceed ~24 hours")
 }

 func test_runner_directDispatch_firesOnExactShowMyReminders() async throws {
 let onDevice = MockHostAdapter(profileID: .gemmaLocal, tier: .fast, steps: [])
 let tool = FakeRemindersListTool(output: """
 Found 2 reminders:
 [ ] Buy groceries (due: 4/17/26, 6:00 PM) [Personal]
 [ ] Submit YC application (due: 4/18/26, 11:59 PM) [Work]
 """)
 let runner = AgentRunner
 let userMessage: RelayMessage = .user(UserContent(blocks: [.text("Show my reminders")]))
 let (stream, continuation) = AsyncThrowingStream<TurnEvent, Error>.makeStream

 async let runnerResult: (state: AgentSessionState, exit: AgentRunner.TurnExit) = {
 let r = await runner.run(
 sessionID: "shortcut-reminders",
 initialUserMessage: userMessage,
 state: .empty,
 contextBuilder: self.makeContextBuilder,
 onDeviceClient: onDevice,
 cloudClient: nil,
 dispatcher: ToolDispatcher,
 toolContextFor: self.makeToolContext,
 tools: [tool],
 toolCatalog: [tool.catalogEntry(source: .builtin)],
 enabledToolNames: ["reminders_list"],
 environment: .current,
 extraSystemContext: [:],
 options: .init(),
 continuation: continuation
 )
 continuation.finish()
 return r
 }

 for try await _ in stream {}
 let (newState, exit) = await runnerResult
 XCTAssertEqual(exit, .completed)
 XCTAssertEqual(onDevice.snapshotRequests.count, 0)
 guard case .assistant(let content) = newState.messages.last else {
 return XCTFail("expected assistant message")
 }
 let text = content.blocks.compactMap { block -> String? in
 if case .text(let t) = block { return t } else { return nil }
 }.joined()
 XCTAssertTrue(text.contains("2 pending"))
 XCTAssertTrue(text.contains("Buy groceries"))
 XCTAssertTrue(text.contains("Submit YC application"))
 }

 func test_runner_directDispatch_doesNotFireOnLongerRemindersPrompt() async throws {
 let onDevice = MockHostAdapter(
 profileID: .gemmaLocal,
 tier: .fast,
 steps: [
 .response(
 compiledResponse(tier: .fast, text: "Sure."),
 streamedTokens: ["Sure."]
 )
 ]
 )
 let tool = FakeRemindersListTool(output: "")
 let runner = AgentRunner
 let userMessage: RelayMessage = .user(UserContent(blocks: [.text("Show my reminders for next week organized by priority")]))
 let (stream, continuation) = AsyncThrowingStream<TurnEvent, Error>.makeStream

 async let runnerResult: (state: AgentSessionState, exit: AgentRunner.TurnExit) = {
 let r = await runner.run(
 sessionID: "no-shortcut-long-reminders",
 initialUserMessage: userMessage,
 state: .empty,
 contextBuilder: self.makeContextBuilder,
 onDeviceClient: onDevice,
 cloudClient: nil,
 dispatcher: ToolDispatcher,
 toolContextFor: self.makeToolContext,
 tools: [tool],
 toolCatalog: [tool.catalogEntry(source: .builtin)],
 enabledToolNames: ["reminders_list"],
 environment: .current,
 extraSystemContext: [:],
 options: .init(),
 continuation: continuation
 )
 continuation.finish()
 return r
 }

 for try await _ in stream {}
 _ = await runnerResult
 XCTAssertGreaterThanOrEqual(onDevice.snapshotRequests.count, 1)
 }

 func test_formatRemindersListShortcutResult_rendersCleanSentence() {
 let raw = """
 Found 2 reminders:
 [ ] Buy groceries (due: 4/17/26, 6:00 PM) [Personal]
 [ ] Submit YC application (due: 4/18/26, 11:59 PM) [Work]
 """
 let out = AgentRunner.formatRemindersListShortcutResult(raw)
 XCTAssertTrue(out.contains("2 pending reminders"))
 XCTAssertTrue(out.contains("Buy groceries"))
 XCTAssertTrue(out.contains("Submit YC application"))
 XCTAssertFalse(out.contains("[Personal]"), "list tag should be stripped")
 XCTAssertFalse(out.contains("[ ]"), "checkbox should be stripped")
 }

 func test_formatRemindersListShortcutResult_handlesEmptyReminders() {
 XCTAssertEqual(
 AgentRunner.formatRemindersListShortcutResult("No reminders found."),
 "You have no pending reminders."
 )
 }

 func test_formatRemindersListShortcutResult_passesThroughErrors() {
 let raw = "Error: Reminders access denied."
 XCTAssertEqual(AgentRunner.formatRemindersListShortcutResult(raw), raw)
 }

 // MARK: - Bug A + Bug B

 /// Bug A regression: validator must run on EVERY iteration of the
 /// turn loop, even after a successful cloud handoff already fired.
 /// Pre-hotfix the `!usedCloudFallback` gate skipped validation
 /// entirely on iter 2+, letting Gemma's post-tool help-desk text
 /// reach the user verbatim. This test reproduces the device-log
 /// shape and asserts the substitution path takes over.
 func test_runner_validatesIter2AfterCloudFallback_substitutesAcknowledgment() async throws {
 let toolUse = ParsedToolCall(id: "echo_1", name: "echo", inputJSON: "{}")
 let onDevice = MockHostAdapter(
 profileID: .gemmaLocal,
 tier: .fast,
 steps: [
 // Iter 1: Gemma produces help-desk text → validator
 // catches it → cloudHandoff path fires.
 .response(
 compiledResponse(tier: .fast, text: "How can I help you today?"),
 streamedTokens: ["How can I help you today?"]
 ),
 // Iter 2 (after cloud + tool result): Gemma produces
 // ANOTHER help-desk text. Pre-hotfix this slipped to
 // user verbatim. Post-hotfix the substitution fires.
 .response(
 compiledResponse(tier: .fast, text: "What can I help you with today?"),
 streamedTokens: ["What can I help you with today?"]
 ),
 ]
 )
 let cloud = MockHostAdapter(
 profileID: .geminiCloud,
 tier: .cloud,
 steps: [
 // Cloud handoff in iter 1: emit a tool call (echo) so
 // the loop progresses to iter 2 with tool result in
 // history. Empty text is fine; toolCall is what matters.
 .response(compiledResponse(tier: .cloud, text: "", toolCalls: [toolUse]))
 ]
 )
 let runner = AgentRunner
 let tool = EchoTool
 let userMessage: RelayMessage = .user(UserContent(blocks: [.text("Hi")]))
 let (stream, continuation) = AsyncThrowingStream<TurnEvent, Error>.makeStream

 async let runnerResult: (state: AgentSessionState, exit: AgentRunner.TurnExit) = {
 let r = await runner.run(
 sessionID: "bugA-postcloud-validator",
 initialUserMessage: userMessage,
 state: .empty,
 contextBuilder: self.makeContextBuilder,
 onDeviceClient: onDevice,
 cloudClient: cloud,
 dispatcher: ToolDispatcher,
 toolContextFor: self.makeToolContext,
 tools: [tool],
 toolCatalog: [tool.catalogEntry(source: .builtin)],
 enabledToolNames: ["echo"],
 environment: .current,
 extraSystemContext: [:],
 options: .init(),
 continuation: continuation
 )
 continuation.finish()
 return r
 }

 for try await _ in stream {}
 let (newState, exit) = await runnerResult

 XCTAssertEqual(exit, .completed)
 // Final assistant message must be the substituted acknowledgment,
 // NOT the help-desk shape Gemma produced on iter 2.
 guard case .assistant(let content) = newState.messages.last else {
 return XCTFail("expected assistant message as last entry")
 }
 let assistantText = content.blocks.compactMap { block -> String? in
 if case .text(let t) = block { return t } else { return nil }
 }.joined()
 XCTAssertEqual(
 assistantText,
 ResponseObedienceValidator.postCloudObedienceFallbackText,
 "expected substitution; got: \(assistantText)"
 )
 XCTAssertFalse(
 assistantText.lowercased().contains("how can i help"),
 "help-desk shape must not leak through"
 )
 XCTAssertFalse(
 assistantText.lowercased().contains("what can i help"),
 "help-desk shape must not leak through"
 )
 }

 /// When cloud fallback is actually invoked but Gemini's response ALSO
 /// fails validation, the user should see the on-device fallback text
 /// without the misleading `Cloud fallback unavailable` disclaimer.
 func test_runner_cloudRejectedByValidator_doesNotClaimUnavailable() async throws {
 let onDevice = MockHostAdapter(
 profileID: .gemmaLocal,
 tier: .fast,
 steps: [
 .response(
 compiledResponse(tier: .fast, text: "How can I help you today?"),
 streamedTokens: ["How can I help you today?"]
 )
 ]
 )
 let cloud = MockHostAdapter(
 profileID: .geminiCloud,
 tier: .cloud,
 steps: [
 .response(
 compiledResponse(tier: .cloud, text: "Hello! How can Glass assist you today?"),
 streamedTokens: ["Hello! How can Glass assist you today?"]
 )
 ]
 )
 let runner = AgentRunner
 let userMessage: RelayMessage = .user(UserContent(blocks: [.text("Hi")]))
 let (stream, continuation) = AsyncThrowingStream<TurnEvent, Error>.makeStream

 async let runnerResult: (state: AgentSessionState, exit: AgentRunner.TurnExit) = {
 let r = await runner.run(
 sessionID: "cloud-validator-reject",
 initialUserMessage: userMessage,
 state: .empty,
 contextBuilder: self.makeContextBuilder,
 onDeviceClient: onDevice,
 cloudClient: cloud,
 dispatcher: ToolDispatcher,
 toolContextFor: self.makeToolContext,
 tools: [],
 enabledToolNames: [],
 environment: .current,
 extraSystemContext: [:],
 options: .init(),
 continuation: continuation
 )
 continuation.finish()
 return r
 }

 var doneText: String?
 for try await event in stream {
 if case .done(let message) = event,
 case .assistant(let content) = message {
 doneText = content.blocks.compactMap { block -> String? in
 if case .text(let t) = block { return t }
 return nil
 }.joined()
 }
 }

 let (newState, exit) = await runnerResult
 XCTAssertEqual(exit, .completed)
 XCTAssertEqual(doneText, "How can I help you today?")
 XCTAssertFalse(doneText?.contains("Cloud fallback unavailable") ?? true)
 XCTAssertEqual(newState.recoveryState.lastContinuationReason, .cloudRetry)
 XCTAssertTrue(newState.recoveryState.cloudFallbackUsedLastTurn)
 }

 /// Bug B regression: when toolMode is elevated to .required (via
 /// `isToolIntent` time/date fast-path) AND on-device Gemma returns
 /// `.message` with empty toolCalls (Gemma ignored forceTools), the
 /// runner must route to cloud where Gemini's `toolConfig.mode = "ANY"`
 /// is more reliable. Reproduces Isaac's `What time is it?` device
 /// turn that came back as a help-desk dodge instead of an actual time.
 func test_runner_routesToCloud_whenToolRequiredAndPrimaryEmitsNoToolCall() async throws {
 let onDevice = MockHostAdapter(
 profileID: .gemmaLocal,
 tier: .fast,
 steps: [
 // Gemma ignored forceTools and emitted a generic
 // non-help-desk text. Validator must NOT fire on this
 // (so we test the Bug B branch in isolation, not Bug A).
 .response(
 compiledResponse(tier: .fast, text: "Sure, one moment."),
 streamedTokens: ["Sure, one moment."]
 )
 ]
 )
 let cloud = MockHostAdapter(
 profileID: .geminiCloud,
 tier: .cloud,
 steps: [
 .response(
 compiledResponse(tier: .cloud, text: "It is 3:47 PM."),
 streamedTokens: ["It is 3:47 PM."]
 )
 ]
 )
 let runner = AgentRunner
 let tool = EchoTool
 // User message MUST trigger isToolIntent so ContextBuilder
 // elevates toolMode to .required. "what time is it" is in the
 // fast-path.
 // #4: "What time is it?" now hits the direct-
 // dispatch shortcut and bypasses the model loop entirely. To
 // exercise the Bug B (toolMode=.required + no tool call) path,
 // use a verb+noun-gate prompt instead — same toolMode elevation,
 // not in the tight time/date whitelist.
 let userMessage: RelayMessage = .user(UserContent(blocks: [.text("Search my files for project notes")]))
 let (stream, continuation) = AsyncThrowingStream<TurnEvent, Error>.makeStream

 async let runnerResult: (state: AgentSessionState, exit: AgentRunner.TurnExit) = {
 let r = await runner.run(
 sessionID: "bugB-tool-required-fallback",
 initialUserMessage: userMessage,
 state: .empty,
 contextBuilder: self.makeContextBuilder,
 onDeviceClient: onDevice,
 cloudClient: cloud,
 dispatcher: ToolDispatcher,
 toolContextFor: self.makeToolContext,
 tools: [tool],
 toolCatalog: [tool.catalogEntry(source: .builtin)],
 enabledToolNames: ["echo"],
 environment: .current,
 extraSystemContext: [:],
 options: .init(),
 continuation: continuation
 )
 continuation.finish()
 return r
 }

 for try await _ in stream {}
 let (newState, _) = await runnerResult

 XCTAssertEqual(
 onDevice.snapshotRequests.count, 1,
 "primary should run exactly once"
 )
 XCTAssertEqual(
 cloud.snapshotRequests.count, 1,
 "Bug B fallback must route to cloud when on-device skipped tool emission under toolMode=.required"
 )
 XCTAssertEqual(newState.recoveryState.cloudFallbackUsedLastTurn, true)
 // Verify primary's request actually had toolMode=.required —
 // otherwise the test isn't exercising the new branch.
 XCTAssertEqual(
 onDevice.snapshotRequests.first?.hostOptions.toolMode,
 .required,
 "primary request should have toolMode=.required (via isToolIntent fast-path on 'what time is it?')"
 )
 }

 /// Bug B regression guard: when toolMode is .required AND primary
 /// DID emit a tool call, the new fallback branch must NOT fire (no
 /// double-route to cloud). Tool result loops naturally as before.
 func test_runner_doesNotDoubleRoute_whenToolCallPresentUnderToolRequired() async throws {
 let toolUse = ParsedToolCall(id: "echo_1", name: "echo", inputJSON: "{}")
 let onDevice = MockHostAdapter(
 profileID: .gemmaLocal,
 tier: .fast,
 steps: [
 // Iter 1: Gemma honors forceTools and emits the tool
 // call. The Bug B branch's `result.toolCalls.isEmpty`
 // check should be false → branch skipped.
 .response(compiledResponse(tier: .fast, text: "", toolCalls: [toolUse])),
 // Iter 2: after tool result, Gemma produces final text.
 .response(
 compiledResponse(tier: .fast, text: "It is 3:47 PM."),
 streamedTokens: ["It is 3:47 PM."]
 )
 ]
 )
 let cloud = MockHostAdapter(
 profileID: .geminiCloud,
 tier: .cloud,
 steps: [
 .response(compiledResponse(tier: .cloud, text: "SHOULD NOT BE CALLED"))
 ]
 )
 let runner = AgentRunner
 let tool = EchoTool
 // #4: "What time is it?" now hits the direct-
 // dispatch shortcut and bypasses the model loop entirely. To
 // exercise the Bug B (toolMode=.required + no tool call) path,
 // use a verb+noun-gate prompt instead — same toolMode elevation,
 // not in the tight time/date whitelist.
 let userMessage: RelayMessage = .user(UserContent(blocks: [.text("Search my files for project notes")]))
 let (stream, continuation) = AsyncThrowingStream<TurnEvent, Error>.makeStream

 async let runnerResult: (state: AgentSessionState, exit: AgentRunner.TurnExit) = {
 let r = await runner.run(
 sessionID: "bugB-no-doubleroute",
 initialUserMessage: userMessage,
 state: .empty,
 contextBuilder: self.makeContextBuilder,
 onDeviceClient: onDevice,
 cloudClient: cloud,
 dispatcher: ToolDispatcher,
 toolContextFor: self.makeToolContext,
 tools: [tool],
 toolCatalog: [tool.catalogEntry(source: .builtin)],
 enabledToolNames: ["echo"],
 environment: .current,
 extraSystemContext: [:],
 options: .init(),
 continuation: continuation
 )
 continuation.finish()
 return r
 }

 for try await _ in stream {}
 _ = await runnerResult

 XCTAssertEqual(
 onDevice.snapshotRequests.count, 2,
 "primary should run twice (iter 1 = tool call, iter 2 = final text)"
 )
 XCTAssertEqual(
 cloud.snapshotRequests.count, 0,
 "cloud must NOT be called when primary already emitted tool call under toolMode=.required"
 )
 }

 // MARK: - Round-6 web-search pre-route

 /// Search-intent prompt pre-routes to cloud regardless of message
 /// count. On-device Gemma is bypassed; cloud handles via grounding.
 func test_runner_preRoutesWebSearchIntent_bypassesOnDevice() async throws {
 let onDevice = MockHostAdapter(
 profileID: .gemmaLocal,
 tier: .fast,
 steps: [
 .response(
 compiledResponse(tier: .fast, text: "SHOULD NOT BE CALLED"),
 streamedTokens: ["SHOULD NOT BE CALLED"]
 )
 ]
 )
 let cloud = MockHostAdapter(
 profileID: .geminiCloud,
 tier: .cloud,
 steps: [
 .response(
 compiledResponse(tier: .cloud, text: "Per Google Search, the YC W26 batch was announced last week."),
 streamedTokens: ["Per Google Search, the YC W26 batch was announced last week."]
 )
 ]
 )
 let runner = AgentRunner
 let userMessage: RelayMessage = .user(UserContent(blocks: [.text("Search the web for the YC W26 batch announcement")]))
 let (stream, continuation) = AsyncThrowingStream<TurnEvent, Error>.makeStream

 async let runnerResult: (state: AgentSessionState, exit: AgentRunner.TurnExit) = {
 let r = await runner.run(
 sessionID: "websearch-preroute",
 initialUserMessage: userMessage,
 state: .empty,
 contextBuilder: self.makeContextBuilder,
 onDeviceClient: onDevice,
 cloudClient: cloud,
 dispatcher: ToolDispatcher,
 toolContextFor: self.makeToolContext,
 tools: [],
 toolCatalog: [],
 enabledToolNames: [],
 environment: .current,
 extraSystemContext: [:],
 options: .init(),
 continuation: continuation
 )
 continuation.finish()
 return r
 }

 for try await _ in stream {}
 let (newState, exit) = await runnerResult

 XCTAssertEqual(exit, .completed)
 XCTAssertEqual(
 onDevice.snapshotRequests.count, 0,
 "web-search pre-route should bypass on-device Gemma"
 )
 XCTAssertEqual(
 cloud.snapshotRequests.count, 1,
 "cloud should be called exactly once via web-search pre-route"
 )
 XCTAssertEqual(newState.recoveryState.cloudFallbackUsedLastTurn, true)
 }

 /// Negative: arbitrary non-search prompts must NOT pre-route.
 func test_runner_doesNotPreRouteNonSearchQueries() async throws {
 let onDevice = MockHostAdapter(
 profileID: .gemmaLocal,
 tier: .fast,
 steps: [
 .response(
 compiledResponse(tier: .fast, text: "Quantum tunneling is..."),
 streamedTokens: ["Quantum tunneling is..."]
 )
 ]
 )
 let cloud = MockHostAdapter(
 profileID: .geminiCloud,
 tier: .cloud,
 steps: [
 .response(
 compiledResponse(tier: .cloud, text: "SHOULD NOT BE CALLED"),
 streamedTokens: ["SHOULD NOT BE CALLED"]
 )
 ]
 )
 let runner = AgentRunner
 let userMessage: RelayMessage = .user(UserContent(blocks: [.text("Tell me about quantum tunneling")]))
 let (stream, continuation) = AsyncThrowingStream<TurnEvent, Error>.makeStream

 async let runnerResult: (state: AgentSessionState, exit: AgentRunner.TurnExit) = {
 let r = await runner.run(
 sessionID: "websearch-no-preroute",
 initialUserMessage: userMessage,
 state: .empty,
 contextBuilder: self.makeContextBuilder,
 onDeviceClient: onDevice,
 cloudClient: cloud,
 dispatcher: ToolDispatcher,
 toolContextFor: self.makeToolContext,
 tools: [],
 toolCatalog: [],
 enabledToolNames: [],
 environment: .current,
 extraSystemContext: [:],
 options: .init(),
 continuation: continuation
 )
 continuation.finish()
 return r
 }

 for try await _ in stream {}
 _ = await runnerResult

 XCTAssertEqual(
 onDevice.snapshotRequests.count, 1,
 "non-search prompts must run on-device"
 )
 XCTAssertEqual(
 cloud.snapshotRequests.count, 0,
 "cloud must not be called when search intent is absent"
 )
 }

 /// per-turn dedupe of idempotent (read-only) tool calls.
 /// When the model emits the same tool call across two iterations
 /// within a turn, the second invocation should hit the cache and
 /// the underlying tool's `call(...)` must run exactly once.
 func test_runner_dedupesIdempotentToolCallsAcrossIterations() async throws {
 final class CountingEchoTool: RelayTool, @unchecked Sendable {
 var name: String { "echo" }
 var description: String { "test echo" }
 var inputSchema: ToolInputSchema {
 ToolInputSchema(json: #"{"type":"object","properties":{}}"#)
 }
 var isConcurrencySafe: Bool { true }
 var isReadOnly: Bool { true }
 var isDestructive: Bool { false }
 private let lock = NSLock
 private var _count = 0
 var count: Int {
 lock.lock; defer { lock.unlock }
 return _count
 }
 func call(input: ToolInput, context: ToolCallContext) async throws -> ToolResult {
 lock.lock
 _count += 1
 lock.unlock
 return ToolResult(toolUseId: "", output: "ok", isError: false)
 }
 }

 let firstCall = ToolUseBlock(id: "call_1", name: "echo", inputJson: "{}")
 let secondCall = ToolUseBlock(id: "call_2", name: "echo", inputJson: "{}")
 let mock = MockModelClient(responses: [
 result(text: "", toolUses: [firstCall]),
 result(text: "", toolUses: [secondCall]),
 result(text: "done"),
 ])
 let runner = AgentRunner
 let echo = CountingEchoTool
 let userMessage: RelayMessage = .user(UserContent(blocks: [.text("run echo twice")]))
 let (stream, continuation) = AsyncThrowingStream<TurnEvent, Error>.makeStream

 async let runnerResult: (state: AgentSessionState, exit: AgentRunner.TurnExit) = {
 let r = await runner.run(
 initialUserMessage: userMessage,
 state: .empty,
 contextBuilder: self.makeContextBuilder,
 onDeviceClient: mock,
 cloudClient: nil,
 dispatcher: ToolDispatcher,
 toolContextFor: self.makeToolContext,
 tools: [echo],
 enabledToolNames: ["echo"],
 environment: .current,
 extraSystemContext: [:],
 options: .init(),
 continuation: continuation
 )
 continuation.finish()
 return r
 }

 for try await _ in stream {}
 _ = await runnerResult

 XCTAssertEqual(
 echo.count, 1,
 "idempotent (isReadOnly) tool must be deduped across iterations within a turn"
 )
 }

 /// Side-effecting (non-read-only) tools must NEVER be deduped — every
 /// model emit re-executes. Regression guard for the dedupe
 /// scope.
 func test_runner_doesNotDedupeSideEffectingTools() async throws {
 final class CountingMutateTool: RelayTool, @unchecked Sendable {
 var name: String { "mutate" }
 var description: String { "test mutate" }
 var inputSchema: ToolInputSchema {
 ToolInputSchema(json: #"{"type":"object","properties":{}}"#)
 }
 var isConcurrencySafe: Bool { false }
 var isReadOnly: Bool { false }
 var isDestructive: Bool { false }
 private let lock = NSLock
 private var _count = 0
 var count: Int {
 lock.lock; defer { lock.unlock }
 return _count
 }
 func call(input: ToolInput, context: ToolCallContext) async throws -> ToolResult {
 lock.lock
 _count += 1
 lock.unlock
 return ToolResult(toolUseId: "", output: "ok", isError: false)
 }
 }

 let firstCall = ToolUseBlock(id: "call_1", name: "mutate", inputJson: "{}")
 let secondCall = ToolUseBlock(id: "call_2", name: "mutate", inputJson: "{}")
 let mock = MockModelClient(responses: [
 result(text: "", toolUses: [firstCall]),
 result(text: "", toolUses: [secondCall]),
 result(text: "done"),
 ])
 let runner = AgentRunner
 let mutate = CountingMutateTool
 let userMessage: RelayMessage = .user(UserContent(blocks: [.text("mutate twice")]))
 let (stream, continuation) = AsyncThrowingStream<TurnEvent, Error>.makeStream

 async let runnerResult: (state: AgentSessionState, exit: AgentRunner.TurnExit) = {
 let r = await runner.run(
 initialUserMessage: userMessage,
 state: .empty,
 contextBuilder: self.makeContextBuilder,
 onDeviceClient: mock,
 cloudClient: nil,
 dispatcher: ToolDispatcher,
 toolContextFor: self.makeToolContext,
 tools: [mutate],
 enabledToolNames: ["mutate"],
 environment: .current,
 extraSystemContext: [:],
 options: .init(),
 continuation: continuation
 )
 continuation.finish()
 return r
 }

 for try await _ in stream {}
 _ = await runnerResult

 XCTAssertEqual(
 mutate.count, 2,
 "non-read-only tool must run on every emit; dedupe must not kick in"
 )
 }

 /// T13 summarization pre-route still wins at high message count —
 /// log signal must be `LONG-CONTEXT-SUMMARIZATION`, not `LONG-CONTEXT`,
 /// because the T13 check runs first. This test asserts behavior, not
 /// log text (no log capture in unit tests today), but confirms the
 /// T13 path is preserved at 10+ messages.
 func test_runner_longContextPreRoute_t13PatternStillRoutesViaT13() async throws {
 let onDevice = MockHostAdapter(
 profileID: .gemmaLocal,
 tier: .fast,
 steps: [
 .response(
 compiledResponse(tier: .fast, text: "wrong"),
 streamedTokens: ["wrong"]
 )
 ]
 )
 let cloud = MockHostAdapter(
 profileID: .geminiCloud,
 tier: .cloud,
 steps: [
 .response(
 compiledResponse(tier: .cloud, text: "Conversation summary from cloud."),
 streamedTokens: ["Conversation summary from cloud."]
 )
 ]
 )
 let runner = AgentRunner
 let priorState = makeStateWithHistory(pairCount: 6)
 let userMessage: RelayMessage = .user(UserContent(blocks: [.text("Summarize our conversation so far")]))
 let (stream, continuation) = AsyncThrowingStream<TurnEvent, Error>.makeStream

 async let runnerResult: (state: AgentSessionState, exit: AgentRunner.TurnExit) = {
 let r = await runner.run(
 sessionID: "longctx-t13-overlap",
 initialUserMessage: userMessage,
 state: priorState,
 contextBuilder: self.makeContextBuilder,
 onDeviceClient: onDevice,
 cloudClient: cloud,
 dispatcher: ToolDispatcher,
 toolContextFor: self.makeToolContext,
 tools: [],
 toolCatalog: [],
 enabledToolNames: [],
 environment: .current,
 extraSystemContext: [:],
 options: .init(),
 continuation: continuation
 )
 continuation.finish()
 return r
 }

 for try await _ in stream {}
 _ = await runnerResult

 // Either pre-route is acceptable — both bypass on-device and
 // route to cloud exactly once.
 XCTAssertEqual(onDevice.snapshotRequests.count, 0)
 XCTAssertEqual(cloud.snapshotRequests.count, 1)
 }

 /// Safety net: when the pattern matches but no cloudClient is
 /// available at runtime, the pre-route still fires (by design — the
 /// outer branch can't introspect cloudClient from streamCompletion),
 /// and the caller's `textOnlyFallback` produces `emptyFallbackMessage`
 /// because pre-route synthesizes `outputText: ""`. User sees the
 /// user-facing fallback sentence, not a hallucinated Gemma summary.
 func test_runner_preRoute_withoutCloudClient_fallsBackToEmptyMessage() async throws {
 let onDevice = MockHostAdapter(
 profileID: .gemmaLocal,
 tier: .fast,
 steps: [
 .response(
 compiledResponse(tier: .fast, text: "If we ran, bad hallucinated summary."),
 streamedTokens: ["If we ran, bad hallucinated summary."]
 )
 ]
 )
 let runner = AgentRunner
 let userMessage: RelayMessage = .user(UserContent(blocks: [.text("Summarize our conversation so far")]))
 let (stream, continuation) = AsyncThrowingStream<TurnEvent, Error>.makeStream

 async let runnerResult: (state: AgentSessionState, exit: AgentRunner.TurnExit) = {
 let r = await runner.run(
 sessionID: "t13-preroute-no-cloud",
 initialUserMessage: userMessage,
 state: .empty,
 contextBuilder: self.makeContextBuilder,
 onDeviceClient: onDevice,
 cloudClient: nil,
 dispatcher: ToolDispatcher,
 toolContextFor: self.makeToolContext,
 tools: [],
 toolCatalog: [],
 enabledToolNames: [],
 environment: .current,
 extraSystemContext: [:],
 options: .init(),
 continuation: continuation
 )
 continuation.finish()
 return r
 }

 for try await _ in stream {}
 let (newState, _) = await runnerResult

 XCTAssertEqual(
 onDevice.snapshotRequests.count, 0,
 "pre-route still fires even without cloudClient — streamCompletion can't introspect outer runtime"
 )
 guard case .assistant(let content) = newState.messages.last else {
 return XCTFail("expected assistant message as last entry")
 }
 let assistantText = content.blocks.compactMap { block -> String? in
 if case .text(let t) = block { return t } else { return nil }
 }.joined()
 XCTAssertEqual(
 assistantText,
 AgentRunner.emptyFallbackMessage,
 "expected emptyFallbackMessage when pre-route fires but cloud is unavailable"
 )
 }
}

private extension Array {
 subscript(safe index: Int) -> Element? {
 indices.contains(index) ? self[index] : nil
 }
}
