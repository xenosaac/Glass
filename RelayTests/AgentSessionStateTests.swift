import XCTest
@testable import Relay

final class AgentSessionStateTests: XCTestCase {

 private func userText(_ text: String, isMeta: Bool = false) -> RelayMessage {
 .user(UserContent(blocks: [.text(text)], isMeta: isMeta))
 }

 private func assistantToolUse(_ id: String, name: String = "echo") -> RelayMessage {
 .assistant(AssistantContent(blocks: [
 .toolUse(ToolUseBlock(id: id, name: name, inputJson: "{}"))
 ]))
 }

 func test_hydrated_derivesTurnCountAndSummaryStateFromCompactBoundary() {
 let history: [RelayMessage] = [
 MessageFactory.compactBoundary(summary: "Older facts"),
 userText("new question"),
 .assistant(AssistantContent(blocks: [.text("answer")]))
 ]

 let hydrated = AgentSessionState.hydrated(from: history)

 XCTAssertEqual(hydrated.turnCount, 1)
 XCTAssertEqual(hydrated.summaryState.latestBoundarySummary, "Older facts")
 XCTAssertEqual(hydrated.summaryState.latestBoundaryMessageIndex, 0)
 XCTAssertEqual(hydrated.summaryState.lastCompactedAtTurnCount, 0)
 }

 func test_hydrated_derivesRecentToolStateFromVisibleToolBatch() {
 let history: [RelayMessage] = [
 userText("run tool"),
 assistantToolUse("call_1"),
 .toolResult([
 ToolResultBlock(toolUseId: "call_1", output: String(repeating: "x", count: 220), isError: false)
 ]),
 .assistant(AssistantContent(blocks: [.text("done")]))
 ]

 let hydrated = AgentSessionState.hydrated(from: history)

 XCTAssertTrue(hydrated.recentToolState.activeToolUses.isEmpty)
 XCTAssertEqual(hydrated.recentToolState.lastCompletedBatch.count, 1)
 XCTAssertEqual(hydrated.recentToolState.lastCompletedBatch[0].toolUseId, "call_1")
 XCTAssertEqual(hydrated.recentToolState.lastCompletedAtTurnCount, 1)
 XCTAssertTrue(hydrated.recentToolState.lastCompletedBatch[0].outputPreview.hasSuffix("..."))
 XCTAssertEqual(hydrated.recentToolState.lastCompletedBatch[0].outputPreview.count, 203)
 }

 func test_hydrated_resetsEphemeralRuntimeState() {
 let history: [RelayMessage] = [
 userText("hello"),
 .assistant(AssistantContent(blocks: [.text("hi")]))
 ]

 let hydrated = AgentSessionState.hydrated(from: history)

 XCTAssertEqual(hydrated.pendingApprovalState, .empty)
 XCTAssertEqual(hydrated.retrievalState, .empty)
 XCTAssertEqual(hydrated.recoveryState, .empty)
 }
}
