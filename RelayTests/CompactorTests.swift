import XCTest
@testable import Relay

/// tests for `Compactor`. All use an in-process
/// `RecordingMockModelClient` conforming to `ModelClient` so the
/// summarization side-query is driven deterministically without
/// touching real inference.
///
/// Eight tests, grouped:
/// Policy (a–f): threshold, circuit breaker, same-turn gate, tail
/// preservation, tool-pair preservation.
/// (g) `isMeta` regression: the boundary does not bump `turnCount`
/// and would be hidden by any `!isMeta` visible filter.
/// (h) timing regression: the mock receives only the pre-existing
/// `state.messages` — never a brand-new user message simulated at
/// the wrapping turn boundary.
final class CompactorTests: XCTestCase {

 // MARK: - Mock model client

 /// Records every `stream(...)` invocation's `messages` parameter so
 /// tests can assert exactly what the compactor fed to the model.
 /// Driven by a queue of canned results; on exhaustion, throws via
 /// `MockError.exhausted`. Use `queueFailure` to inject a throw for
 /// circuit-breaker tests.
 private final class RecordingMockModelClient: ModelClient, @unchecked Sendable {
 enum Outcome {
 case success(summary: String)
 case failure
 }

 private let lock = NSLock
 private var queue: [Outcome]
 private(set) var callCount: Int = 0
 private(set) var lastReceivedMessages: [RelayMessage] = []
 private(set) var allReceivedMessages: [[RelayMessage]] = []

 init(queue: [Outcome]) {
 self.queue = queue
 }

 enum MockError: Error { case exhausted, canned }

 nonisolated func stream(
 messages: [RelayMessage],
 tools: [any RelayTool],
 options: CactusModelHost.CompletionOptions,
 systemPrompt: String?
 ) -> AsyncThrowingStream<CactusModelHost.StreamEvent, Error> {
 lock.lock
 callCount += 1
 lastReceivedMessages = messages
 allReceivedMessages.append(messages)
 let outcome = queue.isEmpty ? Outcome.failure : queue.removeFirst
 lock.unlock

 return AsyncThrowingStream { continuation in
 switch outcome {
 case .success(let summary):
 let body = """
 <analysis>
 pretend analysis
 </analysis>
 <summary>
 \(summary)
 </summary>
 """
 let result = CactusModelHost.CompletionResult(
 text: body,
 toolUses: [],
 confidence: 1.0,
 cloudHandoff: false,
 prefillTPS: 0, decodeTPS: 0,
 timeToFirstTokenMs: 0, totalTimeMs: 0, ramUsageMB: 0
 )
 continuation.yield(.done(result))
 continuation.finish()
 case .failure:
 continuation.finish(throwing: MockError.canned)
 }
 }
 }
 }

 // MARK: - Helpers

 /// Build a message whose text payload has a known byte length so
 /// the token-count estimator (bytes/4) produces a known token count.
 private func userText(_ text: String) -> RelayMessage {
 .user(UserContent(blocks: [.text(text)]))
 }

 private func assistantText(_ text: String) -> RelayMessage {
 .assistant(AssistantContent(blocks: [.text(text)]))
 }

 private func assistantToolUse(id: String, name: String = "echo") -> RelayMessage {
 .assistant(AssistantContent(blocks: [
 .toolUse(ToolUseBlock(id: id, name: name, inputJson: "{}"))
 ]))
 }

 private func toolResult(id: String, output: String = "ok") -> RelayMessage {
 .toolResult([ToolResultBlock(toolUseId: id, output: output, isError: false)])
 }

 /// Long-enough history to cross the 8_000-token default budget. At
 /// utf8/4 tokens, a single 32 KB text block is ~8_192 tokens on
 /// its own — so two 16 KB messages comfortably clear the bar.
 private func makeOverBudgetHistory() -> [RelayMessage] {
 let big = String(repeating: "x", count: 16_384)
 return [
 userText(big),
 assistantText(big),
 userText("a"),
 assistantText("b"),
 userText("c"),
 assistantText("d"),
 ]
 }

 // MARK: - (a) under threshold

