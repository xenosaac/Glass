import XCTest
@testable import Relay

final class ReplayHarnessTests: XCTestCase {
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

 func test_replayHarness_promptTooLongFixture_replaysRecoveryPath() async throws {
 let harness = ReplayHarness(
 fixtureURL: ReplayHarness.fixtureURL(named: "prompt_too_long_retry.json")
 )

 let execution = try await harness.execute

 XCTAssertEqual(execution.runArtifacts.exit, .completed)
 XCTAssertEqual(
 execution.recoveryEvents,
 [.compactingContext, .clearProvisionalOutput, .retryingAfterContextReduction]
 )
 XCTAssertTrue(execution.currentTurnFocuses.contains { $0.contains("Turn classification: question") })
 XCTAssertTrue(execution.promptSnapshots.contains { $0.contains("# Current turn focus") })
 }

 func test_replayHarness_cloudRetryFixture_replaysWithoutTerminalFailure() async throws {
 let harness = ReplayHarness(
 fixtureURL: ReplayHarness.fixtureURL(named: "cloud_retry_sequence.json")
 )

 let execution = try await harness.execute

 XCTAssertEqual(execution.runArtifacts.exit, .completed)
 XCTAssertEqual(execution.recoveryEvents, [.retryingWithCloud, .clearProvisionalOutput])
 XCTAssertTrue(execution.runArtifacts.recoveryState.cloudFallbackUsedLastTurn)
 XCTAssertTrue(execution.promptSnapshots.contains { $0.contains("Current turn focus") })
 }

 func test_replayHarness_retrievalFixture_keepsSupportScopedToLatestQuestion() async throws {
 let harness = ReplayHarness(
 fixtureURL: ReplayHarness.fixtureURL(named: "retrieval_latest_turn.json")
 )

 let execution = try await harness.execute

 XCTAssertEqual(execution.runArtifacts.exit, .completed)
 XCTAssertTrue(execution.retrievedArtifactCounts.contains(1))
 XCTAssertTrue(execution.currentTurnFocuses.contains { $0.contains("Retrieved context available for this turn:") })
 }

 func test_replayHarness_interruptedToolFixture_preservesToolResultContinuity() async throws {
 let harness = ReplayHarness(
 fixtureURL: ReplayHarness.fixtureURL(named: "interrupted_tool_turn.json")
 )

 let execution = try await harness.execute

 XCTAssertEqual(execution.runArtifacts.exit, .interrupted)
 XCTAssertEqual(
 execution.recoveryEvents,
 [.cleaningUpInterruptedTurn, .clearProvisionalOutput]
 )
 XCTAssertEqual(execution.finalState.recentToolState.activeToolUses, [])
 XCTAssertTrue(
 execution.finalState.messages.contains { message in
 if case .toolResult = message {
 return textContent(of: message).contains("interrupted")
 }
 return false
 }
 )
 }

 func test_replayHarness_sameThreadReferentialFollowupFixture_keepsPreviousAnswerInFocus() async throws {
 let harness = ReplayHarness(
 fixtureURL: ReplayHarness.fixtureURL(named: "same_thread_referential_followup.json")
 )

 let execution = try await harness.execute

 XCTAssertEqual(execution.runArtifacts.exit, .completed)
 XCTAssertTrue(execution.currentTurnFocuses.contains { $0.contains("Turn classification: referentialFollowup") })
 XCTAssertTrue(execution.currentTurnFocuses.contains { $0.contains("assistant: The list describes the goals for refactoring and upgrading various parts of the system architecture across nine main areas.") })
 XCTAssertTrue(execution.currentTurnFocuses.contains { $0.contains("user: What is this about: 1. Harness Contract + PromptCompiler Skeleton") })
 XCTAssertFalse(execution.currentTurnFocuses.contains { $0.contains("Retrieved context available for this turn:") })
 }

 func test_replayHarness_factRecallUnknownNameFixture_anchorsUnknownFactPath() async throws {
 let harness = ReplayHarness(
 fixtureURL: ReplayHarness.fixtureURL(named: "fact_recall_unknown_name.json")
 )

 let execution = try await harness.execute

 XCTAssertEqual(execution.runArtifacts.exit, .completed)
 XCTAssertTrue(execution.currentTurnFocuses.contains { $0.contains("Turn classification: factRecallUnknown") })
 XCTAssertTrue(execution.currentTurnFocuses.contains { $0.contains("Latest visible facts:\n- none available for this turn") })
 XCTAssertTrue(execution.currentTurnFocuses.contains { $0.contains("No visible fact currently answers this recall question. Say you do not know it yet and invite the user to tell you.") })
 XCTAssertFalse(execution.currentTurnFocuses.contains { $0.contains("Retrieved context available for this turn:") })
 let finalAssistant = try XCTUnwrap(execution.runArtifacts.finalAssistantMessage)
 XCTAssertEqual(textContent(of: finalAssistant), "I don't know your name yet. Tell me and I'll remember it.")
 }

 func test_replayHarness_factRecallKnownNameFixture_anchorsKnownFactPath() async throws {
 let harness = ReplayHarness(
 fixtureURL: ReplayHarness.fixtureURL(named: "five_turn_name_recall_final_turn.json")
 )

 let execution = try await harness.execute

 XCTAssertEqual(execution.runArtifacts.exit, .completed)
 XCTAssertTrue(execution.currentTurnFocuses.contains { $0.contains("Turn classification: factRecallKnown") })
 XCTAssertTrue(execution.currentTurnFocuses.contains { $0.contains("Latest visible facts:") })
 XCTAssertTrue(execution.currentTurnFocuses.contains { $0.contains("My name is Isaac. Please remember that.") })
 XCTAssertFalse(execution.currentTurnFocuses.contains { $0.contains("Retrieved context available for this turn:") })
 let finalAssistant = try XCTUnwrap(execution.runArtifacts.finalAssistantMessage)
 XCTAssertEqual(textContent(of: finalAssistant), "Your name is Isaac.")
 }
}
