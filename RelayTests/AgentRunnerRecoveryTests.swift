import XCTest
@testable import Relay

final class AgentRunnerRecoveryTests: XCTestCase {
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

 private func makeContextBuilder() -> ContextBuilder {
 ContextBuilder(memoryStore: nil)
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

 private func seededHistoryState() -> AgentSessionState {
 AgentSessionState(
 messages: [
 .user(UserContent(blocks: [.text("old user 1")])),
 .assistant(AssistantContent(blocks: [.text("old assistant 1")])),
 .user(UserContent(blocks: [.text("old user 2")])),
 .assistant(AssistantContent(blocks: [.text("old assistant 2")])),
 .user(UserContent(blocks: [.text("old user 3")]))
 ],
 turnCount: 3
 )
 }

 func test_runner_promptTooLong_recoversWithReactiveCompaction() async throws {
 let onDevice = SequenceModelClient(steps: [
 .error(CactusModelHost.HostError.inferenceFailed("prompt too long")),
 .result(result(text: "recovered answer"))
 ])
 let compactorClient = SequenceModelClient(steps: [.result(result(text: "compact summary"))])
 let recoveryCompactor = Compactor(modelClient: compactorClient)
 let runner = AgentRunner

 let (stream, continuation) = AsyncThrowingStream<TurnEvent, Error>.makeStream
 async let runnerResult: (state: AgentSessionState, exit: AgentRunner.TurnExit) = {
 let result = await runner.run(
 initialUserMessage: .user(UserContent(blocks: [.text("new question")])) ,
 state: seededHistoryState,
 contextBuilder: makeContextBuilder,
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

 var recoveryStates: [RecoveryDisplayState] = []
 var clearCount = 0
 var failureCount = 0
 for try await event in stream {
 switch event {
 case .recoveryStateChanged(let state):
 recoveryStates.append(state)
 case .clearProvisionalOutput:
 clearCount += 1
 case .failure:
 failureCount += 1
 default:
 break
 }
 }

 let (newState, exit) = await runnerResult
 XCTAssertEqual(exit, .completed)
 XCTAssertEqual(recoveryStates, [.compactingContext, .retryingAfterContextReduction])
 XCTAssertEqual(clearCount, 1)
 XCTAssertEqual(failureCount, 0)
 XCTAssertEqual(newState.recoveryState.lastExit, .completed)
 XCTAssertEqual(newState.recoveryState.lastContinuationReason, .promptTooLongRetry)
 XCTAssertEqual(newState.recoveryState.recoveryAttemptCountLastTurn, 1)
 XCTAssertEqual(newState.recoveryState.lastWithheldRecoverableError, "prompt too long")
 XCTAssertEqual(newState.summaryState.latestBoundarySummary, "compact summary")
 }

 func test_runner_promptTooLongRetryExhausted_emitsTerminalFailureAfterRetry() async throws {
 let onDevice = SequenceModelClient(steps: [
 .error(CactusModelHost.HostError.inferenceFailed("prompt too long")),
 .error(CactusModelHost.HostError.inferenceFailed("prompt too long again"))
 ])
 let compactorClient = SequenceModelClient(steps: [.result(result(text: "compact summary"))])
 let recoveryCompactor = Compactor(modelClient: compactorClient)
 let runner = AgentRunner

 let (stream, continuation) = AsyncThrowingStream<TurnEvent, Error>.makeStream
 async let runnerResult: (state: AgentSessionState, exit: AgentRunner.TurnExit) = {
 let result = await runner.run(
 initialUserMessage: .user(UserContent(blocks: [.text("new question")])) ,
 state: seededHistoryState,
 contextBuilder: makeContextBuilder,
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

 let (failedState, exit) = await runnerResult
 XCTAssertEqual(failures, ["Inference error: Inference failed: prompt too long again"])
 XCTAssertEqual(failedState.recoveryState.lastExit, .modelError)
 XCTAssertEqual(failedState.recoveryState.lastContinuationReason, .promptTooLongRetry)
 XCTAssertEqual(failedState.recoveryState.lastErrorMessage, "Inference failed: prompt too long again")
 XCTAssertEqual(failedState.recoveryState.recoveryAttemptCountLastTurn, 1)
 if case .modelError(let message) = exit {
 XCTAssertEqual(message, "Inference failed: prompt too long again")
 } else {
 XCTFail("expected .modelError, got \(exit)")
 }
 }

 func test_runner_cloudRetryNetworkFailureFallsBackWithoutFailureEvent() async throws {
 let onDevice = SequenceModelClient(steps: [
 .result(result(text: "on-device draft", cloudHandoff: true))
 ])
 let cloud = SequenceModelClient(steps: [
 .error(GeminiClient.GeminiError.networkError("timeout"))
 ])
 let runner = AgentRunner

 let (stream, continuation) = AsyncThrowingStream<TurnEvent, Error>.makeStream
 async let runnerResult: (state: AgentSessionState, exit: AgentRunner.TurnExit) = {
 let result = await runner.run(
 initialUserMessage: .user(UserContent(blocks: [.text("summarize")])) ,
 state: .empty,
 contextBuilder: makeContextBuilder,
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

 var recoveryStates: [RecoveryDisplayState] = []
 var clearCount = 0
 var failureCount = 0
 var doneText: String?
 for try await event in stream {
 switch event {
 case .recoveryStateChanged(let state):
 recoveryStates.append(state)
 case .clearProvisionalOutput:
 clearCount += 1
 case .failure:
 failureCount += 1
 case .done(let message):
 if case .assistant(let content) = message {
 doneText = content.blocks.compactMap { block -> String? in
 if case .text(let value) = block { return value }
 return nil
 }.joined()
 }
 default:
 break
 }
 }

 let (newState, exit) = await runnerResult
 XCTAssertEqual(exit, .completed)
 XCTAssertEqual(recoveryStates, [.retryingWithCloud])
 XCTAssertEqual(clearCount, 2)
 XCTAssertEqual(failureCount, 0)
 XCTAssertEqual(doneText, "on-device draft\n\n[Cloud fallback unavailable — showing on-device response]")
 XCTAssertEqual(newState.recoveryState.lastContinuationReason, .cloudRetry)
 XCTAssertEqual(newState.recoveryState.lastWithheldRecoverableError, "timeout")
 XCTAssertEqual(newState.recoveryState.recoveryAttemptCountLastTurn, 1)
 XCTAssertTrue(newState.recoveryState.cloudFallbackUsedLastTurn)
 }

 func test_runner_cancellationAfterToolUseCommitsSyntheticInterruptedResults() async throws {
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
 contextBuilder: makeContextBuilder,
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

 var sawToolStarted = false
 var recoveryStates: [RecoveryDisplayState] = []
 var completedResults: [ToolResult] = []
 var failureCount = 0

 for try await event in stream {
 switch event {
 case .toolCallStarted:
 sawToolStarted = true
 task.cancel
 case .recoveryStateChanged(let state):
 recoveryStates.append(state)
 case .toolCallCompleted(_, let result):
 completedResults.append(result)
 case .failure:
 failureCount += 1
 default:
 break
 }
 }

 let (newState, exit) = await task.value
 XCTAssertTrue(sawToolStarted)
 XCTAssertEqual(recoveryStates, [.cleaningUpInterruptedTurn])
 XCTAssertEqual(failureCount, 0)
 XCTAssertEqual(exit, .interrupted)
 XCTAssertTrue(newState.recentToolState.activeToolUses.isEmpty)
 XCTAssertEqual(newState.recoveryState.lastExit, .interrupted)
 XCTAssertEqual(newState.recoveryState.lastContinuationReason, .interruptCleanup)
 XCTAssertEqual(newState.recoveryState.consecutiveFailures, 0)
 XCTAssertEqual(completedResults.count, 1)
 XCTAssertEqual(completedResults.first?.toolUseId, "call_interrupt")
 XCTAssertTrue(completedResults.first?.isError == true)
 XCTAssertEqual(completedResults.first?.output, "Tool interrupted before result")

 guard case .toolResult(let blocks) = newState.messages.last else {
 return XCTFail("expected synthetic toolResult appended on interruption")
 }
 XCTAssertEqual(blocks.count, 1)
 XCTAssertEqual(blocks.first?.output, "Tool interrupted before result")
 }
}