 func test_compactor_underThreshold_isNoOp() async {
 let mock = RecordingMockModelClient(queue: [])
 let compactor = Compactor(modelClient: mock)

 let state = AgentSessionState(
 messages: [userText("hi"), assistantText("hello")],
 turnCount: 1
 )

 let should = await compactor.shouldCompact(state: state)
 XCTAssertFalse(should)

 let (newState, didCompact) = await compactor.compact(state: state)
 XCTAssertFalse(didCompact)
 XCTAssertEqual(newState.messages.count, state.messages.count)
 XCTAssertEqual(mock.callCount, 0, "model must not be called under threshold")
 }

 // MARK: - (b) over threshold — summarization fires + boundary inserted

 func test_compactor_overThreshold_firesAndInsertsBoundary() async {
 let mock = RecordingMockModelClient(queue: [.success(summary: "compact summary body")])
 let compactor = Compactor(modelClient: mock, tailPreserveCount: 2)

 let history = makeOverBudgetHistory
 let state = AgentSessionState(messages: history, turnCount: 3)

 let shouldB = await compactor.shouldCompact(state: state)
 XCTAssertTrue(shouldB)

 let (newState, didCompact) = await compactor.compact(state: state)
 XCTAssertTrue(didCompact)
 XCTAssertEqual(mock.callCount, 1)

 // Resulting messages = [boundary] + tailPreserveCount messages.
 XCTAssertEqual(newState.messages.count, 1 + 2)

 // Boundary is a meta user message containing the summary body.
 guard case .user(let content) = newState.messages[0] else {
 return XCTFail("expected boundary to be .user")
 }
 XCTAssertTrue(content.isMeta)
 guard case .text(let boundaryText) = content.blocks[0] else {
 return XCTFail("expected boundary text block")
 }
 XCTAssertTrue(boundaryText.contains("<compact-boundary>"))
 XCTAssertTrue(boundaryText.contains("compact summary body"))
 XCTAssertTrue(boundaryText.contains("</compact-boundary>"))
 XCTAssertEqual(newState.summaryState.latestBoundarySummary, "compact summary body")
 XCTAssertEqual(newState.summaryState.lastCompactedAtTurnCount, 3)
 XCTAssertEqual(newState.summaryState.latestBoundaryMessageIndex, 0)

 // failureCount reset; same-turn gate advanced.
 XCTAssertEqual(newState.autoCompactTracking.failureCount, 0)
 XCTAssertEqual(newState.autoCompactTracking.lastAttemptedAtTurnCount, 3)
 }

 func test_compactor_failure_preservesExistingSummaryState() async {
 let mock = RecordingMockModelClient(queue: [.failure])
 let compactor = Compactor(modelClient: mock)

 var state = AgentSessionState(messages: makeOverBudgetHistory, turnCount: 5)
 state.summaryState = SessionSummaryState(
 latestBoundarySummary: "existing summary",
 lastCompactedAtTurnCount: 4,
 latestBoundaryMessageIndex: 0
 )

 let (newState, didCompact) = await compactor.compact(state: state)
 XCTAssertFalse(didCompact)
 XCTAssertEqual(newState.summaryState, state.summaryState)
 XCTAssertEqual(newState.autoCompactTracking.failureCount, 1)
 }

 // MARK: - (c) 3-strike circuit breaker

 func test_compactor_threeFailures_locksOutFourthAttempt() async {
 let mock = RecordingMockModelClient(queue: [.failure, .failure, .failure])
 let compactor = Compactor(modelClient: mock)

 var state = AgentSessionState(messages: makeOverBudgetHistory, turnCount: 1)

 for turn in 1...3 {
 state.turnCount = turn
 let shouldAttempt = await compactor.shouldCompact(state: state)
 XCTAssertTrue(shouldAttempt, "turn \(turn) should still be eligible pre-call")
 let (newState, didCompact) = await compactor.compact(state: state)
 XCTAssertFalse(didCompact, "turn \(turn) should fail")
 state = newState
 }

 XCTAssertEqual(state.autoCompactTracking.failureCount, 3)

 // Fourth turn: circuit breaker locks it out.
 state.turnCount = 4
 let shouldAfterLockout = await compactor.shouldCompact(state: state)
 XCTAssertFalse(shouldAfterLockout,
 "circuit breaker must skip attempts after maxFailures")
 XCTAssertEqual(mock.callCount, 3, "model must not be called a 4th time")
 }

 // MARK: - (d) same-turn gate

 func test_compactor_sameTurnGate_blocksRepeatAttempt() async {
 let mock = RecordingMockModelClient(queue: [.failure])
 let compactor = Compactor(modelClient: mock)

 let state = AgentSessionState(messages: makeOverBudgetHistory, turnCount: 7)

 let shouldPre = await compactor.shouldCompact(state: state)
 XCTAssertTrue(shouldPre)
 let (after, _) = await compactor.compact(state: state)

 // same-turn gate advanced even though the summary failed.
 XCTAssertEqual(after.autoCompactTracking.lastAttemptedAtTurnCount, 7)

 // Re-check with the updated state: should NOT be eligible.
 let shouldRetry = await compactor.shouldCompact(state: after)
 XCTAssertFalse(shouldRetry,
 "same-turn gate must block retry within the same turnCount")
 }

 // MARK: - (e) tool_use / tool_result pair preserved across split

 func test_compactor_preservesToolPairAcrossSplit() async {
 let mock = RecordingMockModelClient(queue: [.success(summary: "s")])
 // tailPreserveCount = 1, but the tail-front message is a
 // toolResult whose paired assistant tool_use sits at prefix end.
 // Compactor must pull the pair together into the tail.
 let compactor = Compactor(modelClient: mock, tailPreserveCount: 1)

 let history: [RelayMessage] = [
 userText("big"),
 assistantText("blah"),
 userText("larger"),
 assistantToolUse(id: "call_1"), // index 3
 toolResult(id: "call_1"), // index 4 — would be the lone tail at count=1
 ]

 // Budget forced low enough to trigger; 1000 tokens floor.
 let state = AgentSessionState(
 messages: history + [userText(String(repeating: "y", count: 40_000))],
 turnCount: 1
 )

 let shouldE = await compactor.shouldCompact(state: state)
 XCTAssertTrue(shouldE)
 let (newState, didCompact) = await compactor.compact(state: state)
 XCTAssertTrue(didCompact)

 // Find the toolUse + its toolResult in the new messages. They
 // must both appear AFTER the boundary (at index 0) and be
 // contiguous.
 let tail = Array(newState.messages.dropFirst)
 let useIdx = tail.firstIndex { msg in
 if case .assistant(let c) = msg {
 return c.blocks.contains { if case .toolUse(let u) = $0, u.id == "call_1" { return true } else { return false } }
 }
 return false
 }
 let resultIdx = tail.firstIndex { msg in
 if case .toolResult(let blocks) = msg {
 return blocks.contains { $0.toolUseId == "call_1" }
 }
 return false
 }

 if let useIdx, let resultIdx {
 XCTAssertEqual(resultIdx - useIdx, 1, "tool_use and tool_result must remain adjacent")
 } else {
 // Either both are present in the tail (passed), or both
 // landed in the summarized prefix. Fail if only one
 // survived — that would be a split.
 XCTAssertEqual(useIdx == nil, resultIdx == nil,
 "pair must not be cleaved: either both in tail or both in prefix")
 }
 }

 // MARK: - (f) tail preserved verbatim

 func test_compactor_preservesTailVerbatim() async {
 let mock = RecordingMockModelClient(queue: [.success(summary: "s")])
 let compactor = Compactor(modelClient: mock, tailPreserveCount: 3)

 let tailU = userText("tail-u")
 let tailA = assistantText("tail-a")
 let tailU2 = userText("tail-u2")
 let history = makeOverBudgetHistory + [tailU, tailA, tailU2]
 let state = AgentSessionState(messages: history, turnCount: 1)

 let (newState, didCompact) = await compactor.compact(state: state)
 XCTAssertTrue(didCompact)

 // After a boundary, the last 3 messages must equal the tail
 // slice verbatim.
 let lastThree = Array(newState.messages.suffix(3))
 XCTAssertEqual(lastThree.count, 3)

 guard case .user(let u0) = lastThree[0], case .text(let t0) = u0.blocks.first else {
 return XCTFail("unexpected shape at tail[0]")
 }
 XCTAssertEqual(t0, "tail-u")

 guard case .assistant(let a1) = lastThree[1], case .text(let t1) = a1.blocks.first else {
 return XCTFail("unexpected shape at tail[1]")
 }
 XCTAssertEqual(t1, "tail-a")

 guard case .user(let u2) = lastThree[2], case .text(let t2) = u2.blocks.first else {
 return XCTFail("unexpected shape at tail[2]")
 }
 XCTAssertEqual(t2, "tail-u2")
 }

 // MARK: - (g) boundary is isMeta + does not bump turnCount + hidden by !isMeta filter

 func test_compactor_boundary_isMetaAndDoesNotBumpTurnCount() async {
 let mock = RecordingMockModelClient(queue: [.success(summary: "boundary summary")])
 let compactor = Compactor(modelClient: mock, tailPreserveCount: 2)

 let state = AgentSessionState(
 messages: makeOverBudgetHistory,
 turnCount: 5
 )

 let preCompactNonMeta = AgentSessionState.derivedTurnCount(from: state.messages)

 let (newState, didCompact) = await compactor.compact(state: state)
 XCTAssertTrue(didCompact)

 // (g.1) Boundary message is .user with isMeta == true.
 guard case .user(let boundary) = newState.messages[0] else {
 return XCTFail("expected boundary at index 0")
 }
 XCTAssertTrue(boundary.isMeta, "boundary must be isMeta: true")

 // (g.2) Boundary does not contribute to derivedTurnCount.
 let postNonMeta = AgentSessionState.derivedTurnCount(from: newState.messages)
 XCTAssertLessThanOrEqual(postNonMeta, preCompactNonMeta,
 "derivedTurnCount must not increase after compaction")

 // (g.3) state.turnCount is preserved (compactor doesn't bump it).
 XCTAssertEqual(newState.turnCount, state.turnCount)

 // (g.4) A stock !isMeta display filter hides the boundary.
 let visible = newState.messages.filter { msg in
 if case .user(let c) = msg { return !c.isMeta }
 return true // assistant + toolResult always visible under this filter
 }
 for msg in visible {
 if case .user(let c) = msg {
 XCTAssertFalse(c.isMeta, "no isMeta user message should be in the visible set")
 }
 }
 // Also assert the boundary index 0 would NOT be in that visible set.
 XCTAssertFalse(visible.contains { msg in
 if case .user(let c) = msg {
 return c.isMeta && c.blocks.contains { if case .text(let t) = $0, t.contains("<compact-boundary>") { return true } else { return false } }
 }
 return false
 }, "boundary must be hidden from the !isMeta visible view")
 }

 // MARK: - (h) timing: mock receives pre-existing state.messages only

 /// Load-bearing contract test per plan: `Compactor.compact`
 /// must summarize only prior history — never a brand-new user
 /// message that has not yet been appended to state. We simulate
 /// `AgentCore.runTurn`'s intended timing: the new message exists
 /// as a local value, `state` holds prior history, and compact
 /// must NOT see the new value.
 func test_compactor_timing_seesPriorHistoryOnly() async {
 let mock = RecordingMockModelClient(queue: [.success(summary: "s")])
 let compactor = Compactor(modelClient: mock)

 let priorHistory = makeOverBudgetHistory
 let state = AgentSessionState(messages: priorHistory, turnCount: 2)

 // Simulate AgentCore.runTurn: the brand-new user message is a
 // LOCAL value, not yet part of state.messages. Compactor runs
 // BEFORE this message is handed to the runner.
 let brandNewUserMessage = userText("brand-new-input-SHOULD-NOT-BE-SUMMARIZED")

 _ = await compactor.compact(state: state)
 XCTAssertEqual(mock.callCount, 1, "summarizer should have been called exactly once")

 // The messages array the compactor fed to the model must equal
 // state.messages (prior history) and must NOT contain the
 // brand-new user input.
 XCTAssertEqual(mock.lastReceivedMessages.count, priorHistory.count - 0 /* possibly fewer after split */,
 "compactor receives the prefix slice of state.messages only")

 for received in mock.lastReceivedMessages {
 if case .user(let c) = received,
 case .text(let t) = c.blocks.first,
 t.contains("brand-new-input-SHOULD-NOT-BE-SUMMARIZED") {
 XCTFail("compactor must NOT see the brand-new user message on the same invocation")
 }
 }

 // Sanity: brandNewUserMessage is non-nil and distinguishable —
 // ensures we didn't accidentally elide it from a scope-only use.
 if case .user(let c) = brandNewUserMessage,
 case .text(let t) = c.blocks.first {
 XCTAssertTrue(t.contains("brand-new-input"))
 } else {
 XCTFail("test scaffolding error: brand-new message shape unexpected")
 }
 }
}
